#!/usr/bin/env python3
"""
sentry-ci-report.py — reports CI workflow outcomes to the shared fleet-infra
Sentry project (org simple-with-us), via raw envelope HTTP (no sentry-sdk
dependency, no GitHub Actions marketplace action).

Invoked by .github/workflows/sentry-ci-report.yml, which listens for
`workflow_run: types: [completed]` across the observed workflows in this
repo and sets the env vars this script reads.  This script itself does not
know about GitHub Actions beyond reading those env vars — all the wiring
lives in the workflow file.

Two independent signals are sent per completed run:
  1. If the run's conclusion warrants an alert (failure / timed_out /
     startup_failure — see ALERT_CONCLUSIONS): a Sentry error event tagged with
     {app, workflow, branch, actor}, carrying the run URL, fingerprinted on
     [ci-failure, app, workflow] so every failure of one workflow groups into
     ONE Sentry issue instead of paging separately every time.
  2. If the run was schedule-triggered (event == "schedule"): a Sentry Crons
     check-in.  HogHunter currently has no scheduled workflows, so
     CRON_SCHEDULES is empty; an unexpected schedule still raises a config-
     drift event instead of minting a silent dead monitor.

The branch is deliberately NOT part of the fingerprint (it was until
2026-08-12).  Branch names are unbounded and short-lived, so including one
minted a brand-new, permanent Sentry issue for every (workflow, branch) pair.

The `app` tag + fingerprint component are required: fleet-infra is shared
across repos, and this repo shares workflow names ("CI") with peer apps.

Secrets: SENTRY_FLEET_DSN is read only from the environment (set by the
workflow from the repo secret) and is NEVER printed or logged in any form,
including in exception messages.

Gold copy: BotFleet origin/main, itself from Usage-Monitor PR #1394.
Adapted for HogHunter (APP = "hoghunter").
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

# This repo's identity in the shared fleet-infra project.
APP = "hoghunter"

# Keyed by the workflow's DISPLAY NAME (its `name:`).  HogHunter has no
# `schedule:` triggers today; keep this empty rather than inventing monitors
# that would immediately page as missed.  If a cron lane is added, put its
# display name and expression here in the same PR.
CRON_SCHEDULES: dict[str, str] = {}

DEFAULT_CHECKIN_MARGIN_MINUTES = 15
CRON_CHECKIN_MARGIN_OVERRIDES: dict[str, int] = {}
_CRON_CHECKIN_MARGIN_FOLDED = {
    name.casefold(): margin for name, margin in CRON_CHECKIN_MARGIN_OVERRIDES.items()
}
_CRON_SCHEDULES_FOLDED = {name.casefold(): expr for name, expr in CRON_SCHEDULES.items()}

WORKFLOWS_DIR = Path(__file__).resolve().parent.parent / ".github" / "workflows"

ALERT_CONCLUSIONS = frozenset({"failure", "timed_out", "startup_failure"})

MONITOR_SLUG_MAX_LEN = 50


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    slug = re.sub(r"-+", "-", slug)
    return slug


def monitor_slug(app: str, workflow_name: str) -> str:
    """The Sentry Crons monitor slug for a workflow, guaranteed <= 50 chars."""
    slug = f"ci-{app}-{slugify(workflow_name)}"
    return slug[:MONITOR_SLUG_MAX_LEN].rstrip("-")


def discover_workflow_names(workflows_dir: Path = WORKFLOWS_DIR) -> set[str] | None:
    """Return the `name:` of every workflow under .github/workflows."""
    if not workflows_dir.is_dir():
        return None
    names: set[str] = set()
    for path in sorted(workflows_dir.glob("*.y*ml")):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            match = re.match(r"^name:\s*(.+?)\s*$", line)
            if match:
                names.add(match.group(1).strip().strip("\"'"))
                break
    return names


def find_cron_schedule_drift(known_names: set[str] | None) -> list[str]:
    """CRON_SCHEDULES keys that match no real workflow `name:`."""
    if not known_names:
        return []
    folded = {name.casefold() for name in known_names}
    return sorted(key for key in CRON_SCHEDULES if key.casefold() not in folded)


def parse_dsn(dsn: str) -> tuple[str, str, str]:
    """Parse a Sentry DSN into (public_key, host, project_id).

    Raises ValueError without ever including the raw DSN in the message.
    """
    match = re.match(r"^https://([^@]+)@([^/]+)/(.+)$", dsn.strip())
    if not match:
        raise ValueError(
            "SENTRY_FLEET_DSN is not in the expected https://<key>@<host>/<project> shape"
        )
    return match.group(1), match.group(2), match.group(3)


def send_envelope(envelope_url: str, auth_header: str, item_type: str, item_payload: dict) -> None:
    item_body = json.dumps(item_payload).encode("utf-8")
    envelope_header = json.dumps(
        {"sent_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    ).encode("utf-8")
    item_header = json.dumps({"type": item_type, "length": len(item_body)}).encode("utf-8")
    body = envelope_header + b"\n" + item_header + b"\n" + item_body + b"\n"

    request = urllib.request.Request(
        envelope_url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/x-sentry-envelope",
            "X-Sentry-Auth": auth_header,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as resp:
            print(f"Sentry envelope POST ({item_type}) -> HTTP {resp.status}")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        print(f"::warning::Sentry envelope POST ({item_type}) failed: HTTP {exc.code}: {detail}")
    except urllib.error.URLError as exc:
        print(f"::warning::Sentry envelope POST ({item_type}) failed: {exc.reason}")
    except Exception as exc:  # noqa: BLE001 — fail open on ANY transient network error
        print(f"::warning::Sentry envelope POST ({item_type}) failed: {type(exc).__name__}")


def send_config_drift_event(
    envelope_url: str,
    auth_header: str,
    kind: str,
    message: str,
    fingerprint: list[str],
    extra: dict,
) -> None:
    payload = {
        "event_id": uuid.uuid4().hex,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "platform": "other",
        "level": "warning",
        "environment": "fleet-ci",
        "message": message,
        "tags": {"app": APP, "drift": kind},
        "extra": extra,
        "fingerprint": fingerprint,
    }
    send_envelope(envelope_url, auth_header, "event", payload)


def main() -> int:
    dsn = os.environ.get("SENTRY_FLEET_DSN", "").strip()
    workflow_name = os.environ.get("WORKFLOW_NAME", "unknown")
    conclusion = os.environ.get("WORKFLOW_CONCLUSION", "unknown")
    event = os.environ.get("WORKFLOW_EVENT", "unknown")
    branch = os.environ.get("WORKFLOW_BRANCH", "unknown")
    actor = os.environ.get("WORKFLOW_ACTOR", "unknown")
    run_url = os.environ.get("WORKFLOW_RUN_URL", "")
    run_id = os.environ.get("WORKFLOW_RUN_ID", "")

    if not dsn:
        print("::warning::SENTRY_FLEET_DSN secret is not set; skipping Sentry report for this run.")
        return 0

    try:
        public_key, host, project_id = parse_dsn(dsn)
    except ValueError as exc:
        print(f"::error::{exc}")
        return 0

    envelope_url = f"https://{host}/api/{project_id}/envelope/"
    auth_header = (
        f"Sentry sentry_version=7, sentry_client=sentry-ci-report/1.0, sentry_key={public_key}"
    )

    stale_keys = find_cron_schedule_drift(discover_workflow_names())
    if stale_keys:
        joined = ", ".join(repr(key) for key in stale_keys)
        print(
            f"::error::CRON_SCHEDULES key(s) {joined} match no workflow `name:` under "
            ".github/workflows/ — those cron check-ins are not being sent.  "
            "Re-key CRON_SCHEDULES in scripts/sentry-ci-report.py to the current name."
        )
        send_config_drift_event(
            envelope_url,
            auth_header,
            "stale-cron-key",
            f"sentry-ci-report CRON_SCHEDULES has stale workflow name(s): {joined} [{APP}]",
            ["ci-report-config-drift", APP, "stale-cron-key"],
            {"stale_keys": stale_keys, "run_url": run_url},
        )

    if conclusion in ALERT_CONCLUSIONS:
        event_payload = {
            "event_id": uuid.uuid4().hex,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "platform": "other",
            "level": "error",
            "environment": "fleet-ci",
            "message": f"CI workflow {conclusion}: {workflow_name} [{APP}]",
            "tags": {"app": APP, "workflow": workflow_name, "branch": branch, "actor": actor},
            "extra": {"run_url": run_url, "run_id": run_id, "branch": branch},
            "fingerprint": ["ci-failure", APP, workflow_name],
        }
        send_envelope(envelope_url, auth_header, "event", event_payload)
        print(f"Sent Sentry {conclusion} event for workflow '{workflow_name}' on branch '{branch}'.")
    else:
        print(f"Workflow '{workflow_name}' concluded '{conclusion}' (no alert); no error event sent.")

    if event == "schedule":
        cron_expr = _CRON_SCHEDULES_FOLDED.get(workflow_name.casefold())
        if not cron_expr:
            print(
                f"::warning::Schedule-triggered run for '{workflow_name}' has no known cron "
                "expression mapped in CRON_SCHEDULES; skipping check-in."
            )
            send_config_drift_event(
                envelope_url,
                auth_header,
                "unmapped-schedule",
                f"sentry-ci-report has no CRON_SCHEDULES entry for scheduled workflow "
                f"'{workflow_name}' [{APP}]",
                ["ci-report-config-drift", APP, "unmapped-schedule", workflow_name],
                {"workflow": workflow_name, "run_url": run_url, "run_id": run_id},
            )
        else:
            checkin_status = "ok" if conclusion == "success" else "error"
            slug = monitor_slug(APP, workflow_name)
            checkin_margin = _CRON_CHECKIN_MARGIN_FOLDED.get(
                workflow_name.casefold(), DEFAULT_CHECKIN_MARGIN_MINUTES
            )
            checkin_payload = {
                "check_in_id": uuid.uuid4().hex,
                "monitor_slug": slug,
                "status": checkin_status,
                "monitor_config": {
                    "schedule": {"type": "crontab", "value": cron_expr},
                    "checkin_margin": checkin_margin,
                    "max_runtime": 60,
                    "timezone": "UTC",
                },
            }
            send_envelope(envelope_url, auth_header, "check_in", checkin_payload)
            print(
                f"Sent Sentry Crons check-in '{checkin_status}' for monitor '{slug}' "
                f"(workflow '{workflow_name}')."
            )
    else:
        print(
            f"Workflow '{workflow_name}' was triggered by '{event}' (not schedule); "
            "no cron check-in sent."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())

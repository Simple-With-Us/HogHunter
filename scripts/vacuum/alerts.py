from __future__ import annotations

import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any, Optional

from .config import expand_path, load_config
from .store import VacuumStore

LAUNCHD_LABEL = "com.simplewithus.hoghunter.robotic-vacuum"


@dataclass
class AlertDecision:
    should_notify: bool
    kind: str
    message: str
    recovered: bool = False


def launchd_loaded(home_label: str = LAUNCHD_LABEL) -> bool:
    if sys.platform != "darwin":
        return True
    try:
        uid = subprocess.check_output(["id", "-u"], text=True).strip()
        domain = f"gui/{uid}"
        out = subprocess.check_output(["launchctl", "print", f"{domain}/{home_label}"], text=True, stderr=subprocess.DEVNULL)
        return "path =" in out or "program =" in out
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return False


def evaluate_alerts(store: VacuumStore, cfg: dict[str, Any], now: float | None = None) -> list[AlertDecision]:
    now = now or time.time()
    intervals = cfg.get("intervals_seconds", {})
    mult = float(cfg.get("overdue_multiplier", 1.5))
    state = store.load_alert_state()
    decisions: list[AlertDecision] = []

    if sys.platform == "darwin" and not launchd_loaded():
        decisions.append(_dedupe(
            state,
            key="launchd_missing",
            active=AlertDecision(True, "launchd_missing", "Robotic Vacuum is not loaded in the background.  Scheduled cleaning will not run until you install or reload it."),
            recovered_message="Robotic Vacuum is loaded again.  Scheduled cleaning resumed.",
            now=now,
        ))

    for trigger, interval in (("watch", intervals.get("watch", 300)), ("janitor", intervals.get("janitor", 1800)), ("full", intervals.get("full", 14400))):
        last = store.last_run_for(trigger)
        if not last:
            continue
        ended = float(last.get("ended_at") or last.get("started_at") or 0)
        if ended <= 0:
            continue
        overdue_sec = float(interval) * mult
        if now - ended > overdue_sec:
            title = {"watch": "pressure check", "janitor": "worktree janitor", "full": "full vacuum"}[trigger]
            decisions.append(_dedupe(
                state,
                key=f"overdue_{trigger}",
                active=AlertDecision(
                    True,
                    f"overdue_{trigger}",
                    f"The scheduled {title} has not finished in time.  Last run was {int((now - ended) / 60)} minutes ago.",
                ),
                recovered_message=f"The scheduled {title} is running on time again.",
                now=now,
            ))

    history = store.load_history()
    if history:
        last = history[-1]
        fails = [s for s in (last.get("steps") or []) if s.get("status") == "failed"]
        if fails and int(last.get("exit_code", 0)) != 0:
            decisions.append(_dedupe(
                state,
                key="run_failed",
                active=AlertDecision(
                    True,
                    "run_failed",
                    f"The last cleaning run reported {len(fails)} failed step(s).  Open Robotic Vacuum for details.",
                ),
                recovered_message="The latest cleaning run completed without failures.",
                now=now,
            ))

    store.save_alert_state(state)
    return [d for d in decisions if d.should_notify]


def _dedupe(
    state: dict[str, Any],
    key: str,
    active: AlertDecision,
    recovered_message: str,
    now: float,
) -> AlertDecision:
    prev = state.get(key, {})
    was_active = bool(prev.get("active"))
    if active.should_notify:
        if not was_active or (now - float(prev.get("last_sent", 0)) > 3600):
            state[key] = {"active": True, "last_sent": now}
            return active
        return AlertDecision(False, active.kind, active.message)
    if was_active:
        state[key] = {"active": False, "last_sent": now}
        return AlertDecision(True, key, recovered_message, recovered=True)
    state[key] = {"active": False, "last_sent": prev.get("last_sent", 0)}
    return AlertDecision(False, active.kind, active.message)


def notify_macos(title: str, body: str) -> None:
    if sys.platform != "darwin":
        return
    script = f'display notification "{_escape_apple(body)}" with title "{_escape_apple(title)}"'
    try:
        subprocess.run(["osascript", "-e", script], check=False, timeout=10)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass


def _escape_apple(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')

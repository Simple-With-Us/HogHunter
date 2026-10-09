"""Retire merged lanes.

Candidates come ONLY from the lane doctor through vacuum.lanes.  The old heuristics (branch-name PR match,
git status without --ignored, no unpushed or process check) are gone: a squash-merged branch name can be
reused, an ignored env file or database is invisible to a plain git status, and a lane someone is standing
in looked idle.  Removal is `git worktree remove` WITHOUT force; a non-zero exit is logged and the run
carries on with the next lane.
"""
from __future__ import annotations

import re
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, NamedTuple, Optional

from . import lanes
from .config import expand_path

Runner = Callable[..., "subprocess.CompletedProcess[str]"]

DETAIL_LIMIT = 600
NEVER_MATCH = r"(?!)"


class RetireOutcome(NamedTuple):
    retired: int
    bytes_freed: int
    detail: str
    actions: list


@dataclass
class RetirePlan:
    """What a run would retire, and why everything else was refused.  ok False means the doctor was
    unusable (reason says why) and nothing may be removed."""

    ok: bool
    reason: str = ""
    choices: list = field(default_factory=list)
    refused: list = field(default_factory=list)
    generated_at: str = ""
    doctor_seconds: float = 0.0
    dry_run: bool = False

    def as_dict(self) -> dict:
        return {
            "ok": self.ok,
            "reason": self.reason,
            "dry_run": self.dry_run,
            "report_generated_at": self.generated_at,
            "doctor_seconds": round(self.doctor_seconds, 1),
            "candidates": [c.as_dict() for c in self.choices],
            "refused": list(self.refused),
        }


def keep_regex(cfg: dict[str, Any]) -> "re.Pattern[str]":
    """Compile the keep list.  An empty pattern means no keep list (re.compile('') would match everything)."""
    return re.compile(cfg.get("keep_worktree_regex") or NEVER_MATCH)


def plan_retire_worktrees(
    cfg: dict[str, Any],
    home: Path,
    runner: Runner,
    *,
    report: Any = None,
    doctor_runner: Optional[lanes.DoctorRunner] = None,
    clock: Callable[[], float] = time.time,
    dry_run: bool = False,
) -> RetirePlan:
    """Ask the doctor which lanes are removable and re-check each one.  Plans only; it never removes.
    report is a LaneReport, or a callable that returns one (the engine passes its cached loader, so a
    disabled step or an invalid keep regex never pays for a doctor run).  Raises re.error for an invalid
    keep regex so the engine can record a failed step."""
    janitor_cfg = cfg.get("janitor", {})
    if not janitor_cfg.get("reap_worktrees", True):
        return RetirePlan(ok=False, reason="worktree retirement disabled", dry_run=dry_run)
    keep_re = keep_regex(cfg)
    settings = lanes.lane_settings(cfg, home)
    if callable(report):
        report = report()
    if report is None:
        report = lanes.load_report(settings, home, doctor_runner, clock)
    ctx = lanes.LaneContext(home, keep_re, settings, runner, clock)
    scan = lanes.removable_lanes(report, ctx)
    return RetirePlan(
        ok=scan.ok,
        reason=scan.reason,
        choices=scan.choices,
        refused=scan.refused,
        generated_at=scan.generated_at,
        doctor_seconds=scan.doctor_seconds,
        dry_run=dry_run,
    )


def _clip(parts: list[str]) -> str:
    """Join the per-lane notes for the step reason without cutting one in half.  The first note is always
    whole (it carries the exact command); later ones are dropped, with a count, once the limit is reached.
    The full list is in the action log."""
    out: list[str] = []
    used = 0
    for index, part in enumerate(parts):
        if out and used + len(part) + 2 > DETAIL_LIMIT:
            out.append(f"... (+{len(parts) - index} more, see {lanes.ACTION_LOG_NAME})")
            break
        out.append(part)
        used += len(part) + 2
    return "; ".join(out)


def apply_retire_worktrees(
    plan: RetirePlan,
    cfg: dict[str, Any],
    home: Path,
    runner: Runner,
    dry_run: bool = False,
    clock: Callable[[], float] = time.time,
    data_dir: Optional[Path] = None,
) -> RetireOutcome:
    """Remove the planned lanes.  Each one is re-checked immediately before its removal, so a lane that
    changed since planning is skipped and logged.  Dry run returns what would happen and removes nothing."""
    actions: list[dict[str, Any]] = []
    if not plan.ok:
        reason = plan.reason or "unknown reason"
        return RetireOutcome(0, 0, f"lane doctor unusable: {reason}; nothing removed", actions)
    if not plan.choices:
        note = f"no lanes eligible ({len(plan.refused)} refused)" if plan.refused else "no lanes eligible"
        return RetireOutcome(0, 0, note, actions)

    ctx = lanes.LaneContext(home, keep_regex(cfg), lanes.lane_settings(cfg, home), runner, clock)
    retired = 0
    freed = 0
    parts: list[str] = []

    def record(entry: dict[str, Any]) -> None:
        actions.append(entry)
        if data_dir is not None and not dry_run:
            lanes.append_action_log(data_dir, {"step_id": "janitor_worktree_retire", **entry})

    for choice in plan.choices:
        size_text = lanes.format_size(choice.size_bytes)
        if dry_run:
            record({"action": "would-retire", **choice.as_dict()})
            parts.append(f"would-retire {choice.path} ({size_text}) via {shlex.join(choice.command)}")
            continue
        repo_root, why = lanes.recheck_for_removal(choice.path, choice.checkout, ctx)
        if why:
            record({"action": "skipped", "path": choice.path, "reason": why, "size_bytes": choice.size_bytes})
            parts.append(f"skipped {choice.path}: {why}")
            continue
        argv = lanes.removal_argv(repo_root, choice.path)
        command = shlex.join(argv)
        res, err = lanes.call(runner, argv, 120.0, env=lanes.git_env())
        if res is None:
            record(
                {"action": "failed", "path": choice.path, "size_bytes": choice.size_bytes, "command": command, "error": err}
            )
            parts.append(f"failed {choice.path} ({size_text}): {err}")
            continue
        if res.returncode != 0:
            tail = " ".join((res.stderr or "").split())[:200]
            record(
                {
                    "action": "failed",
                    "path": choice.path,
                    "size_bytes": choice.size_bytes,
                    "command": command,
                    "exit": res.returncode,
                    "error": tail,
                }
            )
            parts.append(f"failed {choice.path} ({size_text}): git exited {res.returncode} {tail}".rstrip())
            continue
        retired += 1
        freed += choice.size_bytes or 0
        record(
            {
                "action": "retired",
                "path": choice.path,
                "branch": choice.branch,
                "head_sha": choice.head_sha,
                "size_bytes": choice.size_bytes,
                "command": command,
                "exit": 0,
                "reasons": list(choice.reasons),
            }
        )
        parts.append(f"retired {choice.path} ({size_text}) via {command}")
    return RetireOutcome(retired, freed, _clip(parts) if parts else "no worktrees retired", actions)


def retire_worktrees(
    cfg: dict[str, Any],
    home: Path,
    runner: Runner,
    dry_run: bool = False,
    plan: Optional[RetirePlan] = None,
    report: Optional[lanes.LaneReport] = None,
    doctor_runner: Optional[lanes.DoctorRunner] = None,
    clock: Callable[[], float] = time.time,
    data_dir: Optional[Path] = None,
) -> RetireOutcome:
    """Plan (unless a plan is passed in) and apply.  With dry_run true nothing is removed and the outcome
    lists what would happen, command and size included."""
    janitor_cfg = cfg.get("janitor", {})
    if not janitor_cfg.get("reap_worktrees", True):
        return RetireOutcome(0, 0, "worktree retirement disabled", [])
    if plan is None:
        plan = plan_retire_worktrees(
            cfg, home, runner, report=report, doctor_runner=doctor_runner, clock=clock, dry_run=dry_run
        )
    return apply_retire_worktrees(plan, cfg, home, runner, dry_run=dry_run, clock=clock, data_dir=data_dir)


def data_dir_for(cfg: dict[str, Any], home: Path) -> Optional[Path]:
    value = str(cfg.get("data_dir") or "").strip()
    if not value:
        return None
    try:
        return expand_path(value, home)
    except ValueError:
        return None

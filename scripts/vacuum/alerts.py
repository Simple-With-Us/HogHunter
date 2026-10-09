from __future__ import annotations

import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .store import VacuumStore

LAUNCHD_LABEL = "com.simplewithus.hoghunter.robotic-vacuum"

# Set to any value but 0, false, no, off, or empty and notify_macos posts nothing.  Tests and dry runs set it
# so that a Mac never shows a real banner from code that was only meant to be exercised.
NO_NOTIFY_ENV = "HOGHUNTER_NO_NOTIFY"
_FALSY = frozenset({"", "0", "false", "no", "off"})


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


def notifications_suppressed(env: Mapping[str, str] | None = None) -> bool:
    env = os.environ if env is None else env
    return env.get(NO_NOTIFY_ENV, "").strip().lower() not in _FALSY


def plist_path(home: Path) -> Path:
    return home / "Library" / "LaunchAgents" / f"{LAUNCHD_LABEL}.plist"


def _is_real_tick(record: Any) -> bool:
    return isinstance(record, dict) and not record.get("dry_run")


def vacuum_ever_installed(store: VacuumStore, cfg: dict[str, Any], home: Path | None = None) -> bool:
    """True once the Vacuum has been installed or the owner asked to hear about it being absent.

    Any one of these is enough: its launch agent plist is on disk, history.json already holds a real (not dry
    run) record, or `alerts.alert_when_not_installed` is true in the config (default false).  A Vacuum that was
    never installed has nothing to be unloaded, so it must not nag."""
    block = cfg.get("alerts")
    if isinstance(block, dict) and block.get("alert_when_not_installed") is True:
        return True
    if os.path.exists(str(plist_path(Path(home) if home else store.home))):
        return True
    return any(_is_real_tick(r) for r in store.load_history())


def evaluate_alerts(
    store: VacuumStore, cfg: dict[str, Any], now: float | None = None, home: Path | None = None
) -> list[AlertDecision]:
    now = now or time.time()
    intervals = cfg.get("intervals_seconds", {})
    mult = float(cfg.get("overdue_multiplier", 1.5))
    state = store.load_alert_state()
    decisions: list[AlertDecision] = []

    if sys.platform == "darwin" and not vacuum_ever_installed(store, cfg, home):
        # Never installed: stay quiet, and drop any stale "active" flag without a "loaded again" banner for
        # something that was never loaded.
        prev = state.get("launchd_missing", {})
        state["launchd_missing"] = {"active": False, "last_sent": prev.get("last_sent", 0)}
        decisions.append(AlertDecision(False, "launchd_missing", ""))
    else:
        launchd_ok = launchd_loaded() if sys.platform == "darwin" else True
        decisions.append(
            _dedupe(
                state,
                key="launchd_missing",
                condition_active=sys.platform == "darwin" and not launchd_ok,
                kind="launchd_missing",
                active_message="Robotic Vacuum is not loaded in the background.  Scheduled cleaning will not run until you install or reload it.",
                recovered_message="Robotic Vacuum is loaded again.  Scheduled cleaning resumed.",
                now=now,
            )
        )

    for trigger, interval in (("watch", intervals.get("watch", 300)), ("janitor", intervals.get("janitor", 1800)), ("full", intervals.get("full", 14400))):
        last = store.last_run_for(trigger)
        is_overdue = False
        if last:
            ended = float(last.get("ended_at") or last.get("started_at") or 0)
            if ended > 0 and (now - ended) > float(interval) * mult:
                is_overdue = True
        title = {"watch": "pressure check", "janitor": "worktree janitor", "full": "full vacuum"}[trigger]
        decisions.append(
            _dedupe(
                state,
                key=f"overdue_{trigger}",
                condition_active=is_overdue,
                kind=f"overdue_{trigger}",
                active_message=f"The scheduled {title} has not finished in time.",
                recovered_message=f"The scheduled {title} is running on time again.",
                now=now,
            )
        )

    run_failed = False
    history = store.load_history()
    if history:
        last = history[-1]
        fails = [s for s in (last.get("steps") or []) if s.get("status") == "failed"]
        run_failed = bool(fails) and int(last.get("exit_code", 0)) != 0
    decisions.append(
        _dedupe(
            state,
            key="run_failed",
            condition_active=run_failed,
            kind="run_failed",
            active_message="The last cleaning run reported failed step(s).  Open Robotic Vacuum for details.",
            recovered_message="The latest cleaning run completed without failures.",
            now=now,
        )
    )

    store.save_alert_state(state)
    return [d for d in decisions if d.should_notify]


def _dedupe(
    state: dict[str, Any],
    key: str,
    condition_active: bool,
    kind: str,
    active_message: str,
    recovered_message: str,
    now: float,
) -> AlertDecision:
    prev = state.get(key, {})
    was_active = bool(prev.get("active"))
    if condition_active:
        if not was_active or (now - float(prev.get("last_sent", 0)) > 3600):
            state[key] = {"active": True, "last_sent": now}
            return AlertDecision(True, kind, active_message)
        return AlertDecision(False, kind, active_message)
    if was_active:
        state[key] = {"active": False, "last_sent": now}
        return AlertDecision(True, kind, recovered_message, recovered=True)
    state[key] = {"active": False, "last_sent": prev.get("last_sent", 0)}
    return AlertDecision(False, kind, active_message)


def notify_macos(title: str, body: str) -> None:
    if notifications_suppressed():
        return
    if sys.platform != "darwin":
        return
    script = f'display notification "{_escape_apple(body)}" with title "{_escape_apple(title)}"'
    try:
        subprocess.run(["osascript", "-e", script], check=False, timeout=10)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass


def _escape_apple(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')

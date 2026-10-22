#!/usr/bin/env python3
"""Maintain — Hog Hunter scheduled Mac cleaning.

Replaces com.jay.mac-cleanup, com.jay.disk-janitor, and com.jay.mac-resource-watch
with a single launchd agent driven from this repo.  `scripts/robotic-vacuum.py` is a
backward-compatible alias for installed launchd jobs and shims.

Usage:
  maintain.py --tick scheduler          # every 5 min from launchd
  maintain.py --run-now full|janitor|watch
  maintain.py --dry-run [--tick scheduler | --run-now full|janitor|watch|pressure]
                                        # plan only: prints JSON, deletes and records nothing
  maintain.py --status [--json]
  maintain.py --check-alerts
  maintain.py --set-step STEP_ID on|off
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))


# The watchdog that kills a wedged tick.
#
# The launchd job runs this every five minutes.  A tick that wedges -- on a
# slow disk, mid-import, with the host swapping -- blocks every tick after
# it, because launchd will not start a second instance of a StartInterval job
# while one is running.  The maintainer then stops without ever saying so:
# the panel keeps showing the last status it wrote and the disk fills up
# anyway.  A tick that cannot finish has to die so the next one can start.
#
# Measured 2026-10-19: a launchd tick sat in PyImport_ImportModule for 17
# minutes and had written nothing.  The same tick, run by hand, took seven
# seconds.
#
# The number lives in vacuum.config rather than here, because the engine
# derives the reclaim step's own budget from it.  The budget has to sit above
# the longest tick the engine can legitimately run, or the watchdog kills work
# that was still inside its own budget.  A watch tick that decides to clean
# hands off to a pressure run, and the cache reclaim step alone runs
# hoghunter-clean with a budget plus a grace (engine.py
# `_RECLAIM_BUDGET_SECONDS` and `_RECLAIM_GRACE_SECONDS`), so 900s leaves
# room for that step without the watchdog cutting it short.  When the two were
# written down separately they could drift, and a drift here is a tick killed
# in the middle of its work.
#
# vacuum.config is a leaf module with no heavy imports, so importing it here
# -- before the watchdog is armed -- is safe.  The heavier vacuum imports
# still happen below, after the watchdog is up.
from vacuum.config import TICK_WATCHDOG_SEC  # noqa: E402

# vacuum.lock is a leaf module too: standard library only, no vacuum imports.
# The watchdog needs it because `os._exit` skips `finally` and `atexit`, so a
# killed tick used to leave the housekeeper lock behind and every tick after
# it did nothing for two hours.
from vacuum import lock as housekeeper_lock  # noqa: E402

_watchdog_armed = False


def _watchdog_exit(seconds: float) -> None:
    """Exit the process once the tick has overrun its budget."""
    time.sleep(seconds)
    sys.stderr.write(
        f"[hoghunter] scheduler tick exceeded {seconds:.0f}s; "
        "exiting so the next tick can run\n"
    )
    sys.stderr.flush()
    # Give the lock back before the hard exit.  Without this the lock
    # directory survives the kill and every later tick reports "peer holds
    # lock" until the stale window expires.
    try:
        housekeeper_lock.force_release()
    except Exception:  # pragma: no cover - the exit must not be blocked
        pass
    os._exit(3)


def _start_tick_watchdog(seconds: float) -> None:
    """Arm the watchdog.  Nothing is lost when it fires: the store writes
    through a temporary file and renames it, so a kill leaves the last good
    state in place.

    Arming happens twice per tick -- once below, before the vacuum imports,
    and once from main() -- and the second call is a no-op.  Two threads
    would both be harmless, but one keeps the exit message single.
    """
    global _watchdog_armed
    if seconds <= 0 or _watchdog_armed:
        return
    _watchdog_armed = True
    threading.Thread(target=_watchdog_exit, args=(seconds,), daemon=True).start()


class _QuietParserError(Exception):
    """Raised instead of argparse's print-and-exit on a bad flag."""


class _MaintainParser(argparse.ArgumentParser):
    """The parser for this tool, with a quiet failure mode.

    argparse's default `error()` writes a usage block and the message to
    stderr and then exits.  The pre-import watchdog arm parses before main()
    has had any chance to report anything, so a malformed `--tick-timeout`
    produced two usage blocks and two identical errors: one from the arm's
    parser, which knew only three options, and one from main()'s.  The arm
    asks for quiet failures so main() stays the only reporter of the
    mistake, as its own docstring promises.
    """

    quiet_errors = False

    def error(self, message: str) -> None:
        if self.quiet_errors:
            raise _QuietParserError(message)
        super().error(message)


def _build_parser(quiet: bool = False) -> _MaintainParser:
    """The one parser definition for this tool.

    main() and the pre-import watchdog arm both build from here, so the two
    can never disagree about what a flag means or how a repeated flag is
    read.  The arm builds it quietly and without the help action: it runs at
    import time, and a `--help` on the command line has to reach main()'s
    parser rather than print help and exit during the import.
    """
    parser = _MaintainParser(
        description="Hog Hunter Maintain",
        add_help=not quiet,
    )
    parser.quiet_errors = quiet
    parser.add_argument("--tick", choices=["scheduler"], help="Run the combined scheduler tick")
    parser.add_argument(
        "--tick-timeout",
        type=float,
        default=TICK_WATCHDOG_SEC,
        help=(
            "Seconds after which a scheduler tick gives up and exits so the next one can start. "
            "0 disables the watchdog.  launchd will not run a second instance of the job while one "
            "is running, so a wedged tick otherwise stops the maintainer for good."
        ),
    )
    parser.add_argument("--run-now", choices=["watch", "janitor", "full", "pressure"], help="Run one cadence immediately")
    parser.add_argument("--status", action="store_true", help="Print health and last run summary")
    parser.add_argument("--json", action="store_true", dest="as_json", help="Emit JSON (with --status)")
    parser.add_argument("--check-alerts", action="store_true", help="Evaluate alerts and notify")
    parser.add_argument("--set-step", nargs=2, metavar=("STEP_ID", "on|off"), help="Toggle a cleaning step")
    parser.add_argument("--set-config", nargs=2, metavar=("KEY", "VALUE"), help="Set a maintain config value")
    parser.add_argument("--set-coolify-host", metavar="HOST", help="Set the SSH host or alias for remote server maintenance")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        dest="dry_run",
        help="Plan only: run the tick (or the --run-now cadence) with every deleting step in plan-only mode and "
        "print the plan as JSON.  Nothing is deleted and history.json, scheduler state and status are not written.",
    )
    return parser


def _argv_tick_timeout(argv: list[str]) -> float | None:
    """The watchdog budget for this invocation, or None when it must not arm.

    Read straight off argv so the watchdog can be armed before the vacuum
    imports below, which is where the tick that prompted it wedged for 17
    minutes.  Parsed here rather than by main()'s parser because that has not
    run yet at this point.

    The parse has to agree with main()'s.  A hand-rolled scan would not:
    argparse accepts unambiguous abbreviations (`--tick-t 60`) and lets the
    LAST occurrence of a repeated flag win, and a scan that takes the first
    exact spelling sends the watchdog a different budget than the tick it is
    meant to bound.  `_watchdog_armed` then stops main() from correcting it,
    so the watchdog cannot self-correct and the two disagree for the whole
    run.  Both parsers are built by `_build_parser()`, so the option
    definitions are literally the same ones.

    A dry run is not a real tick and never gets a watchdog: its contract is a
    single complete JSON document, and a watchdog that fires mid-print would
    truncate it and exit 3.
    """
    parser = _build_parser(quiet=True)
    try:
        args, _ = parser.parse_known_args(argv)
    except (_QuietParserError, SystemExit):
        # `type=float` rejects a bad value, and this runs before main() has
        # had its chance to report the mistake properly.  The parser is quiet
        # so nothing has been printed yet.  Fall back to the default budget
        # rather than letting the failure escape from import time; main()
        # still owns the error message and the exit code.
        return TICK_WATCHDOG_SEC if _argv_is_scheduler_tick(argv) else None
    if args.tick != "scheduler" or args.dry_run:
        return None
    return args.tick_timeout


def _argv_is_scheduler_tick(argv: list[str]) -> bool:
    """True when argv names a real scheduler tick, spelled out in full.

    Only consulted when the parse above failed, so it deliberately sticks to
    exact spellings rather than guessing at an abbreviation it could not read.
    """
    if "--dry-run" in argv:
        return False
    return any(arg == "--tick" and i + 1 < len(argv) and argv[i + 1] == "scheduler"
               for i, arg in enumerate(argv))


# Armed before the imports on purpose.  A wedge in an import happens before
# main() exists, so a watchdog armed down there cannot see it and launchd
# still refuses to start the next tick.
_tick_timeout = _argv_tick_timeout(sys.argv[1:])
if _tick_timeout is not None:
    _start_tick_watchdog(_tick_timeout)

from vacuum.alerts import NO_NOTIFY_ENV, evaluate_alerts, notify_macos  # noqa: E402
from vacuum.config import STEP_CATALOG, load_config  # noqa: E402
from vacuum.engine import VacuumEngine  # noqa: E402
from vacuum.models import TriggerKind  # noqa: E402
from vacuum.scheduler import (  # noqa: E402
    build_status,
    current_occupancy,
    occupancy_view,
    run_scheduler_tick,
    run_skipped_for_lock,
)
from vacuum.script_registry import bootstrap_registry  # noqa: E402
from vacuum.store import VacuumStore  # noqa: E402


def ensure_standard_mac_paths() -> None:
    standard_paths = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        str(Path.home() / ".local/bin"),
    ]
    current = os.environ.get("PATH", "").split(os.pathsep)
    for p in reversed(standard_paths):
        if p not in current and os.path.isdir(p):
            current.insert(0, p)
    os.environ["PATH"] = os.pathsep.join(current)


ensure_standard_mac_paths()


def _dry_run(store: VacuumStore, args: argparse.Namespace) -> int:
    """Plan-only run.  Stdout is one JSON document and nothing else; nothing is persisted.

    It never evaluates alerts or calls notify_macos, so alert-state.json and history.json stay untouched.  The
    no-notify switch below is a second lock: nothing reached from here can post a banner, even by mistake."""
    os.environ[NO_NOTIFY_ENV] = "1"
    if args.run_now:
        engine = VacuumEngine(store.cfg, store.home)
        if args.run_now == "watch":
            state = store.scheduler_state()
            scratch: dict[str, object] = {}
            if "last_clean_at" in state:
                scratch["last_clean_at"] = state["last_clean_at"]
            prev = state.get("prev_disk_free_gb")
            record, _hits, _cleaned = engine.run_watch_tick(scratch, float(prev) if prev is not None else None, dry_run=True)
        else:
            pressure = args.run_now == "pressure"
            record = engine.run(TriggerKind(args.run_now), pressure=pressure, band="full" if pressure else "cheap", dry_run=True)
        result = {"dry_run": True, "plan": engine.plan, "records": [record.as_dict()]}
    else:
        result = run_scheduler_tick(store, dry_run=True)
    print(json.dumps(result, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.dry_run and (args.set_step or args.set_config or args.set_coolify_host or args.status or args.check_alerts):
        parser.error("--dry-run only combines with --tick or --run-now")

    store = VacuumStore.open()
    bootstrap_registry(store.home, REPO_ROOT, store.cfg)

    if args.set_coolify_host is not None:
        host = args.set_coolify_host.strip()
        store.save_coolify_host(host)
        print(f"coolify_ssh_host -> {host or '(empty)'}")
        return 0

    if args.set_step:
        step_id, flag = args.set_step
        if step_id not in STEP_CATALOG:
            print(f"Unknown step: {step_id}", file=sys.stderr)
            return 2
        enabled = flag.lower() in ("on", "1", "true", "yes")
        store.save_step_toggles({step_id: enabled})
        print(f"{step_id} -> {'enabled' if enabled else 'disabled'}")
        return 0

    if args.set_config:
        key, value = args.set_config
        # Coerce numeric/bool if possible
        val: Any = value
        if value.lower() in ("true", "yes"):
            val = True
        elif value.lower() in ("false", "no"):
            val = False
        else:
            try:
                val = int(value)
            except ValueError:
                try:
                    val = float(value)
                except ValueError:
                    val = value
        store.save_config_value(key, val)
        print(f"config {key} -> {val}")
        return 0

    if args.dry_run:
        return _dry_run(store, args)

    if args.tick == "scheduler":
        _start_tick_watchdog(args.tick_timeout)
        result = run_scheduler_tick(store)
        if args.as_json:
            print(json.dumps(result, indent=2))
        return 0

    if args.run_now:
        engine = VacuumEngine(store.cfg, store.home)
        if args.run_now == "watch":
            state = store.scheduler_state()
            watch_scratch: dict[str, object] = {}
            if "last_clean_at" in state:
                watch_scratch["last_clean_at"] = state["last_clean_at"]
            prev = state.get("prev_disk_free_gb")
            prev_f = float(prev) if prev is not None else None
            record, _hits, _cleaned = engine.run_watch_tick(watch_scratch, prev_f)
            store.append_run(record)
            patch = {k: watch_scratch[k] for k in ("prev_disk_free_gb", "last_clean_at") if k in watch_scratch}
            store.merge_scheduler_state(patch)
            if not run_skipped_for_lock(record):
                store.touch_scheduler("last_watch")
        else:
            trigger = TriggerKind(args.run_now if args.run_now != "pressure" else "pressure")
            pressure = args.run_now == "pressure"
            band = "full" if pressure else "cheap"
            record = engine.run(trigger, pressure=pressure, band=band)
            store.append_run(record)
            if not run_skipped_for_lock(record):
                store.touch_scheduler(f"last_{args.run_now if args.run_now != 'pressure' else 'full'}")
        status = build_status(store, store.cfg)
        store.publish_status(status)
        if args.as_json:
            print(json.dumps(record.as_dict(), indent=2))
        else:
            print(record.summary or f"run {record.run_id} exit={record.exit_code}")
        return record.exit_code

    if args.check_alerts:
        # The same view the tick uses, so a cadence that is only waiting its
        # turn does not raise a banner here either.
        alerts = evaluate_alerts(
            occupancy_view(store, current_occupancy(store, store.cfg)), store.cfg
        )
        for alert in alerts:
            if alert.should_notify:
                notify_macos("Hog Hunter", alert.message)
        if args.as_json:
            print(json.dumps([a.__dict__ for a in alerts if a.should_notify], indent=2))
        return 0

    if args.status:
        status = build_status(store, store.cfg)
        if args.as_json:
            print(json.dumps(status, indent=2))
        else:
            print(f"health: {status.get('health')}")
            print(f"launchd loaded: {status.get('launchd_loaded')}")
        return 0

    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

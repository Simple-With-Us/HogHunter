#!/usr/bin/env python3
"""Robotic Vacuum — Hog Hunter scheduled Mac cleaning.

Replaces com.jay.mac-cleanup, com.jay.disk-janitor, and com.jay.mac-resource-watch
with a single launchd agent driven from this repo.

Usage:
  robotic-vacuum.py --tick scheduler          # every 5 min from launchd
  robotic-vacuum.py --run-now full|janitor|watch
  robotic-vacuum.py --status [--json]
  robotic-vacuum.py --check-alerts
  robotic-vacuum.py --set-step STEP_ID on|off
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

from vacuum.alerts import evaluate_alerts, notify_macos  # noqa: E402
from vacuum.config import STEP_CATALOG, load_config  # noqa: E402
from vacuum.engine import VacuumEngine  # noqa: E402
from vacuum.models import TriggerKind  # noqa: E402
from vacuum.scheduler import build_status, run_scheduler_tick  # noqa: E402
from vacuum.store import VacuumStore  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Hog Hunter Robotic Vacuum")
    parser.add_argument("--tick", choices=["scheduler"], help="Run the combined scheduler tick")
    parser.add_argument("--run-now", choices=["watch", "janitor", "full", "pressure"], help="Run one cadence immediately")
    parser.add_argument("--status", action="store_true", help="Print health and last run summary")
    parser.add_argument("--json", action="store_true", dest="as_json", help="Emit JSON (with --status)")
    parser.add_argument("--check-alerts", action="store_true", help="Evaluate alerts and notify")
    parser.add_argument("--set-step", nargs=2, metavar=("STEP_ID", "on|off"), help="Toggle a cleaning step")
    args = parser.parse_args(argv)

    store = VacuumStore.open()

    if args.set_step:
        step_id, flag = args.set_step
        if step_id not in STEP_CATALOG:
            print(f"Unknown step: {step_id}", file=sys.stderr)
            return 2
        enabled = flag.lower() in ("on", "1", "true", "yes")
        store.save_step_toggles({step_id: enabled})
        print(f"{step_id} -> {'enabled' if enabled else 'disabled'}")
        return 0

    if args.tick == "scheduler":
        result = run_scheduler_tick(store)
        if args.as_json:
            print(json.dumps(result, indent=2))
        return 0

    if args.run_now:
        engine = VacuumEngine(store.cfg, store.home)
        trigger = TriggerKind(args.run_now if args.run_now != "pressure" else "pressure")
        pressure = args.run_now == "pressure"
        band = "full" if pressure else "cheap"
        record = engine.run(trigger, pressure=pressure, band=band)
        store.append_run(record)
        store.touch_scheduler(f"last_{args.run_now if args.run_now != 'pressure' else 'full'}")
        status = build_status(store, store.cfg)
        store.publish_status(status)
        if args.as_json:
            print(json.dumps(record.as_dict(), indent=2))
        else:
            print(record.summary or f"run {record.run_id} exit={record.exit_code}")
        return record.exit_code

    if args.check_alerts:
        alerts = evaluate_alerts(store, store.cfg)
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

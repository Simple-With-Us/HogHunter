from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from .config import load_config
from .engine import VacuumEngine
from .models import TriggerKind
from .models import RunRecord
from .store import VacuumStore


def run_skipped_for_lock(record: RunRecord) -> bool:
    if record.summary and "lock" in record.summary.lower():
        return True
    return any(s.step_id == "housekeeper_lock" for s in record.steps)


def should_run(store: VacuumStore, cfg: dict[str, Any], kind: str, now: float | None = None) -> bool:
    now = now or time.time()
    intervals = cfg.get("intervals_seconds", {})
    interval = float(intervals.get(kind, 0))
    if interval <= 0:
        return False
    state = store.scheduler_state()
    last = float(state.get(f"last_{kind}", 0))
    return (now - last) >= interval


def run_dry_tick(
    store: VacuumStore, engine: VacuumEngine | None = None, now: float | None = None
) -> dict[str, Any]:
    """Run what the next real tick would run, with every deleting step in plan-only mode.  Writes nothing:
    no history, no scheduler state, no status file, no notification.  The result is JSON-ready."""
    cfg = store.cfg
    engine = engine or VacuumEngine(cfg, store.home)
    now = now or time.time()
    state = store.scheduler_state()
    scratch: dict[str, Any] = {}
    if "last_clean_at" in state:
        scratch["last_clean_at"] = state["last_clean_at"]
    prev = state.get("prev_disk_free_gb")
    prev_f = float(prev) if prev is not None else None
    due = {kind: should_run(store, cfg, kind, now) for kind in ("watch", "janitor", "full")}
    records: list[RunRecord] = []
    if due["watch"]:
        record, _hits, _cleaned = engine.run_watch_tick(scratch, prev_f, dry_run=True)
        records.append(record)
    if due["janitor"]:
        records.append(engine.run(TriggerKind.JANITOR, dry_run=True))
    if due["full"]:
        records.append(engine.run(TriggerKind.FULL, band="cheap", dry_run=True))
    return {
        "dry_run": True,
        "due": due,
        "plan": engine.plan,
        "records": [r.as_dict() for r in records],
    }


def run_scheduler_tick(
    store: VacuumStore | None = None, now: float | None = None, dry_run: bool = False
) -> dict[str, Any]:
    store = store or VacuumStore.open()
    cfg = store.cfg
    # The engine reports what it has reclaimed after every step, so a tick the
    # watchdog kills still leaves a record of the work it did.  The store owns
    # the file, so the engine never has to know where it lives.
    engine = VacuumEngine(cfg, store.home, on_step=store.write_partial_run)
    now = now or time.time()
    if dry_run:
        return run_dry_tick(store, engine, now)
    results: list[dict[str, Any]] = []

    state = store.scheduler_state()
    watch_scratch: dict[str, Any] = {}
    if "last_clean_at" in state:
        watch_scratch["last_clean_at"] = state["last_clean_at"]
    prev_free = state.get("prev_disk_free_gb")
    prev_free_f = float(prev_free) if prev_free is not None else None

    if should_run(store, cfg, "watch", now):
        record, hits, cleaned = engine.run_watch_tick(watch_scratch, prev_free_f)
        store.append_run(record)
        store.clear_partial_run()
        if not run_skipped_for_lock(record):
            store.touch_scheduler("last_watch", now)
        results.append({"trigger": "watch", "run_id": record.run_id, "hits": len(hits), "cleaned": cleaned})

    if should_run(store, cfg, "janitor", now):
        record = engine.run(TriggerKind.JANITOR)
        store.append_run(record)
        store.clear_partial_run()
        if not run_skipped_for_lock(record):
            store.touch_scheduler("last_janitor", now)
        results.append({"trigger": "janitor", "run_id": record.run_id})

    if should_run(store, cfg, "full", now):
        record = engine.run(TriggerKind.FULL, band="cheap")
        store.append_run(record)
        store.clear_partial_run()
        if not run_skipped_for_lock(record):
            store.touch_scheduler("last_full", now)
        results.append({"trigger": "full", "run_id": record.run_id})

    if watch_scratch:
        patch = {k: watch_scratch[k] for k in ("prev_disk_free_gb", "last_clean_at") if k in watch_scratch}
        store.merge_scheduler_state(patch)

    from .alerts import evaluate_alerts, notify_macos

    alerts = evaluate_alerts(store, cfg, now)
    for alert in alerts:
        if alert.should_notify:
            notify_macos("Hog Hunter", alert.message)

    status = build_status(store, cfg, now)
    store.publish_status(status)
    return {"ticks": results, "status": status, "alerts": [a.__dict__ for a in alerts if a.should_notify]}


def build_status(store: VacuumStore, cfg: dict[str, Any], now: float | None = None) -> dict[str, Any]:
    now = now or time.time()
    intervals = cfg.get("intervals_seconds", {})
    mult = float(cfg.get("overdue_multiplier", 1.5))
    health = "healthy"
    last_runs: dict[str, Any] = {}
    next_runs: dict[str, float] = {}

    for kind in ("watch", "janitor", "full"):
        last = store.last_run_for(kind)
        interval = float(intervals.get(kind, 0))
        ended = float((last or {}).get("ended_at") or (last or {}).get("started_at") or 0)
        last_runs[kind] = last
        if ended > 0:
            next_runs[kind] = ended + interval
            if now - ended > interval * mult:
                health = "overdue"
        else:
            next_runs[kind] = now

    history = store.load_history()
    last_record = history[-1] if history else None
    if last_record and int(last_record.get("exit_code", 0)) != 0:
        health = "failed"

    # Health has to reflect the disk.  Until now it only ever looked at schedule
    # lateness and the last run's exit code, so the panel said "healthy" while
    # the disk sat at 100% with 3 GB free and every run freed zero bytes --
    # the exact situation this whole feature exists to prevent, reported as
    # fine.  The watch tick samples the disk every five minutes and keeps the
    # number in the scheduler state, so read it from there rather than running
    # another df on a host that is already loaded.
    #
    # The thresholds are the same keys and the same defaults evaluate_hits
    # uses, so the headline and the watch's own threshold hits can never
    # disagree about whether the disk is low.
    rw_cfg = cfg.get("resource_watch", {})
    crit_gb = float(rw_cfg.get("disk_free_crit_gb", 15))
    warn_gb = float(rw_cfg.get("disk_free_warn_gb", 25))
    disk: dict[str, Any] = {"free_gb": None, "health": "unknown"}
    raw_free = store.scheduler_state().get("prev_disk_free_gb")
    if raw_free is not None:
        try:
            free_gb = float(raw_free)
        except (TypeError, ValueError):
            free_gb = None
        if free_gb is not None:
            disk["free_gb"] = round(free_gb, 2)
            if free_gb <= crit_gb:
                disk["health"] = "critical"
            elif free_gb <= warn_gb:
                disk["health"] = "acute"
            else:
                disk["health"] = "ok"
            # A critically low disk outranks a failed run at the headline: it is
            # the emergency the owner has to act on now.  The failed run is
            # still visible in the step list, and "failed" is kept when the disk
            # is merely low.
            if disk["health"] == "critical":
                health = "critical"
            elif disk["health"] == "acute" and health in ("healthy", "overdue"):
                health = "degraded"

    from .alerts import launchd_loaded
    from .script_registry import bootstrap_registry, summary_for_status

    bootstrap_registry(store.home, Path(__file__).resolve().parents[2], cfg)

    # The latest result of each step, from whichever run last ran it.  The last record alone is almost always a
    # watch tick (every five minutes), whose only steps are the disk and memory check, so the UI would show
    # nothing for the cleaning steps.  History is oldest first, so a newer result replaces an older one.
    step_states: dict[str, Any] = {}
    for record in history:
        for s in record.get("steps") or []:
            step_states[s.get("step_id")] = s

    # A tick the watchdog killed never reached the history, so its in-progress
    # copy is the only record of what it reclaimed.  Fold it in: its steps are
    # the newest results, and the run itself is shown beside the last
    # completed one, so a killed tick is visible instead of silently absent.
    partial = store.load_partial_run()
    if partial:
        for s in partial.get("steps") or []:
            step_states[s.get("step_id")] = s

    return {
        "health": health,
        "disk": disk,
        "last_runs": {
            k: float(v["ended_at"])
            for k, v in last_runs.items()
            if v and v.get("ended_at") is not None
        },
        "next_run_at": next_runs,
        "intervals_seconds": intervals,
        "last_run": last_record,
        "partial_run": partial or None,
        "step_last_results": step_states,
        "history_count": len(history),
        "launchd_loaded": launchd_loaded(),
        "maintenance_scripts": summary_for_status(store.home),
    }

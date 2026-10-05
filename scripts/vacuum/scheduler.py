from __future__ import annotations

import time
from typing import Any

from .config import load_config
from .engine import VacuumEngine
from .models import TriggerKind
from .store import VacuumStore


def should_run(store: VacuumStore, cfg: dict[str, Any], kind: str, now: float | None = None) -> bool:
    now = now or time.time()
    intervals = cfg.get("intervals_seconds", {})
    interval = float(intervals.get(kind, 0))
    if interval <= 0:
        return False
    state = store.scheduler_state()
    last = float(state.get(f"last_{kind}", 0))
    return (now - last) >= interval


def run_scheduler_tick(store: VacuumStore | None = None, now: float | None = None) -> dict[str, Any]:
    store = store or VacuumStore.open()
    cfg = store.cfg
    engine = VacuumEngine(cfg, store.home)
    now = now or time.time()
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
        store.touch_scheduler("last_watch", now)
        results.append({"trigger": "watch", "run_id": record.run_id, "hits": len(hits), "cleaned": cleaned})

    if should_run(store, cfg, "janitor", now):
        record = engine.run(TriggerKind.JANITOR)
        store.append_run(record)
        store.touch_scheduler("last_janitor", now)
        results.append({"trigger": "janitor", "run_id": record.run_id})

    if should_run(store, cfg, "full", now):
        record = engine.run(TriggerKind.FULL, band="cheap")
        store.append_run(record)
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

    from .alerts import launchd_loaded

    if not launchd_loaded():
        health = "unloaded"

    step_states: dict[str, Any] = {}
    if last_record:
        for s in last_record.get("steps") or []:
            step_states[s.get("step_id")] = s

    return {
        "health": health,
        "last_runs": {k: (v.get("ended_at") if v else None) for k, v in last_runs.items()},
        "next_run_at": next_runs,
        "intervals_seconds": intervals,
        "last_run": last_record,
        "step_last_results": step_states,
        "history_count": len(history),
        "launchd_loaded": launchd_loaded(),
    }

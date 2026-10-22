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


# The cadences, cheapest first.  The order is also the tie-break order for
# picking a cadence: the longest interval wins a tie, because the short
# interval runs again in five minutes and the long one does not.
CADENCES = ("watch", "janitor", "full")

# How many cadences one tick may run.
#
# One.  A tick used to run every due cadence back to back in the same
# process, and the sum could be longer than the watchdog that bounds a tick.
# Measured on this host 2026-10-21: watch took 279s and janitor 117s, and a
# full reclaim has a 600s budget plus a 180s grace, so a tick with all three
# due wanted 1176s against a 900s watchdog.  The watchdog then killed the
# tick, and because the kill skipped the lock's `__exit__`, the housekeeper
# lock survived it and blocked every tick after it.  The vacuum had not
# completed a tick in six days.
#
# One cadence per tick keeps every tick inside the watchdog: the worst
# single cadence is a full reclaim at 780s.  Nothing is delayed for long,
# because a cadence that is skipped stays due and its overdue time keeps
# growing, so it is the next one to be picked.
MAX_CADENCES_PER_TICK = 1


def overdue_seconds(store: VacuumStore, cfg: dict[str: Any], kind: str, now: float) -> float:
    """How long a cadence has been past its interval.  Negative means not yet due."""
    intervals = cfg.get("intervals_seconds", {})
    interval = float(intervals.get(kind, 0))
    if interval <= 0:
        return float("-inf")
    state = store.scheduler_state()
    last = float(state.get(f"last_{kind}", 0))
    return (now - last) - interval


def skipped_cadences(
    store: VacuumStore, cfg: dict[str, Any], now: float, occupied: str | None
) -> dict[str, str]:
    """The due cadences this tick had to leave behind, and why.

    One tick runs at most one cadence, so every other due cadence waits its
    turn.  That is a legitimate delay and not a failure, and the record of
    it is what keeps a waiting cadence from being reported as overdue.
    """
    if occupied is None:
        return {}
    skipped: dict[str, str] = {}
    for kind in CADENCES:
        if kind == occupied:
            continue
        if should_run(store, cfg, kind, now):
            skipped[kind] = f"the {occupied} cadence occupied the tick"
    return skipped


def cadence_occupancy(
    store: VacuumStore, cfg: dict[str, Any], now: float, selected: list[str]
) -> dict[str, Any]:
    """What this tick is running, and what it is leaving behind."""
    occupied = selected[0] if selected else None
    return {
        "at": now,
        "occupied": occupied,
        "skipped": skipped_cadences(store, cfg, now, occupied),
    }


class _OccupancyStore:
    """The store as the alert layer sees it, with the skipped cadences accounted for.

    The alert layer decides that a cadence is overdue from the last run it
    finished.  A cadence that another cadence legitimately kept out of the
    tick has not finished a run for a long time by definition, and the alert
    layer reads that as a failure and sends a banner for a cadence that is
    only waiting its turn.

    This view answers the question the alert layer asks with the truth: the
    cadence was serviced by the tick, it simply did not run.  A cadence
    whose last run FAILED keeps its own answer, because a cadence that
    broke is not a cadence that waited.
    """

    def __init__(self, store: VacuumStore, occupancy: dict[str, Any], now: float) -> None:
        self.__dict__["_store"] = store
        self.__dict__["_skipped"] = occupancy.get("skipped") or {}
        self.__dict__["_now"] = now

    def __getattr__(self, name: str) -> Any:
        store = self.__dict__.get("_store")
        if store is None:
            raise AttributeError(name)
        return getattr(store, name)

    def last_run_for(self, trigger: str) -> dict[str, Any] | None:
        record = self._store.last_run_for(trigger)
        if not record or trigger not in self._skipped:
            return record
        steps = record.get("steps") or []
        if any(s.get("status") == "failed" for s in steps):
            # The cadence failed, so it is not merely late: it is broken, and
            # the overdue banner has to keep saying so.
            return record
        return {**record, "ended_at": self._now, "skipped_reason": self._skipped[trigger]}


# How long a claim that a cadence was skipped survives when the claim is read
# back from the store instead of handed over by the tick that made it.
#
# A skipped cadence is waiting for the next tick, and the next tick comes one
# tick period later.  The tick period is the fastest cadence's interval,
# because the launchd job fires that often.  The claim survives two of those
# periods, so a tick that ran late does not make a waiting cadence look
# overdue, but a scheduler that stopped ticking does, and that is the signal
# the panel needs.
OCCUPANCY_CLAIM_TICK_PERIODS = 2


def occupancy_claim_lifetime(cfg: dict[str, Any]) -> float:
    """How long the claim that a cadence was skipped stays believable."""
    intervals = cfg.get("intervals_seconds", {})
    periods: list[float] = []
    for value in intervals.values():
        try:
            seconds = float(value)
        except (TypeError, ValueError):
            continue
        if seconds > 0:
            periods.append(seconds)
    if not periods:
        return 0.0
    return OCCUPANCY_CLAIM_TICK_PERIODS * min(periods)


def current_occupancy(
    store: VacuumStore, cfg: dict[str, Any], now: float | None = None
) -> dict[str, Any] | None:
    """The occupancy the last tick recorded, if its claim is still live.

    A reader that did not take part in the tick -- the status command, and a
    manual run that publishes a status afterwards -- has to learn the claim
    from the store.  The claim is only believable while a tick could still
    arrive to service the cadence that is waiting, so it expires.
    """
    now = now or time.time()
    occupancy = store.scheduler_state().get("tick_occupancy") or {}
    if not occupancy.get("skipped"):
        return None
    try:
        at = float(occupancy.get("at") or 0)
    except (TypeError, ValueError):
        return None
    if at <= 0:
        return None
    lifetime = occupancy_claim_lifetime(cfg)
    if lifetime <= 0 or (now - at) > lifetime:
        return None
    return occupancy


def occupancy_view(
    store: VacuumStore, occupancy: dict[str, Any] | None, now: float | None = None
) -> Any:
    """The store as the alert layer reads it, with a skipped cadence accounted for."""
    if not occupancy:
        return store
    return _OccupancyStore(store, occupancy, now or time.time())


def select_cadences(
    store: VacuumStore, cfg: dict[str: Any], now: float | None = None
) -> list[str]:
    """Pick the cadences this tick should run, most overdue first.

    Only cadences that are actually due are considered, and at most
    `MAX_CADENCES_PER_TICK` of them come back.  The one that has been
    waiting longest goes first, and a tie goes to the cadence with the
    longest interval, so the rare four-hourly full reclaim is not pushed
    aside by the five-minute watch every time the two come due together.
    """
    now = now or time.time()
    due = [kind for kind in CADENCES if should_run(store, cfg, kind, now)]
    if not due:
        return []
    due.sort(
        key=lambda kind: (
            -overdue_seconds(store, cfg, kind, now),
            -float(cfg.get("intervals_seconds", {}).get(kind, 0)),
        )
    )
    return due[:MAX_CADENCES_PER_TICK]


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
    due = {kind: should_run(store, cfg, kind, now) for kind in CADENCES}
    selected = select_cadences(store, cfg, now)
    records: list[RunRecord] = []
    # Plan only the cadence the real tick would pick, so the dry run does
    # not over-report work the next tick is not going to do.
    if "watch" in selected:
        record, _hits, _cleaned = engine.run_watch_tick(scratch, prev_f, dry_run=True)
        records.append(record)
    if "janitor" in selected:
        records.append(engine.run(TriggerKind.JANITOR, dry_run=True))
    if "full" in selected:
        records.append(engine.run(TriggerKind.FULL, band="cheap", dry_run=True))
    return {
        "dry_run": True,
        "due": due,
        "selected": selected,
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

    # One cadence per tick, the most overdue one.  Running every due cadence
    # back to back could take longer than the watchdog that bounds a tick,
    # and the watchdog's kill used to leave the housekeeper lock behind.
    selected = select_cadences(store, cfg, now)
    # What this tick runs, and which due cadences it has to leave behind.
    # The record is what tells the alert layer the difference between a
    # cadence that is waiting its turn and a cadence that has failed.
    occupancy = cadence_occupancy(store, cfg, now, selected)

    if "watch" in selected:
        record, hits, cleaned = engine.run_watch_tick(watch_scratch, prev_free_f)
        store.append_run(record)
        store.clear_partial_run()
        if not run_skipped_for_lock(record):
            store.touch_scheduler("last_watch", now)
        results.append({"trigger": "watch", "run_id": record.run_id, "hits": len(hits), "cleaned": cleaned})

    if "janitor" in selected:
        record = engine.run(TriggerKind.JANITOR)
        store.append_run(record)
        store.clear_partial_run()
        if not run_skipped_for_lock(record):
            store.touch_scheduler("last_janitor", now)
        results.append({"trigger": "janitor", "run_id": record.run_id})

    if "full" in selected:
        record = engine.run(TriggerKind.FULL, band="cheap")
        store.append_run(record)
        store.clear_partial_run()
        if not run_skipped_for_lock(record):
            store.touch_scheduler("last_full", now)
        results.append({"trigger": "full", "run_id": record.run_id})

    if watch_scratch:
        patch = {k: watch_scratch[k] for k in ("prev_disk_free_gb", "last_clean_at") if k in watch_scratch}
        store.merge_scheduler_state(patch)

    # The occupancy is kept beside the schedule so the next reader can see
    # which cadence the tick ran and which ones it had to leave behind.
    store.merge_scheduler_state({"tick_occupancy": occupancy})

    from .alerts import evaluate_alerts, notify_macos

    # The alert layer reads the last finished run of a cadence to decide
    # whether it is overdue.  A cadence this tick had to leave behind has
    # not finished a run for a long time by definition, and the view gives
    # the alert layer the truth about it instead of that.
    alerts = evaluate_alerts(_OccupancyStore(store, occupancy, now), cfg, now)
    for alert in alerts:
        if alert.should_notify:
            notify_macos("Hog Hunter", alert.message)

    status = build_status(store, cfg, now, occupancy=occupancy)
    store.publish_status(status)
    return {"ticks": results, "status": status, "alerts": [a.__dict__ for a in alerts if a.should_notify]}


def build_status(
    store: VacuumStore,
    cfg: dict[str, Any],
    now: float | None = None,
    occupancy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """The status the panel reads.

    `occupancy` is the record of what the last tick ran and which due
    cadences it had to leave behind.  When it is given, the status reads
    the cadences through the same view the alert layer reads them
    through, so the panel and the banner cannot disagree about the same
    fact: a cadence that another cadence legitimately kept out of the tick
    is not overdue, and its published next run is not a time that has gone
    by.
    """
    now = now or time.time()
    intervals = cfg.get("intervals_seconds", {})
    mult = float(cfg.get("overdue_multiplier", 1.5))
    health = "healthy"
    last_runs: dict[str, Any] = {}
    next_runs: dict[str, float] = {}
    # A reader that did not take part in the tick learns the claim from the
    # store, so the panel and the banner cannot disagree about the same
    # fact whichever way the status was built.
    if occupancy is None:
        occupancy = current_occupancy(store, cfg, now)
    view = occupancy_view(store, occupancy, now)

    for kind in ("watch", "janitor", "full"):
        raw = store.last_run_for(kind)
        # The view answers for a cadence that was legitimately left behind:
        # it was serviced by the tick, it simply did not run.
        last = view.last_run_for(kind)
        interval = float(intervals.get(kind, 0))
        ended = float((last or {}).get("ended_at") or (last or {}).get("started_at") or 0)
        last_runs[kind] = raw
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
    #
    # It counts only while it is newer than every completed run.  A run that
    # finishes through a path that never clears it (the CLI's --run-now) leaves
    # the old copy on disk, and an old copy must not overwrite the results of
    # a run that finished after it.
    partial = store.load_partial_run()
    if partial:
        newest_started = max((float(r.get("started_at") or 0.0) for r in history), default=0.0)
        if float(partial.get("started_at") or 0.0) <= newest_started:
            partial = {}
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
        # The cadence the last tick ran, and the due cadences it had to
        # leave behind.  A cadence that is waiting its turn is not a
        # cadence that has failed, and this is the record that says so.
        "tick_occupancy": store.scheduler_state().get("tick_occupancy") or {},
        "launchd_loaded": launchd_loaded(),
        "maintenance_scripts": summary_for_status(store.home),
    }

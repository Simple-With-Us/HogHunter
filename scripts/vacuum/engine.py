from __future__ import annotations

import errno
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Optional

from . import lanes
from .config import STEP_CATALOG, TICK_WATCHDOG_SEC, expand_path, step_enabled, steps_for_trigger
from .janitor import RetirePlan, data_dir_for, keep_regex, plan_retire_worktrees, retire_worktrees
from .lock import HousekeeperLock, LockHeld
from .models import RunRecord, StepResult, StepStatus, TriggerKind
from .pressure import evaluate_hits, janitor_pressure_mode, sample_mac

# Steps that run the lane doctor.  Under extreme host load they are skipped like the other heavy janitor work.
#
# janitor_cache_reclaim is deliberately NOT in this list, and must not be added
# back.  It is the disk reclaim step: skipping it under load is a deadlock,
# because the disk pressure that loads the host is exactly what the step exists
# to clear.  The old guard made the step skip itself whenever the host was
# loaded, so on a host that most needed cleaning it never ran, and the disk
# slid to 100% while every run reported zero bytes freed.
#
# The step is safe under load.  It stays inside the cheap (safe) band and the
# reclaim engine bounds itself with --budget-sec=600 plus a 180 s hard stop, so
# it cannot run away on a busy host.
#
# Owner ruling 2026-10-02, recorded in the reclaim policy under
# bands.chunking.pressureShapesWorkNotScope: pressure changes the SHAPE of the
# work, never its SCOPE, and the load and swap thresholds "must never suppress
# the safe or semi-safe tiers".
_HEAVY_LANE_STEPS = ("janitor_worktree_retire", "pressure_apps_deps")


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


def _plural(count: int, noun: str, plural: Optional[str] = None) -> str:
    """The count with the right form of the noun: "1 log", "0 logs", "2 folders".  Step reasons are shown to a
    person in the Robotic Vacuum, so none of them hedges the plural in parentheses."""
    return f"{count} {noun if count == 1 else (plural or noun + 's')}"

# Gates for the older `full` steps, from config/reclaim-policy.json: the xcode-artifacts and dev-caches rules skip
# while any of these processes run (skipWhenAny), a DerivedData project must be untouched for the cache idle gate
# (idlenessGates.cacheMinutes, 90), and an iOS DeviceSupport version for 7 days (idlenessGates.deviceSupportDays).
_BUILD_PROCESSES = ("xcodebuild", "swift-frontend", "clang")
_DERIVED_DATA_IDLE_SECONDS = 90 * 60.0
_DEVICE_SUPPORT_IDLE_SECONDS = 7 * 86400.0

# hoghunter-clean gets a time budget it keeps itself (--budget-sec), and a hard stop a little later.  The old
# single 900 s kill reported a failure and no bytes even when the cleaner had done most of its work.  The budget
# stays under the 900 s the steps used to get, so a tick is never longer than before.
#
# Derived from the watchdog rather than written down twice.  The reclaim step
# has to finish inside the tick that the watchdog kills, and the two numbers
# used to be hard-coded in two files, where nobody could tell they had to
# agree.  The reserve is what the rest of the tick needs: the other steps run
# before and after this one, and they have to fit too.
_RECLAIM_GRACE_SECONDS = 180
_RECLAIM_RESERVE_SECONDS = 120
_RECLAIM_BUDGET_SECONDS = max(30, int(TICK_WATCHDOG_SEC) - _RECLAIM_GRACE_SECONDS - _RECLAIM_RESERVE_SECONDS)

# The Spotlight index folder is protected by macOS (TCC).  A launchd job whose interpreter has no Full Disk Access
# is refused when it lists the folder, with EPERM ("Operation not permitted").  That is a state of the Mac, not a
# failure of the step, so the step reports it as skipped.  Nothing here tries to get around the protection.
_SPOTLIGHT_NEEDS_FDA = "skipped: needs Full Disk Access (macOS blocks the Spotlight index folder)"
_PROTECTED_ERRNOS = (errno.EPERM, errno.EACCES)

# Steps that interpret dry_run themselves (planning vs destructive apply).
_DRY_RUN_AWARE_STEPS = frozenset(
    {
        "resource_sample",
        "janitor_worktree_retire",
        "janitor_cache_reclaim",
        "pressure_apps_deps",
        "shutdown_simulators",
    }
)


def _subprocess_run(cmd: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, **kwargs)


def _run_in_own_group(cmd: list[str], timeout: float) -> tuple[int, str, str, bool]:
    """Run cmd in its own process group and return (exit code, stdout, stderr, timed_out).  On a timeout the whole
    group is killed, so the find, lsof or du the child started cannot outlive it and keep the disk busy.  Any other
    error while waiting (a broken pipe, an interrupt) kills the group too and is raised, so nothing is leaked and
    the step reports the real error instead of a budget overrun."""
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True
    )

    def kill_group() -> None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            try:
                proc.kill()
            except (ProcessLookupError, PermissionError):
                pass

    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out or "", err or "", False
    except subprocess.TimeoutExpired:
        kill_group()
        try:
            out, err = proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            out, err = "", ""
        return -1, out or "", err or "", True
    except BaseException:
        kill_group()
        try:
            proc.communicate(timeout=15)
        except (subprocess.TimeoutExpired, OSError, ValueError):
            pass
        raise


class VacuumEngine:
    def __init__(
        self,
        cfg: dict[str, Any],
        home: Path | None = None,
        runner: Optional[Callable[..., Any]] = None,
        doctor_runner: Optional[lanes.DoctorRunner] = None,
        clock: Callable[[], float] = time.time,
        on_step: Optional[Callable[[RunRecord], None]] = None,
    ) -> None:
        self.home = home or Path.home()
        self.cfg = cfg
        self.lock_path = expand_path(str(cfg.get("housekeeper_lock", "")), self.home)
        # Injectable for tests: the process runner (git, pgrep, lsof, du), the doctor runner, and the clock.
        self._runner: Callable[..., Any] = runner or _subprocess_run
        self._doctor_runner = doctor_runner
        self._clock = clock
        # Called after every step with the run so far, so a tick the watchdog
        # kills still leaves a record of what it reclaimed.
        self._on_step = on_step
        self._planned_retire_plan: RetirePlan | None = None
        self._lane_report_cache: lanes.LaneReport | None = None
        self._busy_reason = ""
        # Itemized actions (dry run: what would happen; real run: what happened).  The CLI prints this.
        self.plan: list[dict[str, Any]] = []

    def _emit_partial(self, record: RunRecord, dry_run: bool = False) -> None:
        """Tell the store what this run has reclaimed so far.

        A tick the watchdog kills still has to report what it reclaimed, and
        a finished run is only appended to the history when it completes.  So
        the store keeps an in-progress copy that is overwritten as the run
        advances, and the status shows it beside the last completed run.

        A dry run reports nothing and writes nothing: it plans, it does not
        act, so there is nothing to have reclaimed.
        """
        if self._on_step is None or dry_run:
            return
        try:
            self._on_step(record)
        except Exception:  # noqa: BLE001 — bookkeeping must never kill a cleaning run
            pass

    def run(
        self,
        trigger: TriggerKind,
        pressure: bool = False,
        band: str = "cheap",
        dry_run: bool = False,
    ) -> RunRecord:
        record = RunRecord(
            run_id=uuid.uuid4().hex[:12],
            trigger=trigger,
            started_at=time.time(),
            band=band,
            pressure=pressure,
        )
        step_ids = steps_for_trigger(self.cfg, trigger.value, pressure=pressure)
        self._planned_retire_plan = None
        self._lane_report_cache = None
        try:
            with HousekeeperLock(self.lock_path):
                sample = sample_mac()
                mode = janitor_pressure_mode(sample, self.cfg.get("janitor", {}))
                for step_id in step_ids:
                    if not step_enabled(self.cfg, step_id):
                        continue
                    meta = STEP_CATALOG.get(step_id, {})
                    title = str(meta.get("title", step_id))
                    if mode == "hard" and step_id in _HEAVY_LANE_STEPS:
                        record.steps.append(
                            StepResult(step_id, title, StepStatus.SKIPPED, reason="host under extreme load; cheap steps only")
                        )
                        self._emit_partial(record, dry_run=dry_run)
                        continue
                    failure = self._plan_step(step_id, dry_run)
                    if failure is not None:
                        record.steps.append(failure)
                        self._emit_partial(record, dry_run=dry_run)
                        continue
                    result = self._run_step(step_id, pressure=pressure, band=band, sample=sample, mode=mode, dry_run=dry_run)
                    record.steps.append(result)
                    self._emit_partial(record, dry_run=dry_run)
                record.finish()
        except LockHeld as exc:
            record.steps.append(
                StepResult("housekeeper_lock", "Housekeeper lock", StepStatus.SKIPPED, reason=str(exc))
            )
            record.finish(0, summary="skipped; peer holds lock")
        finally:
            self._planned_retire_plan = None
            self._lane_report_cache = None
        return record

    def run_single_step(
        self,
        step_id: str,
        pressure: bool = False,
        band: str = "cheap",
        dry_run: bool = False,
    ) -> RunRecord:
        """Run exactly one step, under the housekeeper lock, and record it like any other run.

        The id names the step to run; the catalog decides whether it is a step at all, and the step's own
        toggle decides whether it runs.  A step that is off is reported as skipped rather than quietly
        ignored, so a manual run never works around the switch the owner set, and the record exits 2 so a
        caller sees the refusal.  The heavy lane steps keep the load guard the tick has: under extreme host
        load they are skipped, never pushed through.

        The record is a manual run: it is not a cadence, so it carries no cadence of its own and the
        scheduler clock is left alone by the caller.  A dry run plans only and deletes nothing.
        """
        record = RunRecord(
            run_id=uuid.uuid4().hex[:12],
            trigger=TriggerKind.MANUAL,
            started_at=time.time(),
            band=band,
            pressure=pressure,
        )
        meta = STEP_CATALOG.get(step_id, {})
        title = str(meta.get("title", step_id))
        self._planned_retire_plan = None
        self._lane_report_cache = None
        try:
            with HousekeeperLock(self.lock_path):
                if not step_enabled(self.cfg, step_id):
                    record.steps.append(
                        StepResult(step_id, title, StepStatus.SKIPPED, reason="step is off")
                    )
                    record.finish(2, summary="skipped; step is off")
                    return record
                sample = sample_mac()
                mode = janitor_pressure_mode(sample, self.cfg.get("janitor", {}))
                if mode == "hard" and step_id in _HEAVY_LANE_STEPS:
                    record.steps.append(
                        StepResult(step_id, title, StepStatus.SKIPPED, reason="host under extreme load; cheap steps only")
                    )
                    # Nothing ran, so this is not a successful run:  the exit code is how the
                    # caller learns that the step it asked for was refused, the same way the
                    # "step is off" refusal above reports itself.
                    record.finish(2, summary="skipped; host under extreme load")
                    return record
                failure = self._plan_step(step_id, dry_run)
                if failure is not None:
                    record.steps.append(failure)
                    record.finish()
                    return record
                result = self._run_step(step_id, pressure=pressure, band=band, sample=sample, mode=mode, dry_run=dry_run)
                record.steps.append(result)
                record.finish()
        except LockHeld as exc:
            record.steps.append(
                StepResult("housekeeper_lock", "Housekeeper lock", StepStatus.SKIPPED, reason=str(exc))
            )
            record.finish(0, summary="skipped; peer holds lock")
        finally:
            self._planned_retire_plan = None
            self._lane_report_cache = None
        return record

    def _plan_step(self, step_id: str, dry_run: bool) -> Optional[StepResult]:
        """Prepare the work a step needs before it runs.

        Returns a failed StepResult when the planning itself fails (an invalid keep list, for example), so
        the step fails on its own terms instead of the run dying, and None when the step can go ahead."""
        self._planned_retire_plan = None
        if step_id != "janitor_worktree_retire":
            return None
        try:
            keep_regex(self.cfg)  # an invalid keep list fails the step before the doctor runs
            self._planned_retire_plan = plan_retire_worktrees(
                self.cfg,
                self.home,
                self._runner,
                report=lambda: self._lane_report(write=not dry_run),
                clock=self._clock,
                dry_run=dry_run,
            )
        except Exception as exc:  # noqa: BLE001 — bad operator config must not kill the tick
            meta = STEP_CATALOG.get(step_id, {})
            title = str(meta.get("title", step_id))
            return StepResult(step_id, title, StepStatus.FAILED, reason=str(exc)[:200])
        return None

    def run_watch_tick(
        self, rw_state: dict[str, Any], prev_free: Optional[float], dry_run: bool = False
    ) -> tuple[RunRecord, list[dict[str, Any]], bool]:
        sample = sample_mac()
        hits = evaluate_hits(sample, prev_free, self.cfg.get("resource_watch", {}))
        # Only a sample that really came back from df is worth keeping.  A df
        # that failed reads as zero free, and writing that here would report a
        # critical shortage the disk does not have until the next tick lands.
        if sample.get("disk_sample_ok", True):
            rw_state["prev_disk_free_gb"] = sample.get("disk_free_gb")
        record = RunRecord(
            run_id=uuid.uuid4().hex[:12],
            trigger=TriggerKind.WATCH,
            started_at=time.time(),
        )
        should_clean = False
        try:
            with HousekeeperLock(self.lock_path):
                record.steps.append(
                    StepResult(
                        "resource_sample",
                        "Check disk and memory",
                        StepStatus.RAN,
                        reason=_plural(len(hits), "threshold hit") if hits else "within limits",
                    )
                )
                self._emit_partial(record, dry_run=dry_run)
                if hits:
                    now = time.time()
                    last_clean = float(rw_state.get("last_clean_at", 0))
                    crit = any(h.get("severity") == "critical" for h in hits)
                    cooldown = float(
                        self.cfg.get("resource_watch", {}).get(
                            "clean_cooldown_crit_sec" if crit else "clean_cooldown_sec", 7200
                        )
                    )
                    if now - last_clean >= cooldown:
                        should_clean = True
                        pressure_record = self.run(TriggerKind.PRESSURE, pressure=True, band="full", dry_run=dry_run)
                        record.steps.extend(pressure_record.steps)
                        self._emit_partial(record, dry_run=dry_run)
                        rw_state["last_clean_at"] = now
                        if not dry_run:
                            # The sample above is the disk as it was BEFORE the
                            # cleanup.  Keeping it makes the status this same
                            # tick publishes report the shortage the run just
                            # resolved, so measure the disk again afterwards.
                            after = sample_mac()
                            if after.get("disk_sample_ok", True):
                                rw_state["prev_disk_free_gb"] = after.get("disk_free_gb")
                record.finish(summary="watch tick")
        except LockHeld as exc:
            record.steps.append(
                StepResult("housekeeper_lock", "Housekeeper lock", StepStatus.SKIPPED, reason=str(exc))
            )
            record.finish(0, summary="watch skipped; lock held")
        return record, hits, should_clean

    def _run_step(
        self,
        step_id: str,
        pressure: bool,
        band: str,
        sample: dict[str, Any],
        mode: str,
        dry_run: bool,
    ) -> StepResult:
        meta = STEP_CATALOG.get(step_id, {})
        title = str(meta.get("title", step_id))
        started = time.time()
        try:
            freed, reason, status = self._dispatch(step_id, pressure, band, sample, mode, dry_run)
            dur = int((time.time() - started) * 1000)
            return StepResult(step_id, title, status, reason=reason, bytes_freed=freed, duration_ms=dur)
        except Exception as exc:  # noqa: BLE001 — step boundary; record failure
            dur = int((time.time() - started) * 1000)
            return StepResult(step_id, title, StepStatus.FAILED, reason=str(exc)[:200], duration_ms=dur)

    def _dispatch(
        self,
        step_id: str,
        pressure: bool,
        band: str,
        sample: dict[str, Any],
        mode: str,
        dry_run: bool,
    ) -> tuple[int, str, StepStatus]:
        if sys.platform != "darwin" and step_id not in ("resource_sample",):
            return 0, "skipped on non-macOS host", StepStatus.SKIPPED

        if dry_run and step_id not in _DRY_RUN_AWARE_STEPS:
            return 0, "dry run; no changes", StepStatus.SKIPPED

        handlers: dict[str, Callable[..., tuple[int, str, StepStatus]]] = {
            "resource_sample": lambda: (0, "sampled", StepStatus.RAN),
            "xcode_device_support": self._xcode_device_support,
            "xcode_derived_data": self._xcode_derived_data,
            "core_simulator_caches": self._core_simulator_caches,
            "simctl_delete_unavailable": self._simctl_delete_unavailable,
            "shutdown_simulators": lambda: self._shutdown_simulators(dry_run),
            "npm_cache": self._npm_cache,
            "pnpm_store": self._pnpm_store,
            "yarn_cache": self._yarn_cache,
            "brew_cleanup": self._brew_cleanup,
            "hoghunter_reclaim": lambda: self._hoghunter_reclaim(band),
            "cleanmymac_cli": self._cleanmymac_cli,
            "pm2_logs": self._pm2_logs,
            "vitest_temp_dbs": self._vitest_temp_dbs,
            "spotlight_journals": self._spotlight_journals,
            "codex_archived_sessions": self._codex_archived_sessions,
            "grok_sessions": lambda: self._grok_sessions(pressure),
            "antigravity_brain": self._antigravity_brain,
            "pressure_apps_deps": lambda: self._pressure_apps_deps(dry_run) if pressure else (0, "not under pressure", StepStatus.SKIPPED),
            "coolify_remote": self._coolify_remote,
            "janitor_worktree_retire": lambda: self._janitor_worktree_retire(dry_run),
            "janitor_cache_reclaim": lambda: self._janitor_cache_reclaim(sample, mode, dry_run),
        }
        handler = handlers.get(step_id)
        if not handler:
            return 0, "unknown step", StepStatus.SKIPPED
        return handler()

    def _dir_size_before_clear(self, path: Path) -> int:
        if not path.exists():
            return 0
        total = 0
        try:
            for root, _dirs, files in os.walk(path):
                for f in files:
                    try:
                        total += (Path(root) / f).stat().st_size
                    except OSError:
                        pass
        except OSError:
            return 0
        return total

    def _clear_glob_children(self, directory: Path) -> tuple[int, str, StepStatus]:
        if not directory.is_dir():
            return 0, "path missing", StepStatus.SKIPPED
        before = self._dir_size_before_clear(directory)
        for child in directory.iterdir():
            try:
                if child.is_dir():
                    shutil.rmtree(child, ignore_errors=True)
                else:
                    child.unlink(missing_ok=True)
            except OSError:
                pass
        return before, "cleared", StepStatus.RAN

    def _build_running(self) -> str:
        """Non-empty when xcodebuild, swift-frontend or clang runs, or when the check itself failed.  This is the
        skipWhenAny gate of the xcode-artifacts and dev-caches rules in config/reclaim-policy.json."""
        for name in _BUILD_PROCESSES:
            probe = lanes.executable_state if name == "xcodebuild" else lanes.process_state
            busy, reason = probe(self._runner, name, f"{name} is running")
            if busy:
                return reason
        return ""

    def _clear_idle_children(self, directory: Path, idle_seconds: float, what: str) -> tuple[int, str, StepStatus]:
        """Delete the child folders of directory that nothing wrote to within idle_seconds, and only while no
        build runs.  A symlink, a loose file, a folder with a keep marker, and a folder that cannot be read in
        full (unreadable, or too large to walk) are kept."""
        if directory.is_symlink() or not directory.is_dir():
            return 0, "path missing", StepStatus.SKIPPED
        busy = self._build_running()
        if busy:
            return 0, f"skipped: {busy}", StepStatus.SKIPPED
        freed = cleared = kept = failed = 0
        try:
            children = sorted(directory.iterdir())
        except OSError as exc:
            return 0, f"cannot list {directory.name} ({type(exc).__name__})", StepStatus.SKIPPED
        for child in children:
            if child.is_symlink() or not child.is_dir():
                continue
            if os.path.lexists(child / lanes.KEEP_SENTINEL) or lanes.tree_changed_within(
                str(child), idle_seconds, self._clock, cap=lanes.NESTED_WALK_CAP
            ):
                kept += 1
                continue
            size = self._dir_size_before_clear(child)
            try:
                shutil.rmtree(child)
            except OSError:
                failed += 1
                continue
            freed += size
            cleared += 1
        reason = f"cleared {_plural(cleared, what + ' folder')}, kept {kept} in use or changed recently"
        if failed:
            reason += f", {failed} could not be removed"
        return freed, reason, StepStatus.RAN if cleared else StepStatus.SKIPPED

    def _xcode_device_support(self) -> tuple[int, str, StepStatus]:
        """Off by default (Mode 3 in docs/DEV-CLEANUP-PLAYBOOK.md).  When on: per OS version, untouched 7 days."""
        return self._clear_idle_children(
            self.home / "Library/Developer/Xcode/iOS DeviceSupport", _DEVICE_SUPPORT_IDLE_SECONDS, "DeviceSupport version"
        )

    def _derived_data_dir_problem(self, path: Path) -> str:
        """Why path cannot be the DerivedData folder, or "" when it can.  The step deletes every idle child of
        the folder it is given, so a path typed in Settings > Maintenance (or reported by Xcode) has to be an
        absolute, real folder named DerivedData, and never the home folder or one of its parents."""
        if not path.is_absolute():
            return "not an absolute path"
        if path.is_symlink():
            return "a symlink"
        if not path.is_dir():
            return "not a folder"
        if path.name.lower() != "deriveddata":
            return "not a folder named DerivedData"
        try:
            real = path.resolve()
            home = self.home.resolve()
        except OSError as exc:
            return f"cannot resolve ({type(exc).__name__})"
        if real == home or real in home.parents or real == Path(real.anchor):
            return "the home folder or one of its parents"
        return ""

    def _xcode_derived_data_path(self) -> tuple[Optional[Path], str]:
        """Finds Xcode DerivedData: the path set in Settings > Maintenance first, then the default under home,
        then Xcode's IDECustomDerivedDataLocation.  A configured path that fails _derived_data_dir_problem is a
        skip with the reason (None, why), never a silent fall back to another folder; an Xcode-reported one that
        fails it is ignored."""
        cfg_path = str(self.cfg.get("xcode_derived_data_path") or "").strip()
        if cfg_path:
            p = expand_path(cfg_path, self.home)
            problem = self._derived_data_dir_problem(p)
            if problem:
                return None, f"configured DerivedData path refused: {problem} ({p})"
            return p, ""
        default_home = self.home / "Library/Developer/Xcode/DerivedData"
        if default_home.is_dir():
            return default_home, ""
        try:
            res = subprocess.run(
                ["defaults", "read", "com.apple.dt.Xcode", "IDECustomDerivedDataLocation"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if res.returncode == 0 and res.stdout.strip():
                custom = Path(res.stdout.strip()).expanduser()
                if not self._derived_data_dir_problem(custom):
                    return custom, ""
        except Exception:
            pass
        return default_home, ""

    def _xcode_derived_data(self) -> tuple[int, str, StepStatus]:
        """Per project folder, untouched 90 minutes, and never while a build runs."""
        path, refused = self._xcode_derived_data_path()
        if path is None:
            return 0, refused, StepStatus.SKIPPED
        if not path.is_dir():
            return 0, f"DerivedData path missing ({path})", StepStatus.SKIPPED
        return self._clear_idle_children(path, _DERIVED_DATA_IDLE_SECONDS, "DerivedData project")

    def _core_simulator_caches(self) -> tuple[int, str, StepStatus]:
        return self._clear_glob_children(self.home / "Library/Developer/CoreSimulator/Caches")

    def _simctl_delete_unavailable(self) -> tuple[int, str, StepStatus]:
        """Never runs anything.  `xcrun simctl delete unavailable` deletes simulator devices (user simulator state)
        under CoreSimulator/Devices, which config/reclaim-policy.json and scripts/hoghunter-clean never touch.  The
        step stays in the catalog so the app's toggle for it keeps working; it only reports why it did nothing."""
        return (
            0,
            "not run: it would delete simulator devices in CoreSimulator/Devices, which no cleanup step touches",
            StepStatus.SKIPPED,
        )

    def _tool_command(self, tool_id: str, name: str) -> Optional[str]:
        """The command to run for an external tool: the installation picked under Connected CLI in Settings >
        Maintenance (`tool_paths`) when it is an absolute path to an executable file, otherwise the bare name
        for PATH to resolve.  None when neither exists, which the caller reports as not installed."""
        picked_paths = self.cfg.get("tool_paths")
        if isinstance(picked_paths, dict):
            picked = str(picked_paths.get(tool_id) or "").strip()
            if picked and os.path.isabs(picked) and os.path.isfile(picked) and os.access(picked, os.X_OK):
                return picked
        return name if shutil.which(name) else None

    def _shutdown_simulators(self, dry_run: bool = False) -> tuple[int, str, StepStatus]:
        """Shut down booted Xcode iOS Simulators when no build, test, or Simulator.app is active.  When Bitrig is
        running, 1 booted simulator is exempted so Bitrig can keep its single shared simulator across projects."""
        if not shutil.which("xcrun"):
            return 0, "xcrun not installed", StepStatus.SKIPPED
        busy, reason = lanes.executable_state(self._runner, "xcodebuild", "xcodebuild is running")
        if busy:
            return 0, f"skipped: {reason}", StepStatus.SKIPPED
        busy, reason = lanes.process_state(self._runner, "xctest", "xctest is running")
        if busy:
            return 0, f"skipped: {reason}", StepStatus.SKIPPED
        busy, reason = lanes.process_state(self._runner, r"Simulator\.app", "Simulator.app is open")
        if busy:
            return 0, f"skipped: {reason}", StepStatus.SKIPPED
        try:
            proc = self._runner(
                ["xcrun", "simctl", "list", "devices", "booted", "-j"],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except Exception as exc:  # noqa: BLE001
            return 0, f"simctl list failed ({type(exc).__name__})", StepStatus.SKIPPED
        if getattr(proc, "returncode", 1) != 0:
            return 0, "simctl list failed", StepStatus.SKIPPED
        try:
            doc = json.loads(getattr(proc, "stdout", "") or "{}")
        except ValueError:
            return 0, "simctl list returned invalid JSON", StepStatus.SKIPPED
        booted: list[dict[str, str]] = []
        for items in (doc.get("devices") or {}).values():
            for dev in items or []:
                if isinstance(dev, dict) and dev.get("state") == "Booted" and dev.get("udid"):
                    booted.append({"udid": str(dev["udid"]), "name": str(dev.get("name", ""))})
        if not booted:
            return 0, "0 booted simulators", StepStatus.SKIPPED
        def _score_booted(idx_dev: tuple[int, dict[str, str]]) -> tuple[float, int]:
            idx, dev = idx_dev
            u = dev["udid"]
            t = 0.0
            reaper_state = self.home / "Library" / "Application Support" / "sim-idle-reaper" / "state.json"
            if reaper_state.is_file():
                try:
                    with open(reaper_state, encoding="utf-8") as f:
                        doc_reaper = json.load(f)
                    t = float(doc_reaper.get(u, 0.0))
                except Exception:
                    pass
            dev_dir = self.home / "Library" / "Developer" / "CoreSimulator" / "Devices" / u
            for sub in (dev_dir / "data", dev_dir):
                try:
                    t = max(t, sub.stat().st_mtime)
                except OSError:
                    pass
            return (t, -idx)

        bitrig_busy, _ = lanes.process_state(self._runner, "[Bb]itrig", "Bitrig is running")
        if bitrig_busy:
            if len(booted) == 1:
                return 0, "skipped: Bitrig is running (1 simulator exempt)", StepStatus.SKIPPED
            _exempt_idx, exempt_dev = max(enumerate(booted), key=_score_booted)
            targets = [dev for dev in booted if dev["udid"] != exempt_dev["udid"]]
        else:
            targets = booted
        suffix = ", kept 1 for Bitrig" if bitrig_busy else ""
        if dry_run:
            for dev in targets:
                self.plan.append({"step": "shutdown_simulators", "action": "would_shutdown", "udid": dev["udid"], "name": dev["name"]})
            return 0, f"would shut down {_plural(len(targets), 'booted simulator')}{suffix}", StepStatus.SKIPPED
        shut = 0
        failed = 0
        for dev in targets:
            try:
                res = self._runner(
                    ["xcrun", "simctl", "shutdown", dev["udid"]],
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                if getattr(res, "returncode", 1) == 0:
                    shut += 1
                    self.plan.append({"step": "shutdown_simulators", "action": "shutdown", "udid": dev["udid"], "name": dev["name"]})
                else:
                    failed += 1
            except Exception:  # noqa: BLE001
                failed += 1
        reason = f"shut down {_plural(shut, 'booted simulator')}{suffix}"
        if failed:
            reason += f", {failed} failed"
        return 0, reason, StepStatus.RAN if shut else StepStatus.SKIPPED

    def _npm_cache(self) -> tuple[int, str, StepStatus]:
        npm = self._tool_command("npm", "npm")
        if not npm:
            return 0, "npm not installed", StepStatus.SKIPPED
        if self._install_running("npm (install|ci|update|prune)"):
            return 0, self._skip_busy("npm install in progress"), StepStatus.SKIPPED
        busy = self._build_running()
        if busy:
            return 0, f"skipped: {busy}", StepStatus.SKIPPED
        subprocess.run([npm, "cache", "clean", "--force"], capture_output=True, timeout=300)
        npx = self.home / ".npm/_npx"
        if npx.is_symlink() or not npx.is_dir():
            return 0, "npm cache cleaned", StepStatus.RAN
        # Tools started with npx (MCP servers, for one) run from ~/.npm/_npx; keep it while any process names it.
        if self._pgrep_f(str(npx)):
            return 0, "npm cache cleaned; npx folder kept", StepStatus.RAN
        freed = self._dir_size_before_clear(npx)
        shutil.rmtree(npx, ignore_errors=True)
        return freed, "npm cache cleaned", StepStatus.RAN

    def _pnpm_store(self) -> tuple[int, str, StepStatus]:
        if not shutil.which("pnpm"):
            return 0, "pnpm not installed", StepStatus.SKIPPED
        if self._install_running("pnpm (install|update|add|import|dlx|link)"):
            return 0, self._skip_busy("pnpm install in progress"), StepStatus.SKIPPED
        busy = self._build_running()
        if busy:
            return 0, f"skipped: {busy}", StepStatus.SKIPPED
        subprocess.run(["pnpm", "store", "prune"], capture_output=True, timeout=300)
        return 0, "pnpm store pruned", StepStatus.RAN

    def _yarn_cache(self) -> tuple[int, str, StepStatus]:
        if not shutil.which("yarn"):
            return 0, "yarn not installed", StepStatus.SKIPPED
        if self._install_running("yarn (install|add|upgrade|up|remove)|yarn$"):
            return 0, self._skip_busy("yarn install in progress"), StepStatus.SKIPPED
        busy = self._build_running()
        if busy:
            return 0, f"skipped: {busy}", StepStatus.SKIPPED
        subprocess.run(["yarn", "cache", "clean"], capture_output=True, timeout=300)
        return 0, "yarn cache cleaned", StepStatus.RAN

    def _brew_cleanup(self) -> tuple[int, str, StepStatus]:
        """The brew rule of config/reclaim-policy.json: `brew cleanup --prune=all`, skipped while brew or node-gyp
        runs."""
        brew = self._tool_command("brew", "brew")
        if not brew:
            return 0, "brew not installed", StepStatus.SKIPPED
        if self._install_running(r"brew(\.sh|\.rb)? (install|upgrade|reinstall|update|cleanup|bundle|fetch|uninstall)"):
            return 0, self._skip_busy("brew install in progress"), StepStatus.SKIPPED
        if self._install_running("node-gyp"):
            return 0, self._skip_busy("node-gyp build in progress"), StepStatus.SKIPPED
        subprocess.run([brew, "cleanup", "--prune=all"], capture_output=True, timeout=600)
        return 0, "brew cleanup --prune=all finished", StepStatus.RAN

    def _hoghunter_reclaim(self, band: str) -> tuple[int, str, StepStatus]:
        """Run hoghunter-clean with a time budget, report the bytes it really freed, and treat "budget spent" as
        a good partial run: it removes the most valuable things first and the next run rescans and carries on.
        Only a cleaner that overruns its budget plus the grace period, or exits non-zero, is a failure."""
        path = Path(str(self.cfg.get("hoghunter_clean", "")))
        if not path.is_file():
            return 0, "hoghunter-clean not found", StepStatus.SKIPPED
        budget = self._reclaim_budget()
        cmd = [str(path), "--clean", f"--band={band}", "--json", f"--budget-sec={budget}"]
        code, out, err, timed_out = _run_in_own_group(cmd, budget + _RECLAIM_GRACE_SECONDS)
        if timed_out:
            return (
                0,
                f"stopped: hoghunter-clean overran its {budget}s budget by more than {_RECLAIM_GRACE_SECONDS}s",
                StepStatus.FAILED,
            )
        if code != 0:
            tail = [ln for ln in (err or "").strip().splitlines() if ln.strip()]
            return 0, (tail[-1] if tail else f"reclaim exited {code}")[:200], StepStatus.FAILED
        try:
            report = json.loads(out)
        except ValueError:
            report = None
        if not isinstance(report, dict) or "applied_count" not in report:
            return 0, f"band={band}", StepStatus.RAN  # an older cleaner: it ran, and it cannot say what it freed
        applied = int(report.get("applied_count") or 0)
        failed = int(report.get("failed_count") or 0)
        total = int(report.get("actionable_count") or 0)
        freed = int(report.get("applied_bytes") or 0)
        # `applied_bytes` is the size the scan ESTIMATED before each delete,
        # not proof that the bytes came back.  The cleaner's df-verified
        # `disk_free_delta_gb` is the measured truth, so prefer it when the
        # cleaner is new enough to report it.  Reporting the estimate as
        # "freed" is how a run that deleted nothing still looked like a
        # success.  (Measured 2026-10-19: 6.48 GB estimated, 0.05 GB of
        # actual change, because the host spent it as fast as it was freed.)
        delta_gb = report.get("disk_free_delta_gb")
        if delta_gb is not None:
            measured = int(float(delta_gb) * (1024 ** 3))
            # The delta is the NET change in free space: the host can spend
            # what the run freed, so it is often negative.  `freed` is summed
            # into RunRecord.bytes_freed and rendered by lanes.format_size, so
            # a negative value reaches the panel as "reclaimed -51.2 MB".
            freed = max(0, measured)
            # The reason still says what was measured.  A negative number
            # printed next to "freed" reads as a bug, so the host-spending
            # case is put in words instead: that is what actually happened.
            reason = (
                f"band={band}: removed {applied} of {_plural(total, 'item')}, "
                f"{lanes.format_size(freed)} freed, "
            )
            if measured < 0:
                reason += f"the host used {lanes.format_size(-measured)} while the run worked"
            else:
                reason += f"{lanes.format_size(measured)} measured"
        else:
            reason = f"band={band}: removed {applied} of {_plural(total, 'item')}, {lanes.format_size(freed)}"
        if report.get("scan_truncated"):
            reason += "; the scan hit its budget share, more may be left"
        if report.get("budget_exhausted"):
            reason += f"; time budget spent, {int(report.get('remaining_count') or 0)} left for the next run"
        if failed:
            reason += f"; {failed} could not be removed"
        if failed and not applied:
            return 0, reason[:200], StepStatus.FAILED
        return freed, reason[:200], StepStatus.RAN

    def _cleanmymac_cli(self) -> tuple[int, str, StepStatus]:
        """Run the CleanMyMac CLI's non-interactive sweeps when installed.  Off by default: the CLI is MacPaw
        closed-source software, so this step only invokes it, never vendors it, and only after the owner turns
        the step on.  Mirrors the --cleanmymac path in scripts/hoghunter-clean; keep the two command lists in
        sync.  A missing CLI is a skip, not a failure; a non-zero exit or a timeout is a failure with the tail."""
        cleanmymac = self._tool_command("cleanmymac", "cleanmymac")
        if cleanmymac is None:
            return 0, "CleanMyMac CLI not installed", StepStatus.SKIPPED
        commands = (
            ([cleanmymac, "clean", "junk", "--force"], 600),
            ([cleanmymac, "optimize", "purgeable"], 300),
        )
        ran: list[str] = []
        for argv, timeout in commands:
            try:
                proc = self._runner(argv, capture_output=True, text=True, timeout=timeout)
            except subprocess.TimeoutExpired:
                return 0, f"{' '.join(argv[1:])}: no finish within {timeout}s", StepStatus.FAILED
            except OSError as exc:
                return 0, f"{' '.join(argv[1:])}: {type(exc).__name__}", StepStatus.FAILED
            code = getattr(proc, "returncode", 1)
            if code != 0:
                out = (getattr(proc, "stdout", "") or "") + "\n" + (getattr(proc, "stderr", "") or "")
                tail = [ln for ln in out.splitlines() if ln.strip()]
                return 0, ((tail[-1] if tail else f"exit {code}") + f" ({' '.join(argv[1:])})")[:200], StepStatus.FAILED
            ran.append(" ".join(argv[1:]))
        return 0, f"CleanMyMac sweeps finished ({'; '.join(ran)})", StepStatus.RAN

    def _reclaim_budget(self) -> int:
        try:
            budget = int(float(self.cfg.get("hoghunter_clean_budget_sec", _RECLAIM_BUDGET_SECONDS)))
        except (TypeError, ValueError):
            budget = _RECLAIM_BUDGET_SECONDS
        return max(30, budget)

    def _pm2_logs(self) -> tuple[int, str, StepStatus]:
        cap_mb = int(self.cfg.get("pm2_logs_cap_mb", 50))
        cap = cap_mb * 1024 * 1024
        truncated = 0
        freed = 0
        logs_dir = self.home / ".pm2/logs"
        if logs_dir.is_dir():
            for logf in logs_dir.glob("*.log"):
                try:
                    size = logf.stat().st_size
                    if size > cap:
                        logf.write_text("")
                        truncated += 1
                        freed += size
                except OSError:
                    pass
        pm2_log = self.home / ".pm2/pm2.log"
        try:
            if pm2_log.is_file():
                size = pm2_log.stat().st_size
                if size > cap:
                    pm2_log.write_text("")
                    truncated += 1
                    freed += size
        except OSError:
            pass
        return freed, f"truncated {_plural(truncated, 'log')} in place", StepStatus.RAN

    def _vitest_temp_dbs(self) -> tuple[int, str, StepStatus]:
        try:
            ut = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True, timeout=5).strip().rstrip("/")
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
            return 0, "temp dir unavailable", StepStatus.SKIPPED
        if not ut:
            return 0, "temp dir unavailable", StepStatus.SKIPPED
        removed = 0
        freed = 0
        for entry in Path(ut).glob("agentic-*"):
            try:
                if time.time() - entry.stat().st_mtime > 360 * 60:
                    if entry.is_dir():
                        size = self._dir_size_before_clear(entry)
                        shutil.rmtree(entry, ignore_errors=True)
                    else:
                        size = entry.stat().st_size
                        entry.unlink(missing_ok=True)
                    removed += 1
                    freed += size
            except OSError:
                pass
        return freed, f"removed {_plural(removed, 'stale temp db')}", StepStatus.RAN

    def _spotlight_journals(self) -> tuple[int, str, StepStatus]:
        """Reset the Spotlight indexing journals.  macOS protects this folder (TCC): a process without Full Disk
        Access is refused when it lists it, even though the folder shows as the user's own.  The folder is
        listed FIRST, so a refusal is reported as a skip before any Spotlight daemon is touched.  The step used
        to run killall and then fail, which restarted Spotlight on every full run for nothing."""
        pipe = self.home / "Library/Metadata/CoreSpotlight/DocumentProcessing/PipelineStorage"
        try:
            if not pipe.is_dir():
                return 0, "PipelineStorage missing", StepStatus.SKIPPED
            list(pipe.iterdir())  # the probe: this is the call macOS refuses without Full Disk Access
        except OSError as exc:
            if exc.errno in _PROTECTED_ERRNOS:
                return 0, _SPOTLIGHT_NEEDS_FDA, StepStatus.SKIPPED
            raise
        try:
            subprocess.run(["killall", "knowledgeconstructiond", "corespotlightd", "mds_stores"], capture_output=True)
            freed = 0
            for kind in ("Journals", "HistoricalReports"):
                for found in pipe.rglob(kind):
                    if found.is_dir():
                        freed += self._dir_size_before_clear(found)
                        shutil.rmtree(found, ignore_errors=True)
            for child in sorted(pipe.iterdir()):
                if child.is_dir():
                    (child / "Journals").mkdir(parents=True, exist_ok=True)
            for db in ("StateStore.db", "StateStore.db-wal", "StateStore.db-shm"):
                try:
                    (pipe / db).unlink(missing_ok=True)
                except OSError:
                    pass
        except OSError as exc:
            if exc.errno in _PROTECTED_ERRNOS:
                return 0, _SPOTLIGHT_NEEDS_FDA, StepStatus.SKIPPED
            raise
        return freed, "journals reset", StepStatus.RAN

    def _codex_archived_sessions(self) -> tuple[int, str, StepStatus]:
        path = self.home / ".codex/archived_sessions"
        return self._clear_glob_children(path) if path.is_dir() else (0, "nothing to clear", StepStatus.SKIPPED)

    def _grok_sessions(self, pressure: bool) -> tuple[int, str, StepStatus]:
        root = self.home / ".grok/sessions"
        if not root.is_dir():
            return 0, "no sessions dir", StepStatus.SKIPPED
        days = int(self.cfg.get("grok_session_days_pressure" if pressure else "grok_session_days", 7))
        cutoff = days * 86400
        now = time.time()
        removed = 0
        freed = 0
        for dirpath, _dirnames, filenames in os.walk(root, topdown=False):
            p = Path(dirpath)
            name = p.name
            if not (name.startswith("019") and len(name) >= 20):
                continue
            names = set(filenames)
            if "updates.jsonl" not in names and "chat_history.jsonl" not in names:
                continue
            try:
                newest = max(os.path.getmtime(os.path.join(dirpath, f)) for f in filenames)
            except (OSError, ValueError):
                continue
            if now - newest > cutoff:
                freed += self._dir_size_before_clear(p)
                shutil.rmtree(p, ignore_errors=True)
                removed += 1
        return freed, f"removed {_plural(removed, 'session')}", StepStatus.RAN

    def _antigravity_brain(self) -> tuple[int, str, StepStatus]:
        brain = self.home / ".gemini/antigravity/brain"
        if not brain.is_dir():
            return 0, "no brain dir", StepStatus.SKIPPED
        removed = 0
        freed = 0
        cutoff = time.time() - 7 * 86400
        for child in brain.iterdir():
            if child.is_dir():
                try:
                    if child.stat().st_mtime < cutoff:
                        freed += self._dir_size_before_clear(child)
                        shutil.rmtree(child, ignore_errors=True)
                        removed += 1
                except OSError:
                    pass
        return freed, f"pruned {_plural(removed, 'folder')}", StepStatus.RAN

    def _lane_report(self, write: bool = True) -> lanes.LaneReport:
        """One doctor run per engine run, shared by every lane step.  The doctor takes minutes; never run it twice.
        The last good report is cached on disk, so a timed-out doctor run falls back to recent evidence
        instead of retiring nothing; removal still re-checks every lane live.  Dry runs pass write=False:
        planning may read the cache but never persists state."""
        if self._lane_report_cache is None:
            settings = lanes.lane_settings(self.cfg, self.home)
            cache_file = lanes.doctor_cache_file(data_dir_for(self.cfg, self.home))
            self._lane_report_cache = lanes.load_report(
                settings, self.home, self._doctor_runner, self._clock,
                cache_file=cache_file, cache_write=write,
            )
        return self._lane_report_cache

    def _note(self, step_id: str, action: str, **fields: Any) -> dict[str, Any]:
        entry = {"step_id": step_id, "action": action, **fields}
        self.plan.append(entry)
        return entry

    @staticmethod
    def _log(data_dir: Optional[Path], entry: dict[str, Any]) -> None:
        if data_dir is not None:
            lanes.append_action_log(data_dir, entry)

    def _pressure_apps_deps(self, dry_run: bool = False) -> tuple[int, str, StepStatus]:
        """Clear regenerable build folders (node_modules and friends) in idle lanes.  The lane list comes from the
        lane doctor, so nested lanes are visible.  Fleet lanes only (never harness-managed worktrees).  A lane
        need not be merged, but it must be idle for 24 hours, have no process in it, no keep marker, and a clean
        tracked tree.  Only the folders in lanes.REGENERABLE_NAMES are ever deleted, and a folder holding a
        nested git repository is kept."""
        step = "pressure_apps_deps"
        keep_re = keep_regex(self.cfg)
        report = self._lane_report(write=not dry_run)
        if not report.ok:
            return 0, f"lane doctor unusable: {report.reason}; nothing removed", StepStatus.SKIPPED
        ctx = lanes.LaneContext(self.home, keep_re, lanes.lane_settings(self.cfg, self.home), self._runner, self._clock)
        passing, refused = lanes.dependency_candidates(report, ctx)
        data_dir = data_dir_for(self.cfg, self.home)
        freed = 0
        planned_bytes = 0
        folders = 0
        touched = 0
        for path, co in passing:
            choice, why = lanes.evaluate_dependency_lane(path, co, ctx)
            if choice is None:
                if why:  # an empty reason means the lane has nothing to clean, which is not a refusal
                    refused.append({"path": path, "reason": why})
                continue
            did_any = False
            for target in choice.targets:
                # Re-checked right before the delete: still a plain folder in the lane, no nested git repository.
                full, why = lanes.deletable_target(path, target["path"])
                if not full:
                    refused.append({"path": os.path.join(path, target["path"]), "reason": why})
                    continue
                size = lanes.dir_size_bytes(full, self._runner)
                if size is None:
                    size = self._dir_size_before_clear(Path(full))
                command = f"shutil.rmtree {full}"
                if dry_run:
                    planned_bytes += size
                    folders += 1
                    did_any = True
                    self._note(step, "would-remove-folder", path=full, lane=path, size_bytes=size, command=command)
                    continue
                try:
                    shutil.rmtree(full)
                except OSError as exc:
                    self._log(
                        data_dir,
                        self._note(
                            step, "failed", path=full, lane=path, size_bytes=size, command=command, error=type(exc).__name__
                        ),
                    )
                    continue
                freed += size
                folders += 1
                did_any = True
                self._log(
                    data_dir, self._note(step, "removed-folder", path=full, lane=path, size_bytes=size, command=command)
                )
            touched += 1 if did_any else 0
        if dry_run:
            for item in refused:
                self._note(step, "refused", **item)
        if not folders:
            return 0, f"no idle lanes with regenerable folders ({_plural(len(refused), 'lane')} refused)", StepStatus.SKIPPED
        if dry_run:
            return 0, f"would clear {_plural(folders, 'folder')} in {_plural(touched, 'lane')}, {lanes.format_size(planned_bytes)}", StepStatus.RAN
        return freed, f"cleared {_plural(folders, 'folder')} in {_plural(touched, 'lane')}, {lanes.format_size(freed)}", StepStatus.RAN

    def _coolify_remote(self) -> tuple[int, str, StepStatus]:
        host_value = self.cfg.get("coolify_ssh_host")
        if not isinstance(host_value, str) or not host_value.strip():
            return 0, "No remote servers are set up", StepStatus.SKIPPED
        host = host_value.strip()
        check = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes", host, "exit 0"],
            capture_output=True,
            timeout=10,
        )
        if check.returncode != 0:
            return 0, "ssh unavailable", StepStatus.SKIPPED
        subprocess.run(
            ["ssh", "-o", "ConnectTimeout=5", host, "/etc/cron.daily/coolify-auto-maintenance"],
            capture_output=True,
            timeout=120,
        )
        return 0, "remote maintenance triggered", StepStatus.RAN

    def _janitor_worktree_retire(self, dry_run: bool) -> tuple[int, str, StepStatus]:
        step = "janitor_worktree_retire"
        plan = self._planned_retire_plan
        if plan is None:
            plan = plan_retire_worktrees(
                self.cfg, self.home, self._runner,
                report=lambda: self._lane_report(write=not dry_run),
                clock=self._clock, dry_run=dry_run,
            )
        outcome = retire_worktrees(
            self.cfg,
            self.home,
            self._runner,
            dry_run=dry_run,
            plan=plan,
            clock=self._clock,
            data_dir=data_dir_for(self.cfg, self.home),
        )
        for action in outcome.actions:
            self._note(step, action.pop("action", "action"), **action)
        if dry_run:
            for item in plan.refused:
                self._note(step, "refused", **item)
        if not plan.ok:
            return 0, outcome.detail, StepStatus.SKIPPED
        return outcome.bytes_freed, outcome.detail, StepStatus.RAN if outcome.actions else StepStatus.SKIPPED

    def _janitor_cache_reclaim(self, sample: dict[str, Any], mode: str, dry_run: bool) -> tuple[int, str, StepStatus]:
        # The load guard that used to open this method is gone on purpose.  It
        # skipped the disk reclaim whenever the host was loaded, which is
        # precisely when the disk needs clearing, so the step never ran on a
        # host that needed it.  `mode` is still accepted because the dispatcher
        # passes it, but it no longer decides whether this step happens.
        #
        # The cheap band is the safe tier, and the reclaim engine bounds itself
        # with a time budget and a hard stop, so running it on a loaded host is
        # bounded work, not an outage.
        if not sample.get("disk_sample_ok", True):
            # A df that failed leaves disk_free_gb at zero, and zero free is
            # below every threshold, so this would run a full cheap-band
            # reclaim -- deleting app caches and agent state -- on a disk that
            # is actually healthy.  Skip rather than act on a number nobody
            # measured.
            return 0, "disk sample unavailable; skipping cache reclaim", StepStatus.SKIPPED
        free_gib = float(sample.get("disk_free_gb", 999))
        low = float(self.cfg.get("janitor", {}).get("low_free_gib", 80))
        if free_gib >= low:
            return 0, f"free {free_gib:.0f}G above {low:.0f}G threshold", StepStatus.SKIPPED
        if dry_run:
            return 0, "would reclaim caches", StepStatus.SKIPPED
        # The cheap band is the safe tier.  The semi-safe tier (snapshots,
        # device support, simulator runtimes) stays behind the engine's own
        # calm-band gate, so it is not widened here.
        band = "cheap"
        return self._hoghunter_reclaim(band)

    def _install_running(self, pattern: str) -> bool:
        """True when a matching process runs OR the check itself failed.  A pgrep that errors says nothing
        about what is running, so it counts as busy and the caller skips the step."""
        busy, reason = lanes.process_state(self._runner, pattern)
        self._busy_reason = reason
        return busy

    def _pgrep_f(self, path: str) -> bool:
        """True when a process's command line names this path, matched literally, or when the check failed."""
        busy, reason = lanes.path_process_state(self._runner, path)
        self._busy_reason = reason
        return busy

    def _skip_busy(self, base: str) -> str:
        if "treated as busy" in self._busy_reason:
            return f"skipped: {self._busy_reason}"
        return base

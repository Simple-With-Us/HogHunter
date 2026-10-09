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
from .config import STEP_CATALOG, expand_path, step_enabled, steps_for_trigger
from .janitor import RetirePlan, data_dir_for, keep_regex, plan_retire_worktrees, retire_worktrees
from .lock import HousekeeperLock, LockHeld
from .models import RunRecord, StepResult, StepStatus, TriggerKind
from .pressure import evaluate_hits, janitor_pressure_mode, sample_mac

# Steps that run the lane doctor.  Under extreme host load they are skipped like the other heavy janitor work.
_HEAVY_LANE_STEPS = ("janitor_worktree_retire", "janitor_cache_reclaim", "pressure_apps_deps")

# Gates for the older `full` steps, from config/reclaim-policy.json: the xcode-artifacts and dev-caches rules skip
# while any of these processes run (skipWhenAny), a DerivedData project must be untouched for the cache idle gate
# (idlenessGates.cacheMinutes, 90), and an iOS DeviceSupport version for 7 days (idlenessGates.deviceSupportDays).
_BUILD_PROCESSES = ("xcodebuild", "swift-frontend", "clang")
_DERIVED_DATA_IDLE_SECONDS = 90 * 60.0
_DEVICE_SUPPORT_IDLE_SECONDS = 7 * 86400.0

# hoghunter-clean gets a time budget it keeps itself (--budget-sec), and a hard stop a little later.  The old
# single 900 s kill reported a failure and no bytes even when the cleaner had done most of its work.  The budget
# stays under the 900 s the steps used to get, so a tick is never longer than before.
_RECLAIM_BUDGET_SECONDS = 600
_RECLAIM_GRACE_SECONDS = 180

# The Spotlight index folder is protected by macOS (TCC).  A launchd job whose interpreter has no Full Disk Access
# is refused when it lists the folder, with EPERM ("Operation not permitted").  That is a state of the Mac, not a
# failure of the step, so the step reports it as skipped.  Nothing here tries to get around the protection.
_SPOTLIGHT_NEEDS_FDA = "skipped: needs Full Disk Access (macOS blocks the Spotlight index folder)"
_PROTECTED_ERRNOS = (errno.EPERM, errno.EACCES)

# Steps that interpret dry_run themselves (planning vs destructive apply).
_DRY_RUN_AWARE_STEPS = frozenset(
    {"resource_sample", "janitor_worktree_retire", "janitor_cache_reclaim", "pressure_apps_deps"}
)


def _subprocess_run(cmd: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, **kwargs)


def _run_in_own_group(cmd: list[str], timeout: float) -> tuple[int, str, str, bool]:
    """Run cmd in its own process group and return (exit code, stdout, stderr, timed_out).  On a timeout the whole
    group is killed, so the find, lsof or du the child started cannot outlive it and keep the disk busy."""
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True
    )
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out or "", err or "", False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        try:
            out, err = proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            out, err = "", ""
        return -1, out or "", err or "", True


class VacuumEngine:
    def __init__(
        self,
        cfg: dict[str, Any],
        home: Path | None = None,
        runner: Optional[Callable[..., Any]] = None,
        doctor_runner: Optional[lanes.DoctorRunner] = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.home = home or Path.home()
        self.cfg = cfg
        self.lock_path = expand_path(str(cfg.get("housekeeper_lock", "")), self.home)
        # Injectable for tests: the process runner (git, pgrep, lsof, du), the doctor runner, and the clock.
        self._runner: Callable[..., Any] = runner or _subprocess_run
        self._doctor_runner = doctor_runner
        self._clock = clock
        self._planned_retire_plan: RetirePlan | None = None
        self._lane_report_cache: lanes.LaneReport | None = None
        self._busy_reason = ""
        # Itemized actions (dry run: what would happen; real run: what happened).  The CLI prints this.
        self.plan: list[dict[str, Any]] = []

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
                        continue
                    self._planned_retire_plan = None
                    if step_id == "janitor_worktree_retire":
                        try:
                            keep_regex(self.cfg)  # an invalid keep list fails the step before the doctor runs
                            self._planned_retire_plan = plan_retire_worktrees(
                                self.cfg,
                                self.home,
                                self._runner,
                                report=self._lane_report,
                                clock=self._clock,
                                dry_run=dry_run,
                            )
                        except Exception as exc:  # noqa: BLE001 — bad operator config must not kill the tick
                            record.steps.append(
                                StepResult(step_id, title, StepStatus.FAILED, reason=str(exc)[:200])
                            )
                            continue
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

    def run_watch_tick(
        self, rw_state: dict[str, Any], prev_free: Optional[float], dry_run: bool = False
    ) -> tuple[RunRecord, list[dict[str, Any]], bool]:
        sample = sample_mac()
        hits = evaluate_hits(sample, prev_free, self.cfg.get("resource_watch", {}))
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
                        reason=f"{len(hits)} threshold hit(s)" if hits else "within limits",
                    )
                )
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
                        rw_state["last_clean_at"] = now
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
            "npm_cache": self._npm_cache,
            "pnpm_store": self._pnpm_store,
            "yarn_cache": self._yarn_cache,
            "brew_cleanup": self._brew_cleanup,
            "hoghunter_reclaim": lambda: self._hoghunter_reclaim(band),
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
            busy, reason = lanes.process_state(self._runner, name, f"{name} is running")
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
        reason = f"cleared {cleared} {what} folder(s), kept {kept} in use or changed recently"
        if failed:
            reason += f", {failed} could not be removed"
        return freed, reason, StepStatus.RAN if cleared else StepStatus.SKIPPED

    def _xcode_device_support(self) -> tuple[int, str, StepStatus]:
        """Off by default (Mode 3 in docs/DEV-CLEANUP-PLAYBOOK.md).  When on: per OS version, untouched 7 days."""
        return self._clear_idle_children(
            self.home / "Library/Developer/Xcode/iOS DeviceSupport", _DEVICE_SUPPORT_IDLE_SECONDS, "DeviceSupport version"
        )

    def _xcode_derived_data(self) -> tuple[int, str, StepStatus]:
        """Per project folder, untouched 90 minutes, and never while a build runs."""
        return self._clear_idle_children(
            self.home / "Library/Developer/Xcode/DerivedData", _DERIVED_DATA_IDLE_SECONDS, "DerivedData project"
        )

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

    def _npm_cache(self) -> tuple[int, str, StepStatus]:
        if not shutil.which("npm"):
            return 0, "npm not installed", StepStatus.SKIPPED
        if self._install_running("npm (install|ci|update|prune)"):
            return 0, self._skip_busy("npm install in progress"), StepStatus.SKIPPED
        busy = self._build_running()
        if busy:
            return 0, f"skipped: {busy}", StepStatus.SKIPPED
        subprocess.run(["npm", "cache", "clean", "--force"], capture_output=True, timeout=300)
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
        if not shutil.which("brew"):
            return 0, "brew not installed", StepStatus.SKIPPED
        if self._install_running(r"brew(\.sh|\.rb)? (install|upgrade|reinstall|update|cleanup|bundle|fetch|uninstall)"):
            return 0, self._skip_busy("brew install in progress"), StepStatus.SKIPPED
        if self._install_running("node-gyp"):
            return 0, self._skip_busy("node-gyp build in progress"), StepStatus.SKIPPED
        subprocess.run(["brew", "cleanup", "--prune=all"], capture_output=True, timeout=600)
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
        reason = f"band={band}: removed {applied} of {total} item(s), {lanes.format_size(freed)}"
        if report.get("budget_exhausted"):
            reason += f"; time budget spent, {int(report.get('remaining_count') or 0)} left for the next run"
        if failed:
            reason += f"; {failed} could not be removed"
        if failed and not applied:
            return 0, reason[:200], StepStatus.FAILED
        return freed, reason[:200], StepStatus.RAN

    def _reclaim_budget(self) -> int:
        try:
            budget = int(float(self.cfg.get("hoghunter_clean_budget_sec", _RECLAIM_BUDGET_SECONDS)))
        except (TypeError, ValueError):
            budget = _RECLAIM_BUDGET_SECONDS
        return max(30, budget)

    def _pm2_logs(self) -> tuple[int, str, StepStatus]:
        cap = 50 * 1024 * 1024
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
        return freed, f"truncated {truncated} log(s) in place", StepStatus.RAN

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
        return freed, f"removed {removed} stale temp db(s)", StepStatus.RAN

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
        return freed, f"removed {removed} session(s)", StepStatus.RAN

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
        return freed, f"pruned {removed} folder(s)", StepStatus.RAN

    def _lane_report(self) -> lanes.LaneReport:
        """One doctor run per engine run, shared by every lane step.  The doctor takes minutes; never run it twice."""
        if self._lane_report_cache is None:
            settings = lanes.lane_settings(self.cfg, self.home)
            self._lane_report_cache = lanes.load_report(settings, self.home, self._doctor_runner, self._clock)
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
        report = self._lane_report()
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
            return 0, f"no idle lanes with regenerable folders ({len(refused)} lane(s) refused)", StepStatus.SKIPPED
        if dry_run:
            return 0, f"would clear {folders} folder(s) in {touched} lane(s), {lanes.format_size(planned_bytes)}", StepStatus.RAN
        return freed, f"cleared {folders} folder(s) in {touched} lane(s), {lanes.format_size(freed)}", StepStatus.RAN

    def _coolify_remote(self) -> tuple[int, str, StepStatus]:
        host_value = self.cfg.get("coolify_ssh_host")
        if not isinstance(host_value, str) or not host_value.strip():
            return 0, "coolify_ssh_host not configured", StepStatus.SKIPPED
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
                self.cfg, self.home, self._runner, report=self._lane_report, clock=self._clock, dry_run=dry_run
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
        if mode == "hard":
            return 0, "extreme load; skipped cache reclaim", StepStatus.SKIPPED
        free_gib = float(sample.get("disk_free_gb", 999))
        low = float(self.cfg.get("janitor", {}).get("low_free_gib", 80))
        if free_gib >= low:
            return 0, f"free {free_gib:.0f}G above {low:.0f}G threshold", StepStatus.SKIPPED
        if dry_run:
            return 0, "would reclaim caches", StepStatus.SKIPPED
        # Lean mode skips heavy du probes; still run hoghunter cheap band as cache sweep.
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

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Optional

from .config import STEP_CATALOG, expand_path, step_enabled, steps_for_trigger
from .janitor import plan_retire_worktrees, retire_worktrees
from .lock import HousekeeperLock, LockHeld
from .models import RunRecord, StepResult, StepStatus, TriggerKind
from .pressure import evaluate_hits, janitor_pressure_mode, sample_mac

KEEP_SENTINEL = ".janitor-keep"

# Steps that interpret dry_run themselves (planning vs destructive apply).
_DRY_RUN_AWARE_STEPS = frozenset(
    {"resource_sample", "janitor_worktree_retire", "janitor_cache_reclaim", "pressure_apps_deps"}
)


def _subprocess_run(cmd: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, **kwargs)


class VacuumEngine:
    def __init__(self, cfg: dict[str, Any], home: Path | None = None) -> None:
        self.home = home or Path.home()
        self.cfg = cfg
        self.lock_path = expand_path(str(cfg.get("housekeeper_lock", "")), self.home)
        self._planned_retire_candidates: list[tuple[str, str]] | None = None

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
        self._planned_retire_candidates = None
        try:
            with HousekeeperLock(self.lock_path):
                sample = sample_mac()
                mode = janitor_pressure_mode(sample, self.cfg.get("janitor", {}))
                for step_id in step_ids:
                    if not step_enabled(self.cfg, step_id):
                        continue
                    meta = STEP_CATALOG.get(step_id, {})
                    title = str(meta.get("title", step_id))
                    if mode == "hard" and step_id in ("janitor_worktree_retire", "janitor_cache_reclaim"):
                        record.steps.append(
                            StepResult(step_id, title, StepStatus.SKIPPED, reason="host under extreme load; cheap steps only")
                        )
                        continue
                    self._planned_retire_candidates = None
                    if step_id == "janitor_worktree_retire":
                        try:
                            self._planned_retire_candidates = plan_retire_worktrees(
                                self.cfg, self.home, _subprocess_run, _subprocess_run
                            )
                        except Exception as exc:  # noqa: BLE001 — bad operator config must not kill the tick
                            record.steps.append(
                                StepResult(step_id, title, StepStatus.FAILED, reason=str(exc)[:200])
                            )
                            continue
                    result = self._run_step(step_id, pressure=pressure, band=band, sample=sample, mode=mode, dry_run=dry_run)
                    record.steps.append(result)
                record.finish(0 if all(s.status != StepStatus.FAILED for s in record.steps) else 1)
        except LockHeld as exc:
            record.steps.append(
                StepResult("housekeeper_lock", "Housekeeper lock", StepStatus.SKIPPED, reason=str(exc))
            )
            record.finish(0, summary="skipped; peer holds lock")
        finally:
            self._planned_retire_candidates = None
        return record

    def run_watch_tick(self, rw_state: dict[str, Any], prev_free: Optional[float]) -> tuple[RunRecord, list[dict[str, Any]], bool]:
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
                escalation_failed = False
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
                        pressure_record = self.run(TriggerKind.PRESSURE, pressure=True, band="full")
                        record.steps.extend(pressure_record.steps)
                        rw_state["last_clean_at"] = now
                        escalation_failed = any(s.status == StepStatus.FAILED for s in pressure_record.steps)
                record.finish(1 if escalation_failed else 0, summary="watch tick")
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

    def _xcode_device_support(self) -> tuple[int, str, StepStatus]:
        return self._clear_glob_children(self.home / "Library/Developer/Xcode/iOS DeviceSupport")

    def _xcode_derived_data(self) -> tuple[int, str, StepStatus]:
        return self._clear_glob_children(self.home / "Library/Developer/Xcode/DerivedData")

    def _core_simulator_caches(self) -> tuple[int, str, StepStatus]:
        return self._clear_glob_children(self.home / "Library/Developer/CoreSimulator/Caches")

    def _simctl_delete_unavailable(self) -> tuple[int, str, StepStatus]:
        if not shutil.which("xcrun"):
            return 0, "xcrun not found", StepStatus.SKIPPED
        # Never simctl shutdown all — fleet recall + legacy mac-auto-cleanup comments.
        res = subprocess.run(["xcrun", "simctl", "delete", "unavailable"], capture_output=True, text=True, timeout=120)
        if res.returncode != 0:
            return 0, (res.stderr or res.stdout or "simctl failed")[:120], StepStatus.FAILED
        return 0, "unavailable simulators removed", StepStatus.RAN

    def _npm_cache(self) -> tuple[int, str, StepStatus]:
        if not shutil.which("npm"):
            return 0, "npm not installed", StepStatus.SKIPPED
        if self._install_running("npm (install|ci|update|prune)"):
            return 0, "npm install in progress", StepStatus.SKIPPED
        subprocess.run(["npm", "cache", "clean", "--force"], capture_output=True, timeout=300)
        npx = self.home / ".npm/_npx"
        freed = self._dir_size_before_clear(npx) if npx.is_dir() else 0
        shutil.rmtree(npx, ignore_errors=True)
        return freed, "npm cache cleaned", StepStatus.RAN

    def _pnpm_store(self) -> tuple[int, str, StepStatus]:
        if not shutil.which("pnpm"):
            return 0, "pnpm not installed", StepStatus.SKIPPED
        if self._install_running("pnpm (install|update|add|import|dlx|link)"):
            return 0, "pnpm install in progress", StepStatus.SKIPPED
        subprocess.run(["pnpm", "store", "prune"], capture_output=True, timeout=300)
        return 0, "pnpm store pruned", StepStatus.RAN

    def _yarn_cache(self) -> tuple[int, str, StepStatus]:
        if not shutil.which("yarn"):
            return 0, "yarn not installed", StepStatus.SKIPPED
        subprocess.run(["yarn", "cache", "clean"], capture_output=True, timeout=300)
        return 0, "yarn cache cleaned", StepStatus.RAN

    def _brew_cleanup(self) -> tuple[int, str, StepStatus]:
        if not shutil.which("brew"):
            return 0, "brew not installed", StepStatus.SKIPPED
        if self._install_running("brew (install|upgrade|reinstall)"):
            return 0, "brew install in progress", StepStatus.SKIPPED
        subprocess.run(["brew", "cleanup", "-s"], capture_output=True, timeout=600)
        return 0, "brew cleanup finished", StepStatus.RAN

    def _hoghunter_reclaim(self, band: str) -> tuple[int, str, StepStatus]:
        path = Path(str(self.cfg.get("hoghunter_clean", "")))
        if not path.is_file():
            return 0, "hoghunter-clean not found", StepStatus.SKIPPED
        res = subprocess.run(
            [str(path), "--clean", f"--band={band}"],
            capture_output=True,
            text=True,
            timeout=900,
        )
        if res.returncode != 0:
            return 0, (res.stderr or "reclaim failed")[:120], StepStatus.FAILED
        return 0, f"band={band}", StepStatus.RAN

    def _pm2_logs(self) -> tuple[int, str, StepStatus]:
        cap = 50 * 1024 * 1024
        truncated = 0
        logs_dir = self.home / ".pm2/logs"
        if logs_dir.is_dir():
            for logf in logs_dir.glob("*.log"):
                try:
                    if logf.stat().st_size > cap:
                        logf.write_text("")
                        truncated += 1
                except OSError:
                    pass
        pm2_log = self.home / ".pm2/pm2.log"
        try:
            if pm2_log.is_file() and pm2_log.stat().st_size > cap:
                pm2_log.write_text("")
                truncated += 1
        except OSError:
            pass
        return 0, f"truncated {truncated} log(s) in place", StepStatus.RAN

    def _vitest_temp_dbs(self) -> tuple[int, str, StepStatus]:
        try:
            ut = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True, timeout=5).strip().rstrip("/")
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
            return 0, "temp dir unavailable", StepStatus.SKIPPED
        if not ut:
            return 0, "temp dir unavailable", StepStatus.SKIPPED
        removed = 0
        for entry in Path(ut).glob("agentic-*"):
            try:
                if time.time() - entry.stat().st_mtime > 360 * 60:
                    if entry.is_dir():
                        shutil.rmtree(entry, ignore_errors=True)
                    else:
                        entry.unlink(missing_ok=True)
                    removed += 1
            except OSError:
                pass
        return 0, f"removed {removed} stale temp db(s)", StepStatus.RAN

    def _spotlight_journals(self) -> tuple[int, str, StepStatus]:
        pipe = self.home / "Library/Metadata/CoreSpotlight/DocumentProcessing/PipelineStorage"
        if not pipe.is_dir():
            return 0, "PipelineStorage missing", StepStatus.SKIPPED
        subprocess.run(["killall", "knowledgeconstructiond", "corespotlightd", "mds_stores"], capture_output=True)
        for journals in pipe.rglob("Journals"):
            if journals.is_dir():
                shutil.rmtree(journals, ignore_errors=True)
        for hist in pipe.rglob("HistoricalReports"):
            if hist.is_dir():
                shutil.rmtree(hist, ignore_errors=True)
        for child in pipe.iterdir():
            if child.is_dir():
                (child / "Journals").mkdir(parents=True, exist_ok=True)
        for db in ("StateStore.db", "StateStore.db-wal", "StateStore.db-shm"):
            try:
                (pipe / db).unlink(missing_ok=True)
            except OSError:
                pass
        return 0, "journals reset", StepStatus.RAN

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
                shutil.rmtree(p, ignore_errors=True)
                removed += 1
        return 0, f"removed {removed} session(s)", StepStatus.RAN

    def _antigravity_brain(self) -> tuple[int, str, StepStatus]:
        brain = self.home / ".gemini/antigravity/brain"
        if not brain.is_dir():
            return 0, "no brain dir", StepStatus.SKIPPED
        removed = 0
        cutoff = time.time() - 7 * 86400
        for child in brain.iterdir():
            if child.is_dir():
                try:
                    if child.stat().st_mtime < cutoff:
                        shutil.rmtree(child, ignore_errors=True)
                        removed += 1
                except OSError:
                    pass
        return 0, f"pruned {removed} folder(s)", StepStatus.RAN

    def _pressure_apps_deps(self, dry_run: bool = False) -> tuple[int, str, StepStatus]:
        if dry_run:
            return 0, "dry run; would clear pressure deps", StepStatus.SKIPPED
        keep_re = re.compile(self.cfg.get("keep_worktree_regex") or "")
        apps_glob = str(expand_path(str(self.cfg.get("apps_glob", "~/apps/*")), self.home))
        freed = 0
        for wt in glob.glob(apps_glob):
            if not os.path.isdir(wt) or keep_re.match(wt):
                continue
            if os.path.exists(os.path.join(wt, KEEP_SENTINEL)):
                continue
            if not self._is_git_worktree(wt):
                continue
            if self._wt_has_blocking_dirt(wt):
                continue
            if self._wt_is_active(wt, 4 * 3600):
                continue
            if self._pgrep_f(wt):
                continue
            for sub in ("node_modules", ".next", ".turbo"):
                target = os.path.join(wt, sub)
                if not os.path.isdir(target):
                    continue
                if self._git_tracks_path(wt, sub):
                    continue
                freed += self._du_bytes(Path(target))
                shutil.rmtree(target, ignore_errors=True)
        return freed, "pressure deps reap", StepStatus.RAN

    def _du_bytes(self, path: Path) -> int:
        if not path.exists():
            return 0
        if sys.platform == "darwin" and shutil.which("du"):
            try:
                res = subprocess.run(
                    ["du", "-sk", str(path)],
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                if res.returncode == 0 and res.stdout.strip():
                    kib = int(res.stdout.split()[0])
                    return kib * 1024
            except (subprocess.TimeoutExpired, ValueError, IndexError, OSError):
                pass
        return self._dir_size_before_clear(path)

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
        count, _est, detail = retire_worktrees(
            self.cfg,
            self.home,
            _subprocess_run,
            _subprocess_run,
            dry_run=dry_run,
            candidates=self._planned_retire_candidates,
        )
        return 0, detail or f"retired {count}", StepStatus.RAN if count or detail else StepStatus.SKIPPED

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
        try:
            res = subprocess.run(["pgrep", "-f", pattern], capture_output=True, timeout=3)
            return bool(res.stdout.strip())
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return False

    def _pgrep_f(self, path: str) -> bool:
        try:
            res = subprocess.run(["pgrep", "-f", path], capture_output=True, timeout=3)
            return bool(res.stdout.strip())
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return False

    def _is_git_worktree(self, path: str) -> bool:
        git_dir = os.path.join(path, ".git")
        if not (os.path.isdir(git_dir) or os.path.isfile(git_dir)):
            return False
        try:
            res = subprocess.run(
                ["git", "-C", path, "rev-parse", "--is-inside-work-tree"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            return res.returncode == 0 and res.stdout.strip() == "true"
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return False

    def _wt_has_blocking_dirt(self, path: str) -> bool:
        try:
            res = subprocess.run(["git", "-C", path, "status", "--porcelain"], capture_output=True, text=True, timeout=5)
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return True
        if res.returncode != 0:
            return True
        for line in res.stdout.splitlines():
            if re.match(
                r"^\?\? (node_modules/|\.next/|\.turbo/|next-env\.d\.ts$|tsconfig\.tsbuildinfo$|\.DS_Store$|[^ ]*\.log$|data/app\.db(-wal|-shm)?$)",
                line,
            ):
                continue
            return True
        return False

    def _wt_is_active(self, path: str, idle_sec: float) -> bool:
        now = time.time()
        skip = {".git", "node_modules", ".next", ".turbo"}
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if d not in skip]
            for f in files:
                try:
                    if now - os.path.getmtime(os.path.join(root, f)) < idle_sec:
                        return True
                except OSError:
                    continue
        return False

    def _git_tracks_path(self, wt: str, sub: str) -> bool:
        try:
            res = subprocess.run(
                ["git", "-C", wt, "ls-files", "--error-unmatch", "--", sub],
                capture_output=True,
                timeout=5,
            )
            return res.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return True

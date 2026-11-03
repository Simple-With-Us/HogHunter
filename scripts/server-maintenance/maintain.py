#!/usr/bin/env python3
"""Bounded, pressure-gated server maintenance; stdout is a single v1 JSON result."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import time
import uuid

VERSION = 1
STRATEGIES = ("package-cache", "rotated-logs", "docker-images", "docker-build-cache")
DOCKER = ["/usr/bin/docker", "--host", "unix:///var/run/docker.sock"]
BUILD = DOCKER + ["buildx", "--builder", "default"]
AGE = 7 * 86400
LIMIT = 1000


class StopWork(Exception):
    pass


class Maintenance:
    def __init__(self, root=Path("/"), runner=None, disk=None, clock=time.time,
                 monotonic=time.monotonic, active_files=None, budget=90, audit=None):
        self.root = Path(root)
        self.runner = runner or self.command
        self.disk = disk or self.measure_disk
        self.clock, self.monotonic = clock, monotonic
        self.deadline = monotonic() + budget
        self.active_files = active_files or self.open_files
        self.audit = audit or self.append_audit
        self.cancelled = False
        self.uncertain_child = False
        self.lock = self.path("/run/fleet-housekeeper.lock")
        self.owner = None
        self.lock_state = "unknown"
        self.removed_file_bytes = 0

    def path(self, absolute):
        return self.root / absolute.lstrip("/")

    def check(self):
        if self.cancelled:
            raise StopWork("cancelled")
        if self.monotonic() >= self.deadline:
            raise StopWork("work budget exhausted")

    def measure_disk(self):
        s = os.statvfs(self.root)
        return {"free_bytes": s.f_bavail * s.f_frsize, "total_bytes": s.f_blocks * s.f_frsize,
                "used_percent": round(100 * (s.f_blocks - s.f_bfree) / s.f_blocks, 2)}

    def command(self, argv):
        """Own the process group; cap output and kill/reap on timeout/cancellation."""
        self.check()
        end = min(self.deadline, self.monotonic() + 20)
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                start_new_session=True, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
                                                           "HOME": "/root", "LC_ALL": "C"})
        out = bytearray()
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    self.check()
                    if self.monotonic() >= end:
                        raise StopWork("subprocess timeout")
                    for key, _ in selector.select(0.1):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                        else:
                            out.extend(chunk)
                            if len(out) > 1024 * 1024:
                                raise StopWork("subprocess output limit")
                # A process may close stdout and continue running.
                while proc.poll() is None:
                    self.check()
                    if self.monotonic() >= end:
                        raise StopWork("subprocess timeout")
                    time.sleep(0.05)
            return proc.returncode, out.decode("utf-8", errors="strict")
        finally:
            if proc.poll() is None:
                # Read-only inventory is safe after owned-group termination and
                # reap.  Mutation uncertainty is separately persisted *before*
                # dispatch, since daemon work can outlive even a reaped CLI.
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except OSError:
                    self.uncertain_child = True
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.uncertain_child = True
            finally:
                proc.stdout.close()

    def protected(self, path):
        """No symlink component; case-insensitive keep marker on any parent."""
        for parent in [path, *path.parents]:
            self.check()
            if parent.is_symlink():
                return True
            if parent.is_dir():
                with os.scandir(parent) as entries:
                    for i, entry in enumerate(entries):
                        if i >= LIMIT:
                            return True
                        if entry.name.casefold() == ".janitor-keep":
                            return True
            if parent == self.root:
                break
        return False

    def open_files(self):
        """Unknown/incomplete /proc inventory refuses local file deletion."""
        found, count = set(), 0
        with os.scandir(self.path("/proc")) as processes:
            for i, process in enumerate(processes):
                self.check()
                if i >= 10000:
                    raise StopWork("process inventory limit")
                if not process.name.isdecimal():
                    continue
                try:
                    with os.scandir(Path(process.path) / "fd") as descriptors:
                        for fd in descriptors:
                            count += 1
                            self.check()
                            if count > 50000:
                                raise StopWork("file descriptor inventory limit")
                            try:
                                s = os.stat(fd.path)
                                found.add((s.st_dev, s.st_ino))
                            except FileNotFoundError:
                                pass
                except FileNotFoundError:
                    pass
        return found

    def files(self, strategy):
        directory = self.path("/var/cache/apt/archives" if strategy == "package-cache" else "/var/log/fleet-backup")
        if not directory.exists() or self.protected(directory):
            return []
        pattern = r"[A-Za-z0-9_.+%~-]+\.deb" if strategy == "package-cache" else r"[A-Za-z0-9_.-]+\.log\.[0-9]+\.gz"
        age = AGE if strategy == "package-cache" else 30 * 86400
        candidates = []
        with os.scandir(directory) as entries:
            for i, entry in enumerate(entries):
                self.check()
                if i >= LIMIT:
                    raise StopWork("directory inventory limit")
                if strategy == "rotated-logs" and any(word in entry.name.casefold() for word in ("audit", "auth", "security")):
                    continue
                if not re.fullmatch(pattern, entry.name):
                    continue
                s = entry.stat(follow_symlinks=False)
                if stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and self.clock() - max(s.st_mtime, s.st_ctime) >= age:
                    candidates.append((entry.name, s))
        return candidates

    @staticmethod
    def timestamp(value):
        if not isinstance(value, str):
            raise ValueError("missing timestamp")
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("timestamp requires zone")
        return parsed.timestamp()

    def verify_local_builder(self):
        code, out = self.runner(BUILD + ["inspect"])
        if code or len(out) > 65536:
            raise ValueError("local builder identity unavailable")
        lines = [line.strip() for line in out.splitlines()]
        drivers = [line.split(":", 1)[1].strip() for line in lines if line.startswith("Driver:")]
        endpoints = [line.split(":", 1)[1].strip() for line in lines if line.startswith("Endpoint:")]
        if drivers != ["docker"] or not endpoints or any(e not in ("default", "unix:///var/run/docker.sock") for e in endpoints):
            raise ValueError("default builder is not the local Docker driver")

    def docker_candidates(self, strategy):
        # Do not traverse Docker storage or any volume.  Respect parent keep markers.
        if self.protected(self.path("/var/lib/docker")):
            return []
        if strategy == "docker-images":
            code, out = self.runner(DOCKER + ["image", "ls", "--filter", "dangling=true", "--no-trunc", "--quiet"])
            if code:
                raise ValueError("Docker image inventory unavailable")
            ids = list(dict.fromkeys(out.split()))
            if len(ids) > 100:
                raise StopWork("image inventory limit")
            result = []
            for image in ids:
                self.check()
                if self.image_eligible(image):
                    result.append(image)
            return result
        self.verify_local_builder()
        code, out = self.runner(BUILD + ["du", "--format=json"])
        if code:
            raise ValueError("age-qualified build cache inventory unavailable")
        result = []
        for i, line in enumerate(out.splitlines()):
            self.check()
            if i >= LIMIT:
                raise StopWork("build cache inventory limit")
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("malformed build cache record")
            identity = record.get("ID")
            if not isinstance(identity, str) or not re.fullmatch(r"[a-z0-9]{10,80}", identity):
                raise ValueError("malformed cache identity")
            if (record.get("Reclaimable") is True and record.get("Mutable") is False
                    and record.get("Shared") is False and record.get("Type") == "regular"
                    and self.clock() - self.timestamp(record.get("LastUsedAt")) >= AGE):
                result.append(identity)
        return result[:20]

    def image_eligible(self, identity):
        """Inspect only one exact image using one selected-field JSON object."""
        self.check()
        if not isinstance(identity, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", identity):
            raise ValueError("malformed image identity")
        code, data = self.runner(DOCKER + ["image", "inspect", "--format",
            '{"created":{{json .Created}},"tags":{{json .RepoTags}},"labels":{{json .Config.Labels}}}', identity])
        if code:
            raise ValueError("image changed during inventory")
        record = json.loads(data)
        if not isinstance(record, dict) or set(record) != {"created", "tags", "labels"}:
            raise ValueError("malformed image metadata")
        tags, labels = record["tags"], record["labels"]
        if ((labels is not None and not isinstance(labels, dict))
                or (tags is not None and (not isinstance(tags, list) or any(not isinstance(t, str) for t in tags)))):
            raise ValueError("malformed image tags or labels")
        return (tags in (None, [])
                and not any(str(k).casefold() in ("janitor-keep", "hoghunter.keep") for k in (labels or {}))
                and self.clock() - self.timestamp(record["created"]) >= AGE)

    def remove_files(self, strategy, candidates, progress=None):
        directory = self.path("/var/cache/apt/archives" if strategy == "package-cache" else "/var/log/fleet-backup")
        if self.protected(directory):
            raise ValueError("directory became protected")
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        lockfd = None
        removed = 0
        try:
            if strategy == "package-cache":
                lockfd = os.open("lock", os.O_RDWR | os.O_NOFOLLOW, dir_fd=fd)
                fcntl.lockf(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            active = self.active_files()
            for name, before in candidates:
                self.check()
                after = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                    continue
                if (after.st_dev, after.st_ino) in active or not stat.S_ISREG(after.st_mode) or after.st_nlink != 1:
                    continue
                if self.protected(directory):
                    raise ValueError("directory became protected")
                os.unlink(name, dir_fd=fd)
                removed += 1
                self.removed_file_bytes += after.st_size
                if progress is not None:
                    progress(removed)
        finally:
            if lockfd is not None:
                os.close(lockfd)
            os.close(fd)
        return removed

    def append_audit(self, record):
        path = self.path("/var/log/hoghunter-maintenance.jsonl")
        if self.protected(path):
            raise ValueError("audit path protected")
        fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                raise ValueError("audit ownership refused")
            os.fchmod(fd, 0o600)
            os.write(fd, (json.dumps(record, separators=(",", ":")) + "\n").encode())
            os.fsync(fd)
        finally:
            os.close(fd)

    def process_start(self, pid):
        # /proc stat comm may contain spaces and parentheses; fields follow its final close.
        text = (self.path("/proc") / str(pid) / "stat").read_text()
        close = text.rfind(")")
        fields = text[close + 2:].split() if close >= 0 else []
        if len(fields) <= 19:
            raise ValueError("malformed process stat")
        start = int(fields[19])
        if start <= 0:
            raise ValueError("malformed process start ticks")
        return start

    def sync_lock_directory(self):
        fd = os.open(self.lock, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if os.fstat(fd).st_ino != self.owner["inode"]:
                raise OSError("lock changed")
            os.fsync(fd)
        finally:
            os.close(fd)

    def mutation(self, argv, strategy, identity):
        """Write durable dispatch intent before a CLI can send daemon-side work.

        Parent death, CLI failure and ambiguous completion leave an extra lock
        file that automatic dead-owner recovery must never remove.
        """
        self.check()
        if self.owner is None or json.loads((self.lock / "owner.json").read_text()) != self.owner:
            raise OSError("lock owner changed")
        marker = self.lock / "dispatch.json"
        fd = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump({"owner": self.owner, "strategy": strategy, "identity": identity}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        self.sync_lock_directory()
        try:
            code, output = self.runner(argv)
        except StopWork:
            raise
        except Exception as exc:
            raise StopWork("cleanup dispatch completion unconfirmed; operator inspection required") from exc
        if code or self.uncertain_child:
            raise StopWork("cleanup dispatch completion unconfirmed; operator inspection required")
        # Success is the only automatic evidence that the synchronous daemon
        # request finished; a nonzero/exception/kill keeps the dispatch record.
        marker.unlink()
        self.sync_lock_directory()
        return code, output

    def acquire_lock(self):
        # All new-tool callers share this guard; legacy/unknown locks are left alone.
        self.lock_state = "unknown"
        guard = os.open(self.lock.with_suffix(".guard"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.lock_state = "busy"
                return False
            if self.lock.exists() or self.lock.is_symlink():
                try:
                    ds = self.lock.lstat()
                    op = self.lock / "owner.json"
                    owner_stat = op.lstat()
                    if not stat.S_ISDIR(ds.st_mode) or ds.st_uid != os.geteuid() or not stat.S_ISREG(owner_stat.st_mode):
                        return False
                    if owner_stat.st_uid != os.geteuid() or stat.S_IMODE(owner_stat.st_mode) != 0o600 or owner_stat.st_size > 2048:
                        return False
                    owner = json.loads(op.read_text())
                    if (not isinstance(owner, dict) or set(owner) != {"pid", "start_ticks", "inode", "nonce"}
                            or any(type(owner[k]) is not int or owner[k] <= 0 for k in ("pid", "start_ticks", "inode"))
                            or not isinstance(owner["nonce"], str) or not re.fullmatch(r"[a-f0-9]{32}", owner["nonce"])
                            or owner["inode"] != ds.st_ino):
                        return False
                    if set(x.name for x in self.lock.iterdir()) != {"owner.json"}:
                        return False
                    try:
                        os.kill(owner["pid"], 0)
                    except ProcessLookupError:
                        pass  # Proven dead; never recover on age or an unreadable process.
                    else:
                        if self.process_start(owner["pid"]) == owner["start_ticks"]:
                            self.lock_state = "busy"
                            return False
                    if self.lock.lstat().st_ino != ds.st_ino or op.lstat().st_ino != owner_stat.st_ino:
                        return False
                    op.unlink()
                    self.lock.rmdir()
                except (OSError, ValueError, TypeError):
                    return False
            try:
                self.lock.mkdir(mode=0o700)
            except FileExistsError:
                return False
            inode = self.lock.stat().st_ino
            self.owner = {"pid": os.getpid(), "start_ticks": self.process_start(os.getpid()),
                          "inode": inode, "nonce": uuid.uuid4().hex}
            try:
                owner_fd = os.open(self.lock / "owner.json", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                with os.fdopen(owner_fd, "w") as stream:
                    json.dump(self.owner, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
            except BaseException:
                # Unknown/incomplete record stays held for operator inspection.
                self.owner = None
                raise
            return True
        finally:
            os.close(guard)

    def release_lock(self):
        if self.lock.is_symlink() or self.lock.stat().st_ino != self.owner["inode"]:
            raise OSError("lock changed")
        op = self.lock / "owner.json"
        if op.is_symlink() or json.loads(op.read_text()) != self.owner:
            raise OSError("lock owner changed")
        if set(x.name for x in self.lock.iterdir()) != {"owner.json"}:
            raise OSError("outstanding dispatch or unknown lock evidence")
        op.unlink()
        self.lock.rmdir()

    def execute(self, mode="scheduled", strategies=("package-cache", "rotated-logs", "docker-build-cache"), confirm=False, dry_run=False, manual=False):
        started = self.monotonic()
        before = self.disk()
        result = {"schema_version": VERSION, "tool": "hoghunter-server-maintenance", "mode": mode,
                  "status": "skipped", "reason": "no eligible work", "dry_run": dry_run,
                  "before": before, "after": before, "reclaimed_bytes": 0, "observed_free_delta_bytes": 0, "removed_file_bytes": 0, "candidate_count": 0,
                  "strategies": [], "lock": {"path": "/run/fleet-housekeeper.lock", "acquired": False},
                  "cancellation": {"requested": False}, "duration_seconds": 0}
        held = False
        lock_inode = None
        try:
            if (type(mode) is not str or mode not in ("scan", "plan", "run", "scheduled")
                    or not isinstance(strategies, (tuple, list)) or any(type(s) is not str for s in strategies)
                    or not set(strategies).issubset(STRATEGIES) or len(set(strategies)) != len(strategies)
                    or not strategies or type(confirm) is not bool or type(dry_run) is not bool
                    or type(manual) is not bool or (manual and mode == "scheduled")):
                raise ValueError("unknown mode or strategy")
            if manual:
                result["manual"] = True
            mutating = mode in ("run", "scheduled") and not dry_run
            if mode == "run" and not confirm and not dry_run:
                raise ValueError("explicit run requires --confirm")
            pressure = before["used_percent"] >= 80 or before["free_bytes"] < 25 * 1024**3
            result["pressure"] = pressure
            if not pressure and not manual:
                result["reason"] = "healthy root filesystem; no cleanup inventory needed"
                return result
            if mutating:
                if self.protected(self.lock.parent):
                    raise ValueError("lock parent protected")
                if not self.acquire_lock():
                    if self.lock_state == "busy":
                        result["reason"] = "shared remote cleanup lock busy; no work started"
                    else:
                        result.update(status="partial", reason="shared remote cleanup lock requires inspection; no work started")
                    return result
                held = True
                lock_inode = self.lock.stat().st_ino
                result["lock"]["owner"] = self.owner
                result["lock"]["acquired"] = True
                self.audit({"event": "started", "owner": self.owner, "mode": mode, "strategies": list(strategies)})
            for strategy in strategies:
                self.check()
                item = {"id": strategy, "status": "skipped", "candidate_count": 0, "removed_count": 0, "attempted_count": 0, "reason": "no eligible candidates"}
                result["strategies"].append(item)
                try:
                    candidates = self.files(strategy) if strategy in STRATEGIES[:2] else self.docker_candidates(strategy)
                    item["candidate_count"] = len(candidates)
                    result["candidate_count"] += len(candidates)
                    if not candidates:
                        continue
                    if not mutating:
                        item.update(status="planned", reason="age-qualified candidates; no changes")
                        continue
                    if strategy in STRATEGIES[:2]:
                        item["removed_count"] = self.remove_files(strategy, candidates,
                            progress=lambda count: item.update(removed_count=count))
                    else:
                        for identity in candidates:
                            self.check()
                            # Exact reviewed identities only; never force image removal, containers or volumes.
                            if self.protected(self.path("/var/lib/docker")):
                                raise ValueError("Docker storage became protected")
                            if strategy == "docker-images" and not self.image_eligible(identity):
                                continue
                            if strategy == "docker-build-cache":
                                self.verify_local_builder()
                            argv = (DOCKER + ["image", "rm", identity] if strategy == "docker-images" else
                                    BUILD + ["prune", "--force", "--filter", "id=^" + identity + "$",
                                             "--filter", "until=168h", "--filter", "inuse=false",
                                             "--filter", "mutable=false", "--filter", "shared=false",
                                             "--filter", "type=regular"])
                            self.mutation(argv, strategy, identity)
                            item["attempted_count"] += 1
                    item.update(status="ran" if item["removed_count"] or item["attempted_count"] else "skipped", reason="completed bounded eligible work")
                except (OSError, ValueError, json.JSONDecodeError) as exc:
                    item.update(status="failed", reason=type(exc).__name__)
            statuses = [s["status"] for s in result["strategies"]]
            worked = any(s["removed_count"] or s["attempted_count"] for s in result["strategies"])
            if "failed" in statuses:
                result.update(status="partial" if worked else "failed", reason="one or more strategies failed closed")
            elif worked:
                result.update(status="ran", reason="completed eligible maintenance")
            elif "planned" in statuses:
                result.update(status="planned", reason="eligible maintenance planned; no changes")
        except StopWork as exc:
            result.update(status="cancelled" if self.cancelled else "partial", reason=str(exc))
            for item in result["strategies"]:
                if item["candidate_count"] and item["status"] == "skipped":
                    item.update(status="partial", reason=str(exc))
        except (OSError, ValueError) as exc:
            result.update(status="failed", reason=type(exc).__name__)
        finally:
            result["cancellation"]["requested"] = self.cancelled
            if held:
                try:
                    if self.uncertain_child:
                        # This extra field makes the record unknown to automatic recovery.
                        self.owner["uncertain_child"] = True
                        op = self.lock / "owner.json"
                        if op.is_symlink():
                            raise OSError("lock owner changed")
                        with op.open("w") as stream:
                            json.dump(self.owner, stream)
                            stream.flush()
                            os.fsync(stream.fileno())
                        raise OSError("child completion unconfirmed")
                    self.release_lock()
                    result["lock"]["released"] = True
                except OSError:
                    result["lock"]["released"] = False
                    if result["status"] not in ("cancelled", "failed"):
                        result["status"] = "partial"
                    result["reason"] = "shared lock retained; child completion or ownership requires inspection"
            try:
                result["after"] = self.disk()
                result["observed_free_delta_bytes"] = result["after"]["free_bytes"] - before["free_bytes"]
                result["removed_file_bytes"] = self.removed_file_bytes
            except OSError:
                result.update(status="partial", reason="final disk measurement unavailable")
            result["duration_seconds"] = round(self.monotonic() - started, 3)
            if held:
                try:
                    self.audit(dict(result, event="finished"))
                except (OSError, ValueError):
                    result.update(status="partial", reason="maintenance audit unavailable")
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", default="scheduled", choices=("scan", "plan", "run", "scheduled"))
    parser.add_argument("--strategy", action="append", choices=STRATEGIES)
    parser.add_argument("--confirm", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--manual", action="store_true", help="explicit scan/plan/run even without disk pressure")
    args = parser.parse_args()
    if args.mode == "run" and not args.strategy:
        parser.error("run requires one or more --strategy values")
    if args.manual and args.mode == "scheduled":
        parser.error("--manual is only accepted for scan, plan or run")
    tool = Maintenance()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: setattr(tool, "cancelled", True))
    if os.geteuid() != 0:
        parser.error("requires root")
    defaults = tuple(s for s in STRATEGIES if s != "docker-images")
    result = tool.execute(args.mode, args.strategy or defaults, args.confirm, args.dry_run, args.manual)
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result["status"] in ("ran", "skipped", "planned") else 1


if __name__ == "__main__":
    raise SystemExit(main())

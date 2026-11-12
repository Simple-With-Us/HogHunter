#!/usr/bin/env python3
"""Start the owned Shellular PM2 app only after a bounded manager check says it is down."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Callable, Mapping


STATUS_TIMEOUT_SEC = 10
START_TIMEOUT_SEC = 25
MAX_STATUS_BYTES = 4096
DOWN_STATES = {"stopped", "offline", "errored", "not_found", "process_missing"}


def runtime_paths(runtime: Path) -> dict[str, Path]:
    return {
        "status": runtime / "bin" / "status-json",
        "wrapper": runtime / "bin" / "shellular",
        "entry": runtime / "lib" / "node_modules" / "shellular" / "dist" / "main.js",
        "node": runtime / "node-v24.22.0-linux-x64" / "bin" / "node",
    }


def safe_environment(home: Path, runtime: Path) -> dict[str, str]:
    node_bin = runtime / "node-v24.22.0-linux-x64" / "bin"
    return {
        "HOME": str(home),
        "PM2_HOME": str(runtime / "pm2"),
        "PATH": f"{node_bin}:/usr/bin:/bin",
    }


def _manager_record(runtime: Path, home: Path, proc_root: Path, run: Callable = subprocess.run) -> tuple[str, int, str | None]:
    paths = runtime_paths(runtime)
    try:
        result = run(
            [str(paths["status"])], cwd=str(runtime), env=safe_environment(home, runtime),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            timeout=STATUS_TIMEOUT_SEC, check=False,
        )
    except subprocess.TimeoutExpired:
        return "error", 0, "status_timeout"
    except OSError:
        return "error", 0, "status_runner_error"
    if result.returncode != 0 or len(result.stdout) > MAX_STATUS_BYTES:
        return "error", 0, "status_invalid"
    try:
        record = json.loads(result.stdout)
    except (TypeError, ValueError):
        return "error", 0, "status_invalid"
    if not isinstance(record, dict) or record.get("name") != "shellular" or record.get("execpath") != str(paths["entry"]):
        return "error", 0, "identity_mismatch"
    state = record.get("status")
    pid = record.get("pid")
    if not isinstance(state, str) or not isinstance(pid, int) or isinstance(pid, bool) or pid < 0:
        return "error", 0, "status_invalid"
    if state == "online":
        if pid <= 0 or not (proc_root / str(pid) / "exe").exists():
            return "error", 0, "process_disappeared"
        return "online", pid, None
    if state in DOWN_STATES:
        if pid > 0 and (proc_root / str(pid)).exists():
            return "error", 0, "process_alive_while_manager_down"
        return "down", 0, None
    return "error", 0, "manager_unknown"


def _start(runtime: Path, home: Path, run: Callable = subprocess.run) -> str | None:
    wrapper = runtime_paths(runtime)["wrapper"]
    try:
        result = run(
            [str(wrapper), "--no-qr"], cwd=str(runtime), env=safe_environment(home, runtime),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=START_TIMEOUT_SEC, check=False,
        )
    except subprocess.TimeoutExpired:
        return "start_timeout"
    except OSError:
        return "start_runner_error"
    return None if result.returncode == 0 else "start_failed"


def _atomic_status(path: Path, result: Mapping[str, str], now: dt.datetime | None = None) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = (now or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone.utc).isoformat()
    payload = {
        "version": 1,
        "checked_at_utc": stamp,
        "result": result["result"],
        "action": result["action"],
        "reason": result.get("reason", ""),
    }
    data = (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode()
    fd, name = tempfile.mkstemp(prefix=".watchdog-status-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        os.chmod(path, 0o600)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def run_watchdog(
    runtime: Path = Path("/root/apps/shellular-runtime"),
    home: Path = Path("/root"),
    proc_root: Path = Path("/proc"),
    run: Callable = subprocess.run,
    now: dt.datetime | None = None,
) -> dict[str, str]:
    runtime, home, proc_root = Path(runtime), Path(home), Path(proc_root)
    state_dir = runtime / "var"
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = state_dir / "watchdog.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"result": "busy", "action": "none", "reason": "already_running"}
        state, _, reason = _manager_record(runtime, home, proc_root, run)
        # An online record can race process exit after the manager's PID probe.
        # Start only if a second bounded manager query confirms the missing process.
        if state == "error" and reason == "process_disappeared":
            state, _, reason = _manager_record(runtime, home, proc_root, run)
        if state == "online":
            outcome = {"result": "running", "action": "none", "reason": ""}
        elif state == "error":
            outcome = {"result": "error", "action": "none", "reason": reason or "manager_unknown"}
        else:
            start_error = _start(runtime, home, run)
            if start_error:
                outcome = {"result": "error", "action": "start", "reason": start_error}
            else:
                after, _, after_reason = _manager_record(runtime, home, proc_root, run)
                if after == "online":
                    outcome = {"result": "started", "action": "start", "reason": ""}
                else:
                    outcome = {"result": "error", "action": "start", "reason": after_reason or "start_unconfirmed"}
        _atomic_status(state_dir / "watchdog-status.json", outcome, now)
        return outcome
    finally:
        os.close(lock_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=Path("/root/apps/shellular-runtime"))
    parser.add_argument("--home", type=Path, default=Path("/root"))
    args = parser.parse_args()
    outcome = run_watchdog(args.runtime, args.home)
    return 1 if outcome["result"] == "error" else 0


if __name__ == "__main__":
    raise SystemExit(main())

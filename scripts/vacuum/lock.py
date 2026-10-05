from __future__ import annotations

import os
import time
from pathlib import Path


class HousekeeperLock:
    """Re-entrant owner-token lock at ~/.claude-disk-janitor/.housekeeper.lock."""

    def __init__(self, lock_path: Path, stale_minutes: int = 120) -> None:
        self.lock_path = lock_path
        self.stale_seconds = stale_minutes * 60
        self._owned = False

    def __enter__(self) -> "HousekeeperLock":
        if os.environ.get("HOUSEKEEPER_LOCK_OWNER") == "1":
            return self
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.lock_path.mkdir(exist_ok=False)
            self._owned = True
            os.environ["HOUSEKEEPER_LOCK_OWNER"] = "1"
        except FileExistsError:
            if self._is_stale():
                try:
                    self.lock_path.rmdir()
                except OSError:
                    pass
                try:
                    self.lock_path.mkdir(exist_ok=False)
                    self._owned = True
                    os.environ["HOUSEKEEPER_LOCK_OWNER"] = "1"
                except OSError:
                    raise LockHeld("peer holds housekeeper lock")
            else:
                raise LockHeld("peer holds housekeeper lock")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self._owned:
            try:
                self.lock_path.rmdir()
            except OSError:
                pass
            self._owned = False

    def _is_stale(self) -> bool:
        try:
            age = time.time() - self.lock_path.stat().st_mtime
            return age > self.stale_seconds
        except OSError:
            return True


class LockHeld(Exception):
    pass

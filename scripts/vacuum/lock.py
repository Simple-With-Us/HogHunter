from __future__ import annotations

import json
import os
import socket
import time
import uuid
from pathlib import Path

# The locks this process currently holds.  Recorded by the lock itself so a
# hard exit can release exactly what was taken, without guessing the
# configured path.
_HELD: set[Path] = set()


def owner_path_for(lock_path: Path) -> Path:
    """The identity file that sits *beside* the lock directory.

    It has to be a sibling, not a file inside the lock directory, because
    `~/apps/mac-auto-cleanup.sh` releases the lock with a plain `rmdir` and
    `rmdir` refuses a directory that has anything in it.  A file inside the
    lock would make the shell's release silently fail and leak the lock
    forever, which is the exact failure this whole change exists to stop.
    """
    return lock_path.with_name(lock_path.name + ".owner")


def _pid_alive(pid: int) -> bool:
    """True when a pid still names a live process.

    Signal 0 does not deliver anything; it only asks the kernel whether the
    process exists.  ESRCH means it is gone, EPERM means it exists but belongs
    to somebody else, and anything else is treated as alive so that a check we
    cannot read never causes us to steal a lock that is genuinely held.
    """
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def _read_owner(owner_path: Path) -> dict | None:
    """Read the owner file, or None when it is missing or unreadable.

    A corrupt owner file is treated as no owner file at all, so the caller
    falls back to the age rule.  That is the conservative direction: we wait
    rather than steal a lock we cannot identify.
    """
    try:
        data = json.loads(owner_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _write_owner(owner_path: Path, lock_path: Path) -> None:
    """Record who holds the lock.

    The pid is what makes a killed holder recoverable: the next process to
    ask for the lock can see that the pid is gone and take over at once,
    instead of waiting out the whole stale window.
    """
    payload = {
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "acquired_at": time.time(),
        "lock": str(lock_path),
    }
    try:
        owner_path.write_text(json.dumps(payload), encoding="utf-8")
    except OSError:
        # The lock itself is the mutex.  The owner file is only a hint that
        # makes recovery fast, so failing to write it must not fail the
        # acquire; it just falls back to the age rule.
        pass


def _owner_describes_holder(owner_path: Path, lock_path: Path) -> bool:
    """True when the owner file describes the holder of the lock that is there now.

    A holder that never wrote an owner file -- the shell holder -- leaves a
    leftover file from an earlier holder beside it.  That file names a pid
    that is gone, and reading it as the current holder would let a fresh live
    lock be taken over.  The owner file is only about the current holder when
    it is at least as new as the lock directory.
    """
    try:
        owner_modified = owner_path.stat().st_mtime
        lock_modified = lock_path.stat().st_mtime
    except OSError:
        return False
    return owner_modified >= lock_modified


def _clear_owner(owner_path: Path, only_pid: int | None = None) -> None:
    """Remove the owner file, optionally only when it names a given pid.

    The pid check is what keeps one holder from deleting the identity of
    another: if our lock was stolen as stale while we were still running, the
    file now names somebody else and we leave it alone.
    """
    if only_pid is not None:
        owner = _read_owner(owner_path)
        if owner is not None and int(owner.get("pid", -1)) != only_pid:
            return
    try:
        owner_path.unlink()
    except OSError:
        pass


def force_release() -> bool:
    """Release any lock this process holds, whatever the exit path.

    `os._exit` skips `finally` blocks and `atexit` handlers, so the watchdog
    that kills a wedged tick used to leave the lock directory behind.  Every
    tick after it then saw "peer holds lock" and did nothing until the two
    hour stale window expired.  The watchdog calls this before it exits so
    the common case leaves no lock at all; the owner file covers the cases
    where a process dies without getting the chance.

    The set of held locks is recorded by the lock itself, so this releases
    exactly the lock this process took and does not have to guess the
    configured path.
    """
    released = False
    for lock_path in list(_HELD):
        owner_path = owner_path_for(lock_path)
        owner = _read_owner(owner_path)
        if owner is not None and int(owner.get("pid", -1)) != os.getpid():
            # Somebody else owns it now.  Leave it exactly as it is.
            continue
        _clear_owner(owner_path, only_pid=os.getpid())
        try:
            lock_path.rmdir()
        except OSError:
            continue
        _HELD.discard(lock_path)
        released = True
    if released and os.environ.get("HOUSEKEEPER_LOCK_OWNER") == "1":
        # The token says "this process owns the lock".  With the lock gone the
        # token is a lie, and a child that inherits it would skip the lock
        # and reclaim while a peer holds it.
        del os.environ["HOUSEKEEPER_LOCK_OWNER"]
    return released


class HousekeeperLock:
    """Re-entrant owner-token lock at ~/.claude-disk-janitor/.housekeeper.lock."""

    def __init__(self, lock_path: Path, stale_minutes: int = 120) -> None:
        self.lock_path = lock_path
        self.stale_seconds = stale_minutes * 60
        self._owned = False

    @property
    def owner_path(self) -> Path:
        return owner_path_for(self.lock_path)

    def __enter__(self) -> "HousekeeperLock":
        if os.environ.get("HOUSEKEEPER_LOCK_OWNER") == "1":
            return self
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.lock_path.mkdir(exist_ok=False)
        except FileExistsError:
            # The lock directory is there.  Either a live peer holds it, or
            # it is a leftover we are allowed to take.
            if not (self._takeover_possible() and self._takeover()):
                raise LockHeld("peer holds housekeeper lock")
            # The stale lock is gone.  Take it for real, and lose the race
            # gracefully if another caller got there first.
            try:
                self.lock_path.mkdir(exist_ok=False)
            except OSError:
                raise LockHeld("peer holds housekeeper lock")
        self._owned = True
        _HELD.add(self.lock_path)
        _write_owner(self.owner_path, self.lock_path)
        os.environ["HOUSEKEEPER_LOCK_OWNER"] = "1"
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self._owned:
            _clear_owner(self.owner_path, only_pid=os.getpid())
            try:
                self.lock_path.rmdir()
            except OSError:
                pass
            self._owned = False
            _HELD.discard(self.lock_path)
            if os.environ.get("HOUSEKEEPER_LOCK_OWNER") == "1":
                del os.environ["HOUSEKEEPER_LOCK_OWNER"]

    def _takeover_possible(self) -> bool:
        """True when the lock on disk is free to be taken over.

        Two ways that happens: the holder is older than the stale window, or
        the holder is gone.  The second case is the one that used to cost two
        hours -- a tick killed by the watchdog left the directory behind, and
        the owner file is what lets the next tick see that its pid is dead.
        """
        if self._is_stale():
            return True
        owner = _read_owner(self.owner_path)
        if owner is None:
            # No owner file: either a shell holder that never wrote one, or
            # an owner file we cannot read.  Fall back to the age rule.
            return False
        pid = int(owner.get("pid", -1))
        if pid <= 0:
            return False
        if pid == os.getpid():
            # Our own pid.  The re-entrancy token normally covers this, but if
            # the token was lost we must not steal our own lock.
            return False
        if not _owner_describes_holder(self.owner_path, self.lock_path):
            # The owner file is older than the lock directory, so it belongs
            # to an earlier holder, not to the one that is there now.  The
            # shell holder never writes an owner file, so this is the normal
            # case for a lock the shell is holding: the leftover file names a
            # dead pid, and reading it as the current holder would let a
            # fresh live lock be taken over.
            return False
        return not _pid_alive(pid)

    def _takeover(self) -> bool:
        """Take a lock that is free to be taken, atomically.

        Checking that the lock is stale and then removing it is two steps, and
        two reclaimers can interleave them: both see the stale lock, one
        removes it and creates a fresh one, and the other then removes that
        fresh, empty lock and creates its own, so both believe they hold it.
        Removing is therefore a rename, which only one caller can win: the
        stale directory is moved aside under a name no one else uses, and a
        caller that finds nothing to move lost the race and backs off.

        The rename acts on whatever is at the path at that instant.  When a
        peer had already replaced the stale lock, that is the peer's fresh
        lock, and it is put back rather than removed.
        """
        # The owner file is read before the move, because the move is what
        # decides the race and the file is only removed when it still names
        # the dead holder we found.
        dead_owner_pid = self._owner_pid()
        aside = self.lock_path.with_name(f"{self.lock_path.name}.stale-{uuid.uuid4().hex}")
        try:
            os.rename(self.lock_path, aside)
        except OSError:
            # Nothing to move: another caller won the race, or the holder
            # released the lock between the check and the move.
            return False
        if self._owner_pid() != dead_owner_pid:
            # The owner file names somebody else now.  A new holder took over
            # between our read and our move, so what we moved aside is that
            # holder's lock.  Put it back.
            self._put_back(aside)
            return False
        # The moved lock is free to take when it is old enough, or when the
        # holder we found is gone.  The second case is not a rare one: a tick
        # killed a minute ago leaves a *fresh* directory behind, and the age
        # rule alone would refuse it, which is the wedge this whole change
        # exists to undo.
        moved_is_stale = self._is_stale_at(aside)
        owner_is_gone = (
            dead_owner_pid is not None
            and dead_owner_pid > 0
            and not _pid_alive(dead_owner_pid)
        )
        if not (moved_is_stale or owner_is_gone):
            # Someone else's fresh lock, held by a live process.  Put it back.
            self._put_back(aside)
            return False
        try:
            contents = list(aside.iterdir())
        except OSError:
            contents = []
        if contents:
            # Not the empty marker we made.  Put it back.
            self._put_back(aside)
            return False
        # The owner file belongs to the holder we just moved aside.  It is
        # removed only when it still names that same pid, so a new holder's
        # own file is never taken away.
        if dead_owner_pid is not None and self._owner_pid() == dead_owner_pid:
            _clear_owner(self.owner_path)
        try:
            aside.rmdir()
        except OSError:
            pass
        return True

    def _put_back(self, aside: Path) -> None:
        """Return a directory that was moved aside to the lock path.

        The rename fails when the path is already taken, and that is the case
        to leave alone: a third caller created a lock in the instant the path
        was empty, and putting this one back would mean replacing theirs.  So
        a failed put-back changes nothing.  The moved directory stays beside
        the lock under its ``.stale-`` name and is never deleted, because it
        may be a live peer's lock.
        """
        try:
            os.rename(aside, self.lock_path)
        except OSError:
            # Deliberately nothing: see above.
            pass

    def _owner_pid(self) -> int | None:
        """The pid in the owner file right now, when there is a readable one."""
        owner = _read_owner(self.owner_path)
        if owner is None:
            return None
        try:
            return int(owner.get("pid", -1))
        except (TypeError, ValueError):
            return None

    def _is_stale(self) -> bool:
        return self._is_stale_at(self.lock_path)

    def _is_stale_at(self, path: Path) -> bool:
        try:
            age = time.time() - path.stat().st_mtime
            return age > self.stale_seconds
        except OSError:
            return True


class LockHeld(Exception):
    pass

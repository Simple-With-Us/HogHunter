from __future__ import annotations

import ctypes
import json
import math
import os
import socket
import subprocess
import time
import uuid
from pathlib import Path

try:
    import fcntl
except ImportError:  # pragma: no cover — non-Unix test hosts
    fcntl = None  # type: ignore[assignment]

# The locks this process currently holds, with the identity of the lock
# directory each one created.  Recorded by the lock itself so a hard exit
# can release exactly what was taken, without guessing the configured
# path.
_HELD: dict[Path, tuple[int, int]] = {}

# macOS renamex_np flag: fail the rename when the destination already exists.
# This is the atomic no-replace primitive the housekeeper lock needs.
_RENAME_EXCL = 0x00000004
_RENAME_EXCL_UNSET = object()
_RENAME_EXCL_FN = _RENAME_EXCL_UNSET


def _renamex_np():
    """macOS's renamex_np, or None where it does not exist."""
    global _RENAME_EXCL_FN
    if _RENAME_EXCL_FN is _RENAME_EXCL_UNSET:
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            fn = libc.renamex_np
        except (OSError, AttributeError):
            _RENAME_EXCL_FN = None
        else:
            fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
            fn.restype = ctypes.c_int
            _RENAME_EXCL_FN = fn
    return _RENAME_EXCL_FN


def _rename_exclusive(src: Path, dst: Path) -> bool:
    """Rename src to dst, refusing to replace anything already at dst.

    os.rename is not that primitive.  On POSIX a rename onto an existing EMPTY
    directory SUCCEEDS and replaces it, and the housekeeper lock marker is an
    empty directory, so a plain rename can replace a third reclaimer's fresh
    lock while that reclaimer still believes it holds the lock and sweeps at
    the same time.

    macOS has renamex_np with RENAME_EXCL, which is the atomic no-replace
    rename: the move and the refusal are one decision, so there is no window
    between a check and a rename for a peer to slip into.  Elsewhere the
    fallback checks and then renames, which is strictly weaker but still
    refuses an occupied destination.
    """
    fn = _renamex_np()
    if fn is not None:
        if fn(os.fsencode(str(src)), os.fsencode(str(dst)), _RENAME_EXCL) == 0:
            return True
        return False
    try:
        if dst.exists() or dst.is_symlink():
            return False
        os.rename(src, dst)
        return True
    except OSError:
        return False


def owner_path_for(lock_path: Path) -> Path:
    """The identity file that sits *beside* the lock directory.

    It has to be a sibling, not a file inside the lock directory, because
    `~/apps/mac-auto-cleanup.sh` releases the lock with a plain `rmdir` and
    `rmdir` refuses a directory that has anything in it.  A file inside the
    lock would make the shell's release silently fail and leak the lock
    forever, which is the exact failure this whole change exists to stop.
    """
    return lock_path.with_name(lock_path.name + ".owner")


def guard_path_for(lock_path: Path) -> Path:
    """The mutation guard that sits *beside* the lock directory.

    The guard is the one thing every writer of the housekeeper protocol
    agrees on: HogHunter's Python lock and Swift lock, and AFC's
    `mac-auto-cleanup.sh` and `mac-resource-watch.py`.  It is a plain file
    beside the lock directory, never inside it, for the same reason the
    owner file is a sibling: the shell holder releases the lock with a
    plain `rmdir`.

    It is held with an exclusive `flock` over the whole critical section:
    the ownership check, the stale takeover, the removal, the `mkdir`, the
    owner-file publication, and every release path.

    The guard file is NEVER deleted.  Deleting it would split the flock:
    two processes could each open a different inode and each believe it
    holds the guard, which is the race the guard exists to close.
    """
    return lock_path.with_name(lock_path.name + ".guard")


class _Guard:
    """One process's handle on the mutation guard of one lock."""

    def __init__(self, key: str, path: Path, fd: int) -> None:
        self.key = key
        self.path = path
        self.fd = fd
        # The process that opened the descriptor.  A forked child inherits
        # the table, and the descriptors in it belong to the parent, so the
        # child has to open its own or it would take the parent's guard
        # without ever asking for it.
        self.pid = os.getpid()
        self.depth = 0


# The guards this process holds, by path.  The handle is kept rather than
# reopened, because `flock` belongs to the open file description: a second
# descriptor on the same file is a second lock, and taking it while this
# process already holds the first would deadlock the process against
# itself.
_GUARDS: dict[str, _Guard] = {}


def _guard_for(lock_path: Path) -> _Guard:
    path = guard_path_for(lock_path)
    key = str(path)
    guard = _GUARDS.get(key)
    if guard is not None and guard.pid == os.getpid():
        return guard
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_RDWR | os.O_CREAT, 0o600)
    guard = _Guard(key, path, fd)
    _GUARDS[key] = guard
    return guard


def _acquire_guard(lock_path: Path) -> _Guard:
    """Take the mutation guard for this lock.

    The guard is re-entrant inside one process: taking it again while this
    process already holds it does not block, and it is let go only when the
    last holder releases it.  Nothing that needs the guard is ever waited
    for while the guard is held, so it cannot deadlock.
    """
    guard = _guard_for(lock_path)
    if guard.depth == 0 and fcntl is not None:
        fcntl.flock(guard.fd, fcntl.LOCK_EX)
    guard.depth += 1
    return guard


def _release_guard(guard: _Guard) -> None:
    """Let the guard go, and close the descriptor when nobody holds it."""
    if guard.pid != os.getpid():
        return
    guard.depth -= 1
    if guard.depth > 0:
        return
    guard.depth = 0
    if fcntl is not None:
        fcntl.flock(guard.fd, fcntl.LOCK_UN)
    _GUARDS.pop(guard.key, None)
    try:
        os.close(guard.fd)
    except OSError:
        pass


def _identity_of(path: Path) -> tuple[int, int] | None:
    """The device and inode of a path, when it can be read.

    Two paths with the same identity are the same directory, so the
    identity is what tells the lock this process took from a lock a new
    holder has put in its place.
    """
    try:
        info = os.stat(path)
    except OSError:
        return None
    return (info.st_dev, info.st_ino)


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


# The exact shape of an owner record.  This protocol is written in four
# places -- this file, HogHunter's Swift lock, and AFC's
# `mac-auto-cleanup.sh` and `mac-resource-watch.py` -- and all four publish
# and accept the SAME shape.  A record one of them calls malformed and the
# other calls usable leaves them with conflicting ownership decisions about
# the same lock and the same file, which is how a live lock gets taken away
# from a live holder.
_OWNER_KEYS = frozenset({"pid", "host", "acquired_at", "lock", "start"})

# The longest start token this protocol accepts.  The token is opaque and is
# never parsed, so this bound only keeps a hostile file from putting an
# unbounded string in memory.  The other three implementations apply the
# same bound, in the same place.
_OWNER_START_MAX = 128


def _parse_owner(raw: str) -> dict | None:
    """The owner payload in a raw owner file, or None when it is not usable.

    The owner file is shared state that any process can write, so its shape
    is checked rather than coerced, and this function never raises.  A record
    that is missing a key, carries an unknown key, or holds a value of the
    wrong type or out of bounds is not an owner record, and handing one to
    the lock-ownership logic would let a malformed file decide who holds the
    lock.
    """
    try:
        owner = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(owner, dict):
        return None
    if set(owner) != _OWNER_KEYS:
        # A missing key and an unknown key are the same failure:  the record
        # is not the record this protocol publishes.
        return None
    pid = owner["pid"]
    # Upper bound matches the Swift reader (pid_t is 32-bit):  both readers
    # must accept exactly the same set of owner records.
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0 or pid > 2**31 - 1:
        return None
    host = owner["host"]
    if not isinstance(host, str) or not host:
        return None
    acquired_at = owner["acquired_at"]
    if isinstance(acquired_at, bool) or not isinstance(acquired_at, (int, float)):
        return None
    try:
        finite = math.isfinite(acquired_at)
    except OverflowError:
        # A hundreds-of-digits int is too large to convert to a float:  it
        # is not a timestamp this protocol publishes.
        return None
    if not finite:
        # json accepts NaN and Infinity as literals, so a finite bound is a
        # real check and not a formality.
        return None
    lock = owner["lock"]
    if not isinstance(lock, str) or not lock:
        return None
    start = owner["start"]
    if not isinstance(start, str) or not start or len(start) > _OWNER_START_MAX:
        return None
    return owner


def _read_owner(owner_path: Path) -> dict | None:
    """Read the owner file, or None when it is missing or unusable.

    A corrupt owner file is treated as no owner file at all, so the caller
    falls back to the age rule.  That is the conservative direction: we wait
    rather than steal a lock we cannot identify.
    """
    try:
        raw = owner_path.read_text(encoding="utf-8")
    except OSError:
        return None
    except ValueError:
        # A file that is not UTF-8 raises UnicodeDecodeError, which is a
        # ValueError and NOT an OSError.  It must not escape the release
        # path:  an owner file nobody can read is left alone like any other
        # malformed one.
        return None
    return _parse_owner(raw)


def _owner_pid(owner_path: Path) -> int | None:
    """The pid in the owner file right now, when there is a readable one.

    A missing, malformed or non-positive pid is NO owner at all.  The file
    cannot be trusted to name a holder, so the caller falls back to the age
    rule instead of trusting a pid it could not read, and the releasing side
    treats the file as one that names nobody.
    """
    owner = _read_owner(owner_path)
    if owner is None:
        return None
    pid = owner["pid"]
    return pid if pid > 0 else None


def _owner_is_local(owner: dict) -> bool:
    """True when the owner file names a holder on this machine.

    A pid only means something on the machine that owns it, so a lock held
    on another host cannot be taken over on the strength of a pid that is
    not ours.  The record always names a host, so there is no "no host" case
    left to guess about, and the other three implementations of this
    protocol make the same comparison.
    """
    return owner["host"] == socket.gethostname()


def _process_start_token(pid: int) -> str:
    """The start time of the process a pid names, as an opaque string.

    A pid alone does not name a process:  the kernel hands the same number to
    somebody else once the original exits, and a reused pid that is ALIVE
    looks exactly like a holder that is still running.  The start time tells
    the two apart.

    The token is an opaque string, compared and never parsed.  The C locale
    is forced, and the environment is kept to PATH and LC_ALL alone, so that
    this reader and the other three implementations produce the SAME string
    for the same process:  a TZ in the environment renders the same start
    time in a different zone, and the tokens would then disagree for a
    holder that never moved.
    """
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C"}
    try:
        result = subprocess.run(
            # Absolute path:  the Swift reader runs /bin/ps, and a different ps
            # earlier on PATH could render the same process differently.
            ["/bin/ps", "-o", "lstart=", "-p", str(pid)],
            capture_output=True, text=True, timeout=10, check=False, env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def _owner_is_gone(owner: dict) -> bool:
    """True when the owner record proves the holder is gone.

    A dead pid proves it at once.  A live pid does not, because the kernel
    hands the number to somebody else once the original exits:  the holder
    is gone when that pid now names a DIFFERENT process, and the start token
    is what tells the two apart.  When the token cannot be read the record
    cannot speak for the lock, and the age rule decides.
    """
    pid = owner["pid"]
    if not _pid_alive(pid):
        return True
    current = _process_start_token(pid)
    if not current:
        # The start time could not be read:  the record cannot speak for the
        # lock, and the age rule decides.
        return False
    return current != owner["start"]


def _write_owner(owner_path: Path, lock_path: Path) -> None:
    """Record who holds the lock.

    The pid is what makes a killed holder recoverable: the next process to
    ask for the lock can see that the pid is gone and take over at once,
    instead of waiting out the whole stale window.  The start time travels
    with the pid, because a pid the kernel has since handed to somebody else
    would otherwise look exactly like a live holder.

    The file is published with a replace rather than written in place.  A
    reader that opens the owner file while it is being written would
    otherwise see half of it, and half of it is a file with no readable
    pid in it, which reads as "no owner" and makes the lock look free.
    """
    start = _process_start_token(os.getpid())
    if not start:
        # Without the start time the record cannot tell the holder from a
        # reused pid, so none is written:  a missing owner file is an
        # ordinary state -- the shell holder writes none at all -- and the
        # age rule decides.  The lock itself is the mutex.
        return
    payload = {
        "pid": os.getpid(),
        # The host must be a non-empty string:  that is the declared shape of
        # the record, and a record this process writes must be one it can
        # read back.
        "host": socket.gethostname() or "unknown",
        "acquired_at": time.time(),
        "lock": str(lock_path),
        # The start time of THIS process, so a reader can tell the holder
        # from a pid the kernel has since handed to somebody else.
        "start": start,
    }
    tmp = owner_path.with_name(f"{owner_path.name}.{uuid.uuid4().hex}.tmp")
    try:
        # The temp file is PRIVATE (0600):  the owner record names a pid and
        # a host and sits in a shared directory.
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload))
        os.replace(tmp, owner_path)
    except OSError:
        # The lock itself is the mutex.  The owner file is only a hint that
        # makes recovery fast, so failing to write it must not fail the
        # acquire; it just falls back to the age rule.
        try:
            tmp.unlink()
        except OSError:
            pass


def _owner_describes_holder(owner_path: Path, lock_path: Path) -> bool:
    """True when the owner file describes the holder of the lock that is there now.

    A holder that never wrote an owner file -- the shell holder -- leaves a
    leftover file from an earlier holder beside it.  That file names a pid
    that is gone, and reading it as the current holder would let a fresh live
    lock be taken over.  The owner file is only about the current holder when
    it is STRICTLY newer than the lock directory.

    Strictly, not "at least as new":  the other three implementations of this
    protocol refuse a record whose mtime equals the lock directory's, and two
    readers that disagree about the same file leave the fleet with
    conflicting ownership decisions about one lock.
    """
    try:
        owner_modified = owner_path.stat().st_mtime
        lock_modified = lock_path.stat().st_mtime
    except OSError:
        return False
    return owner_modified > lock_modified


def _clear_owner(owner_path: Path, only_pid: int | None = None) -> None:
    """Remove the owner file, optionally only when it names a given pid.

    The pid check is what keeps one holder from deleting the identity of
    another: if our lock was stolen as stale while we were still running, the
    file now names somebody else and we leave it alone.

    A file that cannot be READ AS AN OWNER RECORD is left alone as well.  A
    holder that cannot read the file cannot know whose it is, and deleting
    it would take away the identity of whoever really holds the lock now.
    The same rule the AFC readers apply, and they are the other readers of
    this very file.
    """
    if only_pid is not None:
        pid = _owner_pid(owner_path)
        if pid is None or pid != only_pid:
            return
    try:
        owner_path.unlink()
    except OSError:
        pass


def _remove_lock_directory(lock_path: Path, identity: tuple[int, int] | None) -> bool:
    """Remove the lock directory, but only when it is still the one that was taken.

    The directory is moved aside first, because a check and a removal are
    two steps and a takeover can slip between them: the check says "this is
    the lock I took", a new holder replaces the path with its own lock, and
    the removal then takes the NEW holder's lock away while that holder goes
    on believing it holds the lock.  Moving the directory aside is one
    decision, and what lands there is whatever was at the path, so it goes
    back untouched when it turns out not to be ours.

    Returns True when the lock directory is gone.
    """
    aside = lock_path.with_name(f"{lock_path.name}.release-{uuid.uuid4().hex}")
    if not _rename_exclusive(lock_path, aside):
        return False
    if identity is not None and _identity_of(aside) != identity:
        # A new holder's lock is at the path.  Put it back exactly as it was.
        _rename_exclusive(aside, lock_path)
        return False
    try:
        os.rmdir(aside)
    except OSError:
        # Not empty, so it is not the marker we made.  Put it back rather
        # than destroy what is inside it.
        _rename_exclusive(aside, lock_path)
        return False
    return True


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
    for lock_path, identity in list(_HELD.items()):
        owner_path = owner_path_for(lock_path)
        guard = _acquire_guard(lock_path)
        try:
            pid = _owner_pid(owner_path)
            if pid is not None and pid != os.getpid():
                # Somebody else owns it now.  Leave it exactly as it is.
                continue
            if not _remove_lock_directory(lock_path, identity):
                continue
            # The lock directory goes first and the owner file second.  The
            # other order strands the lock: a failed removal after the owner
            # file is gone leaves a lock that nobody owns and that nothing
            # can take over until the whole stale window has passed.
            _clear_owner(owner_path, only_pid=os.getpid())
            _HELD.pop(lock_path, None)
            released = True
        finally:
            _release_guard(guard)
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
        self._identity: tuple[int, int] | None = None

    @property
    def owner_path(self) -> Path:
        return owner_path_for(self.lock_path)

    @property
    def guard_path(self) -> Path:
        return guard_path_for(self.lock_path)

    def __enter__(self) -> "HousekeeperLock":
        if os.environ.get("HOUSEKEEPER_LOCK_OWNER") == "1":
            return self
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        # The guard is held across the whole critical section: the
        # ownership check, the stale takeover, the removal, the `mkdir` and
        # the owner-file publication.  Two reclaimers that both decide to
        # take a stale lock over cannot interleave inside it.
        guard = _acquire_guard(self.lock_path)
        try:
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
            self._identity = _identity_of(self.lock_path)
            _HELD[self.lock_path] = self._identity
            _write_owner(self.owner_path, self.lock_path)
        finally:
            _release_guard(guard)
        os.environ["HOUSEKEEPER_LOCK_OWNER"] = "1"
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self._owned:
            guard = _acquire_guard(self.lock_path)
            try:
                # The lock directory goes first and the owner file second, so
                # a failed removal cannot strand a lock that nobody owns.
                if _remove_lock_directory(self.lock_path, self._identity):
                    _clear_owner(self.owner_path, only_pid=os.getpid())
            finally:
                _release_guard(guard)
            self._owned = False
            _HELD.pop(self.lock_path, None)
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
            # No usable owner file: either a shell holder that never wrote
            # one, or a file that is not the record this protocol publishes.
            # Fall back to the age rule.
            return False
        pid = owner["pid"]
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
        if not _owner_is_local(owner):
            # The holder is on another machine.  Its pid says nothing about a
            # process here, so the lock may only be taken over once the stale
            # window has passed.
            return False
        # The record proves the holder is gone:  a dead pid, or a live pid
        # that now names a different process.
        return _owner_is_gone(owner)

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
        dead_owner = _read_owner(self.owner_path)
        dead_owner_pid = dead_owner["pid"] if dead_owner is not None else None
        aside = self.lock_path.with_name(f"{self.lock_path.name}.stale-{uuid.uuid4().hex}")
        try:
            os.rename(self.lock_path, aside)
        except OSError:
            # Nothing to move: another caller won the race, or the holder
            # released the lock between the check and the move.
            return False
        if _read_owner(self.owner_path) != dead_owner:
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
        # The holder we found is gone when its pid is dead, or when that pid
        # now names a different process.  The start token is what tells the
        # two apart, and it is the same rule every implementation applies.
        owner_is_gone = dead_owner is not None and _owner_is_gone(dead_owner)
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
        try:
            aside.rmdir()
        except OSError:
            pass
        # The owner file belongs to the holder we just moved aside.  It is
        # removed only when it still names that same pid, so a new holder's
        # own file is never taken away.
        if dead_owner_pid is not None and self._owner_pid() == dead_owner_pid:
            _clear_owner(self.owner_path)
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
        _rename_exclusive(aside, self.lock_path)

    def _owner_pid(self) -> int | None:
        """The pid in the owner file right now, when there is a readable one."""
        return _owner_pid(self.owner_path)

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

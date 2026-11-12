"""Cooperative monotonic run deadlines and owned child process groups.

Checks bound work between filesystem calls; they cannot interrupt a stuck kernel syscall.
The outer watchdog remains responsible for that final containment boundary.
"""
from __future__ import annotations

import contextvars
import functools
import os
import signal
import subprocess
import time
import threading
from contextlib import contextmanager
from typing import Callable


class BudgetExceeded(Exception):
    pass


class WorkBudget:
    def __init__(self, seconds: float, monotonic: Callable[[], float] = time.monotonic):
        self.monotonic = monotonic
        self.deadline = monotonic() + max(0.0, seconds)

    def remaining(self) -> float:
        return max(0.0, self.deadline - self.monotonic())

    def check(self) -> None:
        if self.remaining() <= 0:
            raise BudgetExceeded("maintenance work budget exhausted")

    def timeout(self, seconds: float) -> float:
        self.check()
        return min(seconds, self.remaining())


_current = contextvars.ContextVar("vacuum_work_budget", default=None)
_children: dict[int, subprocess.Popen] = {}
_children_lock = threading.RLock()
_shutdown = False


def current():
    return _current.get()


def check() -> None:
    if current() is not None:
        current().check()


def timeout(seconds: float) -> float:
    return current().timeout(seconds) if current() is not None else seconds


@contextmanager
def scope(work_budget):
    token = _current.set(work_budget)
    try:
        yield work_budget
    finally:
        _current.reset(token)


def bounded_run(method):
    """Nested watch/pressure runs share one deadline; independent calls start afresh."""
    @functools.wraps(method)
    def wrapped(self, *args, **kwargs):
        previous = getattr(self, "_active_record", None)
        work_budget = current() or WorkBudget(self._work_budget_seconds, self._monotonic)
        try:
            with scope(work_budget):
                return method(self, *args, **kwargs)
        finally:
            self._active_record = previous
    return wrapped


def spawn(argv, **kwargs):
    # Spawning and registering are atomic against watchdog shutdown.
    with _children_lock:
        if _shutdown:
            raise BudgetExceeded("maintenance watchdog is shutting down child work")
        proc = subprocess.Popen(argv, start_new_session=True, **kwargs)
        _children[proc.pid] = proc
        return proc


def close_output_pipes(proc) -> None:
    for stream in (proc.stdout, proc.stderr):
        if stream is not None:
            try:
                stream.close()
            except (OSError, ValueError):
                pass


def kill_group(proc) -> bool:
    """Stop/reap the owned group without waiting for inherited pipe EOF.

    A descendant that starts another session is outside this group's scope.
    It may keep stdout open after the owned group stopped; that is not evidence
    that this group is still alive, and must not wedge the lock barrier.
    """
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError:
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.wait(timeout=5)
    except (subprocess.TimeoutExpired, OSError, ValueError):
        return False
    if group_stopped(proc.pid):
        close_output_pipes(proc)
        with _children_lock:
            _children.pop(proc.pid, None)
        return True
    return False


def group_stopped(pgid) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return True
    except OSError:
        return False
    # Reparented zombies cannot execute or touch the filesystem, but kill(0)
    # continues to see them until init reaps them.  Inspect states, never argv.
    try:
        states = subprocess.run(["ps", "-axo", "pgid=,stat="], capture_output=True,
                                text=True, timeout=2, start_new_session=True)
        if states.returncode != 0:
            return False
        matches = [row.split()[1] for row in states.stdout.splitlines()
                   if len(row.split()) == 2 and row.split()[0] == str(pgid)]
        if matches:
            return all(state.startswith("Z") for state in matches)
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return True
        return False
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


@contextmanager
def child_barrier(on_wait=None, monotonic=time.monotonic, sleep=time.sleep):
    """Retain the lock for live/unknown children; report each 30s of drain."""
    try:
        yield
    finally:
        started = monotonic()
        last_notice = started
        while True:
            with _children_lock:
                children = list(_children.values())
            stopped = True
            for index, proc in enumerate(children):
                stopped = kill_group(proc) and stopped
                now = monotonic()
                pending = not stopped or index + 1 < len(children)
                if pending and on_wait is not None and now - last_notice >= 30:
                    last_notice = now
                    try:
                        on_wait(max(0.0, now - started))
                    except Exception:
                        pass  # observability failure must never release a live group
            if stopped:
                break
            sleep(.1)


def unregister(proc):
    # Closing its pipes and exiting does not prove a leader's children stopped.
    if group_stopped(proc.pid):
        with _children_lock:
            _children.pop(proc.pid, None)
        return
    if not kill_group(proc):
        raise ChildProcessError("owned child process group could not be proven stopped")


def terminate_all() -> bool:
    """Kill/reap every owned group; False means lock release is not proven safe."""
    global _shutdown
    with _children_lock:
        _shutdown = True
        children = list(_children.values())
    return all([kill_group(proc) for proc in children])


def run_process(argv, **kwargs):
    """subprocess.run subset used by lane probes, with descendant containment."""
    seconds = timeout(float(kwargs.pop("timeout", 60)))
    capture = kwargs.pop("capture_output", False)
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    proc = spawn(argv, **kwargs)
    try:
        out, err = proc.communicate(timeout=seconds)
    except BaseException:
        kill_group(proc)
        raise
    unregister(proc)
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)

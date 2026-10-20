#!/usr/bin/env python3
"""Run an optional command with a deadline and clean up its process group."""
import argparse
import os
import math
import signal
import subprocess
import sys
import time


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def signal_group(group, signum):
    try:
        os.killpg(group, signum)
        return True
    except ProcessLookupError:
        return False
    except OSError as error:
        # EPERM/EINVAL must not abort the cleanup; the caller falls back to the
        # direct child, which we always own.
        if signum == 0:
            return True  # Existence/permission is not proof of live members.
        print(f'Could not signal process group {group}: {error}', file=sys.stderr, flush=True)
        return False


def wait_unreaped(process, timeout, cancellation=lambda: None):
    """Observe exit without releasing the leader PID before group cleanup."""
    deadline = time.monotonic() + timeout
    while True:
        if signum := cancellation():
            raise Interrupted(signum)
        event = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if event is not None and event.si_pid == process.pid:
            return event.si_status if event.si_code == os.CLD_EXITED else -event.si_status
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(process.args, timeout)
        time.sleep(min(0.02, remaining))


def run(command, timeout, grace=2):
    process = None
    previous = {}
    requested_signal = None

    def interrupted(signum, _frame):
        # Never raise inside Popen: it may already own a child not yet returned.
        nonlocal requested_signal
        requested_signal = signum

    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous[signum] = signal.signal(signum, interrupted)
        process = subprocess.Popen(command, start_new_session=True)
        # Readiness marker for the cancellation test: it is emitted only once both
        # handlers are installed, so a test never signals into the install window.
        print('Supervisor ready.', file=sys.stderr, flush=True)
        try:
            return wait_unreaped(process, timeout, lambda: requested_signal)
        except subprocess.TimeoutExpired:
            print('Optional capture exceeded its deadline.', file=sys.stderr, flush=True)
            raise
    except Interrupted as interruption:
        # Covers the handler-install window too, so a signal there is not a traceback.
        return 128 + interruption.signum
    finally:
        # Cleanup is required even when the parent already exited successfully:
        # a GUI/helper descendant can still hold the runner's output handles.
        for signum in previous:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if process is not None:
                if signal_group(process.pid, signal.SIGTERM):
                    deadline = time.monotonic() + grace
                    while time.monotonic() < deadline:
                        if not signal_group(process.pid, 0):
                            break
                        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
                # Escalate the whole group even when the graceful signal was refused:
                # killpg reports EPERM for members it may not signal while still
                # signalling the rest, so a False return is not proof the group is gone.
                signal_group(process.pid, signal.SIGKILL)
                try:
                    process.kill()
                except OSError:
                    pass
                try:
                    process.wait(timeout=max(grace, 5))
                except subprocess.TimeoutExpired:
                    print('Capture process did not exit after group cleanup.',
                          file=sys.stderr, flush=True)
                    raise
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--grace', type=float, default=2)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not math.isfinite(args.timeout) or not math.isfinite(args.grace) or args.timeout <= 0 or args.grace < 0:
        parser.error('A command, positive timeout and nonnegative grace are required.')
    if not all(hasattr(os, name) for name in ('waitid', 'WNOWAIT')):
        parser.error('This supervisor requires waitid with WNOWAIT support.')
    try:
        result = run(command, args.timeout, args.grace)
    except subprocess.TimeoutExpired:
        result = 124
    print(f'Optional capture exit status: {result}', file=sys.stderr, flush=True)
    return result if result >= 0 else 128 - result


if __name__ == '__main__':
    sys.exit(main())

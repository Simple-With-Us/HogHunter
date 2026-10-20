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


def run(command, timeout, grace=2):
    process = subprocess.Popen(command, start_new_session=True)
    previous = {}

    def interrupted(signum, _frame):
        raise Interrupted(signum)

    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous[signum] = signal.signal(signum, interrupted)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print('Optional capture exceeded its deadline.', file=sys.stderr, flush=True)
            return 124
        except Interrupted as interruption:
            return 128 + interruption.signum
    finally:
        # Cleanup is required even when the parent already exited successfully:
        # a GUI/helper descendant can still hold the runner's output handles.
        for signum in previous:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if signal_group(process.pid, signal.SIGTERM):
                deadline = time.monotonic() + grace
                while time.monotonic() < deadline:
                    if not signal_group(process.pid, 0):
                        break
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))
                signal_group(process.pid, signal.SIGKILL)
            process.wait()
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
    result = run(command, args.timeout, args.grace)
    print(f'Optional capture exit status: {result}', file=sys.stderr, flush=True)
    return result if result >= 0 else 128 - result


if __name__ == '__main__':
    sys.exit(main())

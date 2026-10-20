#!/usr/bin/env python3
"""Supplement the existing VPS snapshot without reading arguments or credentials.

Run after the existing watch finishes, under the same scheduler lock.  Directory
failures omit that measurement; they never become a fictitious zero size.
"""
import argparse
import datetime
import re
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

TOOLS = (
    ('claude', 'Claude Code', ('claude',)),
    ('codex', 'Codex', ('codex',)),
    ('muse', 'Muse', ('muse',)),
    ('minimax', 'MiniMax Code', ('mcode',)),
    ('fleet-cli', 'Fleet CLI', ('agent-sync', 'board')),
    ('fleet-listener', 'Fleet Listener', ('agent-sync-listener',)),
    ('recall', 'Fleet Recall', ('recall',)),
    ('shellular', 'Shellular', ('shellular',)),
    ('docker', 'Docker', ('dockerd',)),
    ('caddy', 'Caddy', ('caddy',)),
    ('postgres', 'PostgreSQL', ('postgres',)),
    ('redis', 'Redis', ('redis-server',)),
)
DIRECTORIES = ('Code', 'apps/lanes', '.claude', '.codex', '.config/muse', '.minimax', '.minimax-code', '.npm', '.cache')


def process_inventory(proc=Path('/proc')):
    """Read executable names only; permission errors make negative results unknown."""
    names = []
    complete = True
    try:
        entries = list(proc.iterdir())
    except OSError:
        return [], False
    for entry in entries:
        if not entry.name.isdigit():
            continue
        if int(entry.name) in {os.getpid(), os.getppid()}:
            continue  # The collector and its launcher are not watched tools.
        try:
            name = (entry / 'comm').read_text().strip()
            # Kernel comm truncates names.  The symlink is executable identity only.
            try:
                executable = Path(os.readlink(entry / 'exe')).name
            except FileNotFoundError:
                executable = name
            names.append({name, executable})
        except FileNotFoundError:
            continue  # A process exiting during enumeration is normal.
        except OSError:
            complete = False
    return names, complete


def installed_command(command, home=None):
    home = Path.home() if home is None else home
    candidates = [home / '.local/bin' / command, home / '.minimax-code/bin' / command,
                  home / '.cargo/bin' / command, home / '.codex/bin' / command]
    if command == 'shellular' and (home / 'apps/shellular-runtime').is_dir():
        return True
    return any(path.is_file() and os.access(path, os.X_OK) for path in candidates)


def tool_statuses(inventory, complete, which=shutil.which, installed=installed_command):
    rows = []
    # Interpreted CLIs cannot be identified safely from executable identity alone.
    interpreted = any(names & {'node', 'nodejs', 'python', 'python3', 'bash', 'sh'} for names in inventory)
    for ident, label, commands in TOOLS:
        count = sum(bool(names.intersection(commands)) for names in inventory)
        is_installed = any(which(command) is not None or installed(command) for command in commands)
        if count:
            state = 'running'
        elif not complete or (interpreted and ident not in {'docker', 'caddy', 'postgres', 'redis'}):
            state = 'unknown'
        else:
            state = 'stopped' if is_installed else 'absent'
        rows.append(dict(id=ident, name=label, state=state, count=count))
    return rows


# Named service metadata can identify interpreted daemons without inspecting argv.
SERVICE_UNITS = {
    'fleet-listener': 'agent-sync-listener.service',
    'recall': 'fleet-recall.service',
    'shellular': 'shellular.service',
}


def service_state(unit, run=subprocess.run):
    try:
        result = run(['systemctl', 'show', unit, '--property=LoadState,ActiveState', '--no-pager'],
                     capture_output=True, text=True, timeout=2, check=False)
        values = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        if result.returncode != 0 or values.get('LoadState') != 'loaded':
            return None
        active = values.get('ActiveState')
        if active == 'active':
            return 'running'
        if active in {'inactive', 'failed'}:
            return 'stopped'
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def shellular_state(home, run=subprocess.run, proc=Path('/proc')):
    """Read the manager's filtered identity helper, never PM2 environment or argv."""
    helper = home / 'apps/shellular-runtime/bin/status-json'
    expected = str(home / 'apps/shellular-runtime/lib/node_modules/shellular/dist/main.js')
    try:
        result = run([str(helper)], capture_output=True, text=True, timeout=3, check=False)
        if result.returncode != 0 or len(result.stdout) > 4096:
            return 'unknown'
        identity = json.loads(result.stdout)
        if not isinstance(identity, dict) or identity.get('name') != 'shellular' or identity.get('execpath') != expected:
            return 'unknown'
        status = identity.get('status')
        if status == 'online':
            pid = identity.get('pid')
            if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0 and (proc / str(pid) / 'exe').exists():
                return 'running'
            return 'unknown'
        if status in {'stopped', 'offline', 'errored'}:
            return 'stopped'
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return 'unknown'


def directory_bytes(path, run=subprocess.run):
    try:
        if not path.is_dir():
            return None
        result = run(['du', '-sx', '--block-size=1', '--', str(path)],
                     capture_output=True, text=True, timeout=8, check=False)
        if result.returncode != 0:
            return None
        value = int(result.stdout.split()[0])
        return value if value >= 0 else None
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return None


def supplement(snapshot, home, measure=directory_bytes, inventory=None, services=service_state, shellular=shellular_state):
    result = dict(snapshot)
    directories = {row['path']: row for row in snapshot.get('largest_dirs', [])}
    for relative in DIRECTORIES:
        path = home / relative
        directories.pop(str(path), None)
        size = measure(path)
        if size is not None:
            directories[str(path)] = dict(path=str(path), bytes=size)
    result['largest_dirs'] = list(directories.values())
    names, complete = process_inventory() if inventory is None else inventory
    rows = tool_statuses(names, complete)
    for row in rows:
        if row['id'] in SERVICE_UNITS and row['state'] != 'running':
            state = services(SERVICE_UNITS[row['id']])
            if state is not None:
                row['state'] = state
                row['count'] = 1 if state == 'running' else 0
    for row in rows:
        if row['id'] == 'shellular':
            state = shellular(home)
            if state in {'running', 'stopped'} or row['state'] not in {'running', 'stopped'}:
                row['state'] = state
                row['count'] = 1 if state == 'running' else 0
    result['tool_statuses'] = rows
    return result


def database_samples(snapshot, state):
    """Read only the three audited numeric size histories, never database contents."""
    try:
        source_time = datetime.datetime.fromisoformat(snapshot['generated_at'].replace('Z', '+00:00')).timestamp()
    except (KeyError, ValueError, TypeError):
        return []
    samples = []
    for key in ('st_app_db', 'ct_db', 'um_db'):
        if key not in snapshot.get('app_dbs', {}):
            continue
        try:
            path = state / (key + '.samples')
            if path.stat().st_size > 1_048_576:
                continue
            lines = path.read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            if re.fullmatch(r'[0-9]+ [0-9]+', line) is None:
                continue
            timestamp, size = map(int, line.split())
            if source_time - 172800 <= timestamp <= source_time and size <= 9223372036854775807:
                samples.append(dict(path=key, bytes=size, sampled_at=timestamp))
    return sorted(samples, key=lambda row: row['sampled_at'])[-1800:]


def directory_samples(snapshot, state):
    """Own a bounded new directory-history file; leave legacy histories untouched."""
    try:
        timestamp = datetime.datetime.fromisoformat(snapshot['generated_at'].replace('Z', '+00:00')).timestamp()
    except (KeyError, ValueError, TypeError):
        return []
    path = state / 'hoghunter-directory-history.json'
    previous = {}
    try:
        if path.stat().st_size <= 1_048_576:
            previous = json.loads(path.read_text())
    except (OSError, ValueError):
        pass
    host = snapshot.get('host', '')
    rows = previous.get('samples', []) if isinstance(previous, dict) and previous.get('host') == host else []
    if not isinstance(rows, list):
        rows = []
    valid = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        when, size, name = row.get('sampled_at'), row.get('bytes'), row.get('path')
        if (isinstance(when, (int, float)) and isinstance(size, int) and size >= 0
                and isinstance(name, str) and len(name) <= 4096
                and timestamp - 172800 <= when <= timestamp):
            valid[(name, int(when // 900))] = row
    for directory in snapshot.get('largest_dirs', []):
        valid[(directory['path'], int(timestamp // 900))] = dict(
            path=directory['path'], bytes=directory['bytes'], sampled_at=timestamp)
    # Each path has at most 193 quarter-hour observations over the 48-hour window.
    rows = sorted(valid.values(), key=lambda row: row['sampled_at'])
    by_path = {}
    for row in rows:
        by_path.setdefault(row['path'], []).append(row)
    rows = [row for group in by_path.values() for row in group[-193:]][-6000:]
    atomic_write(path, dict(host=host, samples=rows))
    return rows


def atomic_write(path, value):
    fd, temporary = tempfile.mkstemp(prefix='.vps-status-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, separators=(',', ':'))
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot', type=Path, required=True)
    parser.add_argument('--history', type=Path, default=Path('/root/.vps-storage-watch'))
    parser.add_argument('--home', type=Path, default=Path.home())
    args = parser.parse_args()
    original = json.loads(args.snapshot.read_text())
    # Prevent applying measurements to a snapshot published during the scan.
    output = supplement(original, args.home)
    output['database_samples'] = database_samples(original, args.history)
    # Check freshness *before* `directory_samples`: that helper persists the
    # directory-history cache, so ordering it last would commit measurements
    # derived from a snapshot this run has just decided to discard.
    current = json.loads(args.snapshot.read_text())
    if current != original:
        raise SystemExit('Snapshot changed during collection; leaving it untouched.')
    output['directory_samples'] = directory_samples(output, args.history)
    atomic_write(args.snapshot, output)


if __name__ == '__main__':
    main()

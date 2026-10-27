#!/usr/bin/env python3
"""Control a process or a Coolify workload on this host, deliberately.

The Mac asks for this over SSH and always names a process by its identity --
the pid and the start time the sampler read -- never by a bare pid, so a pid
that was recycled between the last sample and the click is refused instead of
signalled.  The owner allowlist keeps the action to the accounts this host
runs and to Coolify's own workloads, the denylist keeps the host alive, and
every action lands in a root-only audit log.

Install it root-owned and not writable by anyone else:

    install -o root -g root -m 0755 control.py /usr/local/sbin/hoghunter-control
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys

# The accounts this host runs work under.  A process owned by anyone else is
# never a target.
ALLOWED_OWNERS = ('root', 'jay')

# Infrastructure that keeps the host reachable, the fleet wired and the
# workloads running.  These are never stopped, whatever the caller asks for.
PROTECTED_NAMES = {
    'systemd', 'init', 'kthreadd', 'ksoftirqd', 'kworker', 'kworker/0', 'migration',
    'rcu_sched', 'rcu_bh', 'watchdog', 'kswapd0', 'kcompactd0', 'khugepaged',
    'sshd', 'sshd-session', 'tailscaled', 'dockerd', 'containerd', 'containerd-shim',
    'cron', 'crond', 'rsyslogd', 'dbus-daemon', 'dbus-broker', 'udevd', 'polkitd',
    'fail2ban-server', 'unattended-upgr', 'NetworkManager', 'systemd-journald',
    'systemd-logind', 'systemd-udevd', 'systemd-resolved', 'systemd-timesyncd',
    'getty', 'agetty', 'agetty2', 'login', 'su', 'sudo', 'bash', 'sh', 'dash',
    'ssh', 'sshd-session', 'scp', 'sftp', 'rsync',
    'datadog-agent', 'trace-agent', 'process-agent', 'system-probe', 'agent',
    'coolify', 'coolify-proxy', 'coolify-db', 'coolify-redis', 'coolify-sentinel',
    'traefik',
}

# The interpreters are not protected: the workloads that waste CPU on this
# host are node and python processes, and protecting them would protect the
# problem instead of the host.  A process that belongs to a container is
# stopped through its container, so the protected names apply to host
# processes only.

# Where the audit log lives.  Root-only, because it names what was stopped.
AUDIT_LOG = Path('/var/log/hoghunter-control.log')


def process_stat_fields(pid, proc=Path('/proc')):
    """The /proc fields of one process, or None when it is gone."""
    try:
        raw = (proc / str(pid) / 'stat').read_text()
    except OSError:
        return None
    try:
        tail = raw[raw.rindex(')') + 2:].split()
    except ValueError:
        return None
    # tail[0] is the state, so field N lives at index N - 3.  utime is field
    # 14, stime 15, starttime 22, ppid 4.
    try:
        return {
            'comm': raw[raw.index('(') + 1:raw.rindex(')')],
            'ppid': int(tail[1]),
            'utime': int(tail[11]),
            'stime': int(tail[12]),
            'start_time': int(tail[19]),
        }
    except (IndexError, ValueError):
        return None


def is_kernel_thread(pid, proc=Path('/proc')):
    """A kernel thread has no executable of its own, and cannot be signalled."""
    return not (proc / str(pid) / 'exe').exists()


def owner_of(pid, proc=Path('/proc')):
    try:
        uid = (proc / str(pid)).stat().st_uid
    except OSError:
        return None
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def ancestor_pids(proc=Path('/proc')):
    """Every pid above this process, so a caller never stops its own session."""
    ancestors = set()
    pid = os.getppid()
    while pid and pid not in ancestors:
        ancestors.add(pid)
        fields = process_stat_fields(pid, proc)
        if fields is None:
            break
        pid = fields['ppid']
    return ancestors


def container_identities(run=subprocess.run):
    """Container id -> container name, read once for the whole listing."""
    identities = {}
    try:
        listing = run(['docker', 'ps', '--no-trunc', '--format', '{{.ID}} {{.Names}}'],
                      capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return identities
    if listing.returncode != 0:
        return identities
    for line in listing.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            identities[parts[0]] = parts[1]
    return identities


def container_of(pid, identities, proc=Path('/proc')):
    """The container a process belongs to, or None."""
    if not identities:
        return None
    try:
        cgroup = (proc / str(pid) / 'cgroup').read_text()
    except OSError:
        return None
    for container_id, name in identities.items():
        if container_id in cgroup:
            return name
    return None


def coolify_containers(run=subprocess.run):
    """The Coolify workloads on this host, with the name the owner knows."""
    try:
        listing = run(['docker', 'ps', '--format', '{{.ID}}'], capture_output=True, text=True, timeout=5, check=False)
        if listing.returncode != 0:
            return []
        ids = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
        if not ids:
            return []
        detail = run(['docker', 'inspect'] + ids, capture_output=True, text=True, timeout=15, check=False)
        if detail.returncode != 0:
            return []
        inspected = json.loads(detail.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return []
    rows = []
    for entry in inspected if isinstance(inspected, list) else []:
        labels = (entry.get('Config') or {}).get('Labels') or {}
        if 'coolify.name' not in labels:
            continue
        project = labels.get('coolify.projectName') or ''
        resource = labels.get('coolify.resourceName') or labels.get('coolify.serviceName') or ''
        state = entry.get('State') or {}
        rows.append({
            'container': (entry.get('Name') or '').lstrip('/'),
            'name': ' / '.join(part for part in (project, resource) if part) or labels['coolify.name'],
            'type': labels.get('coolify.type') or 'standalone',
            'status': state.get('Status') or 'unknown',
            'health': (state.get('Health') or {}).get('Status') or '',
        })
    rows.sort(key=lambda row: row['name'])
    return rows


def list_targets(proc=Path('/proc'), identities=None, run=subprocess.run, owners=ALLOWED_OWNERS):
    """The processes and workloads this host is willing to act on."""
    if identities is None:
        identities = container_identities(run)
    rows = []
    for entry in sorted(proc.iterdir()):
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        fields = process_stat_fields(pid, proc)
        if fields is None:
            continue
        owner = owner_of(pid, proc)
        container = container_of(pid, identities, proc)
        if owner not in owners and container is None:
            continue
        if fields['comm'] in PROTECTED_NAMES and container is None:
            continue
        if container is None and is_kernel_thread(pid, proc):
            continue  # Kernel threads cannot be signalled and are not work.
        rows.append({
            'pid': pid,
            'start_time': fields['start_time'],
            'name': fields['comm'],
            'owner': owner,
            'container': container,
            'controllable': pid > 1 and fields['comm'] not in PROTECTED_NAMES,
        })
    return {'processes': rows, 'containers': coolify_containers()}


def stop_process(pid, start_time, force=False, proc=Path('/proc'), kill=None, ancestors=None, container_lookup=None, identities=None, owners=ALLOWED_OWNERS):
    """Stop one process, if it is still the one the caller named."""
    if pid <= 1:
        return {'ok': False, 'reason': 'refusing to signal pid 1'}
    fields = process_stat_fields(pid, proc)
    if fields is None:
        return {'ok': False, 'reason': 'that process is already gone'}
    if fields['start_time'] != start_time:
        return {'ok': False, 'reason': 'that process changed since it was sampled'}
    if pid in (ancestors if ancestors is not None else ancestor_pids(proc)):
        return {'ok': False, 'reason': 'refusing to stop this session'}
    owner = owner_of(pid, proc)
    container = container_lookup(pid) if container_lookup is not None else container_of(pid, identities, proc)
    if owner not in owners and container is None:
        return {'ok': False, 'reason': f'owned by {owner or "another user"}'}
    if fields['comm'] in PROTECTED_NAMES and container is None:
        return {'ok': False, 'reason': f'{fields["comm"]} keeps the host running'}
    if container is None and is_kernel_thread(pid, proc):
        return {'ok': False, 'reason': 'kernel threads cannot be signalled'}
    try:
        (kill or os.kill)(pid, signal.SIGKILL if force else signal.SIGTERM)
    except OSError as error:
        return {'ok': False, 'reason': error.strerror or 'could not signal it'}
    return {'ok': True, 'pid': pid, 'name': fields['comm'], 'owner': owner,
            'container': container, 'signal': 'SIGKILL' if force else 'SIGTERM'}


def container_action(name, action, run=subprocess.run):
    """Stop or restart one Coolify workload."""
    targets = {}
    display = {}
    for row in coolify_containers(run=run):
        targets.setdefault(row['container'], row)
        display.setdefault(row['name'], []).append(row)
    # The Mac names the workload by the display name it was shown, so a
    # workload is reachable by either name.  The Docker name wins when both
    # are present, and Docker is always told the Docker name: the display
    # label carries spaces the remote shell would split.  Scaled replicas
    # share a display name, so an ambiguous one is refused, never guessed.
    if name not in targets:
        matches = display.get(name, [])
        if len(matches) > 1:
            return {'ok': False, 'reason': 'that name matches more than one workload; use the container name'}
        if matches:
            targets[name] = matches[0]
    if name not in targets:
        return {'ok': False, 'reason': 'that workload is not running on this host'}
    container = targets[name]['container']
    try:
        result = run(['docker', action, container], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'ok': False, 'reason': str(error)}
    if result.returncode != 0:
        return {'ok': False, 'reason': (result.stderr or result.stdout or 'docker refused').strip()[:200]}
    return {'ok': True, 'container': container, 'name': targets[name]['name'], 'action': action}


def audit(command, target, outcome):
    """One line, root-only, naming what was done."""
    command, target, outcome = (' '.join(str(v).split()) for v in (command, target, outcome))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    try:
        with open(AUDIT_LOG, 'a', encoding='utf-8') as log:
            log.write(f'{stamp} command={command} target={target} outcome={outcome}\n')
            os.chmod(AUDIT_LOG, 0o600)
    except OSError:
        pass


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)

    listing = sub.add_parser('list', help='the processes and workloads this host will act on')
    listing.add_argument('--owner', choices=('root', 'jay', 'container'), help='only one group')

    stop = sub.add_parser('stop-process', help='stop one process by identity')
    stop.add_argument('--pid', type=int, required=True)
    stop.add_argument('--start-time', type=int, required=True)
    stop.add_argument('--force', action='store_true', help='SIGKILL instead of SIGTERM')
    stop.add_argument('--confirm', action='store_true', help='required: this stops a process')

    for action in ('stop-container', 'restart-container'):
        command = sub.add_parser(action, help=f'{action} for one Coolify workload')
        command.add_argument('--name', required=True)
        command.add_argument('--confirm', action='store_true', help='required: this changes a workload')

    args = parser.parse_args(argv)

    if args.command == 'list':
        targets = list_targets()
        if args.owner:
            if args.owner == 'container':
                targets['processes'] = [row for row in targets['processes'] if row['container']]
            else:
                targets['processes'] = [row for row in targets['processes']
                                        if row['owner'] == args.owner and not row['container']]
        print(json.dumps(targets))
        return 0

    if not args.confirm:
        print(json.dumps({'ok': False, 'reason': 'this command needs --confirm'}))
        audit(args.command, getattr(args, 'name', getattr(args, 'pid', '?')), 'refused: no --confirm')
        return 2

    if args.command == 'stop-process':
        # Container membership exempts a process from the host's ownership
        # and infrastructure guards, so the identities are looked up here:
        # without them every process looks like a host process.
        outcome = stop_process(args.pid, args.start_time, force=args.force,
                               identities=container_identities())
        target = f'pid={args.pid}'
    else:
        action = 'stop' if args.command == 'stop-container' else 'restart'
        outcome = container_action(args.name, action)
        target = args.name

    audit(args.command, target, 'ok' if outcome.get('ok') else f'refused: {outcome.get("reason")}')
    print(json.dumps(outcome))
    return 0 if outcome.get('ok') else 1


if __name__ == '__main__':
    sys.exit(main())

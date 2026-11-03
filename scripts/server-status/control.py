#!/usr/bin/env python3
"""Identity-bound, root-only process/workload control; never reads argv or environments."""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

ALLOWED_OWNERS = ('root', 'jay')
PROTECTED_NAMES = {
    'systemd', 'init', 'kthreadd', 'ksoftirqd', 'kworker', 'migration', 'rcu_sched',
    'watchdog', 'kswapd0', 'kcompactd0', 'khugepaged', 'sshd', 'sshd-session',
    'tailscaled', 'dockerd', 'containerd', 'containerd-shim', 'cron', 'crond',
    'rsyslogd', 'dbus-daemon', 'dbus-broker', 'udevd', 'polkitd', 'fail2ban-server',
    'unattended-upgr', 'NetworkManager', 'systemd-journald', 'systemd-logind',
    'systemd-udevd', 'systemd-resolved', 'systemd-timesyncd', 'getty', 'agetty',
    'login', 'su', 'sudo', 'bash', 'sh', 'dash', 'ssh', 'scp', 'sftp', 'rsync',
    'datadog-agent', 'trace-agent', 'process-agent', 'system-probe', 'agent',
    'coolify', 'coolify-proxy', 'coolify-db', 'coolify-redis', 'coolify-sentinel',
    'traefik', 'postgres', 'postmaster', 'redis-server', 'qdrant', 'mysqld',
    'mariadbd', 'mongod', 'minio', 'sqlite3',
}
PROTECTED_UNITS = {'operator.service', 'fleet-recall.service', 'claude-remote-control.service',
                   'smbd.service', 'smb-tailnet-firewall.service', 'docker.service',
                   'containerd.service', 'tailscaled.service', 'ssh.service', 'sshd.service'}
PROTECTED_CONTAINERS = {'coolify', 'coolify-db', 'coolify-redis', 'coolify-proxy', 'coolify-sentinel',
                        'traefik', 'datadog-agent', 'operator-listener', 'fleet-recall', 'recall-api'}
DOCKER = ['/usr/bin/docker', '--host', 'unix:///var/run/docker.sock']
AUDIT_LOG = Path('/var/log/hoghunter-control.log')
LOCK_PATH = Path('/run/hoghunter-control.lock')
STATE_DIR = Path('/var/lib/hoghunter/control')

# The Docker template requests only allowlisted metadata.  A full inspect would
# read Config.Env and argv even if nobody printed the result.
DOCKER_FORMAT = '{"id":{{json .Id}},"container":{{json .Name}},"name":{{json (index .Config.Labels "coolify.name")}},"project":{{json (index .Config.Labels "coolify.projectName")}},"resource":{{json (index .Config.Labels "coolify.resourceName")}},"service":{{json (index .Config.Labels "coolify.serviceName")}},"type":{{json (index .Config.Labels "coolify.type")}},"status":{{json .State.Status}},"started_at":{{json .State.StartedAt}}}'


def read_text(path, limit=65536):
    with open(path, 'r', encoding='utf-8') as stream:
        text = stream.read(limit + 1)
    if len(text) > limit:
        raise ValueError('metadata limit exceeded')
    return text


def bounded_run(argv, timeout=20, max_output=1024 * 1024, **_kwargs):
    """Fixed argv, bounded time/output, owned children; no shell or stderr disclosure."""
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               start_new_session=True,
                               env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root', 'LC_ALL': 'C'})
    out = bytearray()
    deadline = time.monotonic() + min(20, max(0.01, float(timeout)))
    completed = False
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map() or process.poll() is None:
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(argv[0], 20)
                for key, _ in selector.select(0.1):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        out.extend(chunk)
                        if len(out) > max_output:
                            raise ValueError('command output limit exceeded')
        completed = True
        return subprocess.CompletedProcess(argv, process.returncode, out.decode('utf-8'), '')
    finally:
        if not completed or process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)
        process.stdout.close()


def process_stat_fields(pid, proc=Path('/proc')):
    try:
        raw = read_text(proc / str(pid) / 'stat')
        tail = raw[raw.rindex(')') + 2:].split()
        return {'comm': raw[raw.index('(') + 1:raw.rindex(')')], 'state': tail[0],
                'ppid': int(tail[1]), 'minor_faults': int(tail[7]), 'major_faults': int(tail[9]),
                'utime': int(tail[11]), 'stime': int(tail[12]), 'nice': int(tail[16]),
                'threads': int(tail[17]), 'start_time': int(tail[19])}
    except (OSError, ValueError, IndexError):
        return None


def boot_identity(proc=Path('/proc')):
    try:
        value = read_text(proc / 'sys/kernel/random/boot_id', 128).strip()
        return value if re.fullmatch(r'[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}', value) else None
    except (OSError, ValueError):
        return None


def owner_of(pid, proc=Path('/proc')):
    try:
        uid = (proc / str(pid)).stat().st_uid
        return pwd.getpwuid(uid).pw_name
    except (OSError, KeyError):
        return None


def ancestor_pids(proc=Path('/proc')):
    result, pid = {os.getpid()}, os.getppid()
    for _ in range(64):
        if not pid or pid in result:
            break
        result.add(pid)
        fields = process_stat_fields(pid, proc)
        if fields is None:
            break
        pid = fields['ppid']
    return result


def protected_container(row):
    names = [row.get(key) or '' for key in ('container', 'name', 'resource', 'service')]
    for name in names:
        lower = name.lstrip('/').casefold()
        if any(lower == p or lower.startswith(p + '-') for p in PROTECTED_CONTAINERS):
            return 'this workload keeps the host or fleet running'
        if re.search(r'(^|[-_/ .])(postgres|redis|qdrant|mysql|mariadb|mongodb|minio)([-_/ .]|$)', lower):
            return 'stateful infrastructure requires its own service runbook'
    return None


def coolify_containers(run=bounded_run):
    try:
        listing = run(DOCKER + ['ps', '--no-trunc', '--format', '{{.ID}}'], timeout=5, capture_output=True, text=True, check=False)
        if listing.returncode != 0 or len(listing.stdout) > 65536:
            return None
        ids = listing.stdout.split()
        if len(ids) > 256 or any(not re.fullmatch('[a-f0-9]{64}', value) for value in ids):
            return None
        if not ids:
            return []
        detail = run(DOCKER + ['inspect', '--format', DOCKER_FORMAT] + ids, timeout=15, capture_output=True, text=True, check=False)
        if detail.returncode != 0 or len(detail.stdout) > 1024 * 1024:
            return None
        rows, seen = [], set()
        for line in detail.stdout.splitlines():
            entry = json.loads(line)
            if not isinstance(entry, dict) or entry.get('id') not in ids or entry.get('id') in seen:
                return None
            seen.add(entry['id'])
            if any(entry.get(key) is not None and type(entry[key]) is not str for key in
                   ('container', 'name', 'project', 'resource', 'service', 'type', 'status', 'started_at')):
                return None
            if not entry.get('name'):
                continue
            if not isinstance(entry.get('container'), str) or not isinstance(entry.get('started_at'), str):
                return None
            entry['container'] = entry['container'].lstrip('/')
            entry['display_name'] = ' / '.join(p for p in (entry.get('project'), entry.get('resource') or entry.get('service')) if p) or entry['name']
            entry['protection_reason'] = protected_container(entry)
            entry['allowed_actions'] = [] if entry['protection_reason'] else ['stop', 'restart']
            rows.append(entry)
        return rows
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        return None


def container_identities(run=bounded_run):
    rows = coolify_containers(run)
    return None if rows is None else {row['id']: row['container'] for row in rows}


def inspect_process(pid, start_time, boot_id, proc=Path('/proc'), ancestors=None,
                    containers=None, owners=ALLOWED_OWNERS, sample=False):
    if type(pid) is not int or type(start_time) is not int or pid <= 1 or start_time <= 0:
        return None, 'a valid pid and start time are required; pid 1 is protected'
    if not boot_id or boot_identity(proc) != boot_id:
        return None, 'the server restarted or its boot identity is unavailable; refresh the snapshot'
    fields = process_stat_fields(pid, proc)
    if fields is None or fields['start_time'] != start_time:
        return None, 'that process changed since it was sampled'
    if pid in (ancestors if ancestors is not None else ancestor_pids(proc)):
        return None, 'refusing to act on this session'
    try:
        executable = Path(os.readlink(proc / str(pid) / 'exe')).name
        cgroup = read_text(proc / str(pid) / 'cgroup')
    except (OSError, ValueError):
        return None, 'executable or cgroup identity unavailable; kernel threads are protected'
    owner = owner_of(pid, proc)
    matched = None
    if 'docker' in cgroup:
        if containers is None:
            return None, 'container ownership is unavailable'
        matched = next((row for row in containers if row['id'] in cgroup), None)
        if matched is None:
            return None, 'this container is outside the Coolify workload allowlist'
    if owner not in owners and matched is None:
        return None, 'this process belongs to another account'
    if not sample:
        if executable in PROTECTED_NAMES or fields['comm'] in PROTECTED_NAMES or executable.startswith('systemd-'):
            return None, executable + ' keeps the host or its data running'
        segments = {part for line in cgroup.splitlines() for part in line.split(':', 2)[-1].split('/')}
        if any(unit in segments for unit in PROTECTED_UNITS):
            return None, 'this named service keeps the host or fleet running'
        if matched and matched.get('protection_reason'):
            return None, matched['protection_reason']
    return dict(pid=pid, start_time=start_time, boot_id=boot_id, name=executable,
                owner=owner, container=matched['container'] if matched else None,
                container_id=matched['id'] if matched else None, fields=fields), None


def same_identity(target, proc, ancestors, containers, owners, sample=False):
    current, reason = inspect_process(target['pid'], target['start_time'], target['boot_id'],
                                     proc, ancestors, containers, owners, sample)
    if reason or any(current[k] != target[k] for k in ('name', 'owner', 'container_id')):
        return False
    return True


def _signal_identity(target, sig, proc, validate, pidfd_open=None, send=None, close=os.close):
    # No numeric-pid signalling fallback: pidfd pins the signal's target.
    opener = pidfd_open or getattr(os, 'pidfd_open', None)
    sender = send or getattr(signal, 'pidfd_send_signal', None)
    if opener is None or sender is None:
        return {'ok': False, 'reason': 'this host lacks identity-bound pidfd signalling'}
    fd = opener(target['pid'], 0)
    try:
        if not validate():
            return {'ok': False, 'reason': 'process identity changed before signalling'}
        sender(fd, sig, None, 0)
    finally:
        close(fd)
    return {'ok': True, 'action': 'force-quit' if sig == signal.SIGKILL else 'quit', 'pid': target['pid'],
            'start_time': target['start_time'], 'boot_id': target['boot_id'], 'name': target['name']}


def state_file(state_dir):
    path = state_dir / 'priority.json'
    for parent in [state_dir, *state_dir.parents]:
        if parent.is_symlink():
            raise ValueError('priority state symlink refused')
    if not state_dir.exists():
        state_dir.mkdir(parents=True, mode=0o700)
    if state_dir.stat().st_uid != os.geteuid() or stat.S_IMODE(state_dir.stat().st_mode) & 0o077:
        raise ValueError('priority state ownership refused')
    if path.is_symlink():
        raise ValueError('priority state symlink refused')
    if path.exists():
        info = path.stat()
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            raise ValueError('priority state ownership refused')
    return path


def priority_action(target, action, validate, state_dir=STATE_DIR, getpriority=os.getpriority,
                    setpriority=os.setpriority):
    path = state_file(state_dir)
    records = json.loads(read_text(path, 65536)) if path.exists() else {}
    if not isinstance(records, dict) or len(records) > 256:
        return {'ok': False, 'reason': 'priority restore state is unavailable'}
    key = f'{target["boot_id"]}:{target["pid"]}:{target["start_time"]}'
    current = getpriority(os.PRIO_PROCESS, target['pid'])
    if not validate():
        return {'ok': False, 'reason': 'process identity changed before priority update'}
    if action == 'tame':
        original = records.get(key, current) if current == 19 else current
        if type(original) is not int or not -20 <= original <= 19:
            return {'ok': False, 'reason': 'invalid saved priority'}
        records[key] = original
        wanted = 19
    else:
        original = records.get(key)
        if type(original) is not int or not -20 <= original <= 19:
            return {'ok': False, 'reason': 'this tool has no matching priority to restore'}
        if current != 19:
            return {'ok': False, 'reason': 'priority changed outside Hog Hunter; preserving it'}
        wanted = original
    # Persist undo evidence before lowering priority; losing it must not cause a
    # blind reset to priority zero on a later request.
    fd, temporary = tempfile.mkstemp(prefix='.priority-', dir=state_dir)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(records, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    if not validate():
        return {'ok': False, 'reason': 'process identity changed before priority update'}
    setpriority(os.PRIO_PROCESS, target['pid'], wanted)
    if not validate() or getpriority(os.PRIO_PROCESS, target['pid']) != wanted:
        return {'ok': False, 'reason': 'priority update could not be verified'}
    return {'ok': True, 'action': action, 'pid': target['pid'], 'start_time': target['start_time'],
            'boot_id': target['boot_id'], 'nice': wanted, 'name': target['name']}


def process_memory(pid, proc):
    values = {}
    try:
        for line in read_text(proc / str(pid) / 'status').splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[0] in ('VmSwap:', 'VmRSS:') and parts[1].isdigit() and parts[2] == 'kB':
                values['swap_bytes' if parts[0] == 'VmSwap:' else 'resident_bytes'] = int(parts[1]) * 1024
    except (OSError, ValueError):
        pass
    return values


def sample_process(target, validate, proc=Path('/proc'), sleep=time.sleep, monotonic=time.monotonic):
    if not validate():
        return {'ok': False, 'reason': 'process changed before sampling'}
    first = process_stat_fields(target['pid'], proc)
    memory = process_memory(target['pid'], proc)
    start = monotonic()
    sleep(3)
    elapsed = monotonic() - start
    if not validate() or not 0.1 <= elapsed <= 10:
        return {'ok': False, 'reason': 'process changed or sample window unavailable'}
    last = process_stat_fields(target['pid'], proc)
    if first is None or last is None:
        return {'ok': False, 'reason': 'process exited during sample'}
    ticks = last['utime'] + last['stime'] - first['utime'] - first['stime']
    if ticks < 0:
        return {'ok': False, 'reason': 'process counters reset during sample'}
    report = {key: target[key] for key in ('pid', 'start_time', 'boot_id', 'name')}
    report.update(duration_seconds=round(elapsed, 3), cpu_percent=round(100 * ticks / os.sysconf('SC_CLK_TCK') / elapsed, 2),
                  minor_faults=max(0, last['minor_faults'] - first['minor_faults']),
                  major_faults=max(0, last['major_faults'] - first['major_faults']),
                  memory_before=memory, memory_after=process_memory(target['pid'], proc),
                  nice=last['nice'], threads=last['threads'], state=last['state'],
                  source='kernel counters; no stack attachment')
    return {'ok': True, 'action': 'sample', 'sample': report}


def process_action(action, pid, start_time, boot_id, proc=Path('/proc'), containers=None,
                   owners=ALLOWED_OWNERS, ancestors=None, allow_workload=False,
                   pidfd_open=None, send=None, close=os.close, state_dir=STATE_DIR,
                   getpriority=os.getpriority, setpriority=os.setpriority, sleep=time.sleep,
                   monotonic=time.monotonic):
    if action not in ('quit', 'force-quit', 'tame', 'untame', 'sample'):
        return {'ok': False, 'reason': 'unknown process action'}
    target, reason = inspect_process(pid, start_time, boot_id, proc, ancestors, containers, owners, action == 'sample')
    if reason:
        return {'ok': False, 'reason': reason}
    if target['container'] and action != 'sample' and not allow_workload:
        return {'ok': False, 'reason': 'container process control requires explicit workload interruption acknowledgement'}
    validate = lambda: same_identity(target, proc, ancestors, containers, owners, action == 'sample')
    try:
        if action in ('quit', 'force-quit'):
            return _signal_identity(target, signal.SIGKILL if action == 'force-quit' else signal.SIGTERM,
                                    proc, validate, pidfd_open, send, close)
        if action in ('tame', 'untame'):
            return priority_action(target, action, validate, state_dir, getpriority, setpriority)
        return sample_process(target, validate, proc, sleep, monotonic)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {'ok': False, 'reason': 'the guarded process action failed'}


def list_targets(proc=Path('/proc'), run=bounded_run, owners=ALLOWED_OWNERS):
    containers = coolify_containers(run)
    boot = boot_identity(proc)
    rows = []
    with os.scandir(proc) as entries:
        for i, entry in enumerate(entries):
            if i >= 10000:
                break
            if not entry.name.isdecimal():
                continue
            pid = int(entry.name)
            fields = process_stat_fields(pid, proc)
            if fields is None:
                continue
            target, reason = inspect_process(pid, fields['start_time'], boot, proc,
                                             containers=containers, owners=owners)
            rows.append({'pid': pid, 'start_time': fields['start_time'], 'boot_id': boot,
                         'name': target['name'] if target else fields['comm'],
                         'owner': owner_of(pid, proc), 'nice': fields['nice'],
                         'allowed_actions': [] if reason else ['quit', 'force-quit', 'tame', 'untame', 'sample'],
                         'protection_reason': reason})
    return {'processes': rows, 'containers': containers}


def container_action(name, action, container_id=None, started_at=None, run=bounded_run):
    if action not in ('stop', 'restart'):
        return {'ok': False, 'reason': 'unknown workload action'}
    if not isinstance(container_id, str) or not re.fullmatch('[a-f0-9]{64}', container_id) or not started_at:
        return {'ok': False, 'reason': 'refresh the snapshot for a full container identity and start time'}
    rows = coolify_containers(run)
    if rows is None:
        return {'ok': False, 'reason': 'workload inventory unavailable'}
    row = next((row for row in rows if row['id'] == container_id and row['container'] == name), None)
    if row is None or row['started_at'] != started_at:
        return {'ok': False, 'reason': 'that workload changed since it was sampled'}
    if row['protection_reason']:
        return {'ok': False, 'reason': row['protection_reason']}
    try:
        result = run(DOCKER + [action, '--time', '10', container_id], timeout=20, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            return {'ok': False, 'reason': 'Docker refused the workload action'}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {'ok': False, 'reason': 'workload action failed or timed out; refresh its status'}
    return {'ok': True, 'container_id': container_id, 'name': row['display_name'], 'action': action}


def audit(command, target, outcome, path=AUDIT_LOG):
    # Failure is fatal before actions; never swallow inability to audit.
    if path.is_symlink():
        raise OSError('audit symlink refused')
    fd = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise OSError('audit ownership refused')
        os.fchmod(fd, 0o600)
        record = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'command': command, 'target': target, 'outcome': outcome}
        os.write(fd, (json.dumps(record, separators=(',', ':')) + '\n').encode())
        os.fsync(fd)
    finally:
        os.close(fd)


@contextlib.contextmanager
def action_lock(path=LOCK_PATH):
    if path.is_symlink():
        raise OSError('action lock symlink refused')
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise OSError('action lock ownership refused')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def main(argv=None, proc=Path('/proc'), run=bounded_run, audit_fn=audit, lock_path=LOCK_PATH,
         require_root=lambda: os.geteuid() == 0, process_fn=process_action):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('list')
    for verb in ('stop-process', 'tame-process', 'untame-process', 'sample-process'):
        command = sub.add_parser(verb)
        command.add_argument('--pid', type=int, required=True)
        command.add_argument('--start-time', type=int, required=True)
        command.add_argument('--boot-id', required=True)
        command.add_argument('--confirm', action='store_true')
        command.add_argument('--allow-workload-interruption', action='store_true')
        if verb == 'stop-process':
            command.add_argument('--force', action='store_true')
    for verb in ('stop-container', 'restart-container'):
        command = sub.add_parser(verb)
        command.add_argument('--name', required=True)
        command.add_argument('--container-id', required=True)
        command.add_argument('--started-at', required=True)
        command.add_argument('--confirm', action='store_true')
        command.add_argument('--allow-workload-interruption', action='store_true')
    args = parser.parse_args(argv)
    deadline = time.monotonic() + 25
    def request_run(arguments, **kwargs):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(arguments[0], 25)
        kwargs['timeout'] = min(remaining, kwargs.get('timeout', 20))
        return run(arguments, **kwargs)
    if args.command == 'list':
        if not require_root():
            print(json.dumps({'ok': False, 'reason': 'root is required'}))
            return 1
        print(json.dumps(list_targets(proc=proc, run=request_run)))
        return 0
    if not require_root() or not args.confirm:
        outcome = {'ok': False, 'reason': 'root and explicit --confirm are required'}
    else:
        target = str(getattr(args, 'pid', getattr(args, 'name', '?')))
        try:
            with action_lock(lock_path):
                audit_fn(args.command, target, 'started')
                if args.command.endswith('-process'):
                    action = {'stop-process': 'force-quit' if getattr(args, 'force', False) else 'quit',
                              'tame-process': 'tame', 'untame-process': 'untame', 'sample-process': 'sample'}[args.command]
                    outcome = process_fn(action, args.pid, args.start_time, args.boot_id, proc=proc,
                                         containers=coolify_containers(request_run), allow_workload=args.allow_workload_interruption)
                elif not args.allow_workload_interruption:
                    outcome = {'ok': False, 'reason': 'workload interruption acknowledgement is required'}
                else:
                    outcome = container_action(args.name, 'stop' if args.command == 'stop-container' else 'restart',
                                               args.container_id, args.started_at, request_run)
                audit_fn(args.command, target, outcome)
        except BlockingIOError:
            outcome = {'ok': False, 'reason': 'another server control action is running'}
        except (OSError, ValueError, subprocess.TimeoutExpired):
            outcome = {'ok': False, 'reason': 'control lock, audit or action completion unavailable; refresh server status'}
    print(json.dumps(outcome, separators=(',', ':')))
    return 0 if outcome.get('ok') is True else 1


if __name__ == '__main__':
    raise SystemExit(main())

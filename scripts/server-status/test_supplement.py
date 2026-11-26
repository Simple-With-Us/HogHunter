import importlib.util
import datetime
import pwd
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('supplement', Path(__file__).with_name('supplement.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SupplementTests(unittest.TestCase):
    def test_collector_and_launcher_do_not_make_tools_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            for pid in (os.getpid(), os.getppid()):
                path = proc / str(pid)
                path.mkdir(exist_ok=True)
                (path / 'comm').write_text('python3')
            names, complete = module.process_inventory(proc)
            self.assertEqual(names, [])
            self.assertTrue(complete)

    def test_shellular_helper_failure_preserves_verified_service_state(self):
        output = module.supplement({}, Path('/fixture'), lambda _: None, ([], True),
                                   lambda _: 'running', lambda _: 'unknown')
        row = next(row for row in output['tool_statuses'] if row['id'] == 'shellular')
        self.assertEqual(row['state'], 'running')
        self.assertEqual(row['count'], 1)

    def test_preserves_existing_database_device_and_source_timestamp(self):
        source = dict(generated_at='2026-01-01T00:00:00Z', host='fixture',
                      devices={'root': {'free_bytes': 123}}, app_dbs={'app': 456})
        output = module.supplement(source, Path('/fixture'), lambda _: 100, ([], True), lambda _: None, lambda _: 'unknown',
                                   ismount_func=lambda _: False)
        for key in source:
            self.assertEqual(output[key], source[key])
        self.assertIn('/fixture/Code', [row['path'] for row in output['largest_dirs']])
        self.assertIn('/fixture/apps/lanes', [row['path'] for row in output['largest_dirs']])

    def test_a_tool_that_is_not_installed_reads_as_absent_even_with_interpreters(self):
        """Nothing on this host can be running a tool the host does not have."""
        rows = module.tool_statuses([{'python3'}], True, lambda _: None, installed=lambda _: False)
        states = {row['id']: row for row in rows}
        self.assertEqual(states['muse']['state'], 'absent')
        self.assertIn('not installed', states['muse']['reason'])

    def test_a_container_is_the_honest_identity_for_a_tool_the_process_list_cannot_prove(self):
        """The recall service runs inside a container, where the process is python."""
        rows = module.tool_statuses([{'python3'}], True, lambda _: '/fixture/bin', installed=lambda _: True,
                                    containers={'recall-api-9kqckay6g0cgb4exwls20sry'})
        states = {row['id']: row for row in rows}
        self.assertEqual(states['recall']['state'], 'running')
        self.assertEqual(states['recall']['count'], 1)
        self.assertIn('container', states['recall']['reason'])

    def test_a_container_is_the_honest_identity_for_the_listener(self):
        """The listener is the Operator now: it runs as a Coolify workload, so
        the workload name is the only identity that can answer for it."""
        rows = module.tool_statuses([{'python3'}], True, lambda _: '/fixture/bin', installed=lambda _: True,
                                    containers={'operator-listener-server'})
        states = {row['id']: row for row in rows}
        self.assertEqual(states['fleet-listener']['state'], 'running')
        self.assertEqual(states['fleet-listener']['count'], 1)
        self.assertIn('container', states['fleet-listener']['reason'])

    def test_an_unrelated_operator_container_does_not_answer_for_the_listener(self):
        """A container that merely starts with the word operator is not the
        listener: the match is on the workload name operator-listener, so an
        unrelated operator-* workload cannot mask a real outage."""
        rows = module.tool_statuses([{'python3'}], True, lambda _: '/fixture/bin', installed=lambda _: True,
                                    containers={'operator-backup'})
        states = {row['id']: row for row in rows}
        self.assertEqual(states['fleet-listener']['state'], 'unknown')
        self.assertEqual(states['fleet-listener']['count'], 0)

    def test_every_tool_row_carries_a_reason(self):
        """A dot with no explanation is a dot the owner cannot act on."""
        rows = module.tool_statuses([{'codex'}], True, lambda _: '/fixture/bin', installed=lambda _: True)
        for row in rows:
            self.assertTrue(row['reason'], row['id'])

    def test_the_minimax_seat_is_named_after_its_launcher(self):
        rows = module.tool_statuses([{'minimax-code'}], True, lambda _: '/fixture/bin', installed=lambda _: True)
        states = {row['id']: row for row in rows}
        self.assertEqual(states['minimax']['state'], 'running')
        self.assertEqual(states['minimax']['count'], 1)

    def test_a_named_service_answers_for_an_interpreted_tool(self):
        source = dict(generated_at='2026-01-01T00:00:00Z', host='fixture', devices={})
        output = module.supplement(source, Path('/fixture'), lambda _: None, ([{'python3'}], True),
                                   lambda unit: 'stopped' if unit.endswith('claude-remote-control.service') else None,
                                   lambda _: 'unknown')
        states = {row['id']: row for row in output['tool_statuses']}
        self.assertEqual(states['claude']['state'], 'stopped')
        self.assertIn('claude-remote-control.service', states['claude']['reason'])

    def test_top_processes_reports_a_cpu_share_without_reading_arguments(self):
        """The reading comes from tick counters and executable identity only."""
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            for pid, comm, ticks in ((11, 'next-server', 100), (12, 'python3', 50)):
                path = proc / str(pid)
                path.mkdir()
                (path / 'comm').write_text(comm)
                (path / 'stat').write_text(f'{pid} ({comm}) S 1 1 0 0 0 0 0 0 0 0 0 {ticks} 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0')
            rows = module.top_processes(proc=proc, limit=5, sleep=lambda _: None, elapsed=1.0,
                                        run=lambda *a, **k: subprocess.CompletedProcess(a, 1, '', ''))
            self.assertEqual([row['pid'] for row in rows], [11, 12])
            self.assertTrue(all(row['name'] for row in rows))
            self.assertNotIn('args', rows[0])
            self.assertNotIn('command', rows[0])

    def test_paging_uses_actual_window_and_pressure_has_own_timestamp(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / 'pressure').mkdir()
            (proc / 'pressure/memory').write_text('some avg10=12.50 avg60=1 avg300=1 total=10\nfull avg10=3.25 avg60=1 avg300=1 total=5\n')
            (proc / 'vmstat').write_text('pswpin 100\npswpout 200\n')
            times = iter([10, 12])
            def sample(_):
                (proc / 'vmstat').write_text('pswpin 110\npswpout 220\n')
            stamp = datetime.datetime(2026, 11, 3, 15, tzinfo=datetime.timezone.utc)
            result = module.memory_pressure(proc, sleep=sample, monotonic=lambda: next(times), now=lambda: stamp)
            page = os.sysconf('SC_PAGE_SIZE')
            self.assertEqual(result['swap_in_bytes_per_second'], 10 * page / 2)
            self.assertEqual(result['swap_out_bytes_per_second'], 20 * page / 2)
            self.assertEqual(result['duration_seconds'], 2)
            self.assertEqual(result['sampled_at'], stamp.isoformat())
            self.assertEqual(result['memory_some_avg10'], 12.5)
            self.assertEqual(result['memory_full_avg10'], 3.25)

    def test_missing_or_reset_paging_is_unknown_and_invalid_psi_never_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            times = iter([0, 1])
            self.assertIsNone(module.memory_pressure(proc, sleep=lambda _: None, monotonic=lambda: next(times)))
            (proc / 'pressure').mkdir()
            (proc / 'pressure/memory').write_text('some avg10=nan avg60=0\nfull avg10=101 avg60=0\n')
            (proc / 'vmstat').write_text('pswpin 100\npswpout 100\n')
            def reset(_):
                (proc / 'vmstat').write_text('pswpin 10\npswpout 10\n')
            times = iter([0, 1])
            self.assertIsNone(module.memory_pressure(proc, sleep=reset, monotonic=lambda: next(times)))

    def test_process_window_rejects_pid_reuse_and_keeps_memory_swap_leaders(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / 'sys/kernel/random').mkdir(parents=True)
            boot = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            (proc / 'sys/kernel/random/boot_id').write_text(boot)
            def write(pid, ticks=0, start=999, rss=1, swap=1):
                path = proc / str(pid)
                path.mkdir(exist_ok=True)
                tail = ['S', '1'] + ['0'] * 9 + [str(ticks), '0'] + ['0'] * 3 + ['0', '1', '0', str(start)] + ['0'] * 20
                (path / 'stat').write_text(str(pid) + ' (worker) ' + ' '.join(tail))
                (path / 'comm').write_text('worker')
                (path / 'cgroup').write_text('0::/user.slice/session.scope')
                (path / 'status').write_text(f'VmRSS: {rss} kB\nVmSwap: {swap} kB\n')
                if not (path / 'exe').is_symlink():
                    (path / 'exe').symlink_to('/usr/bin/worker')
            for pid in (21, 22, 23, 24):
                write(pid)
            def advance(_):
                write(21, ticks=100, rss=10, swap=10)
                write(22, ticks=1, rss=1000, swap=10)
                write(23, ticks=1, rss=10, swap=1000)
                write(24, ticks=10000, start=1001, rss=10000, swap=10000)
            times = iter([0, 1])
            rows = module.top_processes(proc, limit=3, sleep=advance, monotonic=lambda: next(times),
                                        owners=(pwd.getpwuid(os.getuid()).pw_name,),
                                        run=lambda a, **_: subprocess.CompletedProcess(a, 0, '', ''))
            self.assertEqual({r['pid'] for r in rows}, {21, 22, 23})
            self.assertTrue(all(r['boot_id'] == boot and 'quit' in r['allowed_actions'] for r in rows))
            self.assertEqual(next(r for r in rows if r['pid'] == 23)['swap_bytes'], 1000 * 1024)

    def test_coolify_resources_reads_only_allowlisted_metadata_and_numeric_stats(self):
        identity = 'a' * 64
        metadata = dict(id=identity, container='/worker-box', name='worker-box', project='example',
                        resource='worker', service=None, type='application', status='running',
                        started_at='2026-11-03T00:00:00Z')
        def run(args, **kwargs):
            if 'ps' in args:
                return subprocess.CompletedProcess(args, 0, identity + '\n', '')
            if 'inspect' in args:
                self.assertIn('--format', args)
                self.assertNotIn('Config.Env', args[args.index('--format') + 1])
                return subprocess.CompletedProcess(args, 0, json.dumps(metadata), '')
            if 'stats' in args:
                return subprocess.CompletedProcess(args, 0, 'worker-box\t12.50%\t535.1MiB / 5GiB\n', '')
            return subprocess.CompletedProcess(args, 1, '', '')
        rows = module.coolify_resources(run=run)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['name'], 'example / worker')
        self.assertEqual(rows[0]['cpu_percent'], 12.5)
        self.assertEqual(rows[0]['memory_bytes'], int(535.1 * 1024 ** 2))
        self.assertEqual(rows[0]['container_id'], identity)
        self.assertEqual(rows[0]['allowed_actions'], ['stop', 'restart'])
        self.assertNotIn('image', rows[0])

    def test_coolify_resources_omit_what_they_cannot_measure(self):
        identity = 'b' * 64
        def run(args, **kwargs):
            if 'ps' in args:
                return subprocess.CompletedProcess(args, 0, identity, '')
            if 'inspect' in args:
                return subprocess.CompletedProcess(args, 0, json.dumps(dict(id=identity, container='/worker', name='worker',
                    project=None, resource=None, service=None, type='application', status='exited', started_at='2026-11-03T00:00:00Z')), '')
            return subprocess.CompletedProcess(args, 1, '', '')
        rows = module.coolify_resources(run=run)
        self.assertEqual(rows[0]['status'], 'exited')
        self.assertIsNone(rows[0]['cpu_percent'])
        self.assertIsNone(rows[0]['memory_bytes'])

    def test_collector_exposes_database_service_and_unknown_classification_refusals(self):
        identity = 'a' * 64
        for kind in ('database', 'standalone-postgresql', 'service', None, ''):
            with self.subTest(kind=kind):
                metadata = dict(id=identity, container='/production-data', name='production-data',
                                resource='primary', service=None, project='example', type=kind,
                                status='running', started_at='2026-11-03T00:00:00Z')
                def run(args, **_):
                    return subprocess.CompletedProcess(args, 0,
                        identity if 'ps' in args else json.dumps(metadata) if 'inspect' in args else '', '')
                row = module.coolify_resources(run)[0]
                self.assertEqual(row['allowed_actions'], [])
                self.assertTrue(row['protection_reason'])

    def test_fleet_extra_volume_monitored_when_mounted(self):
        with tempfile.TemporaryDirectory() as directory:
            extra_path = Path(directory) / 'mnt' / 'fleet-extra'
            extra_path.mkdir(parents=True)
            class MockStatVFS:
                f_bavail = 100_000_000
                f_blocks = 200_000_000
                f_frsize = 4096
            source = dict(generated_at='2026-01-01T00:00:00Z', host='fixture',
                          devices={'root': {'mount': '/', 'free_bytes': 123}})
            output = module.supplement(source, Path('/fixture'), lambda _: None, ([], True),
                                       lambda _: None, lambda _: 'unknown',
                                       extra_volume=extra_path, statvfs_func=lambda _: MockStatVFS(),
                                       ismount_func=lambda _: True)
            self.assertIn('fleet_extra', output['devices'])
            dev = output['devices']['fleet_extra']
            self.assertEqual(dev['mount'], str(extra_path))
            self.assertEqual(dev['free_bytes'], 100_000_000 * 4096)
            self.assertIn('GB disk: extra volume', dev['note'])

    def test_fleet_extra_volume_ignored_when_unmounted(self):
        with tempfile.TemporaryDirectory() as directory:
            extra_path = Path(directory) / 'mnt' / 'fleet-extra'
            extra_path.mkdir(parents=True)
            source = dict(generated_at='2026-01-01T00:00:00Z', host='fixture',
                          devices={'root': {'mount': '/', 'free_bytes': 123}})
            output = module.supplement(source, Path('/fixture'), lambda _: None, ([], True),
                                       lambda _: None, lambda _: 'unknown',
                                       extra_volume=extra_path, ismount_func=lambda _: False)
            self.assertNotIn('fleet_extra', output['devices'])

    def test_failed_measurement_does_not_retimestamp_old_size(self):
        source = {'largest_dirs': [{'path': '/fixture/Code', 'bytes': 999}]}
        output = module.supplement(source, Path('/fixture'), lambda _: None, ([], True), lambda _: None, lambda _: 'unknown')
        self.assertEqual(output['largest_dirs'], [])

    def test_native_running_and_safe_negative_states(self):
        rows = module.tool_statuses([{'codex'}], True, lambda cmd: '/bin/postgres' if cmd == 'postgres' else None, installed=lambda _: False)
        states = {row['id']: row for row in rows}
        self.assertEqual(states['codex']['state'], 'running')
        self.assertEqual(states['codex']['count'], 1)
        self.assertEqual(states['postgres']['state'], 'stopped')
        self.assertEqual(states['muse']['state'], 'absent')

    def test_caddy_is_not_a_reported_tool(self):
        """Caddy no longer runs on the server, so it is no longer in the tool list."""
        rows = module.tool_statuses([{'codex'}], True,
                                    lambda cmd: '/bin/caddy' if cmd == 'caddy' else None,
                                    installed=lambda _: False)
        self.assertNotIn('caddy', [row['id'] for row in rows])
        self.assertNotIn('Caddy', [row['name'] for row in rows])

    def test_incomplete_inventory_and_interpreters_are_not_stopped(self):
        for inventory, complete in [([], False), ([{'python3'}], True)]:
            rows = module.tool_statuses(inventory, complete, lambda _: '/fixture/bin')
            self.assertEqual(next(row for row in rows if row['id'] == 'fleet-listener')['state'], 'unknown')

    def test_timeout_does_not_return_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            def timeout(*args, **kwargs):
                raise subprocess.TimeoutExpired('du', 8)
            self.assertIsNone(module.directory_bytes(Path(directory), timeout))

    def test_manager_state_uses_only_named_metadata(self):
        def run(args, **kwargs):
            self.assertEqual(args[1:3], ['show', 'fixture.service'])
            return subprocess.CompletedProcess(args, 0, 'LoadState=loaded\nActiveState=active\n', '')
        self.assertEqual(module.service_state('fixture.service', run), 'running')

    def test_legacy_database_history_filters_bad_future_and_old_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'st_app_db.samples').write_text('1767225600 100\n1767312000 150\nbad\n1767312001 999\n')
            snapshot = {'generated_at': '2026-01-02T00:00:00Z', 'app_dbs': {'st_app_db': 150}}
            rows = module.database_samples(snapshot, root)
            self.assertEqual([row['bytes'] for row in rows], [100, 150])
            self.assertEqual(rows[0]['sampled_at'], 1767225600)

    def test_directory_history_retains_baseline_and_is_host_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = dict(host='fixture', generated_at='2026-01-01T00:00:00Z',
                            largest_dirs=[dict(path='/fixture/Code', bytes=100)])
            module.directory_samples(snapshot, root)
            snapshot.update(generated_at='2026-01-02T00:00:00Z', largest_dirs=[dict(path='/fixture/Code', bytes=150)])
            self.assertEqual(len(module.directory_samples(snapshot, root)), 2)
            snapshot['host'] = 'different'
            self.assertEqual(len(module.directory_samples(snapshot, root)), 1)

    def test_known_local_install_is_detected_without_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / '.minimax-code/bin/mcode'
            binary.parent.mkdir(parents=True)
            binary.write_text('fixture')
            binary.chmod(0o700)
            self.assertTrue(module.installed_command('mcode', root))

    def test_shellular_filtered_identity(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / '42/exe'
            executable.parent.mkdir()
            executable.write_text('fixture')
            identity = dict(name='shellular', status='online', pid=42,
                            execpath='/fixture/apps/shellular-runtime/lib/node_modules/shellular/dist/main.js')
            def run(args, **kwargs):
                self.assertEqual(kwargs['timeout'], 3)
                return subprocess.CompletedProcess(args, 0, json.dumps(identity), '')
            self.assertEqual(module.shellular_state(Path('/fixture'), run, root), 'running')
            identity['execpath'] = '/wrong/path'
            self.assertEqual(module.shellular_state(Path('/fixture'), run, root), 'unknown')
            identity['execpath'] = '/fixture/apps/shellular-runtime/lib/node_modules/shellular/dist/main.js'
            identity['status'] = 'offline'
            self.assertEqual(module.shellular_state(Path('/fixture'), run, root), 'stopped')

    def test_shellular_invalid_output_and_timeout_are_unknown(self):
        def invalid(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, '{invalid', '')
        def timeout(args, **kwargs):
            raise subprocess.TimeoutExpired('filtered-helper', 3)
        for runner in (invalid, timeout):
            self.assertEqual(module.shellular_state(Path('/fixture'), runner), 'unknown')

    def test_live_collection_overlaps_the_tick_window_with_the_docker_reads(self):
        import threading
        barrier = threading.Barrier(2, timeout=5)

        def processes():
            barrier.wait()
            return [{'name': 'fixture'}]

        def coolify():
            barrier.wait()
            return {'state': 'fixture'}

        output = module.supplement({}, Path('/fixture'), lambda _: None, ([], True),
                                   lambda _: None, lambda _: 'unknown', containers=[],
                                   processes=processes, coolify=coolify, collect_live=True, pressure=lambda: None, storage=lambda: {})
        # A sequential collector would time the barrier out; both results arrive.
        self.assertEqual(output['processes'], [{'name': 'fixture'}])
        self.assertEqual(output['coolify'], {'state': 'fixture'})

    def test_live_collection_omits_only_the_failed_section(self):
        """One broken collector must not abort the whole enriched write:  the
        old unguarded .result() calls let a single failure skip the publish,
        leaving readers with the base watch's vitals and no processes."""
        def broken():
            raise RuntimeError('fixture failure')

        output = module.supplement({}, Path('/fixture'), lambda _: None, ([], True),
                                   lambda _: None, lambda _: 'unknown', containers=[],
                                   processes=lambda: [{'name': 'fixture'}], coolify=broken,
                                   collect_live=True, pressure=lambda: None, storage=lambda: {})
        self.assertNotIn('coolify', output)
        self.assertEqual(output['processes'], [{'name': 'fixture'}])
        self.assertIn('storage_diagnostics', output)
        self.assertIn('memory_pressure', output)

    def test_live_collection_failure_drops_a_stale_section_value(self):
        """A section that fails must not republish the value it carried in:
        an old reading presented as fresh is worse than an honest gap."""
        def broken():
            raise RuntimeError('fixture failure')

        output = module.supplement({'coolify': {'stale': True}}, Path('/fixture'), lambda _: None, ([], True),
                                   lambda _: None, lambda _: 'unknown', containers=[],
                                   processes=lambda: [], coolify=broken, collect_live=True,
                                   pressure=lambda: None, storage=lambda: {})
        self.assertNotIn('coolify', output)

    def test_wrapper_stages_the_base_watch_and_publishes_only_via_supplement(self):
        wrapper = Path(__file__).with_name('run-watch.sh').read_text()
        self.assertIn('VPS_STORAGE_SNAPSHOT="$state/base.json"', wrapper)
        self.assertIn('--base "$state/base.json"', wrapper)
        self.assertIn('--snapshot /root/vps-storage-status.json', wrapper)

    def test_main_publishes_only_the_enriched_snapshot_to_the_canonical_path(self):
        """Single publisher:  the base watch's staging file is the supplement's
        input, and the canonical path only ever receives the enriched write —
        a base-only file (vitals, no processes) can never land there."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / 'base.json'
            canonical = root / 'vps-storage-status.json'
            base.write_text(json.dumps({'generated_at': '2026-01-01T00:00:00Z', 'host': 'fixture'}))
            enriched = {'generated_at': '2026-01-01T00:00:00Z', 'host': 'fixture',
                        'processes': [{'name': 'fixture'}]}
            argv = ['supplement', '--snapshot', str(canonical), '--base', str(base),
                    '--home', str(root), '--history', str(root)]
            with mock.patch.object(module, 'supplement', return_value=dict(enriched)) as supplement_stub, \
                    mock.patch.object(module, 'database_samples', return_value=[]), \
                    mock.patch.object(module, 'directory_samples', return_value=[]), \
                    mock.patch.object(sys, 'argv', argv):
                module.main()
            self.assertEqual(supplement_stub.call_args[0][0]['host'], 'fixture')
            published = json.loads(canonical.read_text())
            self.assertEqual(published['processes'], [{'name': 'fixture'}])
            # The staging file is left exactly as the base watch wrote it.
            self.assertNotIn('processes', json.loads(base.read_text()))

    def test_main_failure_leaves_the_canonical_snapshot_untouched(self):
        """A wholesale supplement failure exits without touching the canonical
        file:  fully stale beats vitals-only with an empty process list."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / 'base.json'
            canonical = root / 'vps-storage-status.json'
            base.write_text(json.dumps({'generated_at': '2026-01-01T00:00:00Z', 'host': 'fixture'}))
            canonical.write_text('{"previous": true}\n')

            def broken(*args, **kwargs):
                raise RuntimeError('fixture failure')

            argv = ['supplement', '--snapshot', str(canonical), '--base', str(base),
                    '--home', str(root), '--history', str(root)]
            with mock.patch.object(module, 'supplement', broken), \
                    mock.patch.object(sys, 'argv', argv):
                with self.assertRaises(RuntimeError):
                    module.main()
            self.assertEqual(canonical.read_text(), '{"previous": true}\n')

    def test_maintenance_history_reads_finished_records_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'audit.jsonl'
            records = [
                {'event': 'started', 'mode': 'run', 'strategies': ['package-cache']},
                {'event': 'finished', 'mode': 'run', 'status': 'ran',
                 'finished_at': '2026-11-25T10:00:00+00:00',
                 'observed_free_delta_bytes': 123456,
                 'thresholds': {'used_percent_at_or_above': 80, 'free_bytes_at_or_below': 25 * 1024**3},
                 'strategies': [
                     {'id': 'package-cache', 'candidate_count': 3, 'removed_count': 3},
                     {'id': 'rotated-logs', 'candidate_count': 1, 'removed_count': 0},
                 ]},
                {'event': 'finished', 'mode': 'scheduled', 'status': 'skipped',
                 'observed_free_delta_bytes': 0,
                 'strategies': []},
                'not json at all',
                {'event': 'finished', 'mode': 'bogus', 'status': 'wrong-mode',
                 'observed_free_delta_bytes': -5,
                 'strategies': [{'id': 'package-cache', 'candidate_count': 'many',
                                 'removed_count': True}]},
            ]
            path.write_text('\n'.join(json.dumps(r) if isinstance(r, dict) else r for r in records) + '\n')
            value = module.maintenance_history(path)
        self.assertEqual(value['thresholds'],
                         {'used_percent_at_or_above': 80.0, 'free_bytes_at_or_below': 25 * 1024**3})
        history = value['history']
        self.assertEqual([row['mode'] for row in history], [None, 'scheduled', 'run'])
        newest = history[-1]
        self.assertEqual(newest['status'], 'ran')
        self.assertEqual(newest['observed_free_delta_bytes'], 123456)
        self.assertEqual(newest['removed_count'], 3)
        self.assertEqual(newest['candidate_count'], 4)
        self.assertEqual(newest['strategy_count'], 2)
        self.assertEqual(history[0]['observed_free_delta_bytes'], -5, "signed, never dropped")
        self.assertEqual(history[0]['removed_count'], 0)

    def test_maintenance_history_limits_and_reports_unreadable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'audit.jsonl'
            path.write_text(''.join(json.dumps({'event': 'finished', 'mode': 'run', 'status': 'ran',
                                                'observed_free_delta_bytes': i, 'strategies': []}) + '\n'
                                    for i in range(30)))
            value = module.maintenance_history(path, limit=5)
            self.assertEqual(len(value['history']), 5)
            self.assertEqual(value['history'][0]['observed_free_delta_bytes'], 29)
            self.assertIsNone(module.maintenance_history(Path(directory) / 'missing.jsonl'))

    def test_maintenance_history_reads_only_the_log_tail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'audit.jsonl'
            rows = []
            for i in range(4000):
                rows.append(json.dumps({'event': 'finished', 'mode': 'run', 'status': 'ran',
                                        'observed_free_delta_bytes': i, 'strategies': []}))
            path.write_text('\n'.join(rows) + '\n')
            self.assertGreater(path.stat().st_size, 262144)
            value = module.maintenance_history(path)
        self.assertEqual(len(value['history']), 10)
        self.assertIsNotNone(value['history'][0])
        newest = value['history'][0]['observed_free_delta_bytes']
        self.assertGreater(newest, value['history'][-1]['observed_free_delta_bytes'])

    def test_atomic_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'snapshot.json'
            module.atomic_write(path, {'safe': 1})
            self.assertEqual(path.read_text(), '{"safe":1}\n')
            self.assertEqual(len(list(Path(directory).iterdir())), 1)


if __name__ == '__main__':
    unittest.main()

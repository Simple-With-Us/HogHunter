import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

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

    def test_coolify_resources_reads_labels_and_state(self):
        inspected = [{
            'Name': '/yagelvqux9e8l1kztif7bf2o',
            'Config': {'Labels': {'coolify.name': 'yagelvqux9e8l1kztif7bf2o',
                                  'coolify.type': 'application',
                                  'coolify.projectName': 'fleet-infra',
                                  'coolify.resourceName': 'um-appworker',
                                  'coolify.applicationUuid': 'yagelvqux9e8l1kztif7bf2o'},
                       'Image': 'yagelvqux9e8l1kztif7bf2o:5cbd'},
            'State': {'Status': 'running', 'Health': {'Status': 'healthy'}, 'StartedAt': '2026-10-26T06:11:38Z'},
        }]
        def run(args, **kwargs):
            if args[1] == 'ps':
                return subprocess.CompletedProcess(args, 0, 'abc123\n', '')
            if args[1] == 'inspect':
                return subprocess.CompletedProcess(args, 0, json.dumps(inspected), '')
            if args[1] == 'stats':
                return subprocess.CompletedProcess(args, 0, 'yagelvqux9e8l1kztif7bf2o\t12.50%\t535.1MiB / 5GiB\n', '')
            return subprocess.CompletedProcess(args, 1, '', '')
        rows = module.coolify_resources(run=run)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['name'], 'fleet-infra / um-appworker')
        self.assertEqual(rows[0]['type'], 'application')
        self.assertEqual(rows[0]['status'], 'running')
        self.assertEqual(rows[0]['cpu_percent'], 12.5)
        self.assertEqual(rows[0]['memory_bytes'], int(535.1 * 1024 ** 2))
        self.assertEqual(rows[0]['uuid'], 'yagelvqux9e8l1kztif7bf2o')

    def test_coolify_resources_omit_what_they_cannot_measure(self):
        def run(args, **kwargs):
            if args[1] == 'ps':
                return subprocess.CompletedProcess(args, 0, 'abc123\n', '')
            if args[1] == 'inspect':
                return subprocess.CompletedProcess(args, 0, json.dumps([{
                    'Name': '/x', 'Config': {'Labels': {'coolify.name': 'x'}, 'Image': 'i'},
                    'State': {'Status': 'exited'}}]), '')
            return subprocess.CompletedProcess(args, 1, '', '')
        rows = module.coolify_resources(run=run)
        self.assertEqual(rows[0]['status'], 'exited')
        self.assertIsNone(rows[0]['cpu_percent'])
        self.assertIsNone(rows[0]['memory_bytes'])

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

    def test_atomic_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'snapshot.json'
            module.atomic_write(path, {'safe': 1})
            self.assertEqual(path.read_text(), '{"safe":1}\n')
            self.assertEqual(len(list(Path(directory).iterdir())), 1)


if __name__ == '__main__':
    unittest.main()

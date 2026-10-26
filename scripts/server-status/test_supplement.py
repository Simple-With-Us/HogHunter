import importlib.util
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
        output = module.supplement(source, Path('/fixture'), lambda _: 100, ([], True), lambda _: None, lambda _: 'unknown')
        for key in source:
            self.assertEqual(output[key], source[key])
        self.assertIn('/fixture/Code', [row['path'] for row in output['largest_dirs']])
        self.assertIn('/fixture/apps/lanes', [row['path'] for row in output['largest_dirs']])

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
                                       extra_volume=extra_path, statvfs_func=lambda _: MockStatVFS())
            self.assertIn('fleet_extra', output['devices'])
            dev = output['devices']['fleet_extra']
            self.assertEqual(dev['mount'], str(extra_path))
            self.assertEqual(dev['free_bytes'], 100_000_000 * 4096)
            self.assertIn('GB disk: extra volume', dev['note'])

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

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('storage_supplement', Path(__file__).with_name('supplement.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class StorageDiagnosticsTests(unittest.TestCase):
    def fixture(self, blobs=None):
        if blobs is None:
            blobs = dict(status='complete', count=2, allocated_bytes=8192, apparent_bytes=5000,
                         modified_hour_bytes=4096, modified_day_bytes=8192, device=1, inode=2)
        rows = [dict(type=name, total='3', active='2', size='1.25GB', reclaimable='250MB (20%)')
                for name in ('Images', 'Build Cache', 'Local Volumes', 'Containers')]
        def run(argv, **kwargs):
            self.assertLessEqual(kwargs['timeout'], m.STORAGE_BUDGET)
            self.assertEqual(kwargs['max_output'], 65536)
            if '--storage-blobs' in argv:
                self.assertEqual(argv[:6], ['/usr/bin/ionice', '-c', '3', '/usr/bin/nice', '-n', '19'])
                value = json.dumps(blobs)
            elif 'info' in argv:
                self.assertNotIn('Config', argv[-1])
                value = json.dumps(dict(root='/var/lib/docker', driver='overlayfs',
                                       driver_status=[['driver-type', 'io.containerd.snapshotter.v1']]))
            else:
                self.assertIn('df', argv)
                value = '\n'.join(map(json.dumps, rows))
            return subprocess.CompletedProcess(argv, 0, value, '')
        return run, rows

    def test_selected_aggregates_use_decimal_bytes_and_remain_separate(self):
        run, _ = self.fixture()
        result = m.storage_diagnostics(run)
        self.assertEqual(result['status'], 'complete')
        self.assertTrue(result['daemon']['uses_containerd'])
        self.assertEqual(len(result['categories']['items']), 4)
        self.assertEqual(result['categories']['items'][0]['size_bytes'], 1250000000)
        self.assertEqual(result['categories']['items'][0]['engine_reclaimable_bytes'], 250000000)
        self.assertNotIn('total_bytes', result)

    def test_daemon_failure_timeout_and_malformed_results_are_unavailable(self):
        for mode in ('failure', 'timeout', 'malformed', 'oversized'):
            def run(argv, **kwargs):
                if mode == 'timeout':
                    raise subprocess.TimeoutExpired('fixture', 1)
                return subprocess.CompletedProcess(argv, 1 if mode == 'failure' else 0,
                    'x' * 65537 if mode == 'oversized' else '{invalid', 'private diagnostic')
            with self.subTest(mode=mode):
                result = m.storage_diagnostics(run)
                self.assertEqual(result['status'], 'unavailable')
                self.assertEqual(result['categories']['items'], [])
                self.assertNotIn('private diagnostic', json.dumps(result))

    def test_malformed_missing_duplicate_counts_and_sizes_refuse_totals(self):
        for mutation in ('duplicate', 'missing', 'count', 'size', 'percent'):
            run, rows = self.fixture()
            if mutation == 'duplicate': rows[-1] = rows[0]
            if mutation == 'missing': rows.pop()
            if mutation == 'count': rows[0]['active'] = '999'
            if mutation == 'size': rows[0]['size'] = 'NaNGB'
            if mutation == 'percent': rows[0]['reclaimable'] = '1GB (101%)'
            with self.subTest(mutation=mutation):
                result = m.storage_diagnostics(run)
                self.assertEqual(result['categories']['status'], 'unavailable')
                self.assertEqual(result['categories']['items'], [])

    def test_global_budget_stops_later_commands_without_inventing_zero(self):
        calls = []
        times = iter([0, 0, 11, 11])
        def run(argv, **kwargs):
            calls.append(argv)
            raise subprocess.TimeoutExpired('fixture', kwargs['timeout'])
        result = m.storage_diagnostics(run, monotonic=lambda: next(times))
        self.assertEqual(len(calls), 1)
        self.assertEqual(result['categories']['items'], [])
        self.assertNotIn('allocated_bytes', result['blobs'])

    def test_incomplete_blob_counters_never_become_complete_or_a_baseline(self):
        run, _ = self.fixture(dict(status='incomplete', count=1, allocated_bytes=4096,
                                  apparent_bytes=1, modified_hour_bytes=4096, modified_day_bytes=4096))
        result = m.storage_diagnostics(run)
        self.assertEqual(result['status'], 'partial')
        with tempfile.TemporaryDirectory() as directory:
            m.storage_baseline(result, Path(directory), 'fixture')
            self.assertEqual(list(Path(directory).iterdir()), [])
            self.assertNotIn('change_bytes', result['blobs'])

    def test_flat_blob_metadata_counts_allocation_without_reading_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            (path / 'fixture').write_bytes(b'x' * 5000)
            with patch.object(Path, 'read_text', side_effect=AssertionError('content read')):
                result = m.blob_metadata(path, root=path)
            self.assertEqual(result['status'], 'complete')
            self.assertEqual(result['count'], 1)
            self.assertEqual(result['apparent_bytes'], 5000)
            self.assertEqual(result['allocated_bytes'], (path / 'fixture').stat().st_blocks * 512)
            self.assertNotIn('fixture', json.dumps(result))

    def test_blob_symlink_entry_cap_and_deadline_are_explicitly_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            (path / 'fixture').write_bytes(b'x')
            self.assertEqual(m.blob_metadata(path, root=path, limit=0)['status'], 'incomplete')
            self.assertEqual(m.blob_metadata(path, root=path, budget=0)['status'], 'incomplete')
            (path / 'link').symlink_to(path / 'fixture')
            self.assertEqual(m.blob_metadata(path, root=path)['status'], 'incomplete')
            self.assertEqual(m.blob_metadata(path / 'link', root=path)['status'], 'unavailable')

    def test_complete_baseline_delta_is_scoped_and_failed_observation_preserves_it(self):
        run, _ = self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            first = m.storage_diagnostics(run)
            first['sampled_at'] = '2026-11-03T15:00:00Z'
            m.storage_baseline(first, state, 'fixture')
            self.assertEqual(first['blobs']['baseline_status'], 'first_observation')
            second = m.storage_diagnostics(run)
            second['sampled_at'] = '2026-11-03T15:15:00Z'
            second['blobs']['allocated_bytes'] += 4096
            m.storage_baseline(second, state, 'fixture')
            self.assertEqual(second['blobs']['change_bytes'], 4096)
            saved = (state / 'hoghunter-storage-baseline.json').read_bytes()
            second['blobs']['status'] = 'incomplete'
            m.storage_baseline(second, state, 'fixture')
            self.assertEqual((state / 'hoghunter-storage-baseline.json').read_bytes(), saved)
            second['blobs']['status'] = 'complete'
            m.storage_baseline(second, state, 'different-host')
            self.assertEqual(second['blobs']['baseline_status'], 'first_observation')

    def test_malformed_and_symlink_baseline_remain_unavailable(self):
        run, _ = self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            path = state / 'hoghunter-storage-baseline.json'
            path.write_text('{malformed')
            m.storage_baseline(m.storage_diagnostics(run), state, 'fixture')
            self.assertEqual(path.read_text(), '{malformed')
            path.unlink()
            target = state / 'protected'
            target.write_text('unchanged')
            path.symlink_to(target)
            m.storage_baseline(m.storage_diagnostics(run), state, 'fixture')
            self.assertTrue(path.is_symlink())
            self.assertEqual(target.read_text(), 'unchanged')


if __name__ == '__main__':
    unittest.main()

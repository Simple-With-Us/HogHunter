import os
from pathlib import Path
import subprocess
import tempfile
import unittest
SCRIPT = Path(__file__).with_name('build-run-stamp.sh')
class RunStampTests(unittest.TestCase):
    def test_fresh_time_per_run_without_git_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            tool = Path(folder) / 'date'
            tool.write_text('#!/bin/bash\n[[ "$TZ" == America/Chicago ]] || exit 8\nprintf "%s\\n" "$FIXTURE_STAMP"\n')
            tool.chmod(0o700)
            for value in ['202611152343','202611152344','bad','1000','']:
                r = subprocess.run(['bash',str(SCRIPT)], cwd=folder,capture_output=True,text=True,
                    env=dict(os.environ,PATH=folder+':'+os.environ['PATH'],FIXTURE_STAMP=value))
                if len(value)==12:
                    self.assertEqual(r.returncode,0,r.stderr)
                    self.assertEqual(r.stdout.strip(),value)
                else: self.assertNotEqual(r.returncode,0)
if __name__=='__main__': unittest.main()

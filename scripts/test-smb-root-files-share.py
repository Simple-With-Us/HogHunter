#!/usr/bin/env python3
"""Tests for scripts/smb-root-files-share.sh.

The script is the source of truth for the root-files share, so its rendered
configuration and its refusals are checked here rather than on the server. 
Nothing in this file touches the server, and no test applies a change.
"""
import os
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "smb-root-files-share.sh")


def run(*args, **kwargs):
    return subprocess.run(
        [SCRIPT, *args],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
        **kwargs,
    )


class ShareBlockTests(unittest.TestCase):
    """The rendered block is what lands in smb.conf, so it is checked directly."""

    @classmethod
    def setUpClass(cls):
        result = run("--print-config")
        assert result.returncode == 0, result.stderr
        cls.block = result.stdout

    def test_block_names_the_share_and_the_path(self):
        self.assertIn("[root-files]", self.block)
        self.assertIn("path = /root", self.block)

    def test_block_runs_as_jay_not_root(self):
        self.assertIn("valid users = jay", self.block)
        self.assertIn("force user = jay", self.block)
        self.assertIn("force group = fleet", self.block)
        self.assertNotIn("force user = root", self.block)

    def test_block_is_read_only(self):
        self.assertIn("read only = Yes", self.block)

    def test_block_shows_dot_files(self):
        # The Samba default hides them, and the dot-prefixed agent state is
        # exactly what the owner wants to see.
        self.assertIn("hide dot files = no", self.block)

    def test_block_does_not_follow_links_out_of_the_tree(self):
        self.assertIn("wide links = no", self.block)
        self.assertIn("follow symlinks = yes", self.block)

    def test_block_vetoes_the_key_directories(self):
        self.assertIn("veto files = /.ssh/.gnupg/", self.block)

    def test_block_carries_its_markers(self):
        self.assertIn("# BEGIN hoghunter root-files share", self.block)
        self.assertIn("# END hoghunter root-files share", self.block)

    def test_block_has_no_credential(self):
        lowered = self.block.lower()
        for word in ("password", "passwd", "secret", "token"):
            self.assertNotIn(word, lowered)


class PlanTests(unittest.TestCase):
    """The plan is what the operator reads before applying anything."""

    @classmethod
    def setUpClass(cls):
        result = run()
        assert result.returncode == 0, result.stderr
        cls.plan = result.stdout

    def test_plan_grants_on_the_source_directory(self):
        self.assertIn("setfacl -n --mask -m u:jay:rx /root", self.plan)

    def test_plan_recalculates_the_acl_mask(self):
        # Without --mask, setfacl keeps the old group bits as the mask, and a
        # 0600 file keeps a mask of ---, which makes the grant ineffective.
        for line in self.plan.splitlines():
            if "setfacl" in line:
                self.assertIn("--mask", line)

    def test_plan_never_grants_on_an_excluded_name(self):
        for line in self.plan.splitlines():
            if "setfacl" not in line:
                continue
            self.assertNotIn("/root/.ssh", line)
            self.assertNotIn("/root/.gnupg", line)

    def test_plan_says_what_it_excludes(self):
        self.assertIn("excluded:   .ssh .gnupg", self.plan)


class RefusalTests(unittest.TestCase):
    """The script must not change anything it was not told to change."""

    def test_apply_without_confirm_refuses(self):
        result = run("--apply")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--confirm", result.stderr)
        self.assertIn("nothing was changed", result.stderr)

    def test_apply_with_confirm_refuses_a_missing_source(self):
        # It never reaches the backup or the grant, so this is safe to run even
        # as root.
        result = run("--apply", "--confirm", "--source", "/nonexistent-share-source")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("installed:", result.stdout)

    def test_a_share_name_with_a_path_separator_is_refused(self):
        result = run("--print-config", "--share", "../escape")
        self.assertEqual(result.returncode, 2)

    def test_an_excluded_name_with_a_path_separator_is_refused(self):
        result = run("--print-config", "--exclude", "a/b")
        self.assertEqual(result.returncode, 2)


class ResultingConfigTests(unittest.TestCase):
    """The managed block is replaced, never duplicated, and the rest survives."""

    def _write(self, body):
        path = os.path.join(self.tmp.name, "smb.conf")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        return path

    def setUp(self):
        import tempfile

        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_existing_block_is_replaced_not_appended(self):
        original = (
            "[global]\n"
            "   workgroup = FLEET\n"
            "# BEGIN hoghunter root-files share\n"
            "[root-files]\n"
            "   path = /somewhere/else\n"
            "# END hoghunter root-files share\n"
            "[fleet-extra]\n"
            "   path = /mnt/fleet-extra\n"
        )
        path = self._write(original)
        result = run("--print-resulting-conf", path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("[root-files]"), 1)
        self.assertNotIn("/somewhere/else", result.stdout)
        self.assertIn("path = /root", result.stdout)
        self.assertIn("[fleet-extra]", result.stdout)
        self.assertIn("workgroup = FLEET", result.stdout)

    def test_the_result_is_stable(self):
        path = self._write("[global]\n   workgroup = FLEET\n")
        once = run("--print-resulting-conf", path)
        self.assertEqual(once.returncode, 0, once.stderr)
        second_path = os.path.join(self.tmp.name, "second.conf")
        with open(second_path, "w", encoding="utf-8") as handle:
            handle.write(once.stdout)
        twice = run("--print-resulting-conf", second_path)
        self.assertEqual(twice.returncode, 0, twice.stderr)
        self.assertEqual(once.stdout, twice.stdout)

    def test_a_custom_exclusion_replaces_the_default_list(self):
        path = self._write("[global]\n")
        result = run("--print-resulting-conf", path, "--exclude", ".gnupg")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("veto files = /.gnupg/", result.stdout)
        self.assertNotIn(".ssh", result.stdout)


if __name__ == "__main__":
    unittest.main()

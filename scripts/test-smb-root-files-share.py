#!/usr/bin/env python3
"""Tests for scripts/smb-root-files-share.sh.

The script is the source of truth for the root-files share, so its rendered
configuration and its refusals are checked here rather than on the server.  Nothing
in this file touches the server, and no test applies a change.
"""
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "smb-root-files-share.sh")


def run(*args, **kwargs):
    # The script is invoked through bash rather than directly, so the suite does
    # not depend on the file carrying its executable bit in the checkout.
    return subprocess.run(
        ["bash", SCRIPT, *args],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
        **kwargs,
    )


def tree(*names):
    """Build a directory tree and return its path."""
    root = tempfile.mkdtemp(prefix="smb-share-fixture-")
    for name in names:
        path = os.path.join(root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("x\n")
    return root


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

    def test_block_vetoes_the_samba_password_file(self):
        # The credential that guards the share does not belong inside the share.
        self.assertIn(".fleet-extra-smb.pass", self.block)

    def test_block_carries_its_markers(self):
        self.assertIn("# BEGIN hoghunter root-files share", self.block)
        self.assertIn("# END hoghunter root-files share", self.block)

    def test_block_carries_no_credential_value(self):
        # The block may name a credential file in order to keep it out of the
        # share, but it must never carry a value.
        for line in self.block.splitlines():
            if "veto files" in line:
                self.assertNotIn("=", line.split("veto files", 1)[1].split("=", 1)[1])
                continue
            lowered = line.lower()
            for word in ("password", "passwd", "secret", "token"):
                self.assertNotIn(word, lowered)


class ExclusionTests(unittest.TestCase):
    """A repeated --exclude must never drop an earlier name."""

    def test_a_second_exclude_appends_to_the_first(self):
        result = run("--print-config", "--exclude", ".ssh", "--exclude", ".gnupg")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("veto files = /.ssh/.gnupg/", result.stdout)

    def test_a_second_exclude_keeps_the_first_name_out_of_the_grant(self):
        root = tree(".ssh/id", ".gnupg/secret", "keep/file")
        result = run("--print-targets", "--source", root, "--exclude", ".ssh", "--exclude", ".gnupg")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(os.path.join(root, ".ssh"), result.stdout)
        self.assertNotIn(os.path.join(root, ".gnupg"), result.stdout)
        self.assertIn(os.path.join(root, "keep"), result.stdout)

    def test_the_first_exclude_replaces_the_default_list(self):
        result = run("--print-config", "--exclude", ".gnupg")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("veto files = /.gnupg/", result.stdout)
        self.assertNotIn(".ssh", result.stdout)

    def test_the_default_list_is_used_without_any_exclude(self):
        result = run("--print-config")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in (".ssh", ".gnupg", ".fleet-extra-smb.pass"):
            self.assertIn(name, result.stdout)

    def test_the_credential_files_are_excluded_by_default(self):
        # Live credentials must not travel over the network, and the share
        # authenticates as an account that already holds sudo.
        result = run("--print-config")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in (
            ".coolify-admin-password",
            ".coolify-api-token",
            ".ct-r2-weekly-archive.env",
            ".ct-secrets-export.env",
            ".fleet-extra-smb.pass",
            ".secrets",
            ".zuliprc-bf-monitor",
        ):
            self.assertIn(name, result.stdout)

    def test_an_excluded_name_with_whitespace_is_refused(self):
        result = run("--print-config", "--exclude", "my dir")
        self.assertEqual(result.returncode, 2)
        self.assertIn("whitespace", result.stderr)

    def test_an_excluded_name_with_a_glob_character_is_refused(self):
        result = run("--print-config", "--exclude", "*")
        self.assertEqual(result.returncode, 2)
        self.assertIn("glob", result.stderr)

    def test_an_excluded_name_starting_with_a_dash_is_refused(self):
        result = run("--print-config", "--exclude", "-rf")
        self.assertEqual(result.returncode, 2)
        self.assertIn("dash", result.stderr)


class TargetTests(unittest.TestCase):
    """The target list is the single source of truth for the grant."""

    def setUp(self):
        self.root = tree(
            ".ssh/id_ed25519",
            ".gnupg/secret.gpg",
            "sub/.ssh/nested_key",
            "sub/keep/file.txt",
            "plain/f.txt",
        )

    def test_an_excluded_name_is_pruned_at_every_depth(self):
        result = run("--print-targets", "--source", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(os.path.join(self.root, "sub", ".ssh"), result.stdout)
        self.assertIn(os.path.join(self.root, "sub", "keep", "file.txt"), result.stdout)

    def test_a_symbolic_link_is_never_a_target(self):
        link = os.path.join(self.root, "plain", "link")
        os.symlink("/etc/passwd", link)
        result = run("--print-targets", "--source", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(link, result.stdout)

    def test_the_plan_prunes_the_same_names_as_the_target_list(self):
        plan = run("--source", self.root)
        self.assertEqual(plan.returncode, 0, plan.stderr)
        for name in (".ssh", ".gnupg", ".fleet-extra-smb.pass"):
            self.assertIn("-name " + name, plan.stdout)

    def test_the_plan_never_grants_on_an_excluded_name(self):
        plan = run("--source", self.root)
        self.assertEqual(plan.returncode, 0, plan.stderr)
        for line in plan.stdout.splitlines():
            if "setfacl" not in line:
                continue
            self.assertNotIn(os.path.join(self.root, ".ssh"), line)
            self.assertNotIn(os.path.join(self.root, ".gnupg"), line)


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

    def test_an_unmatched_begin_marker_is_refused(self):
        # A half-written block must not take the rest of the configuration with
        # it, so the run stops instead.
        original = (
            "[global]\n"
            "   workgroup = FLEET\n"
            "# BEGIN hoghunter root-files share\n"
            "[root-files]\n"
            "   path = /somewhere/else\n"
        )
        path = self._write(original)
        result = run("--print-resulting-conf", path)
        self.assertEqual(result.returncode, 3)
        self.assertIn("unmatched begin marker", result.stderr)
        self.assertNotIn("[fleet-extra]", result.stdout)


class InstallSafetyTests(unittest.TestCase):
    """The live configuration is never rewritten in place."""

    @classmethod
    def setUpClass(cls):
        with open(SCRIPT, encoding="utf-8") as handle:
            cls.source = handle.read()

    def test_the_new_configuration_is_written_beside_the_live_one(self):
        self.assertIn('mktemp "${SMB_DIR}/', self.source)

    def test_the_new_configuration_is_renamed_into_place(self):
        self.assertIn('mv -f "$TMP_CONF" "$SMB_CONF"', self.source)

    def test_the_live_configuration_is_never_installed_over_in_place(self):
        # An install onto the live path rewrites it in place, so an interrupted
        # run can leave a truncated configuration behind.
        self.assertNotIn('install -m 0644 -o root -g root "$TMP_CONF" "$SMB_CONF"', self.source)
        self.assertNotIn('install -m 0644 -o root -g root "$BACKUP" "$SMB_CONF"', self.source)

    def test_the_backup_is_renamed_into_place(self):
        self.assertIn('mv -f "${BACKUP}.tmp" "$BACKUP"', self.source)

    def test_the_grant_is_taken_back_off_the_excluded_names(self):
        # An earlier run granted the excluded names, so the script has to remove
        # the grant again rather than only declining to add it.
        self.assertIn('setfacl -R -x "u:${SMB_USER}"', self.source)

    def _function(self, name):
        """Return the body of one shell function from the script source."""
        lines = self.source.splitlines()
        start = None
        for index, line in enumerate(lines):
            if line.startswith(name + "() {"):
                start = index
                break
        self.assertIsNotNone(start, name)
        body = []
        for line in lines[start:]:
            body.append(line)
            if line == "}":
                break
        return "\n".join(body)

    def test_the_revoke_covers_every_excluded_name(self):
        # The key directories are never granted, but the first version of the
        # script granted them, and a grant left on a private key holds it at
        # 0640, which OpenSSH then refuses.  The revoke therefore covers every
        # excluded name, the key directories included.
        body = self._function("revoke_excluded_grant")
        self.assertIn('for excluded in "${EXCLUDE_ARRAY[@]}"', body)

    def test_the_revoke_recalculates_the_mask(self):
        # With -n the mask keeps the value it had, so a granted 0600 file is
        # still reported as 0640 after the grant is taken back off it, and the
        # key stays in the state OpenSSH refuses.  Recalculating the mask
        # restores the file's own mode with the entry.
        body = self._function("revoke_excluded_grant")
        commands = [line for line in body.splitlines() if "setfacl" in line]
        self.assertTrue(commands)
        for line in commands:
            self.assertNotIn("-n", line)

    def test_the_plan_says_the_grant_is_taken_back(self):
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("take the grant back off the excluded names", result.stdout)


if __name__ == "__main__":
    unittest.main()

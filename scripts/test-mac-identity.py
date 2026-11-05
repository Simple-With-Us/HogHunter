#!/usr/bin/env python3
"""Pins the rules that keep macOS privacy grants across updates.

A grant follows the designated requirement, so these tests cover the check that
refuses a wrong identity, the installer gates that run before any build, and the
project setting that keeps ad hoc Debug builds off an external DerivedData.  See
docs/rollouts/2026-11-04-tcc-prompts-and-code-identity.md.

Requires macOS: it calls PlistBuddy and, in one test, the real codesign.
"""
import os
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts" / "check-mac-identity.sh"
INSTALL = ROOT / "scripts" / "install.sh"
POST_GEN = ROOT / "scripts" / "xcodegen-post.sh"
BUNDLE_ID = "com.simplewithus.hoghunter.macos"
TEAM = "CC8UTF7ATG"
REQUIREMENT = (
    f'identifier "{BUNDLE_ID}" and anchor apple generic and '
    "certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
    "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and "
    f"certificate leaf[subject.OU] = {TEAM}"
)
DEVELOPER_ID = f"Developer ID Application: Jay Wedgeworth, LLC ({TEAM})"


def write_tool(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/bin/bash\n" + textwrap.dedent(body))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def make_bundle(parent: Path, bundle_id: str = BUNDLE_ID) -> Path:
    app = parent / "Hog Hunter.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    with open(app / "Contents" / "Info.plist", "wb") as handle:
        plistlib.dump(
            {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "HogHunter", "CFBundlePackageType": "APPL"},
            handle,
        )
    shutil.copy("/bin/echo", app / "Contents" / "MacOS" / "HogHunter")
    return app


class IdentityCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()

    def fake_codesign(self, details: str, requirement: str = REQUIREMENT, verify_status: int = 0) -> None:
        (self.dir / "details").write_text(details)
        (self.dir / "requirement").write_text(f"designated => {requirement}\n")
        write_tool(
            self.bin,
            "codesign",
            f"""\
            case "$*" in
              *--verify*) exit {verify_status} ;;
              *-r-*) cat "{self.dir}/requirement" ;;
              *) cat "{self.dir}/details" >&2 ;;
            esac
            """,
        )

    def run_check(self, app: Path, *flags: str) -> subprocess.CompletedProcess:
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        return subprocess.run([str(CHECK), *flags, str(app)], env=env, capture_output=True, text=True)

    def good_details(self) -> str:
        return (
            f"Identifier={BUNDLE_ID}\n"
            "CodeDirectory v=20500 size=28204 flags=0x10000(runtime) hashes=870+7 location=embedded\n"
            f"Authority={DEVELOPER_ID}\nAuthority=Developer ID Certification Authority\n"
            f"TeamIdentifier={TEAM}\n"
        )

    def test_the_production_identity_passes(self) -> None:
        self.fake_codesign(self.good_details())
        result = self.run_check(make_bundle(self.dir))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_quoted_team_id_rendering_is_accepted_too(self) -> None:
        # codesign prints a leaf OU bare when the Team ID starts with a letter and
        # quoted otherwise; both are the same requirement.
        self.fake_codesign(self.good_details(), requirement=REQUIREMENT.replace(f"= {TEAM}", f'= "{TEAM}"'))
        result = self.run_check(make_bundle(self.dir))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_different_team_in_the_requirement_is_refused(self) -> None:
        self.fake_codesign(self.good_details(), requirement=REQUIREMENT.replace(TEAM, "ZZZZZZZZZZ"))
        self.assertEqual(self.run_check(make_bundle(self.dir)).returncode, 2)

    def test_an_ad_hoc_signature_is_refused(self) -> None:
        self.fake_codesign(
            f"Identifier={BUNDLE_ID}\nCodeDirectory v=20400 size=453 flags=0x2(adhoc) hashes=3+7\n"
            "Signature=adhoc\nTeamIdentifier=not set\n",
            requirement='cdhash H"6f22371fb06d1a284060ca76ec585c894a1593a9"',
        )
        result = self.run_check(make_bundle(self.dir))
        self.assertEqual(result.returncode, 2)
        self.assertIn("ad hoc", result.stderr)

    def test_another_team_is_refused(self) -> None:
        self.fake_codesign(self.good_details().replace(TEAM, "ZZZZZZZZZZ"))
        result = self.run_check(make_bundle(self.dir))
        self.assertEqual(result.returncode, 2)
        self.assertIn("Team ID", result.stderr)

    def test_an_apple_development_certificate_is_refused(self) -> None:
        details = self.good_details().replace(DEVELOPER_ID, f"Apple Development: Someone ({TEAM})")
        self.fake_codesign(details)
        result = self.run_check(make_bundle(self.dir))
        self.assertEqual(result.returncode, 2)
        self.assertIn("first signing authority", result.stderr)

    def test_a_changed_requirement_is_refused(self) -> None:
        self.fake_codesign(self.good_details(), requirement=REQUIREMENT.replace(BUNDLE_ID, BUNDLE_ID + ".other"))
        result = self.run_check(make_bundle(self.dir))
        self.assertEqual(result.returncode, 2)
        self.assertIn("designated requirement", result.stderr)

    def test_another_bundle_id_is_refused(self) -> None:
        self.fake_codesign(self.good_details())
        result = self.run_check(make_bundle(self.dir, bundle_id=BUNDLE_ID + ".development"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("bundle id", result.stderr)

    def test_a_broken_seal_is_refused_unless_the_caller_just_checked_it(self) -> None:
        self.fake_codesign(self.good_details(), verify_status=1)
        app = make_bundle(self.dir)
        self.assertEqual(self.run_check(app).returncode, 2)
        self.assertEqual(self.run_check(app, "--identity-only").returncode, 0)

    def test_a_real_ad_hoc_signature_is_refused(self) -> None:
        app = make_bundle(self.dir)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
        env = dict(os.environ)
        result = subprocess.run([str(CHECK), str(app)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("ad hoc", result.stderr)

    def test_a_reader_that_has_gone_away_does_not_fail_the_check(self) -> None:
        # The installer ignores SIGPIPE during the swap and the children inherit that,
        # so the closing report gets a write error rather than a signal.
        self.fake_codesign(self.good_details())
        app = make_bundle(self.dir)
        read_end, write_end = os.pipe()
        os.close(read_end)
        self.addCleanup(os.close, write_end)
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        result = subprocess.run(
            [str(CHECK), str(app)],
            env=env,
            stdout=write_end,
            stderr=subprocess.DEVNULL,
            preexec_fn=lambda: signal.signal(signal.SIGPIPE, signal.SIG_IGN),
        )
        self.assertEqual(result.returncode, 0)


class InstallerGateTests(unittest.TestCase):
    """Every refusal here must come before the build: xcodegen must not run."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name).resolve()
        self.home = self.dir / "home"
        self.home.mkdir()
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.log = self.dir / "calls"
        write_tool(self.bin, "xcodegen", f'echo xcodegen >> "{self.log}"\n')
        # The build fails here on purpose: a test only needs to see the gates pass.
        write_tool(self.bin, "xcodebuild", 'echo "stop after the gates" >&2\nexit 42\n')
        self.identities(DEVELOPER_ID)

    def identities(self, name: str) -> None:
        line = f'echo \'  1) 0E9E8C80 "{name}"\'' if name else "true"
        write_tool(self.bin, "security", line + "\n")

    def install(self, *arguments: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
        env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.environ['PATH']}")
        return subprocess.run([str(INSTALL), *arguments], env=env, capture_output=True, text=True, cwd=cwd)

    def assert_refused(self, result: subprocess.CompletedProcess, code: int, text: str) -> None:
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertIn(text, result.stderr)
        self.assertFalse(self.log.exists(), "the build started before the refusal")

    def test_an_empty_destination_is_refused_rather_than_read_as_none(self) -> None:
        for arguments in (("--dest", ""), ("--adhoc", "--dest", "")):
            with self.subTest(arguments):
                self.assert_refused(self.install(*arguments), 1, "--dest requires a PATH argument")

    def test_ad_hoc_needs_an_explicit_destination(self) -> None:
        self.assert_refused(self.install("--adhoc"), 3, "refusing an ad hoc install")

    def test_ad_hoc_is_refused_for_each_production_folder(self) -> None:
        (self.home / "Applications").mkdir()
        for destination in ("/Applications", "/Applications/", f"{self.home}/Applications", f"{self.home}/Applications/"):
            self.assert_refused(self.install("--adhoc", "--dest", destination), 3, "refusing an ad hoc install")

    def test_ad_hoc_is_refused_inside_a_production_folder(self) -> None:
        (self.home / "Applications" / "Nested").mkdir(parents=True)
        for destination in ("/Applications/SomeFolder", f"{self.home}/Applications/Nested", f"{self.home}/Applications/Nested/"):
            self.assert_refused(self.install("--adhoc", "--dest", destination), 3, "refusing an ad hoc install")

    def test_ad_hoc_is_refused_for_a_case_variant_of_a_production_folder(self) -> None:
        # The text differs and the folder is the same one.
        (self.home / "Applications").mkdir()
        for destination in (
            "/applications",
            "/APPLICATIONS/NewSub",
            f"{self.home}/applications",
            f"{self.home}/APPLICATIONS/NewSub",
        ):
            with self.subTest(destination):
                if not Path(destination.replace("/NewSub", "")).exists():
                    self.skipTest("this volume is case-sensitive")
                self.assert_refused(self.install("--adhoc", "--dest", destination), 3, "refusing an ad hoc install")

    def test_ad_hoc_is_refused_for_a_folder_that_does_not_exist_yet_however_it_is_spelled(self) -> None:
        applications = self.home / "Applications"
        applications.mkdir()
        link = self.dir / "link-to-applications"
        link.symlink_to(applications)
        system_link = self.dir / "link-to-system"
        system_link.symlink_to("/Applications")
        for destination in (
            f"{link}/NewSub",
            f"{system_link}/NewSub/Deeper",
            "//Applications/NewSub",
            "/private/../Applications/NewSub",
            f"/{self.home}/Applications/NewSub",
            f"{self.home}/./Applications/NewSub",
        ):
            with self.subTest(destination):
                self.assert_refused(self.install("--adhoc", "--dest", destination), 3, "refusing an ad hoc install")

    def test_ad_hoc_is_refused_for_a_path_that_cannot_be_judged(self) -> None:
        (self.home / "Applications").mkdir()
        dangling = self.dir / "dangling"
        dangling.symlink_to(self.dir / "nowhere")
        for destination in (
            # mkdir -p would create "new", and the `..` then lands in Applications.
            f"{self.home}/new/../Applications/x",
            f"{dangling}/x",
        ):
            with self.subTest(destination):
                self.assert_refused(self.install("--adhoc", "--dest", destination), 3, "refusing an ad hoc install")

    def test_ad_hoc_is_refused_for_the_user_folder_before_it_exists(self) -> None:
        for destination in (f"{self.home}/Applications", f"{self.home}/Applications/x", f"{self.home}/applications/x"):
            with self.subTest(destination):
                self.assert_refused(self.install("--adhoc", "--dest", destination), 3, "refusing an ad hoc install")

    def test_a_relative_destination_is_the_callers_folder_not_the_repository(self) -> None:
        (self.home / "Applications").mkdir()
        caller = self.dir / "caller"
        caller.mkdir()
        for target in ("/Applications/NewSub", f"{self.home}/Applications/NewSub"):
            relative = os.path.relpath(target, caller)
            with self.subTest(relative):
                self.assert_refused(self.install("--adhoc", "--dest", relative, cwd=caller), 3, "refusing an ad hoc install")
        result = self.install("--adhoc", "--dest", "scratch", cwd=caller)
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn(f"Destination: {caller}/scratch ", result.stdout)

    def test_a_throwaway_folder_that_only_shares_the_name_passes_the_gates(self) -> None:
        for destination in (self.dir / "Applications", self.dir / "applications" / "x", self.dir / "Applications-old"):
            result = self.install("--adhoc", "--dest", str(destination))
            self.assertEqual(result.returncode, 42, result.stdout + result.stderr)

    def test_ad_hoc_to_a_throwaway_folder_passes_the_gates_and_never_launches(self) -> None:
        result = self.install("--adhoc", "--dest", str(self.dir / "scratch"))
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn("Not launching", result.stdout)

    def test_no_developer_id_identity_is_refused(self) -> None:
        self.identities("")
        self.assert_refused(self.install(), 3, "no Developer ID Application identity")

    def test_another_team_identity_is_refused(self) -> None:
        self.identities("Developer ID Application: Someone Else (ZZZZZZZZZZ)")
        self.assert_refused(self.install(), 3, "no Developer ID Application identity")

    def test_a_copy_in_the_other_folder_is_refused(self) -> None:
        (self.home / "Applications" / "Hog Hunter.app").mkdir(parents=True)
        self.assert_refused(self.install("--dest", str(self.dir / "elsewhere")), 4, "second copy")

    def test_updating_in_place_is_not_a_second_copy_however_the_folder_is_spelled(self) -> None:
        applications = self.home / "Applications"
        (applications / "Hog Hunter.app").mkdir(parents=True)
        link = self.dir / "link-to-applications"
        link.symlink_to(applications)
        spellings = [f"{applications}", f"{applications}/", f"{applications}//", str(link)]
        if (self.home / "applications").exists():
            spellings.append(f"{self.home}/applications")
        for destination in spellings:
            result = self.install("--dest", destination)
            self.assertEqual(result.returncode, 42, destination + result.stdout + result.stderr)

    def test_the_production_identity_passes_the_gates(self) -> None:
        result = self.install()
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertTrue(self.log.exists())


class InstallerSwapTests(unittest.TestCase):
    """The whole script from the build on, in a copy of the repository with every
    outside tool stubbed.  The real tools here are ditto, xattr and PlistBuddy, and
    they only ever see the temporary folder."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name).resolve()
        self.home = self.dir / "home"
        self.home.mkdir()
        self.dest = self.dir / "throwaway"
        self.installed = self.dest / "Hog Hunter.app"
        self.log = self.dir / "calls"
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        repo = self.dir / "repo"
        (repo / "scripts").mkdir(parents=True)
        shutil.copy(INSTALL, repo / "scripts" / "install.sh")
        shutil.copy(ROOT / "HogHunter.entitlements", repo / "HogHunter.entitlements")
        self.script = repo / "scripts" / "install.sh"
        write_tool(
            repo / "scripts",
            "check-mac-identity.sh",
            f"""\
            echo "check $*" >> "{self.log}"
            if [[ "${{SCENARIO:-}}" == stage_check_fails && "$*" == *.hoghunter-install.* ]]; then exit 2; fi
            exit 0
            """,
        )
        self.built = self.dir / "built"
        self.built.mkdir()
        (make_bundle(self.built) / "Contents" / "marker").write_text("NEW")
        write_tool(
            self.bin,
            "xcodebuild",
            f"""\
            if [[ "${{SCENARIO:-}}" == build_fails ]]; then exit 42; fi
            if [[ -n "${{DEST_BECOMES_LINK_TO:-}}" ]]; then ln -s "$DEST_BECOMES_LINK_TO" "{self.dest}"; fi
            mkdir -p build/Build/Products/Release
            /usr/bin/ditto "{self.built}/Hog Hunter.app" build/Build/Products/Release/HogHunter.app
            """,
        )
        write_tool(
            self.bin,
            "codesign",
            f"""\
            last="${{@: -1}}"
            if [[ "$*" == *--verify* && "$last" == */"Hog Hunter.app" && "$last" != *.hoghunter-install.* ]]; then
              case "${{SCENARIO:-}}" in
                verify_fails) exit 1 ;;
                verify_interrupted) kill -TERM "$PPID" ;;
              esac
            fi
            exit 0
            """,
        )
        write_tool(
            self.bin,
            "mv",
            """\
            source="${@: -2:1}"
            target="${@: -1}"
            case "${SCENARIO:-}" in
              swap_fails|swap_and_restore_fail)
                [[ "$source" == *.hoghunter-install.* ]] && exit 1 ;;
            esac
            case "${SCENARIO:-}" in
              swap_and_restore_fail|interrupted_and_restore_fails)
                [[ "$source" == *.hoghunter-previous.* ]] && exit 1 ;;
              aside_fails)
                [[ "$target" == *.hoghunter-previous.* ]] && exit 1 ;;
            esac
            /bin/mv "$@" || exit $?
            case "${SCENARIO:-}" in
              interrupted_between_renames|interrupted_and_restore_fails)
                [[ "$target" == *.hoghunter-previous.* ]] && kill -TERM "$PPID" ;;
              reader_dies|reader_dies_then_interrupted)
                if [[ "$target" == *.hoghunter-previous.* ]]; then
                  kill -9 "$READER_PID"
                  /bin/sleep 0.2
                  [[ "$SCENARIO" == reader_dies ]] || kill -TERM "$PPID"
                fi ;;
            esac
            exit 0
            """,
        )
        for name in ("osascript", "pkill", "xcodegen"):
            write_tool(self.bin, name, f'echo "{name} $*" >> "{self.log}"\n')
        write_tool(
            self.bin,
            "open",
            f"""\
            echo "open $*" >> "{self.log}"
            [[ "${{SCENARIO:-}}" != open_fails ]]
            """,
        )
        write_tool(self.bin, "sleep", '[[ "${SCENARIO:-}" != interrupted_after_quit ]] || kill -TERM "$PPID"\nexit 0\n')
        write_tool(self.bin, "rm", '[[ "${SCENARIO:-}" != interrupted_after_commit ]] || kill -TERM "$PPID"\nexec /bin/rm "$@"\n')
        # Like the real one, status 1 when nothing matches.
        write_tool(self.bin, "pgrep", '[[ -n "${RUNNING_PID:-}" ]] || exit 1\necho "$RUNNING_PID"\n')
        write_tool(self.bin, "lsof", 'echo "p${RUNNING_PID:-}"\necho "n${RUNNING_FROM:-}"\n')
        write_tool(self.bin, "security", f"echo '  1) 0E9E8C80 \"{DEVELOPER_ID}\"'\n")

    def use_fake_system_folder(self) -> Path:
        """Points this copy of the script at a folder of ours instead of /Applications,
        so a production run here can never touch the real one."""
        system = self.dir / "system"
        system.mkdir()
        source = self.script.read_text()
        line = 'SYSTEM_APPLICATIONS="/Applications"'
        self.assertIn(line, source)
        self.script.write_text(source.replace(line, f'SYSTEM_APPLICATIONS="{system}"'))
        return system

    def production_previous_copy(self) -> Path:
        """A default production install's folder, holding the previous copy."""
        self.use_fake_system_folder()
        applications = self.home / "Applications"
        self.previous_copy(applications)
        return applications

    def stuck(self, app: Path) -> None:
        """A bundle `rm -rf` cannot empty."""
        macos = app / "Contents" / "MacOS"
        macos.chmod(0o500)
        self.addCleanup(lambda: [p.chmod(0o700) for p in self.dir.rglob("MacOS")])

    def run_with_reader(self, *arguments: str, scenario: str) -> subprocess.CompletedProcess:
        """Stdout and stderr go to a pipe whose reader the stub kills part way."""
        reader = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        self.addCleanup(reader.wait)
        self.addCleanup(reader.kill)
        self.addCleanup(reader.stdin.close)
        env = dict(
            os.environ,
            HOME=str(self.home),
            PATH=f"{self.bin}:{os.environ['PATH']}",
            SCENARIO=scenario,
            READER_PID=str(reader.pid),
        )
        return subprocess.run([str(self.script), *arguments], env=env, stdout=reader.stdin, stderr=reader.stdin, cwd=self.dir)

    def previous_copy(self, folder: Path) -> Path:
        folder.mkdir(parents=True, exist_ok=True)
        app = make_bundle(folder)
        (app / "Contents" / "marker").write_text("OLD")
        return app

    def run_install(self, *arguments: str, scenario: str = "", **environment: str) -> subprocess.CompletedProcess:
        env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.environ['PATH']}", SCENARIO=scenario, **environment)
        return subprocess.run([str(self.script), *arguments], env=env, capture_output=True, text=True, cwd=self.dir)

    def adhoc(self, scenario: str = "", **environment: str) -> subprocess.CompletedProcess:
        return self.run_install("--adhoc", "--dest", str(self.dest), scenario=scenario, **environment)

    def marker(self, app: Path | None = None) -> str:
        return ((app or self.installed) / "Contents" / "marker").read_text()

    def calls(self) -> str:
        return self.log.read_text() if self.log.exists() else ""

    def hidden_folders(self, directory: Path | None = None) -> list[str]:
        return sorted(p.name for p in (directory or self.dest).iterdir() if p.name.startswith(".hoghunter-"))

    def backup_paths(self) -> list[Path]:
        return sorted(self.dest.glob(".hoghunter-previous.*/Hog Hunter.app"))

    def test_a_finished_install_replaces_the_copy_and_leaves_nothing_behind(self) -> None:
        self.previous_copy(self.dest)
        result = self.adhoc()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.marker(), "NEW")
        self.assertEqual(self.hidden_folders(), [])

    def test_a_production_install_still_works(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "NEW")
        calls = self.calls()
        self.assertIn('osascript -e tell application "Hog Hunter" to quit', calls)
        self.assertIn(f"check {applications}/Hog Hunter.app", calls)
        self.assertIn(f"open {applications}/Hog Hunter.app", calls)
        self.assertEqual(self.hidden_folders(applications), [])

    def test_a_production_install_to_a_case_variant_updates_in_place(self) -> None:
        applications = self.production_previous_copy()
        if not (self.home / "applications").exists():
            self.skipTest("this volume is case-sensitive")
        result = self.run_install("--dest", str(self.home / "applications"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "NEW")

    def test_a_destination_that_turns_into_production_during_the_build_is_refused(self) -> None:
        applications = self.home / "Applications"
        self.previous_copy(applications)
        result = self.adhoc(DEST_BECOMES_LINK_TO=str(applications))
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("now a production location", result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "OLD")
        self.assertEqual(self.hidden_folders(applications), [])

    def test_an_interruption_between_the_renames_puts_the_previous_copy_back(self) -> None:
        self.previous_copy(self.dest)
        result = self.adhoc("interrupted_between_renames")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertEqual(self.marker(), "OLD")
        self.assertIn("The previous copy was restored", result.stderr)
        self.assertEqual(self.hidden_folders(), [])

    def test_an_interruption_during_the_final_check_puts_the_previous_copy_back(self) -> None:
        self.previous_copy(self.dest)
        result = self.adhoc("verify_interrupted")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertEqual(self.marker(), "OLD")
        self.assertEqual(self.hidden_folders(), [])

    def test_a_restore_that_fails_during_an_interruption_keeps_the_only_copy(self) -> None:
        self.previous_copy(self.dest)
        result = self.adhoc("interrupted_and_restore_fails")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        backups = self.backup_paths()
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.marker(backups[0]), "OLD")
        self.assertIn(f"It is at {backups[0]}", result.stderr)
        self.assertNotIn("was restored", result.stderr)
        self.assertEqual(self.hidden_folders(), [backups[0].parent.name])

    def test_a_failed_swap_reports_the_restore_it_made(self) -> None:
        self.previous_copy(self.dest)
        result = self.adhoc("swap_fails")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertEqual(self.marker(), "OLD")
        self.assertIn("The previous copy was restored", result.stderr)
        self.assertEqual(self.hidden_folders(), [])

    def test_a_failed_restore_names_the_backup_and_never_claims_success(self) -> None:
        self.previous_copy(self.dest)
        result = self.adhoc("swap_and_restore_fail")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(self.installed.exists())
        backups = self.backup_paths()
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.marker(backups[0]), "OLD")
        self.assertIn(f"It is at {backups[0]}", result.stderr)
        self.assertNotIn("was restored", result.stderr)

    def test_a_failed_swap_with_nothing_to_restore_says_so(self) -> None:
        result = self.adhoc("swap_fails")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertIn("no previous copy to restore", result.stderr)
        self.assertNotIn("was restored", result.stderr)

    def test_a_failed_final_check_rolls_back(self) -> None:
        self.previous_copy(self.dest)
        result = self.adhoc("verify_fails")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertEqual(self.marker(), "OLD")
        self.assertIn("The previous copy was restored", result.stderr)
        self.assertEqual(self.hidden_folders(), [])

    def test_a_failed_final_check_on_a_first_install_leaves_no_failed_copy(self) -> None:
        result = self.adhoc("verify_fails")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertIn("no previous copy to restore", result.stderr)
        self.assertEqual(self.hidden_folders(), [])

    def test_a_reader_dying_before_a_signal_cannot_stop_the_rollback(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_with_reader(scenario="reader_dies_then_interrupted")
        self.assertEqual(result.returncode, 143)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "OLD")
        self.assertEqual(self.hidden_folders(applications), [])

    def test_a_reader_dying_during_the_swap_does_not_stop_a_good_install(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_with_reader(scenario="reader_dies")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "NEW")
        self.assertIn(f"open {applications}/Hog Hunter.app", self.calls())
        self.assertEqual(self.hidden_folders(applications), [])

    def test_a_closed_stderr_cannot_stop_the_rollback(self) -> None:
        self.previous_copy(self.dest)
        env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.environ['PATH']}", SCENARIO="verify_fails")
        result = subprocess.run(
            ["/bin/bash", "-c", 'exec "$0" "$@" 2>&-', str(self.script), "--adhoc", "--dest", str(self.dest)],
            env=env,
            capture_output=True,
            text=True,
            cwd=self.dir,
        )
        self.assertEqual(result.returncode, 6, result.stdout)
        self.assertEqual(self.marker(), "OLD")
        self.assertEqual(self.hidden_folders(), [])

    def test_a_cleanup_failure_after_the_check_still_reopens_the_app(self) -> None:
        applications = self.production_previous_copy()
        self.stuck(applications / "Hog Hunter.app")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "NEW")
        self.assertIn(f"open {applications}/Hog Hunter.app", self.calls())
        self.assertIn("Warning: could not remove the previous copy", result.stderr)
        self.assertIn("Installed Hog Hunter", result.stdout)

    def test_a_leftover_that_cannot_be_removed_does_not_stop_the_install(self) -> None:
        applications = self.production_previous_copy()
        self.stuck(self.previous_copy(applications / ".hoghunter-previous.AAAAAA"))
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "NEW")
        self.assertIn(f"open {applications}/Hog Hunter.app", self.calls())
        self.assertIn("Warning: could not remove", result.stderr)

    def test_a_pre_rename_copy_that_cannot_be_removed_does_not_stop_the_install(self) -> None:
        applications = self.production_previous_copy()
        legacy = self.dir / "legacy"
        legacy.mkdir()
        (applications / "HogHunter.app").parent.mkdir(exist_ok=True)
        make_bundle(legacy).rename(applications / "HogHunter.app")
        self.stuck(applications / "HogHunter.app")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"open {applications}/Hog Hunter.app", self.calls())
        self.assertIn("Warning: could not remove the pre-rename copy", result.stderr)

    def test_a_copy_that_cannot_be_opened_is_reported_and_stays_installed(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_install(scenario="open_fails")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "NEW")
        self.assertIn("could not be opened", result.stderr)

    def test_an_interruption_after_the_check_keeps_the_new_copy_and_says_the_app_is_closed(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_install(scenario="interrupted_after_commit", RUNNING_PID="99999")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "NEW")
        self.assertIn("has not reopened it", result.stderr)
        self.assertNotIn("open ", self.calls())

    def test_a_previous_copy_that_will_not_move_aside_is_a_reported_failure(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_install(scenario="aside_fails", RUNNING_PID="99999")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "OLD")
        self.assertIn("could not move the previous copy aside", result.stderr)
        self.assertIn("was not changed", result.stderr)
        self.assertNotIn("no previous copy", result.stderr)
        self.assertIn("has not reopened it", result.stderr)
        self.assertEqual(self.hidden_folders(applications), [])

    def test_an_interruption_after_the_quit_says_the_app_is_closed(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_install(scenario="interrupted_after_quit", RUNNING_PID="99999")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "OLD")
        self.assertIn("was not changed", result.stderr)
        self.assertIn("has not reopened it", result.stderr)
        self.assertEqual(self.hidden_folders(applications), [])

    def test_a_staged_copy_that_fails_its_check_exits_six_before_the_quit(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_install(scenario="stage_check_fails")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertIn("the staged copy failed its check", result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "OLD")
        self.assertNotIn("osascript", self.calls())
        self.assertEqual(self.hidden_folders(applications), [])

    def test_an_interruption_during_a_first_install_check_leaves_no_unchecked_copy(self) -> None:
        result = self.adhoc("verify_interrupted")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertIn("no previous copy to restore", result.stderr)
        self.assertEqual(self.hidden_folders(), [])

    def test_the_failure_report_names_a_quit_only_when_something_was_running(self) -> None:
        applications = self.production_previous_copy()
        result = self.run_install(scenario="verify_fails")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertNotIn("quit the running", result.stderr)
        self.assertEqual(self.marker(applications / "Hog Hunter.app"), "OLD")
        result = self.run_install(scenario="verify_fails", RUNNING_PID="99999")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertIn("quit the running Hog Hunter and has not reopened it", result.stderr)

    def test_the_failure_report_names_a_pre_rename_copy_that_is_still_there(self) -> None:
        legacy_parent = self.dir / "legacy"
        legacy_parent.mkdir()
        self.dest.mkdir()
        make_bundle(legacy_parent).rename(self.dest / "HogHunter.app")
        result = self.adhoc("verify_fails")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertIn(f"The older copy at {self.dest}/HogHunter.app is still there", result.stderr)
        self.assertNotIn("no previous copy", result.stderr)
        self.assertTrue((self.dest / "HogHunter.app").is_dir())

    def test_a_hidden_only_copy_keeps_the_default_install_in_its_folder(self) -> None:
        system = self.use_fake_system_folder()
        hidden = self.previous_copy(system / ".hoghunter-previous.AAAAAA")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Destination: {system} ", result.stdout)
        self.assertIn(f"{hidden}, and nothing is installed", result.stdout)
        self.assertEqual(self.marker(system / "Hog Hunter.app"), "NEW")
        self.assertEqual(self.hidden_folders(system), [])
        self.assertFalse((self.home / "Applications").exists())

    def test_a_hidden_copy_in_the_other_folder_is_a_second_copy(self) -> None:
        system = self.use_fake_system_folder()
        hidden = self.previous_copy(system / ".hoghunter-install.AAAAAA")
        result = self.run_install("--dest", str(self.home / "Applications"))
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn(str(hidden), result.stderr)
        self.assertEqual(self.marker(hidden), "OLD")

        shutil.rmtree(hidden.parent)
        self.previous_copy(system)
        hidden = self.previous_copy(self.home / "Applications" / ".hoghunter-previous.BBBBBB")
        result = self.run_install()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn(str(hidden), result.stderr)

    def test_a_copy_in_a_subfolder_is_a_second_copy(self) -> None:
        system = self.use_fake_system_folder()
        nested = self.previous_copy(system / "Utilities")
        for arguments in ((), ("--dest", str(self.home / "Applications")), ("--dest", str(system))):
            with self.subTest(arguments):
                result = self.run_install(*arguments)
                self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
                self.assertIn(str(nested), result.stderr)
        self.assertEqual(self.marker(nested), "OLD")
        self.assertNotIn("xcodegen", self.calls())

    def test_a_copy_in_a_subfolder_of_the_user_folder_is_a_second_copy(self) -> None:
        self.use_fake_system_folder()
        nested = self.previous_copy(self.home / "Applications" / "Tools" / "Deep")
        result = self.run_install()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn(str(nested), result.stderr)

    def test_a_subfolder_holding_the_copy_can_be_updated_in_place(self) -> None:
        system = self.use_fake_system_folder()
        self.previous_copy(system / "Utilities")
        result = self.run_install("--dest", str(system / "Utilities"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.marker(system / "Utilities" / "Hog Hunter.app"), "NEW")

    def test_another_app_in_a_production_folder_is_not_a_copy(self) -> None:
        system = self.use_fake_system_folder()
        (system / "Other.app" / "Contents" / "Hog Hunter.app").mkdir(parents=True)
        self.previous_copy(self.home / "Applications")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_dry_run_describes_the_mode_it_was_given(self) -> None:
        result = self.run_install("--adhoc", "--no-launch", "--dry-run", "--dest", str(self.dest))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("leave the running Hog Hunter alone", result.stdout)
        self.assertIn("not launch it", result.stdout)
        self.assertNotIn("quit the running", result.stdout)

        self.use_fake_system_folder()
        result = self.run_install("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("quit the running Hog Hunter", result.stdout)
        self.assertIn("and launch it", result.stdout)
        result = self.run_install("--no-launch", "--dry-run")
        self.assertIn("leave it closed", result.stdout)
        self.assertNotIn("and launch it", result.stdout)

    def test_a_dry_run_warns_about_every_refusal_a_real_run_would_make(self) -> None:
        self.use_fake_system_folder()
        write_tool(self.bin, "security", "true\n")
        result = self.run_install("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("a real install would refuse, because there is no Developer ID", result.stdout)
        self.assertIn("would stop at the refusal", result.stdout)
        self.assertNotIn("Would sign", result.stdout)
        self.assertEqual(self.run_install().returncode, 3)

        write_tool(self.bin, "security", f"echo '  1) 0E9E8C80 \"{DEVELOPER_ID}\"'\n")
        nested = self.previous_copy(self.home / "Applications" / "Tools")
        result = self.run_install("--dry-run", "--dest", str(self.dest))
        self.assertIn(f"a copy already exists at {nested}", result.stdout)
        self.assertNotIn("Would sign", result.stdout)

    def leftovers(self) -> tuple[Path, Path, Path]:
        previous = self.previous_copy(self.dest / ".hoghunter-previous.AAAAAA")
        staged = self.previous_copy(self.dest / ".hoghunter-install.BBBBBB")
        empty = self.dest / ".hoghunter-previous.CCCCCC"
        empty.mkdir()
        return previous, staged, empty

    def test_a_later_run_reports_and_then_retires_what_an_interrupted_run_left(self) -> None:
        self.previous_copy(self.dest)
        previous, staged, empty = self.leftovers()
        result = self.adhoc()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for path in (previous, staged, empty):
            self.assertIn(str(path if path == empty else path), result.stdout)
        self.assertEqual(self.marker(), "NEW")
        self.assertEqual(self.hidden_folders(), [])

    def test_a_dry_run_reports_leftovers_and_leaves_them(self) -> None:
        previous, staged, _ = self.leftovers()
        result = self.run_install("--adhoc", "--dry-run", "--dest", str(self.dest))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("may be the only copy", result.stdout)
        self.assertEqual(self.marker(previous), "OLD")
        self.assertEqual(self.marker(staged), "OLD")

    def test_a_leftover_that_is_the_only_copy_survives_a_run_that_does_not_finish(self) -> None:
        previous = self.previous_copy(self.dest / ".hoghunter-previous.AAAAAA")
        for scenario in ("build_fails", "swap_fails", "verify_fails"):
            with self.subTest(scenario):
                result = self.adhoc(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("may be the only copy", result.stdout)
                self.assertEqual(self.marker(previous), "OLD")
                self.assertFalse(self.installed.exists())

    def test_an_ad_hoc_copy_leaves_the_production_app_running(self) -> None:
        self.previous_copy(self.dest)
        production = self.previous_copy(self.home / "Applications")
        running = subprocess.Popen(["/bin/sleep", "60"])
        self.addCleanup(running.wait)
        self.addCleanup(running.kill)
        result = self.adhoc(
            RUNNING_PID=str(running.pid),
            RUNNING_FROM=str(production / "Contents" / "MacOS" / "HogHunter"),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("osascript", self.calls())
        self.assertNotIn("pkill", self.calls())
        self.assertIsNone(running.poll(), "the production app was stopped")

    def test_an_ad_hoc_copy_stops_only_a_copy_running_from_its_own_destination(self) -> None:
        self.previous_copy(self.dest)
        running = subprocess.Popen(["/bin/sleep", "60"])
        self.addCleanup(running.kill)
        result = self.adhoc(
            RUNNING_PID=str(running.pid),
            RUNNING_FROM=str(self.installed / "Contents" / "MacOS" / "HogHunter"),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("osascript", self.calls())
        self.assertNotIn("pkill", self.calls())
        self.assertIn(f"pid {running.pid}", result.stdout)
        running.wait(timeout=10)


class SourceRuleTests(unittest.TestCase):
    def test_signing_failure_never_falls_back_to_ad_hoc(self) -> None:
        source = INSTALL.read_text()
        self.assertNotIn('sign_adhoc "Developer ID', source)
        self.assertNotIn('sign_adhoc "no Developer ID', source)
        self.assertNotIn('--sign "Developer ID Application"', source)

    def test_the_installer_checks_a_staged_copy_before_quitting_the_app(self) -> None:
        source = INSTALL.read_text()
        self.assertLess(source.index('check-mac-identity.sh" "$STAGED_PATH"'), source.index('echo "Quitting the running'))

    def test_a_release_checks_the_identity_it_signed(self) -> None:
        source = (ROOT / "scripts" / "mac-release-build.sh").read_text()
        self.assertIn('check-mac-identity.sh" --identity-only "$APP_BUNDLE"', source)

    def test_the_checks_expect_the_project_bundle_id(self) -> None:
        project = (ROOT / "project.yml").read_text()
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER: {BUNDLE_ID}\n", project)
        self.assertIn(f'EXPECTED_BUNDLE_ID="{BUNDLE_ID}"', CHECK.read_text())
        self.assertIn(f'EXPECTED_TEAM_ID="{TEAM}"', CHECK.read_text())
        self.assertIn(f'EXPECTED_TEAM_ID="{TEAM}"', INSTALL.read_text())

    def test_the_previous_app_is_kept_outside_the_staging_folder_until_the_new_one_is_verified(self) -> None:
        source = INSTALL.read_text()
        self.assertNotIn("previous.app", source)
        self.assertLess(source.index('mv "$INSTALLED_PATH" "$BACKUP_DIR/Hog Hunter.app"'), source.index('mv "$STAGED_PATH" "$INSTALLED_PATH"'))
        self.assertLess(source.index('if ! installed_copy_verifies'), source.index('SWAP_COMMITTED=1'))

    def test_the_release_signs_with_the_production_team_certificate(self) -> None:
        source = (ROOT / "scripts" / "mac-release-build.sh").read_text()
        self.assertIn(f"({TEAM})", source[source.index("resolve_codesign_identity() {"):source.index("short_version()")])

    def test_the_lane_sweep_probes_idleness_before_walking_for_keep_markers(self) -> None:
        source = (ROOT / "scripts" / "hoghunter-clean").read_text()
        block = source[source.index("def _hoghunter_lane_refusal"):]
        self.assertLess(block.index("touched_since(s,"), block.index("holds_keep_sentinel(s,"))

    def test_the_project_runs_the_location_script(self) -> None:
        self.assertIn("postGenCommand: scripts/xcodegen-post.sh", (ROOT / "project.yml").read_text())


class DerivedDataLocationTests(unittest.TestCase):
    def test_the_location_is_on_the_home_disk_and_per_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = Path(raw).resolve()
            locations = []
            for lane in ("one", "two"):
                scripts = base / lane / "scripts"
                scripts.mkdir(parents=True)
                shutil.copy(POST_GEN, scripts / POST_GEN.name)
                env = dict(os.environ, HOME=str(base / "home"))
                subprocess.run([str(scripts / POST_GEN.name)], env=env, check=True)
                found = list((base / lane).glob(
                    "HogHunter.xcodeproj/project.xcworkspace/xcuserdata/*.xcuserdatad/WorkspaceSettings.xcsettings"))
                self.assertEqual(len(found), 1)
                with open(found[0], "rb") as handle:
                    settings = plistlib.load(handle)
                self.assertEqual(settings["DerivedDataLocationStyle"], "AbsolutePath")
                locations.append(settings["DerivedDataCustomLocation"])
            for location in locations:
                self.assertTrue(location.startswith(str(base / "home" / "Library" / "Caches") + "/"))
            self.assertNotEqual(locations[0], locations[1])

    def test_a_home_with_xml_characters_still_writes_a_valid_plist(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            base = Path(raw).resolve()
            scripts = base / "lane" / "scripts"
            scripts.mkdir(parents=True)
            shutil.copy(POST_GEN, scripts / POST_GEN.name)
            home = base / "a&b<c>d"
            subprocess.run([str(scripts / POST_GEN.name)], env=dict(os.environ, HOME=str(home)), check=True)
            found = list((base / "lane").glob("HogHunter.xcodeproj/project.xcworkspace/xcuserdata/*/WorkspaceSettings.xcsettings"))
            with open(found[0], "rb") as handle:
                settings = plistlib.load(handle)
            self.assertTrue(settings["DerivedDataCustomLocation"].startswith(str(home) + "/Library/Caches/"))


if __name__ == "__main__":
    if sys.platform != "darwin":
        print("test-mac-identity.py needs macOS", file=sys.stderr)
        sys.exit(1)
    unittest.main()

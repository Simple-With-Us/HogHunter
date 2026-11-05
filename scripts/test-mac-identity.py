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

    def install(self, *arguments: str) -> subprocess.CompletedProcess:
        env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.environ['PATH']}")
        return subprocess.run([str(INSTALL), *arguments], env=env, capture_output=True, text=True)

    def assert_refused(self, result: subprocess.CompletedProcess, code: int, text: str) -> None:
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertIn(text, result.stderr)
        self.assertFalse(self.log.exists(), "the build started before the refusal")

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
        for destination in (f"{applications}", f"{applications}/", f"{applications}//", str(link)):
            result = self.install("--dest", destination)
            self.assertEqual(result.returncode, 42, destination + result.stdout + result.stderr)

    def test_the_production_identity_passes_the_gates(self) -> None:
        result = self.install()
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertTrue(self.log.exists())


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
        self.assertLess(source.index('mv "$STAGED_PATH" "$INSTALLED_PATH"'), source.index('rm -rf "$BACKUP_DIR"'))

    def test_the_release_signs_with_the_production_team_certificate(self) -> None:
        source = (ROOT / "scripts" / "mac-release-build.sh").read_text()
        self.assertIn(f"({TEAM})", source[source.index("resolve_codesign_identity() {"):source.index("short_version()")])

    def test_the_lane_sweep_probes_idleness_before_walking_for_keep_markers(self) -> None:
        source = (ROOT / "scripts" / "hoghunter-clean").read_text()
        block = source[source.index("lanes_root = HOME / _HOGHUNTER_DERIVED_DATA"):]
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

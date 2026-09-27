#!/usr/bin/env python3
"""Synthetic release checks; never contact Apple or read signing credentials."""

import copy
import datetime
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("validator", ROOT / "scripts/validate-ios-release.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def fixtures():
    entitlements = {
        "application-identifier": f"{validator.TEAM_ID}.{validator.BUNDLE_ID}",
        "com.apple.developer.team-identifier": validator.TEAM_ID,
        "get-task-allow": False,
        "beta-reports-active": True,
    }
    return [
        {"CFBundleIdentifier": validator.BUNDLE_ID, "CFBundleVersion": "42",
         "CFBundleShortVersionString": "1.0.1", "CFBundleSupportedPlatforms": ["iPhoneOS"],
         "CFBundlePackageType": "APPL"},
        {"TeamIdentifier": [validator.TEAM_ID], "Platform": ["iOS"],
         "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=30),
         "Entitlements": copy.deepcopy(entitlements)},
        entitlements,
    ]


class IdentityTests(unittest.TestCase):
    def test_valid_archive_and_store_export(self):
        for distribution in (False, True):
            self.assertEqual(validator.validate(*fixtures(), "42", distribution)["build"], "42")

    def test_reject_wrong_identity_and_profile(self):
        cases = [
            (0, "CFBundleIdentifier", "com.simplewithus.hoghunter.macos"),
            (0, "CFBundleVersion", "41"),
            (0, "CFBundleShortVersionString", "1.0.0"),
            (0, "CFBundleSupportedPlatforms", ["iPhoneSimulator"]),
            (0, "CFBundlePackageType", "BNDL"),
            (1, "TeamIdentifier", ["OTHERTEAM"]),
            (1, "Platform", ["OSX"]),
            (1, "ExpirationDate", datetime.datetime(2000, 1, 1)),
            (1, "ProvisionedDevices", ["synthetic-device"]),
            (1, "ProvisionsAllDevices", True),
            (2, "application-identifier", "OTHER.bundle"),
            (2, "com.apple.developer.team-identifier", "OTHERTEAM"),
            (2, "get-task-allow", True),
            (2, "com.apple.security.application-groups", ["group.mac-only"]),
            (2, "com.apple.developer.associated-domains", ["applinks:example.invalid"]),
        ]
        for index, key, value in cases:
            with self.subTest(key=key):
                values = fixtures()
                values[index][key] = value
                with self.assertRaises(ValueError):
                    validator.validate(*values, "42", True)
        for key, value in (("application-identifier", "wrong.bundle"),
                           ("get-task-allow", True), ("beta-reports-active", False),
                           ("com.apple.security.application-groups", ["group.mac-only"])):
            with self.subTest(profile_entitlement=key):
                values = fixtures()
                values[1]["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    validator.validate(*values, "42", True)


# Fake only the external tools.  The release shell and plist validator run unchanged.
FAKE_TOOL = r'''#!/usr/bin/env python3
import os, pathlib, plistlib, sys, zipfile
args = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ['HH_TEST_FIXTURES'])
def option(flag): return args[args.index(flag) + 1]
if name == 'xcodegen':
    pass
elif name == 'xcodebuild':
    if '-exportArchive' in args:
        dest = pathlib.Path(option('-exportPath')); dest.mkdir()
        info = plistlib.loads((root / 'info.plist').read_bytes())
        if os.environ.get('HH_TEST_BAD_EXPORT') == 'true': info['CFBundleVersion'] = '41'
        with zipfile.ZipFile(dest / 'HogHunter.ipa', 'w') as out:
            out.writestr('Payload/HogHunter.app/Info.plist', plistlib.dumps(info))
            out.writestr('Payload/HogHunter.app/embedded.mobileprovision', 'synthetic')
    else:
        assert option('-scheme') == 'HogHunterIOS'
        assert option('-destination') == 'generic/platform=iOS'
        assert 'CURRENT_PROJECT_VERSION=42' in args
        app = pathlib.Path(option('-archivePath')) / 'Products/Applications/HogHunter.app'
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes((root / 'info.plist').read_bytes())
        (app / 'embedded.mobileprovision').write_text('synthetic')
elif name == 'security':
    assert args[:2] == ['cms', '-D']
    sys.stdout.buffer.write((root / 'profile.plist').read_bytes())
elif name == 'codesign':
    if '-d' in args: sys.stdout.buffer.write((root / 'entitlements.plist').read_bytes())
elif name == 'xcrun':
    assert args[:2] == ['altool', '--upload-app']
    assert option('--p8-file-path') == os.environ['ASC_KEY_PATH']
    (root / 'upload-invoked').write_text('yes')
else:
    raise SystemExit('unknown synthetic tool')
'''


class ReleaseFlowTests(unittest.TestCase):
    def run_release(self, *, upload=False, bad_export=False, event="workflow_dispatch"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "bin"
            tools.mkdir()
            for name in ("xcodegen", "xcodebuild", "security", "codesign", "xcrun"):
                path = tools / name
                path.write_text(FAKE_TOOL)
                path.chmod(0o700)
            for name, value in zip(("info", "profile", "entitlements"), fixtures()):
                (root / f"{name}.plist").write_bytes(plistlib.dumps(value))
            key = root / "synthetic-key"
            key.write_text("synthetic-test-data")
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       GITHUB_ACTIONS="true", GITHUB_EVENT_NAME=event, GITHUB_REF="refs/heads/main",
                       ASC_KEY_ID="synthetic-id", ASC_ISSUER_ID="synthetic-issuer", ASC_KEY_PATH=str(key),
                       HH_BUILD_NUMBER="42", HH_TESTFLIGHT_UPLOAD=str(upload).lower(),
                       HH_TEST_BAD_EXPORT=str(bad_export).lower(), HH_TEST_FIXTURES=str(root),
                       RUNNER_TEMP=str(root), GITHUB_STEP_SUMMARY=str(root / "summary"))
            result = subprocess.run(["/bin/bash", str(ROOT / "scripts/ios-testflight-release.sh")],
                                    env=env, text=True, capture_output=True)
            uploaded = (root / "upload-invoked").exists()
            self.assertFalse(list(root.glob("hoghunter-release.*")), "release artifacts were not cleaned")
            return result, uploaded

    def test_export_only_never_uploads(self):
        result, uploaded = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(uploaded)
        self.assertIn("Upload was disabled", result.stdout)

    def test_explicit_upload_after_validation(self):
        result, uploaded = self.run_release(upload=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(uploaded)

    def test_invalid_export_stops_before_upload(self):
        result, uploaded = self.run_release(upload=True, bad_export=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(uploaded)
        self.assertIn("unexpected app build number", result.stderr)

    def test_push_event_is_rejected(self):
        result, uploaded = self.run_release(upload=True, event="push")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(uploaded)
        self.assertIn("guarded manual workflow", result.stderr)


if __name__ == "__main__":
    unittest.main()

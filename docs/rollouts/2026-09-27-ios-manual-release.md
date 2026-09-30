# Hog Hunter manual iOS release workflow

Prepared September 27, 2026.  This workflow preparation does not establish a
signed archive, an uploaded build, Apple beta approval, or an installable beta.
No signing or upload was performed while preparing it.

## Current state and remaining blockers

App Store Connect app `6816633156` uses `com.simplewithus.hoghunter.ios` and
version `1.0.4`.  External group `79295c7f-f69f-4614-9ed3-9a16691380ff` exists
with public link `https://testflight.apple.com/join/yrHXfqSR`, but had zero builds
when verified.  The [readiness record](2026-09-27-ios-testflight-readiness.md)
contains the saved Apple identity and reviewer setup.

The workflow requires repository variable `HH_IOS_TESTFLIGHT_ENABLED=true`.
It stays disabled while replacement ASC credentials and the HogHunter
repository's Infisical references are pending.  No repository secrets were
configured when this preparation began.  Do not use the previous ASC key.

Hog Hunter iOS has no App Group or Associated Domains entitlement.  The Mac
app's entitlements must not be copied into the iPhone target or provisioning
profile.  The existing iOS App Store profile is `6RSNAV8S3S`, for team
`CC8UTF7ATG`; the workflow lets Xcode resolve a current matching profile and
checks its embedded identity and expiration before upload.

## Configuration after the credential hold is cleared

Configure these GitHub repository secrets through the approved secret manager:

- `INFISICAL_PROJECT_ID`
- `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID`
- `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET`

The legacy `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` pair is a supported
fallback, not an additional requirement.  Give the machine identity access to
these Infisical `prod`, `/` entries:

- Replacement `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8`
- `IOS_DIST_P12_BASE64` and `IOS_DIST_P12_PASSWORD`

The key must have access to the Hog Hunter ASC app and the Apple development
resources needed for automatic provisioning.  The certificate must be an
existing valid Apple Distribution identity for team `CC8UTF7ATG`.  Credential
creation, revocation, and permission changes are separate owner-controlled work.

Only the ASC key file path and the key/issuer identifiers cross workflow steps.
The PEM is staged in a unique directory with permissions `700`, in a file with
permissions `600`.  P12 contents and password stay inside the load/import step;
the decoded P12 is removed after import.  Scalar signing fields and the login
token reject line breaks before masking.  Temporary keychain and key files are
removed by the cleanup step.  Signing material and release archives are not
published as workflow artifacts.

## First manual run

After the replacement credentials and access have been verified, enable the
repository variable and run **Hog Hunter iOS TestFlight (manual)** from `main`.
Use stable Xcode 26 or later on the hosted runner.  The workflow also rejects a
beta macOS host.  A push, PR, or schedule cannot trigger this release job.

1. Choose an unused positive numeric build number, up to 18 digits.  Leaving
   it blank uses the current UTC timestamp (`YYYYMMDDHHMM`), matching fleet standard build numbers.
2. Leave **upload** unchecked for the first archive/export validation run.
3. Inspect the run's non-secret identity summary and validation result.  A
   successful run validates the signed archive and exported IPA for the iPhone
   bundle, team, version, selected build number, platform, and profile expiry.
   Export additionally requires an App Store profile without development,
   device-limited, enterprise, or unexpected Mac-only entitlements.
4. To upload, dispatch explicitly with **upload** checked and the intended
   build number.  The same validation runs before the upload command.

The release script only runs inside this hosted manual workflow on `main`.
It builds scheme `HogHunterIOS`; it does not release the Mac app.  Existing
Mac and iOS Simulator CI remains separate.  The synthetic release tests use
fake external tools and cannot prove real signing or Apple acceptance.

## After an upload

A successful upload command is not evidence of a processed or approved beta.
Check ASC for the expected bundle/version/build, successful processing, export
compliance, beta description, What to Test, and review contact details.  Explain
that the reviewer needs a Mac running Hog Hunter on the same Wi-Fi with
**Share With iPhone** enabled and its pairing code.  The iPhone companion is a
read-only view of that Mac, with no hosted demo account.

Assign the eligible build to the existing external group, submit beta review
when required, and verify that the public TestFlight link offers the approved
build before advertising installation.  Leave
[HogHunter #22](https://github.com/jaywedgeworth22/HogHunter/issues/22) and board
`1dd567c8c0054e708882ee69e91c2652` open until that external release is verified.

## Checks requiring no signing credentials

```sh
bash -n scripts/ios-stage-asc-key.sh scripts/ios-appstore-gm-prepare.sh scripts/ios-testflight-release.sh scripts/test-ios-stage-asc-key.sh
bash scripts/test-ios-stage-asc-key.sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-ios-release.py
```

The Linux `release-safety` CI job runs these checks on PRs and `main`.

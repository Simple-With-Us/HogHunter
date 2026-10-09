# Shared vendor folders are not orphaned apps

Sat, Oct 4, 2026 (Kodus follow-up Fri, Oct 9, 2026)

## Context & Objective

Extreme Clean treated shared vendor Application Support containers (Google, Mozilla, Microsoft, MobileSync, CrashReporter) as leftovers from an uninstalled app.  Those folders hold live products.  Orphaned data is selected by default, so one Extreme clean could remove them.

Issue #67.  Branch `grok-build/hh-vendor-folders`.  PR #72.

### Agent-sync / handoff

`AGENT-SYNC.md` was read from the AI-Fleet-Coordinator mirror before this follow-up (canonical live path is unavailable on the cloud seat).  Pre-work `#agent-sync` claim: process failure — the cloud environment has `AGENT_SYNC_TOKEN` / `AGENT_SYNC_POST_TOKEN`, but `https://agent-sync.jays.services` exposes only `/health` (authenticated POST to `/post` returns 404) and no Zulip bot credentials (`ZULIP_EMAIL` / `ZULIP_API_KEY`) are present, so no `repo:`-first claim could be posted.  No claim id is invented.  Effort row and issue #67 remain the board reservation; Mac-side reconciliation can post the missing claim when Zulip credentials are available.

## Changes Made

- `Sources/Storage/DiskCleaner.swift` — `isSharedVendorContainer` (trimmed, case-insensitive), `holdsInstalledProduct` (normalized alphanumeric compare so a version-suffixed child such as `IntelliJIdea2024.2` matches installed `IntelliJ IDEA`), Application Support scan guards, injectable `homeDirectory` for scan-level tests.
- `scripts/clean.sh` — `scan_orphans` mirrors the vendor skip (with `strip()`), bundle-id suffix seeding, and normalized `holds_installed_product` child check.
- `Tests/HogHunterTests/DiskCleanerTests.swift` — helper coverage plus `testScanOrphanedDataSkipsVendorAndInstalledProductFolders` running real `scanOrphanedData` against a temp home.
- `docs/EFFORT-LOG.md` — in-progress / follow-up rows for this branch.

## Decisions & Trade-offs

The named vendor folders are skipped even when no child name matches an installed app.  A Google folder can hold Chrome data under a name the scanner does not treat as the app.  Skipping it means Extreme Clean will not offer that folder after every Google app is gone.  The files stay on disk until someone deletes them on purpose.

Any other Application Support folder is also skipped when one of its children matches an installed bundle id or app name.  The child compare is normalized (lowercase, non-alphanumerics stripped) and accepts a version-suffixed child, because `IntelliJIdea2024.2` never equals `IntelliJ IDEA` exactly and missing that match is the data-loss path.  Tokens of two or fewer characters are dropped as too generic.  The residual trade-off is under-reporting: a removed app's leftover that happens to contain a child matching a generic token is silently skipped.  That errs toward keeping data, which is the safe direction for a deleter.

## Verification State

Python helpers embedded in `scripts/clean.sh` (cloud Linux seat, Fri, Oct 9, 2026):

```text
$ python3 - <<'PY'   # compile SHARED_VENDOR + holds_installed_product from scripts/clean.sh
SYNTAX_CHECK exit=0
jetbrains_match True
brave_match True
brave_suffix_only_match True
unrelated_still_orphan False
whitespace_vendor_trim_ok
BEHAVIOR_CHECK exit=0
$ echo $?
0
```
(Saved under `/opt/cursor/artifacts/pr72-clean-sh-helpers.log`.)


Targeted Swift unit tests (prior macOS run recorded on the branch; cloud seat has no `xcodebuild`):

```text
$ xcodebuild -scheme HogHunter -destination 'platform=macOS' \
    -derivedDataPath /tmp/hh-orphan-dd test \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
    -only-testing:HogHunterTests/DiskCleanerTests/testSharedVendorFoldersAreNotOrphans
exit 0
```

Full build on this cloud seat:

```text
$ xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build
# not run: Linux VM, no Xcode / swift toolchain
# status: BLOCKED on hosted macOS CI (`.github/workflows/ci.yml`)
```

## Next Steps & Blockers

CI must run the full `HogHunterTests` suite including the scan-level orphan test before merge.  A Mac seat with Zulip credentials should post the deferred `repo: HogHunter` claim and reference its message id here.  The pull request stays In Progress until required checks pass and it merges.

## Zero-Code Findings

A helper that is correct in isolation can still be dead in the scan: the orphan guards only protect data if the scan loop actually consults them, so the regression test runs `scanOrphanedData` itself.  When the Swift and shell cleaners implement the same rule, fix both — `scripts/clean.sh scan_orphans` had the identical Application Support orphan rule without the guards.  Trim membership checks on both sides; a leading space in a folder name must not reopen the shared-vendor delete path from the CLI alone.

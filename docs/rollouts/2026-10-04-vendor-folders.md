# Shared vendor folders are not orphaned apps

Sat, Oct 4, 2026

Effort row: `grok-build/hh-vendor-folders`, issue #67.  State stays In Progress until the pull request merges.

## Why

Extreme Clean treated shared vendor Application Support containers (Google, Mozilla, Microsoft, MobileSync, CrashReporter) as leftovers from an uninstalled app.  Those folders hold live products.  Orphaned data is selected by default, so one Extreme clean could remove them.

## What changed

- `Sources/Storage/DiskCleaner.swift` — `isSharedVendorContainer`, `holdsInstalledProduct` (normalized compare so a version-suffixed child such as `IntelliJIdea2024.2` matches the installed `IntelliJ IDEA`), the Application Support scan, and an injectable `homeDirectory` for tests.
- `scripts/clean.sh` — `scan_orphans` mirrors the vendor skip and the child-name check; bundle-id suffixes are seeded as known names, matching the Swift scan.
- `Tests/HogHunterTests/DiskCleanerTests.swift` — `testSharedVendorFoldersAreNotOrphans`, plus `testScanOrphanedDataSkipsVendorAndInstalledProductFolders`, which runs the real `scanOrphanedData` against a temp home.
- `docs/EFFORT-LOG.md` — the in-progress row for this branch.
- `docs/rollouts/2026-10-04-vendor-folders.md` — this note.

## Decisions and trade-offs

The named vendor folders are skipped even when no child name matches an installed app.  A Google folder can hold Chrome data under a name the scanner does not treat as the app.  Skipping it means Extreme Clean will not offer that folder after every Google app is gone.  The files stay on disk until someone deletes them on purpose.

Any other Application Support folder is also skipped when one of its children matches an installed bundle id or app name.  The child compare is normalized (lowercase, non-alphanumerics stripped) and accepts a version-suffixed child, because `IntelliJIdea2024.2` never equals `IntelliJ IDEA` exactly and missing that match is the data-loss path.  Tokens of two or fewer characters are dropped as too generic.  The residual trade-off is under-reporting: a removed app's leftover that happens to contain a child matching a generic token is silently skipped.  That errs toward keeping data, which is the safe direction for a deleter.

## Verification

`xcodebuild -scheme HogHunter -destination 'platform=macOS' -derivedDataPath /tmp/hh-orphan-dd test CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -only-testing:HogHunterTests/DiskCleanerTests/testSharedVendorFoldersAreNotOrphans` exited 0.

The new `testScanOrphanedDataSkipsVendorAndInstalledProductFolders`, the `holdsInstalledProduct` normalization, and the `clean.sh` mirror need the macOS CI run — Swift does not compile on the agent VM.  The embedded Python in `scripts/clean.sh` was syntax-checked and its `holds_installed_product` logic exercised (JetBrains/Brave match, unrelated leftovers still surface, tiny tokens dropped).

## Next Steps & Blockers

CI must run the full `HogHunterTests` suite including the new scan-level test before merge.  The pull request stays In Progress until required checks pass and it merges.

## Zero-Code Findings

A helper that is correct in isolation can still be dead in the scan: the orphan guards only protect data if the scan loop actually consults them, so the regression test runs `scanOrphanedData` itself.  When the Swift and shell cleaners implement the same rule, fix both — `scripts/clean.sh scan_orphans` had the identical Application Support orphan rule without the guards.

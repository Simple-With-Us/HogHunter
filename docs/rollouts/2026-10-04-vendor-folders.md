# Shared vendor folders are not orphaned apps

Sat, Oct 4, 2026

Effort row: `grok-build/hh-vendor-folders`, issue #67.  State stays In Progress until the pull request merges.

## Why

Extreme Clean treated `~/Library/Application Support/Google`, `Mozilla`, `Microsoft`, `MobileSync`, and `CrashReporter` as leftovers from an uninstalled app.  Those folders hold live products.  Orphaned data is selected by default, so one Extreme clean could remove them.

## What changed

- `Sources/Storage/DiskCleaner.swift` — `isSharedVendorContainer`, `holdsInstalledProduct`, and the Application Support scan.
- `Tests/HogHunterTests/DiskCleanerTests.swift` — `testSharedVendorFoldersAreNotOrphans`.
- `docs/EFFORT-LOG.md` — the in-progress row for this branch.
- `docs/rollouts/2026-10-04-vendor-folders.md` — this note.

## Decisions and trade-offs

The named vendor folders are skipped even when no child name matches an installed app.  A Google folder can hold Chrome data under a name the scanner does not treat as the app.  Skipping it means Extreme Clean will not offer that folder after every Google app is gone.  The files stay on disk until someone deletes them on purpose.

Any other Application Support folder is also skipped when one of its children matches an installed bundle id or app name.

## Verification

`xcodebuild -scheme HogHunter -destination 'platform=macOS' -derivedDataPath /tmp/hh-orphan-dd test CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -only-testing:HogHunterTests/DiskCleanerTests/testSharedVendorFoldersAreNotOrphans` exited 0.

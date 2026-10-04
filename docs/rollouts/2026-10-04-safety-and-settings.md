# Hog Hunter safety and Settings fixes

Sat, Oct 4, 2026.  Seat GROK-BUILD.  Branch `grok-build/hh-safety-and-settings`.

## Why

A top-to-bottom review of `origin/main` (`1a07a87`) found bugs that the unit suite could not see.

- The iPhone companion treated the first TCP segment as a finished HTTP response, so a normal snapshot could fail pairing.
- A failed APFS snapshot still deleted files.  Trash items are removed permanently, so there is no Put Back for those.
- `scripts/clean.sh` put the file path inside an AppleScript string, and fell back to `rmtree` when Finder declined.
- The Settings Cleaner tab was tagged with a String while the tab selection is a `SettingsTab`.  That page never appeared.
- A paired iPhone could tame processes while "Allow iPhone to Quit" was off.
- An unattended regimen with no matching rules fell back to cleaning every selected item.

## What changed

- `CompanionHTTP.parseResponse` returns nil until `Content-Length` bytes have arrived.
- `DiskCleaner.clean` returns before any delete when the snapshot fails.
- `scripts/clean.sh` does the same, passes the path as an AppleScript argument, and leaves the file in place when Finder fails.
- Settings Cleaner is `SettingsTab.cleaner`.  The window is 720 pt so eight tabs fit.  The Cleaner form uses the same width as the other tabs.
- Remote tame returns 403 unless the quit opt-in is on.  The Settings label says quit or tame.
- `CleanRegimenRunner.pendingItems` skips when the rule set is empty or matches nothing.
- The network permission string says "Hog Hunter", which is the name in System Settings.

## Verification

Commands actually run are recorded in the PR.  The gate is `xcodegen generate` and `xcodebuild -scheme HogHunter -destination 'platform=macOS' test` with signing off, plus `python3 -m py_compile` of the embedded cleaner.

## Not in this change

- iOS widgets still have no App Group entitlement.  `scripts/validate-ios-release.py` rejects that entitlement on the iPhone signature, and the Sep 27 rollout forbids copying the Mac entitlements file.  Widgets stay empty until the App ID is updated on purpose.
- Remote quit and tame still key off pid alone.  The panel quit path rechecks start time.  The phone path does not.
- Issue #56's stat cards and a wired regimen schedule are still MiniMax's board item `c3b66968`.  The runner is not started from `HogStore`.
- PR #44's `--upload-package` change is not on main.  Main still uses `--upload-app` and stages `AuthKey_<id>.p8`.  The open review threads on #44 are about the package command, which main does not run.
- Extreme-clean orphan selection and `scripts/hoghunter-clean` log truncation stay open.

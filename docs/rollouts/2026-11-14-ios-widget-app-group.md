# iOS widget gets its App Group entitlement

Sat, Nov 14, 2026.  Seat MA.  Issue #65.

## Context & Objective

The Hog Hunter widget on the owner's iPhone has only ever drawn its empty state: the monitor icon, "Hog Hunter", and "Open Hog Hunter to see your Mac."  The owner reported it again today with a screenshot.

The cause is the one issue #65 has carried since the widget shipped in PR #33.  Neither the iPhone app nor the widget extension signs with the App Group entitlement, so the shared container for `group.com.simplewithus.hoghunter` does not exist on device:

- `project.yml` set `CODE_SIGN_ENTITLEMENTS` only on the Mac target.  The `HogHunterIOS` and `HogHunterWidgets` targets set none, and no iOS entitlements file existed in the repo.
- On the app side, `CompanionModel.storeSnapshotForWidgets` writes through `sharedWidgetDefaults()`, which is nil unless `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` exists.  Without the entitlement it never does, so the app silently writes no `last_snapshot` at all.
- On the widget side, `Provider.currentEntry()` reads that suite, finds nothing, and every family falls back to `EmptyWidgetView` with the "Open Hog Hunter to see your Mac." message.

The data path itself is sound: writer and reader share `CompanionSnapshot.swift`, the keys match (`last_snapshot`, `clean_status`, `last_clean_date`, `last_clean_bytes`), and the app does call `WidgetCenter.reloadTimelines(ofKind:)` once a write lands.  Only the container was missing.

## Changes Made

- `ios/HogHunterIOS.entitlements` — new.  The `com.apple.security.application-groups` entitlement naming `group.com.simplewithus.hoghunter`, and nothing else.
- `project.yml` — both iOS targets now set `CODE_SIGN_ENTITLEMENTS: ios/HogHunterIOS.entitlements`.  One file for both targets, so the app and the widget can never drift onto different groups.
- `scripts/test-ios-release.py` — the contract check `test_iphone_targets_carry_no_mac_entitlements` pinned the bug: it asserted the iPhone targets set no entitlements file and no file under `ios/` named the App Group.  That pin was the old release validator's entitlements guard, kept as a source check when the validator was removed in the Oct 2026 auto-ship change (see `docs/rollouts/2026-10-17-ios-auto-ship.md`).  The validator was this fleet's own tool, not Apple's; there is no record of Apple rejecting the group.  The check is rewritten to pin the new contract — both iPhone targets sign with the iOS entitlements file, never the Mac one, and the file names exactly the shared group — keeping the old check's real concern, which was only ever about the Mac entitlements file reaching the iPhone signature.  The Kody review round then tightened it further: the entitlements line is asserted exactly once in each target's own section of `project.yml`, not twice across the two combined, so a one-sided drift cannot pass.

No Swift changed.  The guards that gate widget writes and reloads on the container existing stay as they are; with the entitlement present they now pass.

## Decisions & Trade-offs

One shared entitlements file rather than one per target.  A group mismatch between app and widget is exactly this bug's shape, and a single file makes that mismatch impossible to reintroduce on one side only.

Nothing else was added to the file.  The iOS targets need no other entitlement today, and the Mac target's history with the associated-domains entitlement (see the root `HogHunter.entitlements`) is the standing lesson against adding entitlements speculatively.

## Verification State

Local only so far: the entitlements plist parses, `project.yml` parses, and `scripts/test-ios-release.py` passes with the rewritten contract check (40 tests, 1 skipped, the skip pre-existing).  Hosted CI must generate the project and build the `HogHunterIOS` scheme; this seat has no Xcode.

CI green is not on-device proof.  The widget can only be proven on a phone running a build signed with this entitlement.

## Next Steps & Blockers

- The App Group must be enabled on the two iOS App IDs (`com.simplewithus.hoghunter.ios` and `com.simplewithus.hoghunter.ios.widgets`) in the Developer portal.  The group already exists for the Mac App ID from the 2026-09-22 migration.  Signing is Automatic, so the TestFlight archive flow should register it; if it cannot, the archive fails at signing instead of shipping another empty widget.
- After the next TestFlight build is installed: open the app once so it writes a snapshot, then check the widget shows the Mac's name, CPU and RAM instead of the empty state.

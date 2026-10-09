# 2026-09-26 — iOS companion and app icon

Hog Hunter had no iPhone target.  The Sep 22 bundle migration even recorded that: a single macOS app, no iOS shell.  This rollout adds the companion and replaces the app icon on both platforms with the owner lockup.

Not App Store.  Not TestFlight.

## What the phone does

The iPhone app browses for `_hoghunter._tcp` on the local network.  The Mac advertises that service only while Settings → Share With iPhone is on.  The phone shows the list the Mac panel is already showing (Now, Past Hour, or Past 24 Hours, Apps or Processes, on the CPU scale the Mac is using).

The pairing code is an 8 character token stored on the Mac.  The phone sends it as `Authorization: Bearer`.  A wrong code gets 401 and does not receive the snapshot.  The code is not in the Bonjour TXT record.  TXT carries only `ver` and a stable `id` so the phone can find the same Mac after a restart changes the port.

> **Superseded on 2026-10-09.**  The two paragraphs above and the next line describe the first release.  The owner has since ruled that the phone reaches parity with the desktop app, mutations included.  The server now answers quit, tame, clean, exclusions, view, enroll and pair routes behind opt-ins, each phone has its own token instead of sharing the 8 character code as a bearer, and the shared code only reads.  See `docs/rollouts/2026-10-09-phone-parity-batch-1.md` for the current design.

~~There is no quit route.  The only path the server answers is `GET /v1/snapshot`.~~

Share With iPhone defaults to off.

## Icon

`Assets.xcassets/AppIcon.appiconset` and `ios/Assets.xcassets/AppIcon.appiconset` are rasterized from the square lockup.  No pre-applied squircle.  The menu bar extra is unchanged (flame plus CPU percent).

## Bundle identifiers

| Surface | Bundle ID |
|---|---|
| macOS app | `com.simplewithus.hoghunter.macos` |
| macOS tests | `com.simplewithus.hoghunter.macos.tests` |
| iOS app | `com.simplewithus.hoghunter.ios` |

Mac version 1.4.0 (build 6).  iOS version 1.0.0 (build 1).

## Owner follow-ups

Register `com.simplewithus.hoghunter.ios` in the Apple Developer portal before any signed device install or TestFlight.  The simulator build does not need that.  The App Group `group.com.simplewithus.hoghunter` is still unused.  The companion uses Bonjour, not the App Group.

## Verify

Mac unit tests passed on this machine (`xcodebuild -scheme HogHunter -destination 'platform=macOS' test`, exit 0), including the new snapshot and pairing-code tests.

The iPhone sources typecheck and compile with `swiftc` for `arm64-apple-ios17.0-simulator`.  A full `xcodebuild` of the iOS scheme did not finish here: asset compilation is waiting on `ibtoold`, and the new iOS 26.5 simulator's first boot never reached a ready `bootstatus`, so the app was not installed or screenshotted in this session.  CI builds `HogHunterIOS` for the generic iOS Simulator.

```bash
cd ~/apps/hoghunter-grok-build-ios
xcodegen generate
xcodebuild -scheme HogHunter -destination 'platform=macOS' -derivedDataPath build test CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme HogHunterIOS -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios build CODE_SIGNING_ALLOWED=NO
```

# Permission Prompts And Code Identity

Refs HH-214.

## Observed Problem

The owner's screen shows "HogHunter" would like to access files on a removable volume, over and over.  The owner requires every permission to persist across app updates.

## Cause, From The TCC Log

The dialog was reproduced under `log stream` by one hosted test, `HogFormatTests`, which reads no files, run with the default DerivedData on the external volume:

- `Failed to match existing code requirement for subject com.simplewithus.hoghunter.macos.development and service kTCCServiceSystemPolicyRemovableVolumes`, followed by the stored `cdhash H"6f22…"` and the new `cdhash H"9b9a…"`.
- `AUTHREQ_PROMPTING` for the same service and subject, with `binary_path=/Volumes/External/Excluded/Xcode/DerivedData/…/Debug/HogHunter.app/Contents/MacOS/HogHunter` and `requesting=com.apple.sandboxd`.

A Debug build is signed ad hoc, so its designated requirement is its own hash and the grant dies with the build.  It runs from the external volume because the Mac's global Xcode setting keeps DerivedData there.  The dialog says "HogHunter" because that is the `CFBundleName` Xcode generates from `PRODUCT_NAME` for Debug and Release alike, so a test host looks exactly like the installed app.

With the host on the internal disk, the same test raised only a `preflight=yes` request that answered `authValue=1`, and no `AUTHREQ_PROMPTING`.  A rerun on the external volume two minutes after that Allow did not prompt, because the requirement still matched, which fits the hash being what voids the grant.

The installed app is not the requester.  It made no removable-volume request during the streams, and it has had no kernel denial in the logged window.  Its Full Disk Access, Accessibility and Screen Recording rows in the system TCC database store exactly its current designated requirement, and System Settings lists its removable-volume grant as allowed.

## Changes

- `scripts/xcodegen-post.sh`, run by `options.postGenCommand`, gives each checkout a default DerivedData under `~/Library/Caches/HogHunterDerivedData`.  It writes the per-user workspace settings, because xcodebuild ignores that setting in `xcshareddata`.  An explicit `-derivedDataPath` still wins, which is what Release and CI use.  A project-level `SYMROOT` is not an option: Swift packages refuse legacy build locations.
- `CodeIdentityGuardTests` fails if a test host runs from `/Volumes`.
- `testThePhoneScreenWritesItsGapsAsNonBreakingSpaces` reads repository source, so it now skips on `/Volumes`, and CI still runs it.
- `scripts/check-mac-identity.sh` refuses anything but the production bundle id, Team ID CC8UTF7ATG, a Developer ID certificate and the exact designated requirement.  `scripts/mac-release-build.sh` runs it after signing, before notarization, so the Sparkle path cannot publish a changed identity.
- `scripts/install.sh` refuses, before building, to install without the team's Developer ID identity, to install ad hoc to a production folder, or to create a second copy.  A signing failure now stops the install instead of falling back to ad hoc.  It signs by full certificate name, checks a staged copy before it quits the running app, and swaps that copy in, because `ditto` merges into an existing bundle and can break its seal.  An ad hoc copy never launches: it carries the production bundle id, and a grant made to it would displace the real app's.
- `scripts/test-mac-identity.py` covers the check, the installer gates and the location script, and runs in the macOS CI job.

## What Code Cannot Do

An app cannot grant itself Full Disk Access or removable-volume access.  A grant survives an update only while the designated requirement is unchanged, which is what these checks protect.  Moving to another Team ID, or changing the bundle id, would still cost every grant once.

## Limits

- A checkout picks up the new location only after it has this change and runs `xcodegen generate`.  Lanes that have not rebased keep prompting until then.
- A Debug run with an explicit `-derivedDataPath` on `/Volumes` still prompts.  The guard test fails afterward; it cannot prevent that dialog.
- The dialog's name is unchanged.  `CFBundleName` in `macos/Info.plist` is overridden by the generated plist, so correcting it needs a build step of its own.

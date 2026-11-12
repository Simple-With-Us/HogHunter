# iPhone Parity, Batch 3 (HH-215)

Six small gaps between the phone and the Mac.  Every new snapshot field is optional, so an older Mac or phone decodes the other's snapshot without change.  No regimen control, APFS thinning, non-full Maintain kind, opt-in, webhook change or push alert is added here.

## What Changed

| Gap | Snapshot | Change route | Opt-in |
|---|---|---|---|
| Space by kind of data | `storage.categoryTotals`, plain snapshot | none | none (read) |
| Standard cleanable | `storage.standardCleanableText` and `standardCleanableBytes`, plain snapshot | none | none (read) |
| Custom scripts | `maintain.customScripts`, detailed snapshot | none, read only | Run Maintenance |
| Step toggles and thresholds | `maintain.stepSettings` and `maintain.tuning`, detailed snapshot | `POST /v1/maintain/settings` | Run Maintenance |
| Temp file minimum hours | `storage.tempFileMinimumHours`, plain snapshot | `POST /v1/clean/settings` | Run Disk Cleaner |
| Launch at Login | `settings.launchesAtLogin`, plain snapshot | `POST /v1/settings`, field `launchesAtLogin` | Change Exclusions & View |

Both new routes need a phone's own token from the local network or Tailscale, take a JSON body and no query, and are applied whole or not at all.

## Decisions

**Category totals.**  The Storage tab sums the slices of the apps it lists (25).  The phone's app scan already runs on a five minute cache for the top apps, so the same walk now also yields the totals, with `StorageStore.categoryTotals` as the one place that sums them.  Nothing new is scanned.

**Standard cleanable.**  The field already existed and no view read it, but the Mac never filled it.  It is now the total of a Standard scan the Mac holds for the phone, and only while that scan is younger than the scan lifetime (30 minutes).  A snapshot never starts a scan, an Extreme scan is never reported as a Standard number, and the phone shows no line when the Mac holds no current Standard scan.

**Custom scripts.**  Name, on or off, mode and scope.  Not the path, the argument list or the owner, which can name folders and accounts.  On or off is `MaintainStore.isStepEnabled(script.id)`.  Read only: enabling a custom script runs code the phone has never seen.

**Step toggles and thresholds.**  The route refuses any key that is not a built-in step id in `MaintainStore.catalog`, which is the whole rule that keeps custom scripts Mac-only.  The Mac's disk threshold and PM2 cap were limited only by their sliders, so `CompanionMaintainLimits` now holds the range and step and the Mac's sliders, the worktree stepper, `MaintainStore`'s stored-value check and the route all read it.  The step that includes the remote server (`coolify_remote`) is a built-in toggle, so it is allowed.  Turning it on needs `acknowledgeRemoteServer: true` in the body as well as the phone's confirmation, which says it connects to the remote server over SSH on every Maintain run, including runs the Mac starts by itself, and cleans package caches, rotated backup logs and unused build cache there.  A step in the snapshot's `stepSettings` is listed only when the Mac lists it, so the remote step stays hidden until a host is set.  Each change on the phone confirms, and a threshold is changed with a draft and Apply, so one tap on the stepper does not ask a question per notch.  A Mac with no Maintain status yet still sends a minimal status with the settings, so a fresh Mac can be set up from the phone.

**Temp file minimum.**  `POST /v1/clean/settings` is its own route, field limited to `tempFileMinimumHours`, rather than a field on `POST /v1/settings`: that route is behind the edit opt-in and this value decides which files a clean offers to delete, so it belongs under the cleaner opt-in.  The floor is the Mac's own, one hour, enforced by `TempFileSafetyPolicy.isValid` (whole hours, 1 to 8,760), and the Settings stepper reads the same constant.  A scan already held for the phone is dropped by the existing policy revision check, as it is for a change at the Mac.

**Launch at Login.**  The field rides on `POST /v1/settings` under its existing opt-in.  The Mac sets the login item to a state instead of flipping it, so a phone that asks for what the Mac already has changes nothing.  macOS can refuse or ask for approval, so the snapshot reports the state read back and the phone shows that.

## Tests

`Tests/HogHunterTests/CompanionPhoneParityThreeTests.swift` covers the validators and their bounds, the routes' opt-ins, network rule, bad shapes and query refusal, the whole-or-nothing rule, the custom script refusal, the remote server acknowledgement, disclosure (custom script paths never reach the snapshot, and the detailed fields never reach the plain one), and the older-Mac decode.  The store tests inject the maintain launcher, the login item and the temp file saver, so none touches the real script, login items or cleaner settings.

## Not Verified

The phone screens were built for the iOS Simulator and not driven against a live Mac in this change.  The Mac's real login item registration and the Infisical write-through for a step toggle follow the existing calls and were not exercised.

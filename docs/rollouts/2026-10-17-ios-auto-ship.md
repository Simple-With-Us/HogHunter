# Hog Hunter iOS auto-ship through the fleet script

Owner request, Saturday, October 17, 2026:  bring every TestFlight app up to date, add deploy checks, and make the apps update automatically from now on.  Linear HH-157.  Contract:  a merge to `main` that touches the iPhone companion's native tree uploads a fresh TestFlight build with no human step.

## What the audit found, and what changed

| Finding | Result |
|---|---|
| Marketing version 1.0.6 reused on at least six uploads, because the old release script read it from `project.yml` and never bumped it | Fixed.  The fleet script takes the highest `1.0.N` in App Store Connect and adds one (today that is 10, so the next ship is 1.0.11).  The build number is the UTC cut time, `YYYYMMDDHHmm`.  `project.yml` is not edited:  it is in the Mac release workflow's push paths, and the shipped version is passed to `xcodebuild`, as for every other fleet app. |
| No What to Test | Fixed.  The ship step sets `IOS_TF_RELEASE_NOTES=1`.  The notes are rendered from the commits since the last ship, with agent names and seat tags dropped, and the stamp on the owner's clock (`Wed, Aug 12, 2026 at 1:15am`). |
| No ensure-tf-ready | Fixed.  The fleet script runs it on the exact uploaded build.  `ios/Info.plist` already declares `ITSAppUsesNonExemptEncryption` as false, so `project.yml` needs no new key and was left alone. |
| ASC key came from repository secrets, then the HogHunter Infisical project, not Fleet-OPS `/asc` | Fixed.  `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` come from Fleet-OPS prod `/asc`, as in the other fleet ship workflows.  The same-named repository secrets are no longer read.  The Apple Distribution certificate stays in repository secrets. |
| Paths filter missed shared sources | Fixed.  See below. |
| No rate gate | Fixed.  The fleet script's gate (one upload per hour, skip a HEAD already shipped) is on, with its state restored and saved through `actions/cache`.  Nothing sets `IOS_TF_MIN_INTERVAL_SEC` or `--force-ship`. |

## The native tree

`on.push.paths` lists `ios/**`, `project.yml`, and the shared Mac sources the iOS targets compile (`project.yml`, targets `HogHunterIOS` and `HogHunterWidgets`):

- `Sources/Companion/CompanionSnapshot.swift`, `CompanionHTTP.swift`, `CompanionPeer.swift`
- `Sources/UI/CpuSparklineView.swift`
- `Sources/Telemetry/SentryTelemetry.swift`

They are exact files, not `Sources/Companion/**`.  Most of `Sources/Companion` is the Mac companion server, and an edit there changes nothing in the iPhone binary, so a glob would turn Mac-only commits into TestFlight builds.  `scripts/test-ios-release.py` reads the two target source lists from `project.yml` and fails if any of them would not start a push run, or if the scheduled gate's prefixes drift from the push paths.  The root `Assets.xcassets` is Mac only and was dropped from the filter (a bare directory name matched no file anyway).

The ship machinery is in the filter too (`scripts/ios-*.sh`, `scripts/ios-fleet/**`, the workflow, the Infisical action), so a fix to it is proven by a real ship.

## Triggers

- `push` to `main` with the paths above.
- `workflow_dispatch` with one input, `upload` (default true).  `upload=false` archives and exports without uploading, loads no Sentry secret, writes no ship state, and is the one run allowed from a branch.  The TestFlight freshness check dispatches with `-f upload=true`, so the input name must stay.
- `schedule`, hourly at :41.  It carries `scripts/ios-fleet/scheduled-ship-gate.sh`, which skips unless a native path changed since the last successful ship, so a tick with nothing to ship exits in seconds.  It exists because a PR merged by a bot lands under GitHub's recursion guard and starts no push run, and a push run that failed is never retried.

The repository variable `HH_IOS_TESTFLIGHT_ENABLED` still gates every trigger.

## The vendored fleet files

`scripts/ios-fleet/` is a copy of the Mac fleet tooling (the `ios-fleet` directory on the fleet Mac) so a hosted runner can use it, as in the other fleet repos:

| File | Source | Change |
|---|---|---|
| `ship-testflight.sh`, `ExportOptions-*.plist` | Mac canonical | none |
| `asc-api.mjs` | Mac canonical | `centralTimestamp` drops the ` CT` suffix and writes `am` or `pm` in lower case (the canonical copy still breaks the no-timezone-abbreviation rule);  the agent filter also covers `minimax`, `clutch`, `opencode` and the bracketed tags `[MM]`, `[MC]`, `[MA]`, `[FX]`, `[DSH]`, `[JET]`, `[GROK-WEB]`;  a failed export-compliance PATCH in `ensure-tf-ready` still publishes What to Test before it exits 2 (the canonical copy exits first, and the ship script records the ship, so the notes were lost) |
| `scheduled-ship-gate.sh`, `test-scheduled-ship-gate.sh` | CodeCaps | none |
| `apps.json` | new | the `hoghunter` row only, with `xcodegenDir` set to `.` because the Xcode project is generated and not committed |

Left out on purpose:  `publish-ios-versions.sh` (it writes the public version manifest through `gh` and needs a token a hosted runner does not hold;  the fleet script logs a non-fatal warning), the icon audit, and `build-window.sh`.

## Removed

`scripts/ios-testflight-release.sh` and `scripts/validate-ios-release.py` (the old custom archive, validate and altool upload).  The validator compared the archive to the version in `project.yml`, which the fleet script deliberately overrides.  Its entitlements guard is kept as a source check in `scripts/test-ios-release.py`.

## Verification

- `bash scripts/test-ios-stage-asc-key.sh`, `bash scripts/ios-fleet/test-scheduled-ship-gate.sh` and `python3 scripts/test-ios-release.py` run in the Linux `release-safety` job.
- `bash scripts/ios-ship-testflight.sh --dry-run` (locally, with the state directory pointed at a scratch folder) prints the plan:  `seq sources: local=0 asc=10`, shipping `1.0.11`.
- An `upload=false` dispatch from the PR branch archives and exports on a hosted runner, which proves signing with the Fleet-OPS key and the xcodegen path before `main` switches over.
- After the merge, the fleet TestFlight freshness check (`ios_testflight_freshness.mjs --app hoghunter`, in the Mac fleet tooling) reports `current`.

## Follow-ups

Next steps after the merge:

- Watch the first push run and the first hourly scheduled ticks:  a tick with no native change must exit at the gate, and a second upload inside the hour must be skipped by the rate gate.
- Confirm in App Store Connect that the first build lands as `1.0.11` with What to Test published and export compliance declared, then run the freshness check above.  Issue #22 stays open until the external release is verified.
- Upstream the third `asc-api.mjs` patch (What to Test survives a failed compliance PATCH) and the timezone-free stamp to the canonical fleet copy, so the other fleet apps get them and this copy can return to two patches or none.
- The release-notes tie-break prefix is derived from `projectRel`, which is `.` here because the project is generated at the repository root, so past ten bullets every commit counts as iPhone work and the newest ten are kept.  A per-app prefix list belongs in the canonical `ship-testflight.sh`;  the vendored copy stays identical to it.

Blockers:  none known.  The org machine identity and the org secret `INFISICAL_FLEET_OPS_PROJECT_ID` are already shared with this repository, and they are the pair ContactLogo reads `/asc` with.

## Rollback

Set the repository variable `HH_IOS_TESTFLIGHT_ENABLED` to anything but `true` to stop every trigger, or revert the PR to restore the previous script.  Previous builds stay in TestFlight either way.

# Widget Clean tap reaches a cold launch

Sat, Oct 4, 2026.  Kodus follow-up Tue, Oct 13, 2026.  Seat GROK-BUILD.  Branch `grok-build/hh-widget-clean`.  Pull request #71.

## Context & Objective

The small widget sent every tap to `hoghunter://clean`.  A cold launch set a flag that only `.onChange` inside the dashboard consumed, so the confirm dialog never appeared if the dashboard was created with the flag already set.  A later review also asked for a screenshot of that path, a handoff with the standard sections, and a guarantee that the link itself does not clean the Mac.

Issue #65 stays open for the App Group.  This change does not add the entitlement.

## Changes Made

- `ios/Widgets/HogHunterWidgetViews.swift` — widget SwiftUI, including the small widget's Clean pill (`hoghunter://clean`) and `widgetURL` `hoghunter://open` on the rest of the widget.  `Provider.sampleEntry()` is the screenshot fixture.
- `ios/Widgets/HogHunterWidgets.swift` — WidgetKit `@main` entry only.
- `ios/Sources/CompanionDeepLink.swift` — `hoghunter://clean` is `confirmClean`.  There is no run-clean case.  `CleanRequest.isFresh` expires a pending confirm after 30 seconds.
- `ios/Sources/HogHunterIOSApp.swift` — `onOpenURL` calls `requestCleanDialog()` only when the link asks for confirmation.
- `ios/Sources/CompanionModel.swift` — `takeCleanRequest()` uses that expiry and clears the flag either way.  `-HogHunterCleanConfirm` with `-HogHunterSample` sets the request before the dashboard exists.
- `ios/Sources/CompanionViews.swift` — consumes the request on appear and on change.  Run Safe Clean is the only call to `triggerRemoteClean()`.  `-HogHunterWidgetPreview` draws the widget views.
- `project.yml` — the iOS app compiles the widget views (not `@main`).  The Mac test bundle compiles `CompanionDeepLink.swift`.
- `scripts/ios_screenshot_checks.py` — PNG frame check and the simctl command list.
- `scripts/capture-app-screenshots.sh` — on the booted simulator, requires the embedded `HogHunterWidgets.appex`, a widget-preview frame, a cold-start confirm frame, and `xcrun simctl openurl <udid> hoghunter://clean` followed by `xcrun simctl io <udid> screenshot`.
- `scripts/test-ios-screenshot-checks.py` — Linux check of those rules.
- `.github/workflows/ci.yml` — `release-safety` runs that Linux check.  The macOS `test` job already runs `scripts/capture-app-screenshots.sh`.
- `.github/workflows/screenshots.yml` — the manual lane runs the same openurl and screenshot commands.
- `docs/rollouts/2026-10-04-widget-clean-tap.md` — this note.

`docs/EFFORT-LOG.md` is archived and read-only, so this follow-up does not add a row.

## Decisions & Trade-offs

The dashboard consumes the clean request on appear as well as on change.  A cold launch creates the dashboard with the flag already set, so `.onChange` alone never fires.  The request is one-shot (cleared after consumption) so a later re-appear does not re-show the dialog.  It expires after 30 seconds so a link that arrives while the Mac is unreachable is not replayed when the Mac reconnects.

Only the small widget's Clean pill links to `hoghunter://clean`, not the whole widget surface.  Taps anywhere else open the app with no side effects.  The trade-off is that tapping the widget body does not start the clean flow.

The link classifier has no run-clean case.  `hoghunter://clean` only presents the confirmation.  The Mac is cleaned only if the person taps Run Safe Clean, the phone holds its own token, and the Mac's Allow iPhone to Run Disk Cleaner opt-in is on (owner ruling 2026-10-09 in `AGENTS.md`).  Removing the route would drop the cold-start Clean pill this pull request exists to fix.

Timeline reloads are rate limited to the widget's 5-minute policy, and they are forced when `clean_status`, `last_clean_date`, or `last_clean_bytes` change.  A write into a missing App Group does not reload.

The screenshot host draws the same SwiftUI the extension uses, with `Provider.sampleEntry()`, because issue #65 still blocks live App Group data.  `simctl` cannot place a widget on SpringBoard, so the lane checks that `HogHunterWidgets.appex` is embedded and then screenshots that host.  `simctl io` is given the booted simulator's udid rather than the word `booted`, because a runner can have more than one simulator.

The macOS `test` job still runs the screenshot script under the existing 8-minute cap with `continue-on-error`.  A hung simulator must not cancel the required `test` check.  The frame rules themselves fail the script, and the Linux test of those rules runs in `release-safety`.

## Verification State

| Command | Result |
|---|---|
| `python3 scripts/test-ios-screenshot-checks.py` | PASS (exit 0, 5 tests, Linux seat 2026-10-13) |
| `bash -n scripts/capture-app-screenshots.sh` | PASS (exit 0, Linux seat 2026-10-13) |
| `xcodegen generate` | NOT RUN.  No Xcode on this Linux seat.  macOS CI runs it. |
| `xcodebuild -scheme HogHunter -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -only-testing:HogHunterTests/CompanionDeepLinkTests` | NOT RUN here.  PENDING on the GitHub Actions `test` job. |
| `xcodebuild -scheme HogHunter -destination 'platform=macOS' -derivedDataPath build test CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""` | NOT RUN here.  PENDING on the `test` job.  Last green for the previous head `9801fac` was Actions run 38388752022. |
| `xcodebuild -scheme HogHunterIOS -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -quiet` | NOT RUN here.  PENDING on the `test` job (Build iOS companion).  Same previous run was green before this follow-up. |
| `bash scripts/capture-app-screenshots.sh` (`xcrun simctl openurl` `hoghunter://clean`, then `xcrun simctl io <udid> screenshot`) | NOT RUN here.  No simulator.  The `test` job runs it and continues on error so a hang cannot cancel the required check. |

## Next Steps & Blockers

- Issue #65: the iPhone app and the widget extension still do not share the App Group entitlement.  Widgets stay empty until that group exists in the Apple Developer portal.  The screenshot host uses sample data so the Clean pill can be seen anyway.
- Hosted macOS CI must compile `HogHunterIOS` and `CompanionDeepLinkTests`.  This seat cannot.
- `recall contribute` was not stored.  See Fleet Recall.  The paragraph below is the lesson.

## Zero-Code Findings

A cold-launched SwiftUI view never sees the `.onChange` a warm view would.  Any launch flag consumed only by `.onChange` is dead on cold start.  Consume one-shot launch intents on appear too, and stamp them so they expire if the view that consumes them does not exist yet.

While the App Group entitlement is missing (issue #65), `UserDefaults(suiteName:)` writes do not reach the widget.  Scheduling a reload around a write that cannot land is wasted work.  Gate the reload on the write succeeding, and do not treat a byte-for-byte snapshot compare as a change detector when the payload includes `sampledAt` and live CPU and memory.

## Fleet Recall

Searched on 2026-10-13 from this seat.  `recall` is not on PATH.  `GET https://recall.jays.services/health` returned ok (`fleet-recall-service` 1.0.0, collection `fleet-agents`, `backend_ok` true).  `POST /recall/search` returned 401 unauthorized.  This seat has no recall API key, so these queries were not answered by the corpus and `recall contribute` could not be stored:

- `recall 'WidgetKit App Group UserDefaults suiteName no-op' --app hoghunter --limit 5`
- `recall "SwiftUI cold launch onChange one-shot launch intent" --app hoghunter --limit 5`

A search of `docs/rollouts/` found no earlier HogHunter note of either lesson.  One reusable paragraph:

A SwiftUI launch flag observed only with `.onChange` is dropped when the view is created with the flag already set, so a one-shot deep link has to be consumed on appear as well, and it needs an expiry because the view that consumes it may not exist until a later phase change.

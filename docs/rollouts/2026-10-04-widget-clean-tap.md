# Widget Clean tap reaches a cold launch

Sat, Oct 4, 2026.  Kodus follow-up Wed, Oct 14, 2026.  Seat GROK-BUILD.  Branch `grok-build/hh-widget-clean`.  Pull request #71.

## Context & Objective

The small widget sent every tap to `hoghunter://clean`.  A cold launch set a flag that only `.onChange` inside the dashboard consumed, so the confirm dialog never appeared if the dashboard was created with the flag already set.  A later review also asked for a screenshot of that path, a handoff with the standard sections, and a guarantee that the link itself does not clean the Mac.

Issue #65 stays open for the App Group.  This change does not add the entitlement.

## Changes Made

- `ios/Widgets/HogHunterWidgetViews.swift` — widget SwiftUI, including the small widget's Clean pill (`hoghunter://clean`) and `widgetURL` `hoghunter://open` on the rest of the widget.  `Provider.sampleEntry()` is the screenshot fixture.
- `ios/Widgets/HogHunterWidgets.swift` — WidgetKit `@main` entry only.
- `ios/Sources/CompanionDeepLink.swift` — `hoghunter://clean` is `confirmClean`.  There is no run-clean case.  `CleanRequest.isFresh` expires a pending confirm after 30 seconds.
- `ios/Sources/HogHunterIOSApp.swift` — `onOpenURL` calls `requestCleanDialog()` only when the link asks for confirmation.
- `ios/Sources/CompanionModel.swift` — `takeCleanRequest()` uses that expiry and clears the flag either way.  `triggerRemoteClean()` returns without calling the Mac when `remoteCleanAllowed` is not true.  Widget writes go through `sharedWidgetDefaults()`, which is nil unless `containerURL(forSecurityApplicationGroupIdentifier:)` exists.  `-HogHunterCleanConfirm` with `-HogHunterSample` sets the request before the dashboard exists.
- `ios/Sources/CompanionViews.swift` — consumes the request on appear and on change.  The destructive confirmation is offered only when `CleanLinkPolicy.mayOfferCleanConfirmation` is true.  Otherwise the dashboard shows `CleanLinkPolicy.cleanOffNote` and does not call `triggerRemoteClean()`.  Run Safe Clean is the only call to `triggerRemoteClean()`.  `-HogHunterWidgetPreview` draws the widget views.
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

The link classifier has no run-clean case.  `hoghunter://clean` only asks to present the confirmation, and that confirmation is offered only when `remoteCleanAllowed == true`.  A missing or false opt-in shows the same off note as the storage screen and does not call `triggerRemoteClean()`.  The Mac is cleaned only if the person taps Run Safe Clean, the phone holds its own token, and the Mac's Allow iPhone to Run Disk Cleaner opt-in is on (owner ruling 2026-10-09 in `AGENTS.md`).  Removing the route would drop the cold-start Clean pill this pull request exists to fix.

Timeline reloads are rate limited to the widget's 5-minute policy, and they are forced when `clean_status`, `last_clean_date`, or `last_clean_bytes` change.  Persistence and reloads both require `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.  A missing App Group does not reload.  `UserDefaults(suiteName:)` is not treated as proof the write reached the widget.

The screenshot host draws the same SwiftUI the extension uses, with `Provider.sampleEntry()`, because issue #65 still blocks live App Group data.  `simctl` cannot place a widget on SpringBoard, so the lane checks that `HogHunterWidgets.appex` is embedded and then screenshots that host.  `simctl io` is given the booted simulator's udid rather than the word `booted`, because a runner can have more than one simulator.

The macOS `test` job still runs the screenshot script under the existing 8-minute cap with `continue-on-error`.  A hung simulator must not cancel the required `test` check.  The frame rules themselves fail the script, and the Linux test of those rules runs in `release-safety`.

## Verification State

| Command | Result |
|---|---|
| `python3 scripts/test-ios-screenshot-checks.py` | PASS (exit 0, 5 tests, Linux seat 2026-10-14) |
| `bash -n scripts/capture-app-screenshots.sh` | PASS (exit 0, Linux seat 2026-10-14) |
| `bash scripts/test-ios-stage-asc-key.sh`, `python3 scripts/test-ios-release.py`, `python3 scripts/test-sentry-ci-report.py`, `python3 scripts/test-sentry-wiring.py`, `python3 scripts/test-hoghunter-clean.py`, `python3 scripts/test-robotic-vacuum.py` | PASS (Linux seat 2026-10-14, the `release-safety` script set) |
| `xcodegen generate` | PASS on Actions run 38508049736 (`test` job, commit `a530c81`, step Generate project).  This Linux seat has no Xcode.  The follow-up commit re-runs that job. |
| `xcodebuild -scheme HogHunter -destination 'platform=macOS' test` (the `test` job's Build and test step, which includes `CompanionDeepLinkTests`) | PASS on Actions run 38508049736, commit `a530c81`.  Not run on this seat.  The follow-up commit re-runs that job. |
| `xcodebuild -scheme HogHunterIOS -destination 'generic/platform=iOS Simulator' build` | PASS on Actions run 38508049736, commit `a530c81`, step Build iOS companion.  Not run on this seat.  The follow-up commit re-runs that job. |
| Headless UI smoke (`-HogHunterUISmoke`) | PASS on the same run. |
| `bash scripts/capture-app-screenshots.sh` | On run 38508049736 the script saved `screenshots/ios/widget-small.png`, `clean-cold-start.png`, and `clean-deep-link.png` (the `simctl openurl` of `hoghunter://clean`).  The 8-minute cap then terminated the script.  The step stays `continue-on-error` so a hang cannot cancel the required `test` check. |

## Next Steps & Blockers

- Issue #65: the iPhone app and the widget extension still do not share the App Group entitlement.  Widgets stay empty until that group exists in the Apple Developer portal.  The screenshot host uses sample data so the Clean pill can be seen anyway.  Until the container exists, this build does not reload the widget timeline.
- Hosted macOS CI must compile `HogHunterIOS` and `CompanionDeepLinkTests` again for this follow-up.  This seat cannot.
- One lesson was stored.  See Fleet Recall.  It is not a copy of this note.

## Zero-Code Findings

A cold-launched SwiftUI view never sees the `.onChange` a warm view would.  Any launch flag consumed only by `.onChange` is dead on cold start.  Consume one-shot launch intents on appear too, and stamp them so they expire if the view that consumes them does not exist yet.  That paragraph is the contributed lesson below.  It was not already in the corpus.

While the App Group entitlement is missing (issue #65), the widget cannot see the phone's defaults.  Gate persistence and timeline reloads on `containerURL(forSecurityApplicationGroupIdentifier:)` being non-nil.  Do not treat `UserDefaults(suiteName:)` returning an object as proof the write reached the widget.  The authenticated search below did not return a corpus source that says the initializer itself is a silent no-op, so this note does not claim that.

## Fleet Recall

Searched on 2026-10-14 from this seat with an authenticated `POST https://recall.jays.services/recall/search` (hybrid+rerank, `--app hoghunter --limit 5`).  `recall` is still not on PATH.  The earlier 401 was a missing bearer.  Queries and the top hit of each:

- `WidgetKit App Group UserDefaults suiteName no-op`.  Nearest hit `contrib/AG/2026-10-04/3afe8e7b` (score 0.0018): on macOS, App Groups are code-signing entitlements, not Info.plist keys.  That is a different lesson.  Nothing in the five hits says `UserDefaults(suiteName:)` writes are silent no-ops when the entitlement is missing.  The conclusion is not taken from the corpus.
- `SwiftUI cold launch onChange one-shot launch intent`.  Nearest hit `board/59de20fe198f48818e806c2e43f1e1b1` (score 0.0009): a Mac Settings window bug.  No hit is this cold-start lesson, so it had no natural home.

A search of `docs/rollouts/` found no earlier HogHunter note of either lesson.  Exactly one paragraph was stored with `recall contribute`, category `lesson`, app `hoghunter`, seat `GROK-BUILD`.  `doc_id` `contrib/GROK-BUILD/2026-10-14/53193652`.  Scrub report was empty.  The stored text is:

A SwiftUI flag set before the view exists is invisible to onChange, because onChange does not run for the value the view is created with.  A one-shot deep link has to be read in onAppear as well, and the request needs an expiry so it is not replayed when the view that consumes it appears only after a later phase change.

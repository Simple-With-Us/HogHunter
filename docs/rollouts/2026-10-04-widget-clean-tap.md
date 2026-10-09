# Widget Clean tap reaches a cold launch

Sat, Oct 4, 2026

## Why

The small widget sent every tap to `hoghunter://clean`.  A cold launch set a flag that only `.onChange` inside the dashboard consumed, so the confirm dialog never appeared if the dashboard was created with the flag already set.

## What

The small widget opens the app, and only its Clean pill links to `hoghunter://clean`.  The dashboard consumes that request on appear and on change.  A fresh snapshot asks WidgetKit to reload timelines.

## Still open on issue #65

The widget extension and the iPhone app do not share an App Group entitlement.  The release validator rejects copying the Mac entitlement onto the iPhone signature.  Widgets stay empty until that group exists in the Apple Developer portal.  This change does not add the entitlement.

## Decisions & Trade-offs

The dashboard consumes the clean request on appear as well as on change.  A cold launch creates the dashboard with the flag already set, so `.onChange` alone never fires — the request must be one-shot (cleared after consumption) so a later re-appear does not re-show the dialog.

Only the small widget's Clean pill links to `hoghunter://clean`, not the whole widget surface.  Taps anywhere else open the app with no side effects; the trade-off is that users tapping the widget body do not get the clean flow.

Timeline reloads fire only after a fresh snapshot is actually stored, not on every poll.  WidgetKit budgets reloads, and re-rendering unchanged data every 3 seconds would exhaust that budget for nothing.

## Zero-Code Findings

A cold-launched SwiftUI view never sees the `.onChange` a warm view would: any launch flag consumed only by `.onChange` is dead on cold start.  Consume one-shot launch intents on appear too.

While the App Group entitlement is missing (issue #65), `UserDefaults(suiteName:)` writes are silent no-ops — scheduling widget reloads around a write that cannot land is wasted work.  Gate the reload on the write succeeding.

## Verification

iOS companion and widget extension build for the iOS Simulator.

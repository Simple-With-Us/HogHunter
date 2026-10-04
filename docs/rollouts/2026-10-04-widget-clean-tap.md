# Widget Clean tap reaches a cold launch

Sat, Oct 4, 2026

## Why

The small widget sent every tap to `hoghunter://clean`.  A cold launch set a flag that only `.onChange` inside the dashboard consumed, so the confirm dialog never appeared if the dashboard was created with the flag already set.

## What

The small widget opens the app, and only its Clean pill links to `hoghunter://clean`.  The dashboard consumes that request on appear and on change.  A fresh snapshot asks WidgetKit to reload timelines.

## Still open on issue #65

The widget extension and the iPhone app do not share an App Group entitlement.  The release validator rejects copying the Mac entitlement onto the iPhone signature.  Widgets stay empty until that group exists in the Apple Developer portal.  This change does not add the entitlement.

## Verification

iOS companion and widget extension build for the iOS Simulator.

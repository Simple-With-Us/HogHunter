# App Privacy answers

Use these answers only after confirming that the submitted binary still
matches this repository.  Re-read `SentryTelemetry.swift` and both
`PrivacyInfo.xcprivacy` files before every upload.

- Tracking: **No**
- Data used for third-party advertising, developer advertising, or marketing:
  **None**
- Third-party advertising or analytics SDKs: **None** for advertising or
  product analytics.  The iPhone app and the Mac menubar app link the
  **Sentry** crash-reporting SDK (`sentry-cocoa`, see
  `Sources/Telemetry/SentryTelemetry.swift`).  It is inactive unless the
  build was cut with a `SENTRY_DSN`.  The TestFlight workflow resolves one
  from Infisical prod (GitHub Actions secret `SENTRY_DSN` as a fallback)
  before archiving, but ships the app with Sentry inert rather than failing
  the build when neither resolves.
- Data used for **App Functionality** (diagnostics, not linked to the user):
  - Diagnostics: **Crash Data**, **Performance Data** (app hangs longer than
    two seconds, a 20% sample of traces, and a 10% sample of continuous
    profiles on a sampled trace), and **Other Diagnostic Data** (device
    model, OS version, app version, an anonymous installation identifier).
  - Failed HTTP 5xx responses may include a URL.  Query parameters named
    `token`, `key`, `secret`, `auth`, or `password` are redacted on the
    device before an event is sent.  Pairing tokens, process names, and
    disk paths are never attached on purpose.
  - Sentry is configured with `sendDefaultPii = false`,
    `attachScreenshot = false`, and `attachViewHierarchy = false`.
  - **Session Replay is off.**  The panel lists running processes, and a
    replay would capture other people's work.
- Data linked to the user: **None** from Sentry.  The companion pairing
  token stays on the phone and the Mac; it is not a Sentry identifier.
- Privacy policy URL: none published yet.  Add one before the first App
  Store submission that ships a DSN-enabled build.

The widget extension is not instrumented.

## Mac menubar app

The same answers apply to a Developer ID or adhoc Mac build that was
archived with `SENTRY_DSN` or `SENTRY_DSN_MACOS`.  A local `scripts/install.sh`
without those names ships Sentry inert, so that copy collects nothing.

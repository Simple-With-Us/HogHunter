# Screenshot Scene Verification

HH-207 fixes the actual frames from native CI 41689382968: system Open prompts obscured cleaner/deep-link captures, cold-start showed a network refusal, and a 560-point screenshot window clipped the 800-point Settings view.  The prior artifact and SHA manifest remain in the delivery receipts.

The shared on-demand helper scripts/ios_capture_scenes.py captures the embedded-widget preview, cold-start clean confirmation, finished Quick scan and partial lower-bound/Scan Deeper scene.  scripts/screenshot-text.swift reads the saved pixels with Apple Vision.  Required scene text must be present and known OS/network alert text must be absent; unreadable or unavailable OCR fails required proof and records a reason.  Both native CI capture and the standalone screenshot workflow use these checks.

Only the explicit -HogHunterSample launch enters inert demo behavior and offers controls without a real endpoint.  Normal launches retain their endpoint, opt-in and confirmation gates.  The partial screenshot flag changes only the fixture report.  No screenshot action starts a real cleaner or remote process.

The URL attempt runs last.  A visible unresolved system prompt or any other unverified destination produces deep-link-verification.json with verified=false and puts its image under unverified/.  It never counts as an intended clean confirmation, and the script never accepts the OS prompt.  Launch-scene images prove the actual views separately.

The Mac screenshot harness reuses SettingsView.windowWidth/windowHeight instead of forcing 560x480.  Its PNG must contain complete Settings labels.  A separate native render fixture configures maintenance.example.invalid with scheduling off in a temporary directory, isolated settings and injected inert process/network seams, then renders the actual RemoteMaintenanceCard at dashboard content width.  After cumulative PR255 integration, its artifact must be reviewed for manual strategy controls while scheduling stays off.

Validation requires hermetic scene/alert/unknown-OCR tests, rejection of the historical defective PNGs, native compilation and hosted artifacts.  Review actual finished/partial iPhone images, complete Mac Settings labels and hh207-server-maintenance-schedule-off.png.  An archive or green workflow alone is insufficient, and final cumulative hosted artifacts are required before publication.

Each attempt clears only its known scene and route evidence before capture.  Launch, capture/blank-frame and OCR failures write a failed scene entry with the failing stage before exiting; an early failure leaves the route explicitly not attempted.  A successful retry cannot retain an earlier unverified route PNG.

Ordinary native rendering tests remain usable without an export environment and still require rendered PNG bytes.  Hosted CI sets both render-directory variables and separately requires the named nonempty server maintenance PNG immediately after native tests.  Hermetic checks exercise missing/empty/present artifact gating and failed/successful retry transitions.

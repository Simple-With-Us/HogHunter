# Auto-Update (Sparkle 2)

Owner ruling, Tue, Sep 29, 2026: every fleet Mac app updates itself seamlessly, through Sparkle 2, from signed releases that CI publishes on each merge to `main`.  CodeCaps is the pilot; this document is how Hog Hunter implements the pattern (CodeCaps' `docs/AUTO-UPDATE.md` is the canonical description).

## What Happens

1. A PR merges to `main` and changes the Mac app (`Sources/`, `Assets.xcassets`, `project.yml`, or the build scripts).
2. `.github/workflows/mac-release.yml` builds a universal Release bundle with `xcodegen` + `xcodebuild`, signs it with the Developer ID Application certificate (hardened runtime, secure timestamp, nested code signed inside-out), notarizes and staples the app and the DMG, and writes an appcast whose one item is the new ZIP, signed with Hog Hunter's EdDSA key.
3. The workflow publishes a GitHub release tagged `v<VERSION>-build.<N>`, marked latest, carrying `HogHunter.zip`, `HogHunter.dmg`, their `.sha256` files, and `appcast.xml`, then confirms the live feed names build N.
4. Every installed copy checks `https://github.com/Simple-With-Us/HogHunter/releases/latest/download/appcast.xml` once an hour, downloads the new ZIP in the background, verifies its EdDSA signature before unpacking it, and checks that it is signed by the same Developer ID team.
5. As soon as Hog Hunter is not the frontmost app (for a menu-bar app, nearly always), `AppUpdater` installs the update and relaunches.  If the owner is using Hog Hunter at that moment, the install waits until they switch away.

Settings ▸ About shows "Automatic updates: On" and a **Check For Updates…** button.  The same command is in the app menu.

The iOS companion ships on the same trigger: `.github/workflows/ios-testflight.yml` archives and uploads to TestFlight on every merge to `main` that touches the iOS native tree (`ios/**`, `project.yml`, and the shared Mac files the iPhone targets compile), through the fleet ship script.  See `docs/rollouts/2026-10-17-ios-auto-ship.md`.

## The Pieces

| Piece | Role |
|---|---|
| `project.yml` | Sparkle 2 (`https://github.com/sparkle-project/Sparkle`, from 2.10.0) as an xcodegen package dependency of the `HogHunter` Mac target only. |
| `Sources/App/AutoUpdate.swift` | `AutoUpdateAvailability` (should this build run Sparkle at all) and `AppUpdater` (owns `SPUStandardUpdaterController`, installs as soon as the app is idle). |
| `Sources/App/HogHunterApp.swift` | Starts the updater first thing at launch, adds **Check For Updates…** to the app menu. |
| `Sources/UI/SettingsView.swift` | Settings ▸ About shows "Automatic updates: On/Off · reason" and the check button. |
| `Tests/HogHunterTests/AutoUpdateTests.swift` | The availability gate. |
| `scripts/mac-release-build.sh` | xcodegen + xcodebuild a universal Release, embed and assert `Sparkle.framework`, write the Sparkle Info.plist keys, sign inside-out, run `codesign --verify --deep --strict`, notarize with an App Store Connect API key when `NOTARY_KEY_*` are set, and run `spctl --assess` on the stapled app and DMG. |
| `scripts/make_appcast.sh` | Runs Sparkle's `generate_appcast` over one archive and checks the result: one item, EdDSA-signed, pointing at the right URL. |
| `.github/workflows/mac-release.yml` | The release job.  Also builds and verifies (never publishes) on PRs that touch the bundle. |
| `.github/actions/infisical-secrets`, `scripts/infisical-fetch.mjs` | Reads the signing certificate from Fleet-OPS "Fleet Secrets" (prod, `/mac-certs`) and the Sparkle private key from the HogHunter Infisical project (prod), with same-named repository secrets as the fallback. |

## Failures and Retries

`xcrun stapler staple` fetches Apple's ticket over the network, and it is
flaky on CI runners: on 2026-10-19 the release for build 158 died with
`NSURLErrorDomain -1005 "The network connection was lost"` against
`api.apple-cloudkit.com` and then `The staple and validate action failed!
Error 68`, even though **both notarizations had already been Accepted**.  The
run for the next merge was cancelled behind it, so the published feed stopped
at build 154 while main carried on, and an installed copy that could
self-update had nothing new to take.

Stapling is idempotent: the ticket was already issued, so the fetch can simply
be tried again.  `scripts/mac-release-build.sh` therefore staples through
`staple_with_retry` (five attempts, 30 seconds apart) for both the app and the
disk image, the same helper ContactLogo uses for the same flake.

A release that is still missing after a merge is worth re-running by hand:

```bash
gh workflow run mac-release.yml --ref main
```

## Info.plist Keys

`scripts/mac-release-build.sh` writes these into every staged bundle (local `xcodebuild` builds carry none of them, so a dev build never greets the owner with Sparkle's launch alert):

| Key | Value | Why |
|---|---|---|
| `SUFeedURL` | `https://github.com/Simple-With-Us/HogHunter/releases/latest/download/appcast.xml` | Always the newest release's appcast. |
| `SUPublicEDKey` | `8nQ6+N6opPFZYkZUgMtyvfbqZH92Kpw3haG/6trehuE=` | Verifies each archive.  Public, committed in the build script. |
| `SUEnableAutomaticChecks` | true | No "check automatically?" prompt. |
| `SUAutomaticallyUpdate` | true | Download and install without asking. |
| `SUAllowsAutomaticUpdates` | true | Silent installs are permitted. |
| `SUScheduledCheckInterval` | 3600 | Hourly checks. |
| `SUVerifyUpdateBeforeExtraction` | true | EdDSA check before unpacking. |

## Secrets

Names only; no value is ever printed:

- `MAC_CERT_P12_BASE64`, `MAC_CERT_PASSWORD` — the Developer ID Application certificate for team `CC8UTF7ATG`, in Fleet-OPS ("Fleet Secrets") `prod` at path `/mac-certs`, read at workflow runtime with the org Infisical credentials (`INFISICAL_FLEET_OPS_PROJECT_ID`, `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` / `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET`); same-named GitHub repository secrets as fallback.
- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` — the App Store Connect API key; `notarytool` signs in with it.
- `SPARKLE_ED_PRIVATE_KEY` — the EdDSA private key (base64 of the 32-byte seed) that signs each update archive; in the HogHunter Infisical project (`prod`), same-named repository secret as fallback.  Generated 2026-10-14 for Hog Hunter; the matching public key is committed above.

With any of them missing the job still builds the bundle and verifies its signature, then skips publishing with a notice that names what is missing.

## Rollback

Every release is a GitHub release with its own appcast; rolling back is publishing the previous build's archive as the new latest (or re-running the workflow from the older commit).  The appcast never carries more than one item, so there is no feed history to rewrite.

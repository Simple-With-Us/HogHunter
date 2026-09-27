# Hog Hunter iOS external TestFlight readiness — 2026-09-27

The owner authorized external testing of the iPhone companion.  This document
records the release identity and the exact remaining gates.  It does not claim
that an App Store Connect app, uploaded build, approved beta, or public invite
exists yet.

## Confirmed identity and source

- iPhone target: `HogHunterIOS`, bundle `com.simplewithus.hoghunter.ios`,
  display name `Hog Hunter`, iOS 17+, iPhone only.
- Apple Developer Bundle ID: `KT767XY4GR`, registered for team `CC8UTF7ATG`.
- Active iOS App Store distribution profile: `6RSNAV8S3S`, UUID
  `fd48a6b9-889f-4989-af40-f6773c620097`, using the existing team
  distribution certificate.  Expires 2027-06-30.
- Marketing version is prepared as `1.0.1` for the first upload.  The previous
  `1.0.0` was a simulator-only project version, not an App Store build.
- `ios/Info.plist` declares Bonjour `_hoghunter._tcp`, local-network usage,
  and `ITSAppUsesNonExemptEncryption=false`.  The app only requests a Mac
  snapshot over the local network; it cannot quit processes.
- GitHub CI run `36227076281` built the iOS scheme for generic Simulator.
  A signed device archive and TestFlight upload remain unverified.

## Remaining gates

1. In an authenticated App Store Connect website session, create a new iOS app
   record with bundle `com.simplewithus.hoghunter.ios`, primary locale
   `en-US`, a unique SKU such as `hoghunter-ios`, and the owner-approved
   app name.  Apple's public Apps API cannot create app records.
2. Install the existing distribution profile on the release runner, and use
   the credential-file approach approved by the fleet signing remediation.
   Do not place a multiline ASC private key in GitHub workflow `env` or
   `$GITHUB_ENV`; the current fleet pattern exposed key text in a run log.
3. Archive and upload a `1.0.1` build with a factual What to Test entry.
   Validate the resulting ASC build ID, processing state, bundle ID, export
   compliance, and beta localization before submitting Apple beta review.
4. Create an external beta group, assign an eligible build, submit for beta
   review, and enable/share its public link only when Apple accepts the build.

The reviewer will need a Mac running Hog Hunter on the same Wi-Fi, with
Settings → Share With iPhone enabled and the Mac's pairing code.  There is no
hosted demo account or internet remote-control service.  Do not invent access
credentials or claim that the reviewer can test the paired view without setup.

Tracking: [HogHunter #22](https://github.com/jaywedgeworth22/HogHunter/issues/22),
fleet release [#296](https://github.com/jaywedgeworth22/AI-Fleet-Coordinator/issues/296),
effort board `1dd567c8c0054e708882ee69e91c2652`.

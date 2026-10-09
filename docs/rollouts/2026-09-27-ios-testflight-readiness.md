# Hog Hunter iOS external TestFlight readiness — 2026-09-27

The owner authorized external testing of the iPhone companion.  This document
records the release identity and the remaining gates.  The App Store Connect
app and an external group now exist.  The group has no builds, so its public
invite is not yet a usable installation path.

## Confirmed identity and source

- iPhone target: `HogHunterIOS`, bundle `com.simplewithus.hoghunter.ios`,
  display name `Hog Hunter`, iOS 17+, iPhone only.
- Apple Developer Bundle ID: `KT767XY4GR`, registered for team `CC8UTF7ATG`.
- App Store Connect app **Hog Hunter**, ID `6816633156`, bundle
  `com.simplewithus.hoghunter.ios`, primary locale `en-US`, and SKU
  `hoghunter-ios` was created and verified on its saved app page in the
  owner-authenticated website.  Access is limited to existing account roles.
- Active iOS App Store distribution profile: `6RSNAV8S3S`, UUID
  `fd48a6b9-889f-4989-af40-f6773c620097`, using the existing team
  distribution certificate.  Expires 2027-06-30.
- Marketing version is prepared as `1.0.4` for the first upload.  The previous
  `1.0.0` was a simulator-only project version, not an App Store build.
- `ios/Info.plist` declares Bonjour `_hoghunter._tcp`, local-network usage,
  and `ITSAppUsesNonExemptEncryption=false`.  The app connects to the Mac app
  over the local network or Tailscale; process control and disk cleaning require
  explicit opt-in in Mac Settings.
- GitHub CI run `36227076281` built the iOS scheme for generic Simulator.
  A signed device archive and TestFlight upload remain unverified.
- External group `79295c7f-f69f-4614-9ed3-9a16691380ff` has the public invite
  `https://testflight.apple.com/join/yrHXfqSR`.  No build was assigned when the
  group was verified on September 27.  Do not present it as an available beta.

## Remaining gates

1. Complete replacement signing credentials and repository secret setup, then
   enable the [manual iOS workflow](2026-09-27-ios-manual-release.md).
   It uses Xcode automatic provisioning and validates the resulting profile.
   Do not use the previous ASC key or place a multiline private key in workflow
   `env` or `$GITHUB_ENV`.
2. Archive and upload a `1.0.4` build with a factual What to Test entry.
   Validate the resulting ASC build ID, processing state, bundle ID, export
   compliance, and beta localization before submitting Apple beta review.
3. Assign an eligible build to the existing external group, submit for beta
   review, and verify that the public link offers the approved build before
   promoting it on the website.

The reviewer will need a Mac running Hog Hunter on the same Wi-Fi, with
Settings → Share With iPhone enabled and the Mac's pairing code.  There is no
hosted demo account or internet remote-control service.  Do not invent access
credentials or claim that the reviewer can test the paired view without setup.

The paired view includes controls that act on the Mac (quit, tame, clean, and
changing exclusions and the view).  As of the 2026-10-09 owner ruling each one is
off until the Mac owner turns it on in Settings > iPhone, the phone confirms every
action, and the Mac accepts them only from its local network or Tailscale.  A
reviewer who wants to see them without a Mac can use Demo Mode in the app.  The
review notes must not describe the app as read-only.

Tracking: [HogHunter #22](https://github.com/jaywedgeworth22/HogHunter/issues/22),
fleet release [#296](https://github.com/jaywedgeworth22/AI-Fleet-Coordinator/issues/296),
effort board `1dd567c8c0054e708882ee69e91c2652`.

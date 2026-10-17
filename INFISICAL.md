# INFISICAL.md — Hog Hunter

Infisical is the sole source of truth for Hog Hunter's app-level settings: secrets, env config, and tunable settings knobs.  Per-user settings stay in the app's own store (UserDefaults) and never go in Infisical.  This document is the contract; the implementation is `Sources/Infisical/InfisicalSettings.swift`.

## The policy

Everything Hog Hunter's behavior depends on that is not code lives in the selected Infisical project.  A Project ID must be entered explicitly; there is no built-in project destination.  An admin tunes behavior by editing values in Infisical, not by shipping a build.  The app reads those values at launch into an in-memory cache and serves every runtime read from the cache.

## Who owns the Infisical read

Hog Hunter has no backend.  The Mac app is the whole product (the iPhone companion connects directly to the Mac app over Bonjour or Tailscale), and the local user IS the admin -- the canonical pattern's single-user case.  So the Mac app owns the Infisical read.

A universal-auth client secret is never embedded in the binary.  The admin enters Client ID, Client Secret, and Project ID in Settings > Advanced; the connection is stored together in the Keychain (`com.simplewithus.hoghunter.infisical` / `universal-auth`).  Until a credential is saved, the app behaves exactly as it did before this change: built-in defaults and UserDefaults stand.

The iOS companion never talks to Infisical and never holds a credential.  It receives the effective settings through the Mac's companion snapshot channel.  With the owner's edit opt-in it can also ask the Mac to change four of them; see "Admin gating" below.

## Environment

The app reads the `prod` environment, and only `prod`.  Hog Hunter has a single deployment -- this Mac -- and the `dev` and `staging` environments are retired (owner, 2026-10-10).  `InfisicalSettings.environment` is a constant, not a setting, and `testEnvironmentIsProdOnly` pins it.  The Cursor cloud start script (`scripts/cursor-cloud-start.sh`) reads `INFISICAL_ENV` from `.cursor/infisical.env` (`prod`) and refuses any other value.

## Key inventory

Non-sensitive defaults were seeded into the `prod` environment from the values the repo shipped with.  Secrets are documented as "to be filled by admin" and left empty -- never invent, guess, or copy a secret value.

### Migrated (Infisical is the source of truth)

| Key | Default | What it drives |
|---|---|---|
| `hoghunter.refreshInterval` | `5` | Sampling interval, seconds (Settings > General) |
| `hoghunter.alertThresholdPercent` | `300` | Alert threshold, per-core percent (Settings > Alerts) |
| `hoghunter.alertSustainedMinutes` | `5` | Alert sustained window, minutes (Settings > Alerts) |
| `hoghunter.alertCooldownMinutes` | `30` | Quiet period after an alert fires, minutes |
| `hoghunter.alertWebhookURL` | *(secret, to be filled by admin)* | Webhook posted on alert (Settings > Alerts) |
| `hoghunter.reclaim.criticalFreeGb` | `25` | Disk band: below this is "critical" |
| `hoghunter.reclaim.acuteFreeGb` | `40` | Disk band: below this is "acute" |
| `hoghunter.reclaim.healthyFreeGb` | `80` | Disk band: below this is "ok" |
| `hoghunter.reclaim.cpuIdleFloorPercent` | `12` | Thrash detection: CPU idle % below this |
| `hoghunter.reclaim.swapUsedPct` | `90` | Pressure chunking: swap used % at or above this |
| `hoghunter.reclaim.load1Threshold` | `40` | Pressure chunking: load1 above this |
| `hoghunter.regimen.intervalHours` | `24` | Unattended clean regimen cadence, hours |
| `hoghunter.regimen.targetsPerChunk` | `3` | Regimen chunk size when calm |
| `hoghunter.regimen.chunkPauseSeconds` | `5` | Regimen pause between chunks when calm |
| `hoghunter.regimen.pressuredTargetsPerChunk` | `2` | Regimen chunk size under pressure |
| `hoghunter.regimen.pressuredChunkPauseSeconds` | `10` | Regimen pause between chunks under pressure |
| `hoghunter.regimen.expensiveTierFreeGb` | `40` | Free space below which the expensive tier opens |
| `hoghunter.settingsRefreshMinutes` | `5` | How often the app re-reads Infisical |
| `hoghunter.maintain.step.shutdown_simulators` | `true` | Maintain step toggle: Shut down Xcode Simulators |
| `hoghunter.maintain.step.xcode_derived_data` | `true` | Maintain step toggle: Clear Xcode build cache |
| `hoghunter.maintain.step.xcode_device_support` | `false` | Maintain step toggle: Clear old iPhone debug symbols |
| `hoghunter.maintain.step.core_simulator_caches` | `true` | Maintain step toggle: Clear Simulator cache folders |
| `hoghunter.maintain.step.cleanmymac_cli` | `false` | Maintain step toggle: CleanMyMac CLI sweep |
| `hoghunter.maintain.step.coolify_remote` | `false` | Maintain step toggle: Remote server maintenance |
| `hoghunter.maintain.step.janitor_worktree_retire` | `true` | Maintain step toggle: Retire old merged git worktrees |
| `hoghunter.maintain.step.janitor_cache_reclaim` | `true` | Maintain step toggle: Reclaim caches when disk is low |
| `hoghunter.maintain.interval.watchSec` | `300` | Maintain cadence: resource watch tick interval, seconds |
| `hoghunter.maintain.interval.janitorSec` | `1800` | Maintain cadence: disk janitor run interval, seconds |
| `hoghunter.maintain.interval.fullSec` | `14400` | Maintain cadence: full clean run interval, seconds |
| `hoghunter.maintain.historyMaxRuns` | `500` | Maintain history: maximum run records kept in history.json |
| `hoghunter.maintain.cleanBudgetSec` | `600` | Maintain reclaim: per-run budget for hoghunter-clean, seconds |
| `hoghunter.maintain.coolifySshHost` | `""` | Maintain host: SSH destination for remote Coolify maintenance |
| `hoghunter.maintain.janitor.maxLoadHard` | `250` | Maintain threshold: janitor hard max 1-minute load average |
| `hoghunter.maintain.janitor.lowFreeGib` | `80` | Maintain threshold: disk free space (GiB) triggering cache reclaim |
| `hoghunter.maintain.watch.diskFreeWarnGb` | `25` | Maintain threshold: disk free warning threshold (GB) |
| `hoghunter.maintain.watch.swapUsedPct` | `90` | Maintain threshold: swap memory usage percent warning threshold |

### Deliberately left out (and why)

These stay in UserDefaults (or the app-group defaults for shared state).  They are per-user display choices, consent toggles, device identity, or local operational state -- explicitly out of scope for the SOT.

- `window`, `grouping`, `sort`, `cpuScale`, `menuBarLabelMode`, `appearance` -- per-user display preferences.
- `alertsEnabled`, `shareWithIPhone`, `allowRemoteQuit`, `allowRemoteClean`, `allowRemoteEdit`, `allowRemoteVacuum` -- per-user consent toggles.  Sharing, remote quit or tame, remote clean, remote changes to exclusions and the panel view, and remote Robotic Vacuum runs are each off until the owner turns them on; that decision is not a fleet setting.
- `companionCode`, `companionPeerID` -- per-device pairing identity.
- `companionDevices` -- the list of paired iPhones (name, SHA-256 hash of its token, paired and last-seen times).  Per-device pairing state, never a fleet setting, and it holds hashes only: the tokens themselves are shown to the phone once and not stored on the Mac.
- Cleaner exclusions and the regimen's enabled-rule set -- per-user choices about what may be deleted on this Mac.
- `hoghunter.cleaner.regimen.lastRunAt` -- local operational state.
- `config/reclaim-policy.json` -- the machine-readable reclaim policy with owner rulings and rationale, shared with the `scripts/hoghunter-clean` CLI.  Only its numeric bands are migrated (see the `hoghunter.reclaim.*` keys); the document itself, its comments, and its rule inventory stay in the repo.
The only runtime secret in the Infisical inventory the Mac app reads is the alert webhook URL, which the admin fills in.

### Build-time Sentry (not a runtime Infisical read)

These names are never fetched into `InfisicalStore`.  The DSN is baked into Info.plist at archive / install time (`$(SENTRY_DSN)`), and an empty value keeps `SentryTelemetry.start()` a no-op.  The iPhone companion never talks to Infisical.

| Key | Where Jay sets it | What it drives |
|---|---|---|
| `SENTRY_DSN` | Infisical project `HogHunter` env `prod` path `/`, and GitHub Actions secret `SENTRY_DSN` | iOS TestFlight archive; also the Mac install when `SENTRY_DSN_MACOS` is unset |
| `SENTRY_DSN_MACOS` | Infisical prod `/` (optional) | `scripts/install.sh` prefers this over `SENTRY_DSN` for the menubar app |
| `SENTRY_AUTH_TOKEN` | Infisical prod `/`, and GitHub Actions secret `SENTRY_AUTH_TOKEN` | `sentry-cli debug-files upload` after a TestFlight archive (org `simple-with-us`, project `hoghunter`) |
| `SENTRY_FLEET_DSN` | GitHub Actions org or repo secret | `.github/workflows/sentry-ci-report.yml` reports CI failures to fleet-infra |

Never put a DSN or auth token in git, `project.yml`, Info.plist, a log, or a PR body.

### Build-time signing (not a runtime Infisical read)

The Mac app and the iPhone companion never read these.  They exist so `.github/workflows/ios-testflight.yml` can sign, archive, and upload the iPhone companion to TestFlight.  Owner ruling 2026-10-17: signing and App Store Connect credentials for all apps are in Infisical, project Fleet-OPS, path `/asc`, and the active `ios-testflight.yml` workflow is intended.  Names only here, never values.

| Name | What it is |
|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect API key identifiers |
| `ASC_KEY_P8` | App Store Connect API private key, a multiline PEM that `scripts/ios-stage-asc-key.sh` stages to a mode 600 file |
| `IOS_DIST_P12_BASE64`, `IOS_DIST_P12_PASSWORD` | Apple Distribution certificate for team `CC8UTF7ATG`, and its password |

The canonical copies are in Fleet-OPS `/asc`.  The workflow itself does not read that path.  It takes same-named GitHub Actions repository secrets, and all five exist.  Only when one of the five is empty does it fall back to Infisical `prod` `/` of the project named by its `INFISICAL_PROJECT_ID` secret.  The workflow runs only while the repository variable `HH_IOS_TESTFLIGHT_ENABLED` is `true`, which it is.  A merge to `main` that touches the iOS app uploads a build, and a manual dispatch uploads only when asked.  A green run is not evidence of a processed or approved beta: check App Store Connect separately (issue #22 stays open until the external release is verified).  The Mac Developer ID certificate is a separate path, described in `docs/AUTO-UPDATE.md`.

Never put a signing value in git, a log, a workflow artifact, a PR body, or chat.

### Maintain & Robotic Vacuum (Wired via Infisical & Environment)

Maintain settings (step toggles, intervals, clean budget, remote host, and thresholds) are wired to Infisical.  The Swift Mac app reads Infisical via `InfisicalStore` and writes through on change; the Python engine (`scripts/vacuum/config.py`) consumes them through `apply_env_overrides()`, supporting both `hoghunter.maintain.*` and `HOGHUNTER_MAINTAIN_*` environment variables.

- A Maintain save (a step toggle or the remote server SSH host) writes to Infisical first.  If that write fails, the save fails: the Mac shows the error, reloads the value Infisical still holds, and does not write the local `config.json`.  The local file is only written after Infisical accepted the value, so a refresh can never put a stale Infisical value over a newer local one.
- The lane doctor settings in `scripts/vacuum/lanes.py` keep report age (15 minutes), doctor schema (2), doctor timeout (5 minutes), the 7-day retire floor, and the 24-hour dependency floor as code constants.  Config cannot change them in either direction.
- `lanes.doctor_command` and the `HOGHUNTER_LANE_DOCTOR_COMMAND` override name where the lane doctor is installed on this Mac.  That is a machine-local path, like `hoghunter_clean` and `data_dir`, not a fleet knob.

## The runtime contract

1. **Load at startup.**  `HogHunterApp.init` kicks off `InfisicalSettings.shared.bootstrap()` on a background task.  It reads the Keychain credential, logs in via universal-auth, and GETs `/api/v3/secrets/raw` into the `InfisicalStore` in-memory cache.  Launch never blocks on this: no credential or no network means the built-in defaults and UserDefaults values stand.
2. **Never fetch per-request.**  `CleanPressure`, `CleanRegimen` (via its `effective*` values), `Alerts`, and `HogStore` read `InfisicalStore.shared`, a lock-protected dictionary.  Zero network calls after init, by construction -- the store has no network code at all.
3. **Background refresh.**  A 60-second timer re-reads when `hoghunter.settingsRefreshMinutes` (default 5) has elapsed since the last success, and the app re-reads on `applicationDidBecomeActive` (minimum 30-second gap).  A failed refresh keeps serving the last-known-good cache and records the error on `lastError`, shown in Settings > Advanced.  Staleness is safer than an outage.  After a successful refresh, `HogStore` applies the migrated values over its `@Published` settings (Infisical wins over UserDefaults).
4. **Write-through on admin save.**  Changing a migrated knob in Settings PATCHes Infisical first (`PATCH /api/v3/secrets`); the local cache updates only after the PATCH succeeds.  A failed write throws: the local value is kept so the app stays usable offline, the failure is recorded on `lastError` (never silent), and the next successful refresh re-asserts the Infisical value.  The regimen knobs have no Settings editing surface -- their stored JSON is the local fallback and Infisical overrides it at read time; the Advanced tab's "Push Current Values" is the admin surface for making local values the fleet truth.

## Admin gating

The settings surface is gated by the app's existing admin concept: there is none beyond the local user, because this is a single-user local app.  The local user IS the admin, and the gate is the documented fact that only someone at this Mac's Settings window can change these values -- the same trust boundary as every other setting in the app.  The iPhone companion changes settings only when the owner has turned on Allow iPhone to Change Exclusions & View in Settings > iPhone (off by default), and only these four migrated knobs: `hoghunter.refreshInterval`, `hoghunter.alertThresholdPercent`, `hoghunter.alertSustainedMinutes` and `hoghunter.alertWebhookURL`.  It asks the Mac, over the paired phone's own token and only from the local network or Tailscale; it never talks to Infisical.  The Mac checks every value (refresh 2, 3, 5, 10 or 15 seconds; threshold 100 to 1000 percent in steps of 50; sustained 1 to 30 minutes; webhook an `https` address or empty) and applies the change through the same properties the Settings window uses, so the write-through in "The runtime contract" runs unchanged, including its failure behavior.  The webhook URL is a secret: the Mac never sends it to the phone, which sees only whether one is set and the last two labels of its host, and can replace or clear it.  `alertsEnabled` stays a per-user consent toggle outside the SOT; the phone can flip it too.

## Rotating a value

Edit the key in the Infisical dashboard (project `HogHunter`, environment `prod`).  The app picks it up within `hoghunter.settingsRefreshMinutes` (default 5 minutes), or immediately via Settings > Advanced > Sync Now.  To rotate the universal-auth credential itself: create a new machine identity in Infisical, then replace it in Settings > Advanced (Save to Keychain overwrites).  Never put a secret in code, a log, a PR body, or chat -- names and metadata only.

## Local development

Without a Keychain credential the Infisical code paths are inert: the app runs exactly as before, and the test suite stubs the network entirely (`Tests/HogHunterTests/InfisicalSettingsTests.swift`).  CI needs no Infisical access.

## Selecting another project

Settings > Advanced accepts Client ID, Client Secret, and Project ID.  The host remains `https://app.infisical.com` and the environment remains `prod`.  Existing Keychain records without a valid Project ID remain unconfigured; the admin must enter all three fields and save.  There is no automatic migration or hard-coded project fallback.

Save first validates nonblank credentials and a UUID Project ID, then authenticates and reads that project's `prod` settings.  Only after both operations succeed does it atomically update the Keychain and activate the new connection.  Authentication, access, or Keychain failures leave the previous connection and cache usable.  Secrets are not trimmed, logged, or included in error messages.

A successful target change replaces the cache rather than merging it and resets project-derived effective and persisted fallback values, including the alert webhook.  Same-target refresh failures retain last-known-good settings.  A persisted project marker keeps another project's fallback out of an offline relaunch.  Clearing a connection also clears its project-derived values.  Display preferences and consent choices are unaffected.

Every in-flight refresh, write, and queued settings edit is bound to its original connection generation.  An old operation cannot update the new connection or redirect a queued batch into its project.  A write already sent to the old project may still complete there; its late response is discarded locally.  Concurrent saves are rejected, and a clear invalidates pending saves.

Synthetic regression coverage lives in `InfisicalProjectSelectionTests.swift`; HTTP routing is covered in `InfisicalSettingsTests.swift`.  These tests inject credential persistence and never access the Keychain or a real Infisical identity.  This feature does not create identities, grant project permissions, rotate credentials, add telemetry, or change the iPhone companion.

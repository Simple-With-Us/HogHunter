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
| `hoghunter.refreshInterval` | `3` | Sampling interval, seconds (Settings > General) |
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

### Deliberately left out (and why)

These stay in UserDefaults (or the app-group defaults for shared state).  They are per-user display choices, consent toggles, device identity, or local operational state -- explicitly out of scope for the SOT.

- `window`, `grouping`, `sort`, `cpuScale`, `menuBarLabelMode`, `appearance` -- per-user display preferences.
- `alertsEnabled`, `shareWithIPhone`, `allowRemoteQuit`, `allowRemoteClean`, `allowRemoteEdit`, `allowRemoteVacuum` -- per-user consent toggles.  Sharing, remote quit or tame, remote clean, remote changes to exclusions and the panel view, and remote Robotic Vacuum runs are each off until the owner turns them on; that decision is not a fleet setting.
- `companionCode`, `companionPeerID` -- per-device pairing identity.
- `companionDevices` -- the list of paired iPhones (name, SHA-256 hash of its token, paired and last-seen times).  Per-device pairing state, never a fleet setting, and it holds hashes only: the tokens themselves are shown to the phone once and not stored on the Mac.
- Cleaner exclusions and the regimen's enabled-rule set -- per-user choices about what may be deleted on this Mac.
- `hoghunter.cleaner.regimen.lastRunAt` -- local operational state.
- `config/reclaim-policy.json` -- the machine-readable reclaim policy with owner rulings and rationale, shared with the `scripts/hoghunter-clean` CLI.  Only its numeric bands are migrated (see the `hoghunter.reclaim.*` keys); the document itself, its comments, and its rule inventory stay in the repo.
No secrets, env vars, or build-time configuration existed in the repo before this change -- there was no `.env` file, no API keys, no service URLs.  The only secret in the inventory is the alert webhook URL, which the admin fills in.

### Robotic Vacuum (Python, Not Migrated)

The Robotic Vacuum (`scripts/vacuum/`) is a Python helper with no Infisical reader.  Its config is `config/robotic-vacuum.json`, with a per-user override in Application Support.  It is not in the migrated table, and it is not one of the per-user exclusions above.  It is an open item, and no owner ruling is recorded.

- The lane doctor work of 2026-10-08 adds no tunable.  Report age (15 minutes), doctor schema (2), doctor timeout (5 minutes), the 7-day retire floor, and the 24-hour dependency floor are code constants in `scripts/vacuum/lanes.py`.  Config cannot change them in either direction, and the numeric keys still present in the shipped `lanes` block are ignored.
- `lanes.doctor_command` and the `HOGHUNTER_LANE_DOCTOR_COMMAND` override name where the lane doctor is installed on this Mac.  That is a machine-local path, like `hoghunter_clean` and `data_dir`, not a fleet knob.
- The Vacuum's older settings (intervals, `janitor.*` and `resource_watch.*` thresholds, session ages) predate this change and stay in the JSON file.  Moving them to Infisical needs a reader on the Python side and an owner decision (`docs/rollouts/2026-10-08-lane-doctor-vacuum.md`, open question 9).

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

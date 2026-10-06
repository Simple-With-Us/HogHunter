# INFISICAL.md — Hog Hunter

Infisical is the sole source of truth for Hog Hunter's app-level settings: secrets, env config, and tunable settings knobs.  Per-user settings stay in the app's own store (UserDefaults) and never go in Infisical.  This document is the contract; the implementation is `Sources/Infisical/InfisicalSettings.swift`.

## The policy

Everything Hog Hunter's behavior depends on that is not code lives in the selected Infisical project.  Existing connections retain the original `HogHunter` project (`c1df65f2-adb5-4d64-93c0-f47f969feea1`) until the admin explicitly saves another Project ID.  An admin tunes behavior by editing values in Infisical, not by shipping a build.  The app reads those values at launch into an in-memory cache and serves every runtime read from the cache.

## Who owns the Infisical read

Hog Hunter has no backend.  The Mac app is the whole product (the iPhone companion connects directly to the Mac app over Bonjour or Tailscale), and the local user IS the admin -- the canonical pattern's single-user case.  So the Mac app owns the Infisical read.

A universal-auth client secret is never embedded in the binary.  The admin enters Client ID, Client Secret, and Project ID in Settings > Advanced; the connection is stored together in the Keychain (`com.simplewithus.hoghunter.infisical` / `universal-auth`).  Until a credential is saved, the app behaves exactly as it did before this change: built-in defaults and UserDefaults stand.

The iOS companion never talks to Infisical and never holds a credential.  It receives the effective settings through the Mac's companion snapshot channel.

## Environment

The app reads the `dev` environment.  Hog Hunter has a single deployment -- this Mac -- so `dev` is its production truth; the fleet seeds `dev`.  `staging` and `prod` exist for future use.

## Key inventory

Non-sensitive defaults were seeded into the `dev` environment from the values the repo shipped with.  Secrets are documented as "to be filled by admin" and left empty -- never invent, guess, or copy a secret value.

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
- `alertsEnabled`, `shareWithIPhone`, `allowRemoteQuit` -- per-user consent toggles.  Sharing and remote quit are off until the owner turns them on; that decision is not a fleet setting.
- `companionCode`, `companionPeerID` -- per-device pairing identity.
- Cleaner exclusions and the regimen's enabled-rule set -- per-user choices about what may be deleted on this Mac.
- `hoghunter.cleaner.regimen.lastRunAt` -- local operational state.
- `config/reclaim-policy.json` -- the machine-readable reclaim policy with owner rulings and rationale, shared with the `scripts/hoghunter-clean` CLI.  Only its numeric bands are migrated (see the `hoghunter.reclaim.*` keys); the document itself, its comments, and its rule inventory stay in the repo.

No secrets, env vars, or build-time configuration existed in the repo before this change -- there was no `.env` file, no API keys, no service URLs.  The only secret in the inventory is the alert webhook URL, which the admin fills in.

## The runtime contract

1. **Load at startup.**  `HogHunterApp.init` kicks off `InfisicalSettings.shared.bootstrap()` on a background task.  It reads the Keychain credential, logs in via universal-auth, and GETs `/api/v3/secrets/raw` into the `InfisicalStore` in-memory cache.  Launch never blocks on this: no credential or no network means the built-in defaults and UserDefaults values stand.
2. **Never fetch per-request.**  `CleanPressure`, `CleanRegimen` (via its `effective*` values), `Alerts`, and `HogStore` read `InfisicalStore.shared`, a lock-protected dictionary.  Zero network calls after init, by construction -- the store has no network code at all.
3. **Background refresh.**  A 60-second timer re-reads when `hoghunter.settingsRefreshMinutes` (default 5) has elapsed since the last success, and the app re-reads on `applicationDidBecomeActive` (minimum 30-second gap).  A failed refresh keeps serving the last-known-good cache and records the error on `lastError`, shown in Settings > Advanced.  Staleness is safer than an outage.  After a successful refresh, `HogStore` applies the migrated values over its `@Published` settings (Infisical wins over UserDefaults).
4. **Write-through on admin save.**  Changing a migrated knob in Settings PATCHes Infisical first (`PATCH /api/v3/secrets`); the local cache updates only after the PATCH succeeds.  A failed write throws: the local value is kept so the app stays usable offline, the failure is recorded on `lastError` (never silent), and the next successful refresh re-asserts the Infisical value.  The regimen knobs have no Settings editing surface -- their stored JSON is the local fallback and Infisical overrides it at read time; the Advanced tab's "Push Current Values" is the admin surface for making local values the fleet truth.

## Admin gating

The settings surface is gated by the app's existing admin concept: there is none beyond the local user, because this is a single-user local app.  The local user IS the admin, and the gate is the documented fact that only someone at this Mac's Settings window can change these values -- the same trust boundary as every other setting in the app.  The iPhone companion cannot change settings at all.

## Rotating a value

Edit the key in the Infisical dashboard (project `HogHunter`, environment `dev`).  The app picks it up within `hoghunter.settingsRefreshMinutes` (default 5 minutes), or immediately via Settings > Advanced > Sync Now.  To rotate the universal-auth credential itself: create a new machine identity in Infisical, then replace it in Settings > Advanced (Save to Keychain overwrites).  Never put a secret in code, a log, a PR body, or chat -- names and metadata only.

## Local development

Without a Keychain credential the Infisical code paths are inert: the app runs exactly as before, and the test suite stubs the network entirely (`Tests/HogHunterTests/InfisicalSettingsTests.swift`).  CI needs no Infisical access.

## Selecting another project

Settings > Advanced accepts Client ID, Client Secret, and Project ID.  The host remains `https://app.infisical.com` and the environment remains `dev`.  Legacy Keychain records without a Project ID decode to the original HogHunter project, without migration or a credential rewrite.

Save first validates nonblank credentials and a UUID Project ID, then authenticates and reads that project's `dev` settings.  Only after both operations succeed does it atomically update the Keychain and activate the new connection.  Authentication, access, or Keychain failures leave the previous connection and cache usable.  Secrets are not trimmed, logged, or included in error messages.

A successful target change replaces the cache rather than merging it and resets project-derived effective and persisted fallback values, including the alert webhook.  Same-target refresh failures retain last-known-good settings.  A persisted project marker keeps another project's fallback out of an offline relaunch.  Clearing a connection also clears its project-derived values.  Display preferences and consent choices are unaffected.

Every in-flight refresh, write, and queued settings edit is bound to its original connection generation.  An old operation cannot update the new connection or redirect a queued batch into its project.  A write already sent to the old project may still complete there; its late response is discarded locally.  Concurrent saves are rejected, and a clear invalidates pending saves.

Synthetic regression coverage lives in `InfisicalProjectSelectionTests.swift`; HTTP routing is covered in `InfisicalSettingsTests.swift`.  These tests inject credential persistence and never access the Keychain or a real Infisical identity.  This feature does not create identities, grant project permissions, rotate credentials, add telemetry, or change the iPhone companion.

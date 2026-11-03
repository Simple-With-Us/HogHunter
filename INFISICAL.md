# INFISICAL.md — Hog Hunter

Infisical optionally synchronizes Hog Hunter's app-level settings: secrets, env config, and tunable settings knobs.  When a connection is configured, its values are authoritative for the synchronized keys; without one, built-in defaults and local settings apply.  Per-user settings stay in the app's own store (UserDefaults) and never go in Infisical.  This document is the contract; the implementation is `Sources/Infisical/InfisicalSettings.swift`.

## Policy

The synchronized settings listed below may live in an explicitly selected Infisical project and folder, using either a machine identity or service tokens.  A Project ID must be entered explicitly; there is no built-in project destination.  A connected admin tunes shared behavior by editing those values in Infisical or using the app's write-through controls.  Local operation remains available without configuring Infisical.  A configured app reads those values at launch into an in-memory cache and serves every runtime lookup from that cache.  A failed refresh retains the same connection's last-known-good values; changing the project or read folders does not reuse another target's effective settings.

## Who Owns The Infisical Read

Hog Hunter has no backend.  The Mac app is the whole product (the iPhone companion connects directly to the Mac app over Bonjour or Tailscale), and the local user IS the admin -- the canonical pattern's single-user case.  So the Mac app owns the Infisical read.

Infisical is optional.  Settings > Advanced offers an explicit choice between a machine identity (Universal Auth Client ID and Client Secret) and multiple service tokens.  The active Project ID and settings folder are explicit; the app never discovers or adopts the shared Automation identity.  Without a saved connection, built-in defaults and local settings apply.

New saves store the whole connection in the Mac's Keychain (`com.simplewithus.hoghunter.infisical` / `universal-auth`), including service-token secrets.  Secure entry fields never log credentials.  Existing machine-identity file records remain readable as the previously chosen connection, but service tokens are never accepted from those files.  Saving explicitly replaces the Keychain record and retires legacy file copies after Keychain succeeds.  The nonsecret UserDefaults marker `hoghunter.infisical.legacyFileCredentialRetired` permanently disables legacy file fallback after the first successful explicit save or clear, even if unlinking an old file fails or the Keychain item later disappears.  Background reads suppress Keychain interaction; a locked Keychain is retryable and cannot trigger a prompt.

The iOS companion never talks to Infisical and never holds a credential.  It receives the effective settings through the Mac's companion snapshot channel.  With the owner's edit opt-in it can also ask the Mac to change four of them; see Admin Gating below.

## Environment

The app reads the `prod` environment, and only `prod`.  Hog Hunter has a single deployment -- this Mac -- and the `dev` and `staging` environments are retired (owner, 2026-10-10).  `InfisicalSettings.environment` is a constant, not a setting, and `testEnvironmentIsProdOnly` pins it.  The Cursor cloud start script (`scripts/cursor-cloud-start.sh`) reads `INFISICAL_ENV` from `.cursor/infisical.env` (`prod`) and refuses any other value.

## Key Inventory

The table records the built-in defaults used when no connected value overrides them.  An admin may seed non-secret values into the selected project and folder with Push Current Values to Infisical; the app never assumes a new project was seeded.  Secrets are documented as "to be filled by admin" and left empty -- never invent, guess, or copy a secret value.

### Synchronized Settings (When Connected)

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
| `hoghunter.maintain.janitor.retireMinDays` | `7` | Maintain threshold: idle whole days before an old merged worktree may be retired (1–90) |
| `hoghunter.maintain.watch.diskFreeWarnGb` | `25` | Maintain threshold: disk free warning threshold (GB) |
| `hoghunter.maintain.watch.swapUsedPct` | `90` | Maintain threshold: swap memory usage percent warning threshold |

### Local Settings And Operational State

These stay in UserDefaults (or the app-group defaults for shared state).  They are per-user display choices, consent toggles, device identity, or local operational state -- outside the synchronized settings inventory.

- `window`, `grouping`, `sort`, `cpuScale`, `menuBarLabelMode`, `appearance` -- per-user display preferences.
- `alertsEnabled`, `shareWithIPhone`, `allowRemoteQuit`, `allowRemoteClean`, `allowRemoteEdit`, `allowRemoteMaintain` -- per-user consent toggles.  Sharing, remote quit or tame, remote clean, remote changes to exclusions and the panel view, and remote maintenance runs are each off until the owner turns them on; that decision is not a fleet setting.
- `companionCode`, `companionPeerID` -- per-device pairing identity.
- `companionDevices` -- the list of paired iPhones (name, SHA-256 hash of its token, paired and last-seen times).  Per-device pairing state, never a fleet setting, and it holds hashes only: the tokens themselves are shown to the phone once and not stored on the Mac.
- Cleaner exclusions and the regimen's enabled-rule set -- per-user choices about what may be deleted on this Mac.
- `hoghunter.cleaner.tempMinimumUntouchedHours` -- a local cleaner safety preference in the same app-group defaults as exclusions.  Default 72 hours; whole hours from 1 to 8,760 only, with absent/corrupt stored values falling back to 72 and invalid edits retaining the previous valid choice.  Settings > Cleaner edits it locally; no Infisical key or new phone edit authority is added.  Every /tmp suggestion (even unchecked) and every deletion must pass the effective age, activity, and project/lock/link protections.  Changing it clears stale reports and selections without starting a scan.  Native regimen and companion cleanup share the same DiskCleaner checks.  The CLI's separate `temp-scratch` rule targets specifically named artifacts under the per-user TMPDIR; it does not implement the broader /tmp Temp Files category, so its existing scratch policy remains distinct.  Age does not establish that any file was committed or published.
- `hoghunter.cleaner.regimen.lastRunAt`, `hoghunter.cleaner.regimen.lastGateFailureAt`, `infisicalProjectId`, and `hoghunter.infisical.legacyFileCredentialRetired` -- local operational state, selected-target tracking, and permanent retirement of legacy credential fallback.
- `config/reclaim-policy.json` -- the machine-readable reclaim policy with owner rulings and rationale, shared with the `scripts/hoghunter-clean` CLI.  Only its numeric bands are migrated (see the `hoghunter.reclaim.*` keys); the document itself, its comments, and its rule inventory stay in the repo.
The only secret consumed by the runtime settings inventory is the alert webhook URL, which the admin fills in.  Bulk folder reads may contain additional keys, but those keys do not become runtime settings or companion fields.

### CI And Cloud Authentication

Release workflows and cloud bootstrap use scoped read-only service tokens, independently of the Mac app's optional runtime connection.  They never log in through the shared Automation machine identity.  The checked-in workflows declare these three token destinations:

| Actions Secret | Project | Environment / Folder | Consumers |
|---|---|---|---|
| `INFISICAL_HOGHUNTER_READ_TOKEN` | Explicit `INFISICAL_PROJECT_ID` (`HogHunter`) | `prod` / `/` | Mac release signing/Sentry values, iOS Sentry values, and optional Cursor cloud export |
| `INFISICAL_ASC_READ_TOKEN` | Explicit `INFISICAL_FLEET_OPS_PROJECT_ID` (`Fleet-OPS`) | `prod` / `/asc` | Mac notarization and iOS App Store Connect signing/upload |
| `INFISICAL_MAC_CERTS_READ_TOKEN` | Explicit `INFISICAL_FLEET_OPS_PROJECT_ID` (`Fleet-OPS`) | `prod` / `/mac-certs` | Mac Developer ID certificate import |

The composite action `.github/actions/infisical-secrets/action.yml` calls `scripts/infisical-fetch.mjs`.  Before fetching values, the helper checks each token's own metadata for exactly the requested project, prod folder, and read-only permission.  Invalid, broader, or unverifiable metadata fails closed.  References are not expanded across folders; another folder requires its own scoped token.

Only explicitly supplied `GH_FALLBACK_<NAME>` inputs can provide repository-secret fallback when a token is absent or a secret fetch fails after scope verification.  App Store Connect credentials have no repository-secret fallback and are required for the relevant release operation.  Cursor cloud bootstrap uses only `INFISICAL_HOGHUNTER_READ_TOKEN`; a missing token skips secret export, while an invalid scope fails the export.  Neither path falls back to a machine identity or an authenticated Infisical CLI session.  This document describes the checked-in consumers; deployment and release processing require their own verification.

### Build Sentry Settings (Separate From Runtime Sync)

These names are never fetched into `InfisicalStore`.  The DSN is baked into Info.plist at archive / install time (`$(SENTRY_DSN)`), and an empty value keeps `SentryTelemetry.start()` a no-op.  The iPhone companion never talks to Infisical.

| Key | Where Jay sets it | What it drives |
|---|---|---|
| `SENTRY_DSN` | Infisical project `HogHunter` env `prod` path `/`, and GitHub Actions secret `SENTRY_DSN` | iOS TestFlight archive; also the Mac install when `SENTRY_DSN_MACOS` is unset |
| `SENTRY_DSN_MACOS` | Optional local install environment value; it may be maintained in Infisical prod `/` | `scripts/install.sh` prefers this over `SENTRY_DSN` for the menubar app; the install script itself does not fetch Infisical |
| `SENTRY_AUTH_TOKEN` | Infisical prod `/`, and GitHub Actions secret `SENTRY_AUTH_TOKEN` | `sentry-cli debug-files upload` after a TestFlight archive (org `simple-with-us`, project `hoghunter`) |
| `SENTRY_FLEET_DSN` | GitHub Actions org or repo secret | `.github/workflows/sentry-ci-report.yml` reports CI failures to fleet-infra |

Never commit a literal DSN or auth token in git or print one in a log or PR body.  Build substitution intentionally places the DSN in the archived Info.plist; the Sentry auth token is for upload tooling and is never embedded in the app.

### Build Signing Settings (Separate From Runtime Sync)

The runtime apps do not use these signing credentials.  They exist so `.github/workflows/ios-testflight.yml` can sign, archive, and upload the iPhone companion to TestFlight.  Historical context: the 2026-10-17 owner ruling centralized App Store Connect material in Fleet-OPS `/asc` and authorized the TestFlight workflow.  Current consumers use the separate scoped-token destinations above; Apple Distribution certificate values remain repository secrets as shown below.  Names only here, never values.

| Name | What it is |
|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect API key identifiers |
| `ASC_KEY_P8` | App Store Connect API private key, a multiline PEM that `scripts/ios-stage-asc-key.sh` stages to a mode 600 file |
| `IOS_DIST_P12_BASE64`, `IOS_DIST_P12_PASSWORD` | Apple Distribution certificate for team `CC8UTF7ATG`, and its password |

The canonical copies are in Fleet-OPS prod `/asc`.  The workflow reads `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` through `INFISICAL_ASC_READ_TOKEN`, verified for that exact read-only scope, and does not read the same-named repository secrets or use a machine identity.  The two `IOS_DIST_P12_*` values come from same-named GitHub Actions repository secrets and are scoped to the signing-import step.  `SENTRY_DSN` and `SENTRY_AUTH_TOKEN` are best effort:  Infisical `prod` `/` of this project first, repository secrets after.  The workflow uploads only while the repository variable `HH_IOS_TESTFLIGHT_ENABLED` is `true`; the current variable value must be checked separately.  A merge to `main` that touches the iOS native tree uploads a build, and so does a manual dispatch unless it is run with `upload=false`.  A green run is not evidence of a processed or approved beta: check App Store Connect separately (issue #22 stays open until the external release is verified).  The Mac release separately reads its Developer ID certificate from Fleet-OPS prod `/mac-certs` through `INFISICAL_MAC_CERTS_READ_TOKEN`, with the explicit certificate repository-secret fallbacks declared in `mac-release.yml`; see `docs/AUTO-UPDATE.md`.  Its notarization uses the `/asc` token, and its app signing/Sentry values use the HogHunter root token.

Never put a signing value in git, a log, a workflow artifact, a PR body, or chat.

### Maintain And The Standalone Scheduler

Maintain settings (step toggles, intervals, clean budget, remote host, and thresholds) use Infisical overrides when a connection is configured.  Without one, local configuration and built-in defaults remain available.  The Swift Mac app reads the cache via `InfisicalStore` and writes through on connected changes; the Python engine (`scripts/vacuum/config.py`) consumes them through `apply_env_overrides()`, supporting both `hoghunter.maintain.*` and `HOGHUNTER_MAINTAIN_*` environment variables.

- With a configured connection, a Maintain save (a step toggle or the remote server SSH host) writes to Infisical first.  If that write fails, the save fails: the Mac shows the error, reloads the value Infisical still holds, and does not write the local `config.json`.  In connected mode the local file is only written after Infisical accepted the value; a read-only connection therefore rejects these writes.  Without a configured connection, saves use the local configuration directly.
- The lane doctor settings in `scripts/vacuum/lanes.py` keep report age (15 minutes), doctor schema (2), doctor timeout (5 minutes), and the 24-hour dependency floor as code constants.  Merged-worktree retention is configurable from 1 to 90 whole days, defaults to 7, and invalid values fail safe to 7.
- `lanes.doctor_command` and the `HOGHUNTER_LANE_DOCTOR_COMMAND` override name where the lane doctor is installed on this Mac.  That is a machine-local path, like `hoghunter_clean` and `data_dir`, not a fleet knob.

## Runtime Contract

1. **Load at startup.**  `HogHunterApp.init` starts `InfisicalSettings.shared.bootstrap()` asynchronously.  A configured machine identity logs in through Universal Auth, then reads its explicit project and prod folder.  Service-token mode validates token metadata and reads the active project's declared folders directly, without Universal Auth login.  Both use `GET /api/v3/secrets/raw` to populate `InfisicalStore`.  Launch never blocks on network access; no usable saved connection means local operation, and an offline connected launch can restore only fallback values belonging to that same target.
2. **Never fetch per lookup.**  `CleanPressure`, `CleanRegimen` (via its `effective*` values), `Alerts`, and `HogStore` read `InfisicalStore.shared`, a lock-protected dictionary with no network code.  The settings owner performs network requests only for bootstrap, explicit sync, scheduled refresh, candidate connection validation, and write-through saves.
3. **Background refresh.**  A 60-second timer checks whether `hoghunter.settingsRefreshMinutes` (default 5) has elapsed since the last successful sync, and becoming active permits a refresh after a minimum 30-second gap.  A failed refresh preserves the current target's last-known-good cache and sets `lastError` in Settings > Advanced.  A successful refresh applies synchronized values over local fallback.  Missing credentials do not trigger a machine-identity fallback.
4. **Write-through on connected admin save.**  `PATCH /api/v3/secrets/raw/{key}` runs before updating the cache; a missing key uses `POST` with the same project and folder.  A failed write leaves the cache unchanged and surfaces an error.  General settings may retain a local edit until the next successful refresh reasserts the connected value; Maintain saves reject the change and retain the previous local configuration.  With no configured connection, settings remain local.  In service-token mode, read-only folders reject writes, and a successful read must establish key-to-folder provenance before any write.  The Advanced tab's Push Current Values is the non-secret seed surface and follows the same permission checks.

## Admin Gating

The settings surface is gated by the app's existing admin concept: there is none beyond the local user, because this is a single-user local app.  The local user IS the admin, and the gate is the documented fact that only someone at this Mac's Settings window can change these values -- the same trust boundary as every other setting in the app.  The iPhone companion changes settings only when the owner has turned on Allow iPhone to Change Exclusions & View in Settings > iPhone (off by default), and only these four migrated knobs: `hoghunter.refreshInterval`, `hoghunter.alertThresholdPercent`, `hoghunter.alertSustainedMinutes` and `hoghunter.alertWebhookURL`.  It asks the Mac, over the paired phone's own token and only from the local network or Tailscale; it never talks to Infisical.  The Mac checks every value (refresh 2, 3, 5, 10 or 15 seconds; threshold 100 to 1000 percent in steps of 50; sustained 1 to 30 minutes; webhook an `https` address or empty) and applies the change through the same properties the Settings window uses, so the write-through in Runtime Contract runs unchanged, including its failure behavior.  The webhook URL is a secret: the Mac never sends it to the phone, which sees only whether one is set and the last two labels of its host, and can replace or clear it.  `alertsEnabled` stays a per-user consent toggle outside Infisical sync; the phone can flip it too.

## Rotating A Value

For a connected app, edit the key in the Infisical dashboard in the active project's declared prod folder.  For an unconfigured app, edit the local setting instead.  For a connected value, the app picks it up within `hoghunter.settingsRefreshMinutes` (default 5 minutes), or immediately via Settings > Advanced > Sync Now.  To rotate a credential, replace its secret in Settings > Advanced and save; the candidate is verified before replacing the current connection.  Never put a secret in code, a log, a PR body, or chat -- names and metadata only.

## Local Development

Without a usable saved connection, runtime Infisical requests are inert and the app uses local settings and built-in defaults.  Native tests inject networking, credential persistence, and migration storage without accessing live Infisical credentials or the real Keychain.  Unit-test and build verification need no Infisical access; release jobs use the scoped token contract above for their required signing material and optional telemetry.  The pre-retirement legacy machine-identity file read is described under Who Owns The Infisical Read; it ends permanently after an explicit successful save or clear.

## Selecting Another Project

Settings > Advanced selects the authentication mode, active Project ID, and folder.  Machine-identity mode accepts Client ID and Client Secret; service-token mode accepts multiple entries with explicit project, folder, and read/write roles.  The host remains `https://app.infisical.com` and the environment remains `prod`.  Records without a valid Project ID remain unconfigured; there is no built-in project destination or shared Automation credential fallback.

Save validates the UUID Project ID, folder, and selected mode's credentials.  A machine identity must authenticate and read the chosen prod folder; each service token must pass metadata checks before the active project's folders are read.  Only after validation and reads succeed does the app update the Keychain, retire legacy file fallback, and activate the new connection.  Authentication, scope, access, or Keychain failures preserve the previous connection and cache.  Secret values are never trimmed, logged, or included in error messages.

A successful project, authentication-mode, or read-folder target change replaces the cache rather than merging it and resets target-derived effective and persisted fallback values, including the alert webhook.  Same-target refresh failures retain last-known-good settings.  A persisted target marker keeps another project or folder's fallback out of an offline relaunch.  Clearing a connection also clears its project-derived values.  Display preferences and consent choices are unaffected.

Every in-flight refresh, write, and queued settings edit is bound to its original connection generation.  An old operation cannot update the new connection or redirect a queued batch into its project.  A write already sent to the old project may still complete there; its late response is discarded locally.  Concurrent saves are rejected, and a clear invalidates pending saves.

Synthetic regression coverage lives in `InfisicalProjectSelectionTests.swift`; HTTP routing is covered in `InfisicalSettingsTests.swift`.  These tests inject credential persistence and never access the Keychain or a real Infisical identity.  This feature does not create identities, grant project permissions, rotate credentials, add telemetry, or change the iPhone companion.

## Optional Service Tokens And Folder Routing (HH-199)

The active Project ID selects which saved token routes supply settings.  Each token entry declares its Project ID, exact prod folder, Read Settings flag, and Write Settings flag.  Entries for other projects may be saved together; they are not read into the active project's cache.  Separate read-only and write-only tokens for one folder are supported, as are several non-overlapping read folders.  A write folder must also have a read route, and the explicit New Settings Write Folder must have a write token unless the entire active configuration is read-only.  A configuration may be entirely read-only; attempted admin writes then fail visibly without changing the cache or trying another identity.

Every service token is checked using its own `GET /api/v2/service-token` metadata before accepting a configuration.  The authoritative response must match the declared project, exactly one prod folder scope, and every requested read/write permission.  Multiple or wildcard scopes are refused: Infisical's legacy bulk service-token read can return its own scopes regardless of `secretPath`, so a successful secrets request alone cannot validate folder authority.  This intentionally requires one folder scope per token; add another token for another folder.  Token permissions are checked again before a write.  Revoked, expired, missing, or mismatched authority fails closed; no machine-identity fallback occurs.

Reads explicitly send `workspaceId`, `environment=prod`, `secretPath`, `recursive=false`, and `include_imports=false`.  Settings from different folders are aggregated only when key names do not overlap; duplicate keys reject the candidate or refresh instead of choosing an arbitrary value.  An existing key writes back to its read folder, using that folder's sole write token.  New keys use New Settings Write Folder.  Both PATCH and the 404 create fallback carry the exact same project and folder.  Read-only tokens are never sent to a write endpoint.

The cache target includes authentication mode and read folders as well as project identity, so switching folders within one project discards the prior folder's persisted effective settings.  Generation fences reject queued or in-flight work from the previous connection after a mode, token, project, or folder change.  A failed refresh retains the same connection's last-known-good cache; a failed candidate save preserves the existing connection.  Explicit Clear invalidates pending saves and returns to local settings.

API contract: [Infisical's service-token route](https://github.com/Infisical/infisical/blob/main/backend/src/server/routes/v2/service-token-router.ts) returns direct projectId/workspace, scopes, and permissions fields.  Synthetic tests in `InfisicalServiceTokenTests.swift`, `InfisicalSettingsTests.swift`, and `InfisicalProjectSelectionTests.swift` inject networking and persistence; they never use live tokens or the real Keychain.  The iPhone receives effective settings only and has no credential transport or storage.

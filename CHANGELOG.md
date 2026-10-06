# Changelog

## 1.0.6 — Tue, Oct 6, 2026

Mac side:

- Companion snapshot now ships the top eight storage-heavy apps (with the bundle vs hidden split and the hidden-heavy flag) so the phone can show "Mac Storage by App" without owning its own scanner.  The scan runs on a utility queue, caches for five minutes, and is kicked off by `HogStore` whenever Share With iPhone is enabled (plus a five-minute timer while it stays on).

iOS companion:

- The Storage tab reorders: Mac Disk Usage is now the first section, with the new "Mac Storage by App" section right below it.  The iPhone Storage section sits below both.  Previously the iPhone-Storage section sat on top and several users confused it with the Mac storage because the picker defaulted to Activity and the title read "iPhone".
- New "Mac Storage by App" section renders the snapshot's `CompanionAppStorageRow`s: name + total on top, bundle / hidden numbers beneath, an "approx" tag when a walk had to short-circuit, a red triangle + red row background when hidden bytes are at least five times the .app bundle and over 200 MB, and a "Scanned … ago on &lt;host&gt;" footer from `topAppsScannedAt`.  While the host's first scan is still in flight the section shows a "Scanning installed apps on &lt;host&gt;." hint instead of silently omitting itself.

CI:

- The `Capture app screenshots` step in `.github/workflows/ci.yml` is now wall-clock capped at 8 minutes, marked `continue-on-error: true`, and the matching upload step warns instead of errors on a missing artifact.  This stops the shared macOS-15 runner's two-attempt hang from cancelling the entire `test` status check and blocking PR merge (branch protection does not allow admin override of a `cancelled` required check).

Tests: 200 total, 0 failures (4 new — `CompanionAppStorageTests` pins the new Codable, the backward-compat decode, the always-non-nil topApps array, and the cached-after-invalidate behaviour).  iOS Simulator build green locally.

## 1.0.5 — Mon, Oct 5, 2026

Mac Activity panel:

- The TIME / SHOW / SORT controls now use a custom `SegmentedToggleGroup` instead of a stock segmented `Picker`.  Every segment gets the same 8 pt L/R internal padding so the spacing feels even and short labels (like "Now") are visibly narrower than long ones (like "Past 24 Hours"), instead of every segment being padded to the longest label.
- The sort-direction arrow has moved from sitting next to the SORT picker to being pinned to the far right of the controls row.  The three toggle groups now sit evenly across the row with the arrow as a clear right-anchored control.

iOS companion:

- The Activity / Storage / Network tab picker is now visible at the top of every dashboard render with a "Tap a tab to switch view." caption above it.  Previously the picker existed but defaulted to Activity, so users missed the Storage and Network views entirely on first launch.
- The Storage tab now includes an "iPhone Storage" section above the existing "Mac Disk Usage" section, showing the iPhone's own used / free / total storage with the same colour thresholds (red above 90 %, orange above 80 %).  Implementation reads `URL.resourceValues(forKeys:)` against the iOS sandbox root `/`; no extra entitlement needed.
- The offline / looking status page now explicitly nudges first-time users on cellular toward Tailscale, with the recommended port (`\(CompanionModel.defaultPort)`) and a worked example of what to type (`my-mac.tailnet.ts.net`).  The Connect by Tailscale or Address button was already there; the copy now makes the path obvious instead of hidden behind "Open Hog Hunter on your Mac".

Tests: 196 tests, 0 failures (no new tests — the change is layout polish plus a 30-line storage helper that's exercised through the iOS app at runtime).

## 1.0.4 — Wed, Sep 30, 2026

- Fleet-wide version alignment: aligned macOS and iOS companion marketing versions to `1.0.4` with UTC timestamp build numbers (`YYYYMMDDHHMM`), conforming to fleet-wide release numbering standards across all platforms and retiring legacy `1.4.0 (6)`.
- CI visual verification: added multi-format screenshot capture (iPhone 6.9"/6.7", 6.3"/6.1", 5.5"/4.7", iPad 13", iPad 11", and macOS window) as a blocking gate and CI artifact in GitHub Actions.
- MiniMax Remote decommissioning: expired all builds and revoked public TestFlight links in App Store Connect.

## 1.4.0 — Sat, Sep 26, 2026

iPhone:

- Hog Hunter iPhone companion.  It finds the Mac on the same Wi-Fi or connects remotely over Tailscale to monitor activity, storage, and network connections.  When enabled in Mac Settings, you can safely tame runaway CPU hogs, quit apps, and trigger a safe disk clean.
- On the Mac, Settings has Share With iPhone.  It is off until you turn it on.  The pairing code is shown there.  New Code replaces it.  The code is not advertised on the network.
- Remote control capabilities (quitting/taming apps and running the safe disk cleaner) require individual opt-in in Mac Settings or the pairing approval dialog.
- The phone asks for Local Network access so it can see the Mac.  Allow it on both devices if macOS or iOS asks.

Icon:

- The Finder, About, and notification icon is the Hog Hunter lockup.  macOS still applies its own rounded mask.  The menu bar glyph is still the flame plus the live CPU number.
- The iPhone app uses the same lockup.

## 1.3.0 — Tue, Sep 22, 2026

Storage pane:

- New top-level Storage window reachable from the gear menu and the Settings About row, showing the top 25 installed apps by disk usage with a hidden-cost-versus-bundle split.  Rows are flagged red when `hidden` is more than 5× the bundle size and above 200 MB — the case HogHunter's pane exists to surface (a 200 MB `Chrome.app` that actually owns 5 GB once you add its caches, containers, saved state, logs, cookies, HTTP storage, application scripts, group containers, WebKit/Chromium data, and Application Support).
- Per-app category breakdown when a row is expanded, so the user can see exactly where the bytes live: bundle / sandbox containers / group containers / Application Support / caches / WebKit / preferences plist / saved state / logs / cookies / HTTP storage / application scripts.
- Two filter modes (All installed / Running now) and three sort orders (Total / Hidden / Bundle).  Manual Refresh button and a 5-minute auto-rescan while the window is open.
- Per-directory walk capped at 50,000 entries and 3 seconds per target so a runaway `node_modules` or `DerivedData` does not stall the scan; capped rows are flagged "approximate" in the UI.
- 12 new tests pin the path-attribution rules and the per-directory walk.

Network pane:

- New top-level Network window reachable from the gear menu and Settings, showing the apps with the most open connections and most distinct remote hosts.  Snapshot is `lsof -nP -i -F nPTi`, parsed into per-pid buckets; manual Refresh button and a 10-second auto-rescan while the window is open.
- Three sort orders (Established / Remote hosts / Open sockets).  If lsof is missing the user sees "lsof binary missing"; if it errors with `operation not permitted`, the pane surfaces "Grant Full Disk Access to HogHunter" rather than failing silently.
- 9 new tests pin the lsof parser: empty input, single-pid established TCP, multiple-pid sort order, LISTEN sockets with no remote host, IPv6 endpoints split on the closing bracket (not the first colon), top-host cap at 5, fake `ProcessRunner` pass-through for permission-denied and binary-missing cases.

Other:

- `MetadataResolver.lookup(pid:)` and `MetadataResolver.runningBundleIds()` added so the new panes can pull bundle id + display name without a second NSWorkspace hit.
- `HogStore.runningBundleIdsSnapshot()` and `HogStore.lookup(pid:)` expose the resolver to the panes through the environment object.
- Bumped to `1.3.0` / build 5.

## 1.2.0 — Sun, Sep 20, 2026

Performance:

- The running-app resolver now refreshes every fifth tick (matching the history-record cadence) instead of every tick.  `NSWorkspace.shared.runningApplications` enumerates ~250 apps and reading four properties off each costs the main actor ~40 ms per call, so this drops the per-tick cost noticeably on the default 3 s interval.  Every twentieth tick is still a forced refresh so an app that is promoted from accessory to regular (or back) after launch picks up the change within a few seconds.
- Hog Hunter's own process is filtered at the sampler, so the panel no longer shows a row the user cannot act on.

Correctness:

- `HogFormat.cpu`, `.memory`, `.rate`, and `.percent` are now pinned to `en_US_POSIX`, so a French or German Mac prints `1.5 GB` and `99.6%` (matching Activity Monitor) instead of `1,5 GB` and `99,6 %`.
- `AlertPolicy` is reset whenever alerts are toggled off, so re-enabling starts from a clean slate.  A row that was in cooldown when alerts were turned off can no longer fire immediately, and a row that was four minutes into a five-minute sustained window can no longer finish where it left off.
- `Severity.forProcessCpu` now takes a `CpuScale` and a `coreCount`, so the colour of a row tracks the value the user is actually looking at.  A process showing `12.5%` on the `machineShare` scale (one core on an 8-core machine) is calm, even though the same value on the per-core scale would have been elevated.

User interface:

- The panel header now shows a small bell icon next to the name when alerts are on, with the threshold and sustained duration as the tooltip.
- The header title and staleness dot are now a single accessibility element, so VoiceOver announces the panel state once.
- The whole panel is wrapped in a single accessibility element labelled `Hog Hunter — top processes`, so VoiceOver does not read row-by-row with no panel context.
- `attributionCaption` returns `nil` on an idle machine where everything is zero and every process is readable, so the panel hides the line instead of printing `0% · 0% (0 processes not readable)`.

## Unreleased

- Finder, About, and notification chrome now use a square app icon adapted from the boar emblem.  The artwork is a full-bleed 1024 canvas with no pre-applied squircle crop; macOS applies the system mask at display time.

## 1.1.0 — Wed, Sep 10, 2026

Sampling and data layer:

- Fixed per-process CPU: `proc_taskinfo` and `proc_pid_rusage` ticks are mach absolute-time units and are now converted with `mach_timebase_info`, so a row matches Activity Monitor instead of reading 41.7x too small.
- Per-process memory is now `ri_phys_footprint`, Activity Monitor's Memory column, with resident size kept for detail only.  Machine memory used follows Activity Monitor's formula, and App Memory, Wired, Compressed and Cached Files are all read.
- Added swap used and swap in/out rates, memory pressure from `kern.memorystatus_vm_pressure_level` with an immediate `DispatchSource` reaction, and thermal state.
- Processes are keyed by `ProcessKey(pid, startTime)`, so a recycled pid starts a fresh baseline instead of inheriting the old process's counters.
- Grouping walks `ppid` to the nearest regular app, then falls back to bundle id and executable path.  Two unrelated `node` processes no longer merge.
- Quitting re-checks identity, ownership and a denylist of processes that keep the desktop alive at the moment of the click, and reports what it skipped.
- History moved to a v2 SQLite schema with WAL: values are summed per timestamp before being divided by the window's tick count, results are memoized, every `sqlite3` return code is checked, and rows older than 24 h are pruned.
- Sampling runs on a utility queue.  LaunchServices work happens only for rows about to be drawn, and a tick that fires while the previous one is still running is skipped.

User interface:

- Added a Settings window (General, Appearance, Alerts, Launch at Login, About), reachable from a new gear menu in the panel header.
- Added CPU alerts: an optional notification when one app stays above a per-core threshold for a chosen number of minutes, with a 30 minute cooldown per app.  Off by default.
- Added an Appearance setting.  Light stays the default; System and Dark are available.
- Meters are tinted by severity, and swap, memory pressure and thermal state now appear as small pills under the memory meter.
- Rows gained a context menu: Copy PID, Reveal in Finder, Sample for 3 Seconds (writes to `~/Library/Logs/HogHunter/` and opens the report), and Open Activity Monitor.
- A row's CPU is colored only when it is elevated or hot, and a row that cannot be quit says why on hover instead of showing a dead button.
- The header staleness dot is now always visible: green when sampling is current, amber when it is behind.
- The Quit confirmation names the app, says how many processes are included, and says plainly what Force Quit will do.
- The menu bar can show the busiest app instead of machine CPU, with its name truncated to fit and help text naming the scale.

Fixes from the 1.1 review:

- Alerts are now evaluated against every process or app above the threshold, not against the 25 rows the panel happens to be showing.  With Sort set to Memory, a CPU hog with a small footprint could previously never trigger a notification.
- The alert cooldown now expires by age instead of by visibility, so a row that drops off the list for a tick and comes back can no longer notify twice inside its 30 minute cooldown.
- Hog Hunter is now the notification centre's delegate, so a sustained-hog alert that fires while the panel or Settings is frontmost is shown instead of being silently dropped with its cooldown already spent.
- Notification authorization is settled at launch when alerts are already on, instead of being requested at the moment the first alert posts.
- The notification body names its scale: "Chrome has used 412% of one core for 5 minutes."
- Changing Window, Show or Sort no longer rebuilds rows inside SwiftUI's own view update, which drew "Publishing changes from within view updates is not allowed".
- The running-application table is now read once per pid instead of once per tick, cutting about 45 ms of main-thread work off every refresh, panel open or closed.
- History rows no longer re-run a file-system lookup for each row's display name on every refresh.
- The metadata cache is pruned every 60 ticks as documented, rather than every 1200.
- The history database is opened, migrated and first-pruned on the sampling queue instead of on the main actor during launch, so upgrading from the old schema no longer stalls the menu bar item for about half a second.
- A history failure now clears once queries work again, and no longer sits in the panel for the rest of the session.
- A failed history read is now reported instead of looking exactly like an empty window, and a `PRAGMA user_version` that cannot be read no longer counts as version 0, which would have dropped a healthy table.
- Errors are attributed to what caused them: the Launch at Login toggle shows only its own failure, a quit's summary is no longer red, and history failures have their own line.
- Two history ticks landing in the same second no longer double that second's CPU and memory, and the coverage note can no longer claim more sampled time than its own window holds.
- The menu bar item now reads the live number to VoiceOver instead of repeating the help text, and its help no longer names the per-core scale when the label has fallen back to machine CPU.
- Memory sizes just under a unit boundary print as "1.0 GB" and "1 MB" instead of "1024 MB" and "1024 KB".
- Memory-pressure transitions no longer add sampling passes on top of the timer; a pressure tick re-arms the timer instead, capping the rate at one pass per refresh interval.
- `stop()` now also cancels the memory-pressure source, `HogRow` equality compares every field except the icon, grouping no longer deep-copies a group's member list on every merge, and the `sample` child process no longer writes into a pipe nobody drains.
- Settings calls the login item "Launch at Login", the same name the panel and the coverage note use.
- Quitting a row that acted on nothing -- everything blocked, changed since sampling, or otherwise failed -- is now reported as an error instead of a neutral notice.
- The running-application table now periodically re-reads every app's activation policy instead of trusting the memo forever, so an app promoted from accessory to regular (or back) is picked up without restarting Hog Hunter.
- The menu bar's busiest-app label is now computed from the full snapshot instead of the panel's own display list: with Sort set to Memory, a high-CPU, low-memory process could previously fall outside the panel's top 25 and be missed entirely.
- A process whose owning app was still launching no longer keeps that half-published name (often just its pid) for the rest of the session; the cached entry is replaced once the app finishes publishing itself.
- A process this user is not permitted to read CPU or memory for, but that still exists, is now counted toward the unreadable-process count instead of silently vanishing from it.
- A history tick that fails partway through recording now rolls back instead of committing a partial row, so a tick with no matching samples (or samples with no tick) can no longer sit permanently in the database.

Infrastructure additions (build, test, and release plumbing; no app behavior changed):

- Added a `HogHunterTests` XCTest target (`Tests/HogHunterTests/`) and a `HogHunter` scheme that builds and runs it, covering `CpuMath` and `MemoryMath` conversion math, `Grouping`, `HistoryStore` aggregation, coverage, same-second ticks, error reporting and the v1-to-v2 migration, `AlertPolicy` sustain, cooldown and flapping behaviour, `MetadataResolver` caching, `HogFormat` formatting, and the alert candidate selection lifted into a pure, testable function.
- Added `HogHunter.entitlements` (empty) and turned on `ENABLE_HARDENED_RUNTIME` for Release builds, with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` so Release binaries carry no `get-task-allow` entitlement.
- Added `.github/workflows/ci.yml`: runs `xcodegen generate` and `xcodebuild test` on macOS for every push to `main` and every pull request.
- Added `scripts/install.sh`: builds Release, signs with the "Developer ID Application" identity when available (adhoc fallback otherwise), verifies the signature, quits and replaces the running install in `~/Applications`, and relaunches.  Supports `--adhoc`, `--no-launch`, and `--dry-run`.
- Updated `build.sh`, `README.md`, and `AGENTS.md` to point at `scripts/install.sh` and the new test target and CI.

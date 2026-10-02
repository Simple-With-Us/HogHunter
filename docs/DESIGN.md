# Hog Hunter 1.1 — design

Owner-facing summary of the overhaul that followed the Sep 8, 2026 audit.  This is the contract the implementation follows.  Line references are to `main` at `9af6bbe` unless noted.

## Goals

1. Every number matches what Activity Monitor or `top` would show for the same thing, or says plainly why it cannot.
2. The tool never becomes the hog: sampling runs off the main actor and does no LaunchServices work for rows nobody is looking at.
3. Quitting a process is deliberate, scoped, and honest about what it will do.
4. The panel answers "why is my Mac slow right now": CPU, memory, swap, pressure, and who is responsible.

## Units and scales

- **Per-process CPU** is Activity Monitor's scale: 100% is one core fully busy.  Ticks from `proc_taskinfo` and `proc_pid_rusage` are mach absolute-time units and are converted with `mach_timebase_info` (`CpuMath`).  A decreasing counter means a new process behind a reused pid and yields 0% with a fresh baseline; the previous-sample cache is keyed by `ProcessKey(pid, startTime)`.
- **Machine CPU** is 0 to 100 across all cores from `host_statistics(HOST_CPU_LOAD_INFO)`.  The UI always labels it "of all N cores".  A setting `cpuScale` (`perCore` default, `machineShare`) converts row values by dividing by `coreCount`; the header and rows are never shown on different scales without the scale being named.
- **Memory** per process is `ri_phys_footprint` (Activity Monitor's Memory column), with `pti_resident_size` kept as `residentBytes` for detail only.  Machine memory used is `(internal - purgeable) + wired + compressor` pages, the Activity Monitor "Memory Used" formula; App Memory, Wired, Compressed and Cached Files are exposed too.  Formatting is binary (GiB shown as GB), matching Activity Monitor.
- **Swap** is `vm.swapusage` used bytes, shown as used, never as percent of total, because the pool grows on demand.  Swap in/out rates come from `vm_statistics64.swapins/swapouts` deltas times page size.
- **Memory pressure** is `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical), refreshed every tick, with a `DispatchSource.makeMemoryPressureSource` to react immediately.

## Module layout

```
Sources/
  App/HogHunterApp.swift          MenuBarExtra + Settings scene
  Models.swift                    enums, HogRow, MachinePulse, ProcessKey, ProcessSample, HogFormat, Severity
  Sampling/CpuMath.swift          pure tick-to-percent and wrap-guard math (tested)
  Sampling/SystemStats.swift      host port held once; CPU, memory, swap, pressure, thermal
  Sampling/Sampler.swift          proc_listpids + proc_pidinfo + proc_pid_rusage -> [ProcessSample], MachinePulse; no AppKit
  Sampling/MetadataResolver.swift main-actor cache: display name, bundle id, icon, activation policy, per ProcessKey / bundle id
  Store/Grouping.swift            pure grouping by nearest regular-app ancestor (tested)
  Store/ProcessControl.swift      quit/force-quit with identity, ownership and denylist checks
  Store/Alerts.swift              sustained-threshold notifications
  Store/HogStore.swift            @MainActor orchestration, sampling queue, persistence of choices
  History/HistoryStore.swift      SQLite v2, WAL, per-timestamp aggregation, memoized aggregates (tested)
  UI/HogHunterPanel.swift         panel
  UI/Meters.swift                 CPU and Memory meters with captions and severity color
  UI/RowView.swift                row with context menu
  UI/SettingsView.swift           settings
  Assets.xcassets/AppIcon         Square Finder/About icon; no pre-applied squircle crop
Tests/HogHunterTests/             XCTest: CpuMath, MemoryMath, Grouping, HistoryStore, HogFormat, AlertPolicy, MetadataResolver
scripts/install.sh                build, sign, install to ~/Applications, relaunch

## App icon

The Finder / About / notification icon is `Assets.xcassets/AppIcon.appiconset`, compiled from the square Hog Hunter lockup (boar, wordmark, and the line "Monitor. Detect. Reclaim.").  The source is not squircle-cropped; macOS applies the system mask at display time.  `LSUIElement` still hides the Dock icon while the menu bar extra is running.  The menu bar extra itself stays the flame glyph plus the live CPU number.  The iPhone app uses the same lockup at 1024×1024.
.github/workflows/ci.yml          macOS runner: xcodegen + xcodebuild test
HogHunter.entitlements            empty; Release has no get-task-allow and hardened runtime on
```

## Data types (Models.swift)

```swift
struct ProcessKey: Hashable, Codable { let pid: pid_t; let startTime: UInt64 }   // ri_proc_start_abstime, 0 if unknown

struct ProcessSample: Identifiable {
    var id: ProcessKey { key }
    let key: ProcessKey
    let ppid: pid_t
    let uid: uid_t
    let name: String              // proc_name, or last path component when longer than 31 chars
    let path: String              // proc_pidpath, "" if unavailable
    let cpuPercent: Double        // per-core scale; 0 until a baseline exists
    let hasBaseline: Bool
    let footprintBytes: UInt64    // ri_phys_footprint; falls back to residentBytes
    let residentBytes: UInt64
    let threadCount: Int
    let diskReadBytesPerSec: Double
    let diskWriteBytesPerSec: Double
    let idleWakeupsPerSec: Double
    let isKernelTask: Bool        // pid 0 when readable
}

enum MemoryPressure: Int { case unknown = 0, normal = 1, warning = 2, critical = 4 }

struct MachinePulse: Equatable {
    var cpuPercent: Double                 // 0-100 across all cores
    var coreCount: Int
    var visibleCpuPercent: Double          // sum of readable per-core CPU / coreCount, 0-100
    var readableProcessCount: Int
    var unreadableProcessCount: Int        // taskinfo denied (other users, root)
    var memoryUsedBytes: UInt64            // Activity Monitor formula
    var appMemoryBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedFilesBytes: UInt64
    var totalMemoryBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    var swapInBytesPerSec: Double
    var swapOutBytesPerSec: Double
    var pressure: MemoryPressure
    var thermalState: ProcessInfo.ThermalState
    var sampledAt: Date
    var memoryPercent: Double { total > 0 ? used / total * 100 : 0 }
}

struct HogRow: Identifiable, Hashable {
    var id: String                // "a-<groupKey>" | "p-<pid>-<start>" | "h-<key>"
    var keys: [ProcessKey]        // live members; empty for history rows
    var name: String
    var detail: String            // e.g. "com.google.Chrome · 7 processes" or "pid 812 · 14 threads"
    var cpuPercent: Double        // per-core scale, before cpuScale conversion
    var memoryBytes: UInt64       // footprint, summed for groups
    var peakMemoryBytes: UInt64?  // history only
    var presence: Double?         // history only: fraction of window samples the key appeared in
    var icon: NSImage?
    var path: String?
    var isApp: Bool
    var isGroup: Bool
    var canQuit: Bool
    var quitBlockReason: String?  // "system process", "owned by another user", "this app"
}
```

`HogRow` equality compares every stored property except `icon`, which is a shared `NSImage` reference.  `HogFormat.cpu` prints one decimal below 100 and an integer at or above 100, and always the "%" suffix; `HogFormat.memory` prints integer MB below 1 GB and one-decimal GB above, binary units; `HogFormat.rate` prints "12 MB/s".

## Sampler contract

`final class Sampler` (not main-actor; owned by a serial `DispatchQueue(label: "hoghunter.sampling", qos: .utility)`).

`func snapshot() -> Snapshot` where `Snapshot { pulse: MachinePulse; processes: [ProcessSample]; hasBaseline: Bool }`.

- Enumerate with `proc_listpids` using a buffer with 25% slack, re-read if the second call reports growth.
- For each pid including 0: `proc_pidinfo(PROC_PIDTBSDINFO)` for ppid, uid, start time fallback; `proc_pid_rusage(RUSAGE_INFO_V4)` for user/system ticks, footprint, disk bytes, wake-ups, `ri_proc_start_abstime`; `proc_pidinfo(PROC_PIDTASKINFO)` for `pti_threadnum` and RSS.  A pid whose rusage and taskinfo both fail with EPERM is counted as unreadable.  Confirm empirically whether pid 0 is readable; if so it is the `kernel_task` row, `canQuit` false.
- CPU: `CpuMath.percent(currentTicks:previousTicks:elapsed:tickToNanos:)` returns `nil` when `current < previous` (new baseline) and never returns a value above `100 * coreCount * 1.5`.
- Return every readable process.  Truncation happens in the store, after sorting by the user's choice.
- No AppKit, no LaunchServices, no icons.  Names are `proc_name` or the path's last component.

## SystemStats contract

`final class SystemStats` holds `mach_host_self()` once, releases it in `deinit`, and exposes `func read(previous: SystemStats.Raw?) -> (MachinePulse fields, Raw)`.  `MemoryMath.used(internal:purgeable:wired:compressor:pageSize:)` is a pure, tested function with saturating subtraction.  Machine CPU handles 32-bit tick counter rollover by treating a negative delta as "skip this sample".

## MetadataResolver contract (main actor)

`func resolve(_ keys: [ProcessKey], samples: [ProcessKey: ProcessSample]) -> [ProcessKey: Metadata]` where `Metadata { displayName, bundleId, icon, activationPolicy, isRunningApplication }`.  Cache per `ProcessKey`; icons cached per bundle id or path; `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` and `FileManager.displayName(atPath:)` cached per bundle id.  Called only for rows about to be displayed, plus the top hog for the menu bar label and any process already above the alert threshold.  `prune(live:)` drops entries for vanished keys; the store calls it every 60 ticks and the resolver does not throttle itself.

`refreshRunningApps()` runs every tick, but an `AppInfo` is built once per pid: enumerating `NSWorkspace.shared.runningApplications` is cheap while reading `bundleIdentifier`, `localizedName`, `activationPolicy` and `bundleURL` off ~250 apps costs 40-50 ms of main-thread time.  An entry whose bundle id, name or URL is still nil is not settled yet -- those publish asynchronously after a launch -- so it is read again next tick.  The enumeration is injected through `RunningApplicationInfo` so a test can prove the once-per-pid rule.

## Grouping contract (pure, tested)

`enum Grouping { static func groups(_ samples: [ProcessSample], isRegularApp: (pid_t) -> Bool, bundleId: (pid_t) -> String?) -> [Group] }`

- Walk `ppid` upward (bounded, cycle-safe) to the nearest ancestor for which `isRegularApp` is true; that ancestor is the group owner.  Stop at pid 1.
- If none, group by `bundleId` when present, else by executable `path`, never by bare name.  Two unrelated `node` processes never merge.
- A group's `cpuPercent` is the sum of members; `memoryBytes` is the sum of member footprints; `detail` names the owner's bundle id and the member count.

## ProcessControl contract

`func quit(_ row: HogRow, force: Bool) -> QuitOutcome` where each member is checked in order: identity (current `ri_proc_start_abstime` equals the key's `startTime`, otherwise skipped as "changed since sampling"), ownership (`uid == getuid()`), denylist (`kernel_task`, `launchd`, `WindowServer`, `loginwindow`, `Finder`, `Dock`, `SystemUIServer`, `ControlCenter`, `NotificationCenter`, `coreaudiod`, and Hog Hunter itself), then action: `NSRunningApplication.terminate()` / `forceTerminate()` when the pid is a running application, else `kill(SIGTERM)` / `kill(SIGKILL)`.  Returns per-member results for the UI.  `canQuit` on a row is false when every member is blocked, and `quitBlockReason` explains why.

Alert copy: title "Quit <name>?", message "Asks <name> to quit.  It may show a save prompt or refuse.  <N> processes are included." and for force "Force Quit ends <N> processes immediately.  Unsaved work is lost."  Buttons: Cancel (Escape dismisses it; Return is not bound to any of the three, so a reflex press cannot trigger Quit or Force Quit), Quit, Force Quit (destructive).

## HistoryStore v2

```sql
PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA user_version=2;
CREATE TABLE ticks   (ts INTEGER PRIMARY KEY);
CREATE TABLE samples (ts INTEGER NOT NULL, pid INTEGER NOT NULL, start INTEGER NOT NULL,
                      key TEXT NOT NULL, group_key TEXT NOT NULL, name TEXT NOT NULL, bundle TEXT,
                      cpu REAL NOT NULL, mem INTEGER NOT NULL, reason INTEGER NOT NULL);
CREATE INDEX samples_ts ON samples(ts);
```

- The database is opened, migrated and first-pruned lazily, inside the lock, by whichever entry point is called first -- `HogStore` primes it on the sampling queue -- so a v1 upgrade's `DROP TABLE` never stalls the main actor while the menu bar item is being built.
- On open, if `user_version < 2` the old `samples` table is dropped (it held at most 24 h of values that were 41.7x too small) and the v2 schema is created.
- `record(ticks:)` deletes any `samples` rows already at this whole-second timestamp (last write wins, so two ticks inside one second cannot double that second's sums), then inserts one `ticks` row and the union of the top 25 by CPU and the top 25 by footprint (`reason` bit 1 = CPU, bit 2 = memory), with `cpu` clamped to `[0, 100 * coreCount * 1.5]`.  Every `sqlite3_open`, `sqlite3_exec`, `sqlite3_prepare_v2` and `sqlite3_step` return code is checked and failures set `lastError`; bind indices are static and every non-nullable column is `NOT NULL`, so a bind failure surfaces as a constraint error on step.
- `lastError` is cleared at the start of `record` and of `aggregates` -- the first call of each batch the store makes (record then prune, aggregates then coverage) -- so a transient failure clears once the database works again while the second call in a batch can never erase the first one's error.  A failure to open is never cleared.
- `aggregates(lookback:groupByApp:sort:)` sums per timestamp first, then divides by the window's tick count:

```sql
WITH win AS (SELECT COUNT(*) AS n FROM ticks WHERE ts >= :cutoff),
per_ts AS (SELECT ts, :k AS k, SUM(cpu) AS cpu, SUM(mem) AS mem, MIN(name) AS name, MIN(bundle) AS bundle
           FROM samples WHERE ts >= :cutoff GROUP BY ts, k)
SELECT k, name, bundle, SUM(cpu) * 1.0 / win.n, SUM(mem) * 1.0 / win.n, MAX(mem), MAX(cpu), COUNT(*), win.n
FROM per_ts, win GROUP BY k ORDER BY <avg_cpu | avg_mem> DESC LIMIT 40
```

  Results are memoized per `(lookback, groupByApp, sort, lastRecordedTs)` so the panel can rebuild every tick without re-running the query.
- `coverage()` returns `(sampledSeconds: min(ticks * interval, lookback), firstTs)`; the coverage note says "Sampled 3h 12m of the last 24 h".  Ticks are valued at the current refresh interval, so the answer can be short after a cadence change, but the clamp keeps it from ever exceeding its own window.
- `prune()` runs on open and every 20 minutes, deleting `samples` and `ticks` older than 24 h.

## HogStore

- Owns the sampling queue.  `tick()` dispatches `sampler.snapshot()` to the queue, then hops to the main actor to resolve metadata for displayed rows, rebuild rows, update the label, evaluate alerts, and record history every 5th tick.  If a tick is still running when the timer fires, the fire is skipped.
- Timer: interval from settings (2, 3 or 5 s, default 3), tolerance 0.5 s, added in `.common` run loop mode.
- `panelVisible` (set by the panel's `onAppear` / `onDisappear`) gates history aggregation.  Metadata resolution is bounded by the row limit rather than by visibility: alerts, the menu bar label and history recording all need names with the panel closed, and the running-app table is memoized per pid, so the ungated cost is under 0.2 ms a tick.
- A `@Published` `didSet` that rebuilds rows (`window`, `grouping`, `sort`) hops the rebuild to the next main-actor turn, because the `didSet` runs inside SwiftUI's own view update and reassigning `rows` there is "Publishing changes from within view updates is not allowed".
- Memory-pressure transitions call `tick()` and re-arm the timer, and are ignored when a tick already ran inside the current refresh interval, so pressure flapping cannot multiply the sampling rate.
- Persisted choices via `@AppStorage`: `window`, `grouping`, `sort`, `cpuScale`, `menuBarLabelMode` (`machinePercent` default, `topHogName`), `refreshInterval`, `alertsEnabled` (default off), `alertThresholdPercent` (per-core, default 300), `alertSustainedMinutes` (default 5), `appearance` (`light` default, `system`, `dark`).
- `menuBarLabel`: machine percent by default; with `topHogName`, "<name> <cpu>" on the chosen scale.  Both carry a `help` string naming the scale.
- `hasBaseline` false until the second snapshot; the panel shows "Measuring…" until then.  `isStale` true when `now - pulse.sampledAt > 3 * interval`.
- Visible-versus-invisible caption: "<visible>% attributed to <n> visible processes · <rest>% other users, root and kernel (<m> processes not readable)".

## Alerts

`Alerts.evaluate(candidates:, threshold:, sustained:, now:)` tracks first-exceeded time per row id, fires one `UNUserNotificationCenter` notification when a row has stayed above the per-core threshold for the sustained duration, then applies a 30 minute cooldown per id.  The candidate list is every process or app group at or above the threshold, built by `HogStore` from the whole snapshot -- never from the display list, whose Sort choice and 25-row limit would otherwise decide whether an alert can fire at all.  The cooldown expires by age rather than by visibility, so a row that leaves the candidate set and comes back cannot notify twice inside one cooldown.  The notification body names the scale it is measured on: "Chrome has used 412% of one core for 5 minutes."

`Alerts` is the notification centre's delegate and answers `willPresent` with `[.banner, .list, .sound]`; without a delegate macOS silently drops any alert that arrives while Hog Hunter is frontmost, and the cooldown would still be spent.  Authorization is requested when the setting is switched on, and once at launch when it is already on, so the decision is settled long before a row can fire; denial is shown next to the toggle.

## Panel

- Header: name, staleness dot, and a menu with Settings, Activity Monitor, Quit Hog Hunter.
- Meters: CPU ("42% of all 10 cores", color by severity) and Memory ("13.3 of 16 GB · 16.9 GB swapped · pressure warning", color by pressure).  Under them, the visible-versus-invisible caption and, when swapping, "swapping in 120 MB/s".
- Controls: Window (Now, Past Hour, Past 24 Hours), Show (Apps, Processes), Sort (CPU, Memory).  Choices persist.
- Rows: icon, name, detail, CPU and memory in tabular numerals, a Quit button only when `canQuit`, and a context menu: Copy PID, Reveal in Finder, Sample for 3 Seconds (writes to `~/Library/Logs/HogHunter/` and opens it), Open Activity Monitor.  History rows show "avg CPU · peak <mem> · seen <presence>%".
- Footer: Launch at Login toggle with its own error beside it, coverage note, and a one-line scale legend: "Rows: % of one core.  Header: % of all cores."  Settings uses the same "Launch at Login" name, under a "Startup" section.
- Errors are separated by source: `lastError` (a failed sample or quit) and `historyError` (the database) show in red under the meters, `lastNotice` (what a quit actually did, which is often not a failure) shows in secondary text, and `loginItemError` only ever appears beside the Launch at Login toggle.
- Accessibility: every meter and icon carries a label and value.  Light is the default appearance; System and Dark are settings.

## Build, signing, install

- `project.yml` gains a `HogHunterTests` unit-test target and Release settings `ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, `CODE_SIGN_ENTITLEMENTS = HogHunter.entitlements` (an empty dict).
- `scripts/install.sh` builds Release, signs with "Developer ID Application" when that identity is in the keychain and signing does not prompt within 20 s, otherwise adhoc, then `ditto`s to `~/Applications/Hog Hunter.app`, quits the running instance, and relaunches.  `build.sh` stays as the plain build.
- CI runs on `macos-15`: `brew install xcodegen`, `xcodegen generate`, `xcodebuild -scheme HogHunter -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO`.

## Copy rules

Two ASCII spaces between sentences in every user-facing string.  Buttons, headings and titles in Title Case.  Status text in sentence case.  Times in Central Time when shown.

## Out of scope for 1.1

Privileged helper for root processes, per-process network, GPU, Rosetta and sandbox badges, keyboard navigation, Sparkle updates.  Each is listed in the audit roadmap with its reason.

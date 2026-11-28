# The floors the owner runs with are the floors the repo ships, and the Storage tab scrolls as one

Date: Nov 23, 2026
Seat: MM
Repo: HogHunter
Board: HH-236
Refs: HH-231, HH-234, HH-235

## What was wrong

Three separate problems showed up in the same cleanup pass, and all three are about the gap between what the app does on this Mac and what the repo says it does.

The first is the reclaim floors.  Seat MA's Nov 23 cleanup found the Mac at 137 GiB free after a long fight, and left a set of floors behind as a live override in `~/Library/Application Support/HogHunter/Maintain/config.json`: reclaim below 100 GiB free, pressure at 80, critical at 45, a clean every 30 minutes and every 10 minutes under pressure, worktree retirement at three days, a PM2 log cap of 50 MB, and the remote server step and the CleanMyMac step turned on.  Those numbers were never in the repository, so `config/robotic-vacuum.json` still shipped 80, 65, 30, seven days, 7200 seconds and 1800 seconds.  A fresh clone, a rebuilt install or a new machine silently goes back to waiting until the disk is nearly full before it reclaims anything.  MA tried to land the alignment and the relay's scanner refused the write, so the numbers stayed in one file on one Mac.

The second is the disk hog nobody prunes.  The MiniMax Code runtime keeps every session's messages, snapshots and workspace tree under `~/.minimax/v2`, and nothing ever prunes it.  On this Mac that tree held 14.7 GB, of which 5.4 GB was sixty workspace directories and 3.8 GB was session trees, and it grows with every session.  The cleaner already reclaimed Grok sessions, Codex archived sessions, Antigravity brain folders and BotFleet update packages, so the omission was not a policy decision but a gap in the list.

The third is the Storage tab, and it is what the owner saw on screen.  The Disk Cleaner's category list was squeezed into a thin strip at the bottom of the window, about sixty points tall, with the rest of the height going to a large mostly empty area above it, and only that strip scrolled.  The cause is in `Sources/UI/DiskCleanerView.swift`: the header's own `Spacer()` took every spare point of the window, and the category list lived in a second `ScrollView` below it, so the list got what was left over, which was almost nothing.  The owner's instruction was plain: the whole tab should scroll, not just the bottom tiny portion.

Two more things on the same pass were about the app taking over the owner's screen.  The launchd vacuum runs every 300 seconds, and its alert path shelled out to `tell application "Hog Hunter" to display notification`, which **launches** the app when it is not running and brings it forward, so the Hog Hunter window appeared on its own every few minutes.  And `Sources/App/AppActivationManager.swift` called `NSApp.activate(ignoringOtherApps: true)` and `makeKeyAndOrderFront(nil)`, so a window that appeared took the keyboard away from whatever the owner was typing in.

## What changed

`config/robotic-vacuum.json` now ships MA's floors:

| Setting | Was | Now |
| --- | --- | --- |
| `janitor.low_free_gib` | 80 | 100 |
| `janitor.pressure_free_gib` | 65 | 80 |
| `janitor.crit_free_gib` | 30 | 45 |
| `lanes.retire_min_days` | 7 | 3 |
| `resource_watch.clean_cooldown_sec` | 7200 | 1800 |
| `resource_watch.clean_cooldown_crit_sec` | 1800 | 600 |
| `pm2_logs_cap_mb` | unset | 50 |

The code constants follow, because the repo holds an invariant that the shipped numbers and the constants are the same numbers: `DEFAULT_LANES["retire_min_days"]` in `scripts/vacuum/config.py`, `DEFAULT_RETIRE_MIN_DAYS` in `scripts/vacuum/lanes.py` (now derived from it so the two cannot drift), and the Mac app's own fallback in `Sources/Storage/MaintainStore.swift` are all three days.

The opt-in steps stay opt-in.  `coolify_remote` and `cleanmymac_cli` are off in the shipped policy because `scripts/vacuum/config.py` keeps them in `DEFAULT_OFF_STEPS`, and the CleanMyMac CLI is closed-source software the owner turns on for their own machine.  The floors are the part that is safe to ship; the opt-ins are the owner's to grant.

`Sources/Storage/DiskCleaner.swift` now offers stale MiniMax Code runtime state in the `aiArtifacts` category:

- A session day under `~/.minimax/v2/sessions/<year>/<month>/<day>` whose folder has not been touched for fourteen days.
- A workspace tree under `~/.minimax/v2/workspaces/<hash>` that has not been touched for fourteen days.

Both are listed, not selected: `aiArtifacts` stays a review category, so the owner chooses them.  The age is the safety, not a guess about which seat is busy, because a live session keeps writing inside its own folder.  The safe delete gate gained exactly two prefixes, `~/.minimax/v2/sessions/` and `~/.minimax/v2/workspaces/`, so the runtime's own `sqlite/runtime-state.sqlite` is refused by the same gate that refuses every path outside the allowlist.

`Sources/UI/DiskCleanerView.swift` now has one scroll region for the whole tab.  The tier picker, the banner, the hero header, the temp file note, the regimen block and the category list all live in a single `ScrollView`, and the action bar with Select All, Deselect All, Exclusions, Rescan and Clean Selected stays pinned below it.  The list is no longer competing with the header for the leftover pixels, and scrolling moves the whole tab rather than a strip at the bottom.

`Sources/App/AppActivationManager.swift` stopped taking the keyboard.  The activation policy still switches between accessory and regular, because that is about the Dock icon and the Command-Tab list, but it no longer calls `NSApp.activate(ignoringOtherApps: true)`.  A window that appears is ordered forward with `orderFrontRegardless()`, and it only becomes the key window when the app is already active, which is the case when the owner opens it from the menu bar and not the case when it appears on its own.

`scripts/vacuum/alerts.py` posts a banner without the app.  The alert asks whether Hog Hunter is already running, and only then does it address the app by name; with the app closed the banner goes through Script Editor's own `display notification`, which launches nothing.  The vacuum can no longer open the owner's window.

## What did not change

No iOS simulator runtime, device or profile is touched.  The `apps/lanes` tree is still refused by name, and a path on any volume other than the home volume is still refused.  The `.janitor-keep` marker still protects a tree from inside and from every parent.  Nothing here runs an unattended delete that the owner did not turn on, and nothing launches or drives an app on the owner's machine: the builds and the rendered screenshots run on the GitHub Actions macOS runner.

## How it was verified

`scripts/test-robotic-vacuum.py` gained `test_the_shipped_policy_carries_the_reclaim_floors`, which reads the shipped policy and asserts each floor, so a later edit cannot quietly drop one.  It also gained `TestNotifyNeverLaunchesTheApp`, which proves the banner script does not name the app when the app is closed, does name it when the app is running, and that the running check asks for the executable by its process name.

`Tests/HogHunterTests/DiskCleanerTests.swift` gained two tests: one that a stale session day and a stale workspace are deletable under `aiArtifacts` while `runtime-state.sqlite` is not, and one that drives `scanCategory(.aiArtifacts)` against a temporary home and asserts that the three week old session day and workspace are offered, the fresh session day is not, and nothing under `.minimax` comes back selected.

`Tests/HogHunterTests/StorageCleanerLayoutTests.swift` is new and it carries the layout guard.  It measures the height the cleaner's scroll region is actually given inside a window of the size the owner was looking at, and it fails if that region is less than half the window, so the sliver cannot come back.  It also proves the region grows with the window, that the tab never asks for more height than it is offered, and it renders `hh236-storage-cleaner-tab.png` into the render directory so the runner publishes a picture of the fixed tab.  CI requires that file.

The lane suite was updated where the new floor changes the meaning of a fixture: the fake doctor report now carries three days, the constant tuple in `TestSettings` carries three days, and the tests that exercised a non-default floor now use five.

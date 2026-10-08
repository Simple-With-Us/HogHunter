# Dev Cleanup Playbook

Design and safety reference for three cleanup modes in Hog Hunter: Automatic Maintenance, Manual On-Demand, and Extreme or Developer.  It carries the lessons of the 2026-10-07 fleet lane cleanup into the product.  It holds no credentials and no personal paths.

Status on 2026-10-08.  The Python half (the lane doctor feeding the Robotic Vacuum) is in code and not loaded on this Mac.  The Swift developer tier does not exist yet, and `Sequencing` says when it may start.  Rollout detail: `docs/rollouts/2026-10-08-lane-doctor-vacuum.md`.

## Rules For Every Mode

1. Never delete on a guess.  An unknown, missing, stale, or failed fact means do nothing, and the log says which fact.
2. A fresh, clean, zero-ahead lane is not safe.  Only merged-PR evidence matched by head sha makes a lane removable.  A squash merge leaves the branch name free for reuse, so a name match proves nothing.
3. What git hides still counts.  Plain `git status` hides an env file or a local database that git ignores, and `git worktree remove` would delete it.  Only regenerable build output may be ignored.  git never looks inside an ignored folder, so a clone under `.venv/src` (from `pip install -e git+...`) or under `build/` is invisible: every ignored folder must be walked and must hold no nested git repository.  A tracked file marked `--skip-worktree` or `--assume-unchanged` can hold edits that `git status` never shows, so those flags block too.
4. Remove a lane with `git worktree remove` and never a force flag.  Never `rm -rf` a checkout.  Git refuses a dirty tree by itself, and that refusal is a backstop, not the plan.
5. Check the live tree again right before each delete.  A report is evidence, not permission.
6. Snapshot or trash first where the platform allows.  The Swift cleaner takes an APFS local snapshot and sends items to the Trash.  A lane has no Trash.  Its recovery path is the PR that covers the lane's HEAD, plus the branch ref, which `git worktree remove` leaves in place.  For a merged PR, its head contains HEAD.  For a closed one, its head equals HEAD.  GitHub keeps that PR head.  So commits missing from every remote ref are accepted only on the reported branch with that PR evidence.  On a detached HEAD, any such commit blocks removal, because no ref keeps it.
7. Judge reclaim by a fresh `df`, never by an exit code (`config/reclaim-policy.json`, hard rules).
8. Pressure changes the shape of a run (smaller chunks, longer pauses) and never its scope (owner ruling of 2026-10-02).
9. Log every action.  See `The Ledger`.

## Mode 1: Automatic Maintenance

Safe only.  It never deletes user work, never prompts, and the Swift regimen stays off until the owner turns it on.  Today only the Python tick can run it, and that tick is not loaded.

The table below is the target.  The Python tick reaches it two ways: the `hoghunter_reclaim` step runs `scripts/hoghunter-clean`, which applies the `config/reclaim-policy.json` rules and their gates, and the Vacuum also has older steps of its own.  Those older steps do not all meet these gates.  `The Vacuum's Older Steps` below lists what each one really does.

| What | Rule | Gate |
|---|---|---|
| Package and tool caches | `dev-caches` in `hoghunter-clean`: npm, uv, pip, yarn, swiftpm, playwright, electron and similar | Untouched 90 minutes.  Skipped while xcodebuild, swift-frontend, or clang runs, or more than 20 node processes.  pnpm and gradle only when that fan-out is quiet |
| Xcode DerivedData, one project folder at a time | `xcode-artifacts` | No build running, untouched 90 minutes.  `hoghunter-clean` also checks for an open handle; the Vacuum's own step does not |
| Log rotation | `logs`: tail-truncate in place over 64 MiB, keep 16 MiB.  `sqlite-wal`: checkpoint over 32 MiB | In place, so a daemon's open file really frees space.  Repo checkouts are out of scope |
| Homebrew leftovers | `brew cleanup --prune=all` | Skipped while brew or node-gyp runs |
| Merged, clean, idle lanes | `git worktree remove`, no force | The lane doctor's cleaner list, then the Vacuum's own re-check (below) |
| Dependency folders of idle lanes | `node_modules`, `.next`, `.turbo`, `dist`, `build`, `.gradle`, `DerivedData`, `Pods`, `__pycache__`, `.venv`, `.pytest_cache` | Fleet lanes only, never harness-managed worktrees.  Idle 24 hours, clean tracked tree, no process inside, no keep marker, and no nested git repository inside the folder |

**Lane checks, in order.**  Any failure removes nothing and writes the reason.

1. The doctor report must be fresh (15 minutes), schema 2 or newer, from this home, with `lsof` ok and, for removing a lane, `gh` ok (dependency folders do not need `gh`).  A spawn error, timeout (5 minutes), bad JSON, or a future timestamp fails closed.  These limits, and the 7-day and 24-hour floors, are code constants.  Config can change only where the doctor is installed.
2. The doctor's own conjunction: SAFE-TO-REMOVE, merged-PR evidence by head sha (MERGED, or CLOSED on an exact head match), age and idle at least 7 days, no keep marker, no process cwd, a lane-like location, not a tool cache, no read errors, and a good `gh` lookup for that repo.
3. The Vacuum's re-check at plan time and again right before removal:
   - The path is unchanged, not a symlink, and has a `.git` file.  It is not under a never-touch folder (`~/.grok/worktrees` and the rest of the `hoghunter-clean` list).  No keep marker is on disk, and no other checkout from the report sits inside it.
   - HEAD equals the reported head sha, on the reported branch.
   - `git status --porcelain -z --ignored` shows only regenerable build output.  That is the deletable list above, plus the entries the doctor also treats as regenerable: `.DS_Store`, `*.pyc`, `*.tsbuildinfo`, `venv`, `.build`, `.mypy_cache`, `.ruff_cache`, `dist-*`, and a `node_modules` symlink.  Each match is on the entry's own name.
   - Every ignored folder is walked without following symlinks, and none may hold a `.git` entry.  An unreadable folder, or more than one million entries, refuses.
   - `git ls-files -v` shows no skip-worktree or assume-unchanged flag.
   - Commits missing from every remote ref are allowed only on the reported branch with that PR evidence (Rule 6).
   - The lane is registered and unlocked, and its branch is not checked out elsewhere.
   - No process has it as its working directory (`lsof`), and `pgrep -f`, given the path as a literal (regex characters escaped), finds no process naming it.
4. The command is exactly `git -C <main repo> worktree remove <path>`.  A code assertion rejects `-f` and `--force`.  A non-zero exit is logged as failed and the loop goes on.

What to expect.  On the 2026-10-08 doctor report (270 checkouts), a read-only replay of step 3 over the 38 lane-like worktrees rated SAFE-TO-REMOVE with merged evidence, with the age floor ignored, gave this result: 29 pass, 7 are refused for a nested repository, and 2 are kept by the keep list.  The 7 are SwiftPM `.build/checkouts`, which are real clones.  24 of the 29 pass only because of Rule 6: their commits are under no remote ref, only under the PR head on GitHub and the local branch, and the log line says so.  A real run also needs the 7-day floor and the doctor's cleaner list, so it removes fewer.  No real removal has been run.

Automatic mode never removes a lane that is dirty, open, fresh, beyond its merged PR, or unknown, and never touches anything in Mode 3.

### The Vacuum's Older Steps

These steps came from the retired disk janitor.  They run on the Vacuum's `full` trigger (every 4 hours once the tick is loaded) unless switched off with `--set-step <id> off`.  A failed process check always counts as busy.

| Step | What it does | Gate | Default |
|---|---|---|---|
| `xcode_derived_data` | Deletes DerivedData project folders | Skipped while xcodebuild, swift-frontend, or clang runs.  Per folder: untouched 90 minutes, no keep marker, not a symlink.  No open-handle check | On |
| `xcode_device_support` | Deletes iOS DeviceSupport versions | Same build gate.  Per version: untouched 7 days | Off (a Mode 3 item) |
| `simctl_delete_unavailable` | Nothing.  It reports that it would delete simulator devices in `CoreSimulator/Devices`, which no step touches | None needed | On, as a no-op |
| `npm_cache` | `npm cache clean --force`, then `~/.npm/_npx` unless a running process names that folder | No npm install running, build gate.  No 90-minute idle gate | On |
| `pnpm_store`, `yarn_cache` | `pnpm store prune`, `yarn cache clean` | No install running, build gate.  No node fan-out gate | On |
| `brew_cleanup` | `brew cleanup --prune=all` | No brew or node-gyp process | On |
| `core_simulator_caches`, `pm2_logs`, `vitest_temp_dbs`, `spotlight_journals`, `codex_archived_sessions`, `grok_sessions`, `antigravity_brain`, `coolify_remote` | Unchanged from the janitor | Not reviewed against these rules.  `pm2_logs` truncates to empty, not to 16 MiB | On |

## Mode 2: Manual On-Demand

The user opens a scan and chooses.  The list is reviewable before anything runs.

- **Columns.**  Path class, size, reason, safety class, and what regenerates it.  A lane row also shows the doctor's reasons.
- **Groups for lanes.**  Removable (on the cleaner list and passing the re-check), Needs Review, Unknown.  Only Removable rows can be ticked.  Lanes are never pre-selected.
- **Needs Review.**  Dirty files, ignored local state such as a database or env file, unpushed commits, an open PR, commits past a merged PR, a keep marker, a fresh lane, a detached HEAD that holds the only copy, no remote.  These rows show their reasons with Reveal In Finder and Copy Path.  Hog Hunter does not delete them.  The owner resolves the lane (push, open a PR, or discard on purpose in a terminal).
- **Unknown.**  A fact the doctor could not read.  Shown with the missing fact, never selectable.
- **Same engine, same checks.**  Manual adds the user's choice and no weaker checks.  The same re-check, command form, and ledger apply.
- **Defaults for non-lane rows** follow `CleanCategory.defaultSelected` as it is today.
- **Tools today.**  `python3 scripts/robotic-vacuum.py --dry-run` (prints the plan as JSON and writes nothing), `scripts/hoghunter-clean --scan`, `scripts/clean.sh --scan --dry-run`, and the lane doctor (`lane ls`, `lane ls --cleaner-list`).

## Mode 3: Extreme Or Developer

Opt-in, manual, and never scheduled.  It is reachable only after an acknowledgement toggle, the same pattern as `acknowledgedExtremeDisclaimer` (session only, not persisted; the shell twin is `--confirm-extreme`).  It is not reachable from the phone's `CompanionServer` and not from `CleanRegimen`.  Each row shows its live-measured size, what regenerates it, and how long that takes, and starts unchecked.

| Item | Action | Regenerates by | Time to regenerate |
|---|---|---|---|
| Docker or OrbStack | The engine's own prune (`docker system prune`, `docker builder prune`).  Volumes need a separate tick and a second prompt.  Never delete the engine's data folder | Pulling images, rebuilding | Network and image count decide; slowest row |
| Old simulator runtimes | Runtime bundles unused 24 hours (`simulator-runtimes` rule).  Never `CoreSimulator/Devices` | Download from Xcode | A large download.  18.55 GB measured on 2026-09-27 (`config/reclaim-policy.json`) |
| `node_modules` and build output in stale lanes | The Mode 1 folder list, in lanes idle 30 days or more (proposed), including lanes whose PR is open or unknown.  Only these folders, never the lane | Install and build in that lane | Next install or build |
| Homebrew cache | `brew cleanup -s` | Re-download on next install | Per formula |
| pnpm store | `pnpm store prune` | Re-download on next install | Per project |
| Xcode Archives | Listed by date, never pre-ticked, a warning that they hold the debug symbols of shipped builds | Not regenerable: a rebuild is a different binary | Never |
| iOS DeviceSupport | Versions older than 7 days (`xcode-artifacts` rule).  The Vacuum's `xcode_device_support` step does this and is off by default | Re-created when that device attaches | Minutes at the next attach |

**Safety checks.**  The Rules For Every Mode apply unchanged, plus these.

- Prefer Apple's or the tool's own command over deleting folders.  Every row prints its exact command before it runs, and a dry run prints the same lines.
- Unknown facts still mean skip.  Runtime rows skip while xcodebuild, Simulator, or CoreSimulatorService runs.  Docker rows skip when the engine does not answer.
- Stale-lane rows repeat the Mode 1 live checks except the merged-PR test: the target is a regenerable folder inside the lane, not a symlink, with a clean tracked tree, no process cwd, no keep marker, and no file written in the last 24 hours.  The lane itself is never removed.
- A second prompt for anything that holds data rather than cache: Docker volumes, Xcode Archives.
- A failed step is reported and not retried in the same run.

## Never Touch

Personal media and documents, the Photos library, Pictures, Movies, Music, and personal media found in temp folders.  iCloud and `CloudStorage`.  Secrets, keychains, SSH material, env files, and `~/.secrets`.  Virtual machine bundles (a live one is running infrastructure).  The Time Machine backup itself, as distinct from local snapshots.  Anything with unpushed commits or the only copy of commits.  Anything with a keep marker.  Integration trees (`~/Code/<App>`) and `~/apps` itself.  Other tools' caches and plugin clones.  In-session `~/.grok/worktrees`, and harness-managed worktrees for the dependency step.  Nested git repositories inside ignored folders.  `CoreSimulator/Devices`, which is why the Vacuum never runs `xcrun simctl delete unavailable`.  The Trash, which no automatic mode empties.  Hog Hunter itself.

One honest exception: the existing Extreme tier's Large And Old Files category lists single files under Downloads, Documents, and Desktop for the user to pick one by one.  It is unchecked by default and goes to the Trash.  The developer tier must not include it, and the Vacuum never reads those folders.

## The Ledger

One line per real action, never per dry run.  Fields: time, mode (automatic, manual, developer), path class, size, exact command, outcome.  A skipped or failed action is a line too, with its reason.

Today the Python half writes `lane-actions.jsonl` in its data folder, rotated at 1 MiB, with `at`, `step_id`, `action` (retired, removed-folder, failed, skipped), `path`, `size_bytes`, `command`, `exit`, and `reasons`.  `mode` and `path class` are not there yet.  Add them when the Swift tiers write to the same ledger, so one file answers what was deleted and why.

## Mapping To Existing Pieces

| Piece | Role here |
|---|---|
| `DiskCleaner.swift`, `CleanTier.standard` | Mode 1 and Mode 2 for the Swift side.  Snapshot first, Trash put-back |
| `CleanTier.extreme` | Today's deep tier (orphans, AI artifacts, large files).  The developer tier is separate and does not widen it |
| `CleanRegimen`, `CleanRegimenRunner`, `CleanPressure` | Unwired.  If wired, Mode 1 only, `.standard` only (the runner already passes it).  `schedulableRules` excludes ask-first and expensive |
| Robotic Vacuum (`scripts/vacuum/`, 20 steps) | A five-minute tick.  The lane steps (`janitor_worktree_retire`, `pressure_apps_deps`) and `hoghunter_reclaim` are Mode 1.  The older steps meet only the gates listed under `The Vacuum's Older Steps` |
| `scripts/hoghunter-clean` tiers | safe and semi-safe map to Mode 1.  expensive maps to Mode 3 rows.  ask-first stays report-only |
| `scripts/clean.sh` | Shell twin of `DiskCleaner`, with `--tier` and `--confirm-extreme` |

## What The 2026-10-07 Fleet Cleanup Did And Deliberately Avoided

**Did.**  Installed a read-only inventory of every checkout (the lane doctor).  Classified about 236 checkouts by location and by whether removal could lose work.  Synced and patched the janitor scripts.  Set the folders that tools use for their own worktrees.  Defined a layout for new lanes (`~/apps/lanes/<prefix>/<seat>-<slug>`).

**Avoided.**  Personal media in temp folders.  Lanes with unpushed or uncommitted work.  Detached HEADs holding the only copy of commits.  Repos with no remote.  Lanes with keep markers.  Integration trees.  Other tools' caches and plugin clones.  Live virtual machine bundles.  Every force removal.

The lesson: the inventory came first, and every removal had to name the evidence for it.

## Tunables

New numeric knobs for the Swift tiers (a DerivedData age, the stale-lane idle days) go in Infisical with an `INFISICAL.md` row when the Swift code lands.  Exclusions and enabled rules stay in UserDefaults.  The Python Vacuum's lane limits are not knobs: report age, schema, doctor timeout, the 7-day retire floor, and the 24-hour dependency floor are code constants, and config can change only the doctor's install path.  The Vacuum's older settings in `config/robotic-vacuum.json` predate this work and have no Infisical reader (see `INFISICAL.md`).

## Sequencing

The Swift developer tier comes after two open pull requests are resolved, to avoid conflicts in `DiskCleaner.swift`.

1. **#81** (`feat/disk-hog-cleanup`).  Its `test` check failed on 2026-10-05.  It adds `CoreSimulator/Devices` to the `.developer` allowlist, which contradicts `config/reclaim-policy.json` (Devices is ask-first) and `hoghunter-clean` (forbidden).  Fix it on that PR: inventory only, not deletable.
2. **#72** (`grok-build/hh-vendor-folders`).  Touches `DiskCleaner.swift` and `clean.sh`, and is conflicting with `main`.
3. **Then the developer tier.**  A `CleanTier.developer` case or `DeveloperTier.swift`; manual only; an acknowledgement toggle in `DiskCleanerView`; never referenced by `CompanionServer` or the regimen; a category-bounded allowlist of its own.  `isSafeToDelete` keeps refusing `~/apps` and `CoreSimulator/Devices`.  Read `NSHomeDirectory()` and `userHomeURL` from one injected home so the guard is testable.

**Gaps to close first.**  `.developer` is in the Standard tier and default-selected today, and its allowlist already holds Xcode Archives and iOS DeviceSupport, so the phone's standard clean can reach the debug symbols of shipped builds (they go to the Trash after a snapshot, which is recoverable only until the Trash is emptied).  Move them to Mode 3.  The protected roots (`~/apps`, `~/Code`) are refused only as an exact match; children are refused because no category allowlist names them, with one carve-out for `~/apps/.botfleet-server.node_modules.*`.

**Swift tests to write.**

- A path under `~/apps/lanes` is refused in every `CleanCategory`.
- The BotFleet carve-out is the only allowed child of `~/apps`.
- `CoreSimulator/Devices` is refused in every category, including after #81.
- Archives and DeviceSupport are refused under `.standard`.
- The developer tier is absent from `CleanTier` use in `CompanionServer` and `CleanRegimenRunner` (a source scan or a type-level check).
- Developer scan and clean do nothing until the acknowledgement is set.
- A symlink inside an allowed prefix that points outside it is refused.
- Every developer row is unchecked by default and carries size, regenerates-by, and time text.
- Docker and volume rows need their second confirmation; a failed prune is reported, not retried.
- The ledger line carries mode, path class, size, command, and outcome.
- An injected home drives both the scan and the guard.

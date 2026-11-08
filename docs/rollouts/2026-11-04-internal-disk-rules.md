# Internal Disk Rules

**Update, Nov 5 (HH-219).**  The owner decided to widen automatic deletes modestly.  `xcode-scratch` now deletes a positively identified DerivedData root at 60 GB free or less, and `botfleet-releases` takes superseded BotFleet releases.  See `docs/rollouts/2026-11-05-disk-upkeep-rules.md`.  Everything else below stands.

Fixes HH-213.  Measured on Nov 4 with 59 GB free: the safe tier of `scripts/hoghunter-clean` found about 0 GB, because the caches were already handled and the rest of the space sat outside its rules.  This adds the rules that can act safely, closes a path that could empty the Trash, and puts everything else on the report.

Nothing here was run in apply mode on the Mac.  No launchd job, installed app or live setting changed.  A rule starts deleting only once this lands and the job picks it up.

## What This Ended Up As

The first version also deleted stale build output and Xcode scratch, and `.tmp` under the agent homes.  Two adversarial review rounds on Nov 4 confirmed 23 findings and then 6 more.  Each fix left a refuse-list that a new case got past, and with every gate in place those rules reclaimed almost nothing.  So they became report-only.

**The owner's Nov 4 narrowing was not used for automatic deletes.**  The owner allowed deleting stale build output ("teach HH wherever possible").  Nothing here does, at any disk level.  A person decides from the report, and the playbook's `Never Touch` list stands as written.

| Rule | Tier | When | What it does |
|---|---|---|---|
| `tool-versions` | safe | every run | Deletes old versions from `muse-bin-*`, `~/.local/share/cursor-agent/versions` and `~/.local/share/claude/versions`.  Keeps the newest 2, what the default launcher resolves to, and any version a link, wrapper or LaunchAgent names.  Not changed or run for 7 days, and not running |
| `duplicate-sim-runtimes` | semi-safe | 25 GB free or less | Deletes a second Ready Disk Image of one runtime and version, unused or older than the most recently used, reported `deletable`, and not the image `simctl runtime match list` chooses.  Uses `xcrun simctl runtime delete <id>`, a new op, and confirms by asking simctl again |
| `stale-build-output` | report | on a scan | Lists `.build`, `.next`, `build` and `target` in `~/Code/<repo>`, plus `CodeCaps/ios/CodeCapsCompanion/build`, with what the checks found.  Never deletes |
| `xcode-scratch` | report | on a scan | Lists Xcode-shaped children of `/private/tmp` with what the checks found.  Never deletes |
| `ask-first` | report | every run | Now also `~/BotFleet-migration-backups`, `~/.botfleet/releases` other than the current one, `~/apps/botfleet-*` trees, `~/Code/*/.muse/worktrees`, `~/.minimax/v2/sqlite/backups`, agent `.tmp` folders and the Codex marketplace staging.  Every idle `dist` is listed, and `node_modules` on a scan.  Bound by the scan share |

`is_forbidden` now refuses anything under a `.muse` folder and any `~/apps/botfleet-*` tree, so `apply_delete` turns them down whichever rule names them.

The report rules sit after every rule that can act, and a clean run skips their walks because nobody reads the rows.  `agent-state` no longer takes `.tmp`, and it also refuses any tree holding a `.git`.  `temp-scratch` left the regimen's rule lists, because the Trash mapping was the only thing it selected there.

**The 25 GB line.**  `--band=full` alone does not mean low disk, because the pressure triggers also fire on a 15 GB drop in free space, on swap and on load at any free level.  So `PRESSURE_ONLY_RULES` enforces the line for `duplicate-sim-runtimes`.  A clean run above it does not scan for it, `main` leaves its candidates out, and `apply_candidate` reads df again before each delete.  A df that fails is not pressure.  A read-only `--scan` still lists what it would take.  No other semi-safe rule changed when it runs: `snapshots` keeps its schedule.

**The recheck.**  `tool-versions` and `duplicate-sim-runtimes` pass a `recheck`, which runs right before the delete.  It takes a fresh open-file listing, inside a slice of a quarter of what is left of the budget and at most 60 seconds, and a heavy delete starts only if 30 seconds are left after it.  A refusal shows as `refused_count` and the candidate's `refused`, not as a failure.  It is not atomic: a writer that starts after the recheck is the limit HH-180 records.

**Git.**  Every git call goes through `_git`, which strips `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and the other location variables, because they outrank `-C`.

**Registration.**  The rules are in `config/reclaim-policy.json`.  They are not in `CleanRegimen.schedulableRules`, because the regimen runs `DiskCleaner` and never this engine.  A test reads each rule's tier from its source and compares it with the policy.

## The Trash Finding

An unattended regimen could permanently empty `~/.Trash`, against `neverEmptyTrash` in the policy.  The regimen is off by default, so this needed the owner to have turned it on, and nothing else stood in the way.

1. `temp-scratch` is a default rule (`Sources/Storage/CleanRegimen.swift:153`).
2. The rule map sent `.trash` to `temp-scratch` (`Sources/Storage/CleanRegimenRunner.swift:639`, before this change), so `scanCategories` scanned it.
3. A Trash item is selected by default (`Sources/Storage/DiskCleaner.swift:121` and `:1327`), so `pendingItems` kept it.
4. `clean` removes it with `fileManager.removeItem` (`Sources/Storage/DiskCleaner.swift:2254` to `:2256`), not by moving it anywhere.

The safety snapshot, on by default, was the only way back.  `.trash` now answers to no rule, so no regimen scans or selects it.  The old test asserted the mapping and was replaced.  A person can still select Trash in the Disk Cleaner.  Putting the old mapping back fails both new tests, 6 assertions in all.

**Left as it is, and worth a decision.**  The phone's `POST /v1/clean` runs the default selection, and `phoneMayClean` excludes only snapshots, so a confirmed phone clean also permanently empties the Mac's Trash.  A person asks for that one, so it is outside this finding, but they may not expect it.

## Limits

- **One Xcode.**  `simctl runtime match list` speaks for the active Xcode, so `duplicate-sim-runtimes` gives no candidate unless exactly one is found in `/Applications`, `~/Applications`, Spotlight and `xcode-select`.  One on a volume Spotlight does not index is not seen.
- **The simulator service.**  `simulator-runtimes` stays shut while CoreSimulatorService is alive, and asking simctl anything starts it.  So the duplicate rule asks simctl only when the service is already alive.  A run that finds it down picks nothing there.
- **Tool references.**  A running version shows in the listing, and the default launcher's target is always kept.  A link or wrapper is seen in `~/.local/bin`, `~/bin`, `/usr/local/bin`, `/opt/homebrew/bin` and LaunchAgents, not anywhere else on the disk.  With no proof of what a launcher runs, the tool is left out.
- **Muse prunes itself.**  Its launcher removes old binaries on update, so the store has one file and this rule picks nothing there today.  `~/.local/share/claude/stable` is one unversioned copy and is left out.
- **Simulator tier.**  The policy said semi-safe and the code said `expensive`.  Moving the code would have widened a bulk delete, so the policy was corrected, with a `tiers` block that says what each tier means.  Behavior is unchanged.

## What It Reclaims

Automatically, on this Mac today, about 0.54 GiB from `tool-versions` (see the PR for the scan on the final commit).  That is far short of the issue's hopes, and the report is where the rest shows up: build output, Xcode scratch, 17 GB of BotFleet migration backups, 2.1 GB of MiniMax backups and 2.5 GB of Codex marketplace staging.  Each is a person's call.

## The Runtime Images Are Gone

The two iOS 27.2 images the issue measured were not on the Mac when this work reached them.  `xcrun simctl runtime list` reports 0 disk images, and `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime` holds only its catalog files, with the folder last changed at 2:03pm on Nov 4.  This work ran no delete.  What removed them is not known.

So the JSON shape in the rule's tests comes from the fields recorded when the images were measured, not from live output on this branch.  Any shape it does not recognize gives no candidate, including a missing `lastUsedAt` or `kind`, so a mismatch means the rule does nothing, not that it deletes the wrong image.  Check it the next time two images exist.

## Overlap

PR #261 also touches `scripts/hoghunter-clean` and `scripts/test-hoghunter-clean.py`, in `rule_xcode_artifacts`.  It adds a sweep of its own, on a delete path this change does not use.

## Verification

Tests use fake homes, real throwaway git repos and an injected simctl.  Counts are in the PR.  Each behavior fix's test was run against the previous commit first and failed there, and the regression tests were mutated to confirm they catch what they name.

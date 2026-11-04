# Internal Disk Rules

Fixes HH-213.  Measured on Nov 4 with 59 GB free: the safe tier of `scripts/hoghunter-clean` found about 0 GB, because the caches were already handled and the rest of the space sat outside its rules.  This adds the rules that were missing, closes a path that could empty the Trash, and leaves everything that holds someone's work on the report.

Nothing here was run in apply mode on the Mac.  No launchd job, installed app or live setting changed.  A rule starts deleting only once this lands and the job picks it up.

An independent review of the first commit, `5cab1de`, confirmed 23 findings.  All are fixed in the second commit, and this document describes the code after it.  The list is under `Review Of 5cab1de`.

## The Trash Finding

An unattended regimen could permanently empty `~/.Trash`, against `neverEmptyTrash` in the policy.  The regimen is off by default, so this needed the owner to have turned it on, and nothing else stood in the way.

1. `temp-scratch` is a default rule (`Sources/Storage/CleanRegimen.swift:153`).
2. The rule map sent `.trash` to `temp-scratch` (`Sources/Storage/CleanRegimenRunner.swift:639`, before this change), so `scanCategories` scanned it.
3. A Trash item is selected by default (`Sources/Storage/DiskCleaner.swift:121` and `:1327`), so `pendingItems` kept it.
4. `clean` removes it with `fileManager.removeItem` (`Sources/Storage/DiskCleaner.swift:2254` to `:2256`), not by moving it anywhere.

The safety snapshot, on by default, was the only way back.  `.trash` now answers to no rule, so no regimen scans or selects it.  The old test asserted the mapping and was replaced.  A person can still select Trash in the Disk Cleaner.  Putting the old mapping back fails both new tests, 6 assertions in all.

**Left as it is, and worth a decision.**  The phone's `POST /v1/clean` runs the default selection, and `phoneMayClean` excludes only snapshots, so a confirmed phone clean also permanently empties the Mac's Trash.  A person asks for that one, so it is outside this finding, but they may not expect it.

## The Rules

| Rule | Tier | When | What it takes |
|---|---|---|---|
| `duplicate-sim-runtimes` | semi-safe | 25 GB free or less | A second Ready Disk Image of one runtime and version, unused or older than the most recently used, reported `deletable`, and not the image `simctl runtime match list` chooses.  Deleted with `xcrun simctl runtime delete <id>`, a new op, and confirmed by asking simctl again |
| `stale-build-output` | semi-safe | 25 GB free or less | `.build`, `.next`, `build` and `target` directly in `~/Code/<repo>`, plus `CodeCaps/ios/CodeCapsCompanion/build`, spelled exactly so on disk.  Unchanged 14 days, ignored, nothing tracked, no process working in the repo, and nothing inside on the list of what a rebuild does not make |
| `tool-versions` | safe | every run | `muse-bin-*`, `~/.local/share/cursor-agent/versions` and `~/.local/share/claude/versions`.  Keeps the newest 2, what the default launcher resolves to, and any version a link, wrapper or LaunchAgent names.  Not changed or run for 7 days, and not running |
| `xcode-scratch` | safe | every run | Direct children of `/private/tmp` owned by this user, with every entry in the tree matching what Xcode writes there.  Idle 24 hours, no build running |
| `agent-state` | safe | every run | Now also `.tmp`, and a tree holding any `.git` stays |
| `ask-first` | report | every run | Now also `~/BotFleet-migration-backups`, `~/.botfleet/releases` other than the current one, `~/apps/botfleet-*` trees, `~/Code/*/.muse/worktrees`, `~/.minimax/v2/sqlite/backups` and the Codex marketplace staging.  Stale build output no rule can take stays here with the reason, and every idle `node_modules` and `dist` is listed.  Bound by the scan share |

`is_forbidden` now refuses anything under a `.muse` folder and any `~/apps/botfleet-*` tree, so `apply_delete` turns them down whichever rule names them.

**The 25 GB line.**  `--band=full` alone does not mean low disk, because the pressure triggers also fire on a 15 GB drop in free space, on swap and on load at any free level.  So `PRESSURE_ONLY_RULES` enforces the line per rule.  A clean run above it does not scan for them, `main` leaves their candidates out, and `apply_candidate` reads df again before each delete, so the run stops once it has lifted the disk past the line.  A df that fails is not pressure.  A read-only `--scan` still lists what they would take, and the report's `pressure_rules_open` says whether they could.  No other semi-safe rule changed when it runs: `snapshots` keeps its schedule.

**The recheck.**  A candidate can carry a `recheck`, which runs right before the delete.  It takes a fresh open-file listing, inside a slice of a quarter of what is left of the budget and at most 60 seconds.  The tree rules and `.tmp` ask their gates again and refuse if the path now holds a different object, and the runtime rule works out its victims again.  A heavy delete then starts only if the budget has time to finish it, at 1000 entries a second by the recheck's count and never under 30 seconds.  Otherwise it is left for the next run rather than cut off partway.  A refusal shows as `refused_count` and the candidate's `refused`, not as a failure, so the vacuum's step is not marked incomplete by a gate doing its job.

The rules are in `config/reclaim-policy.json`.  They are not in `CleanRegimen.schedulableRules`, because the regimen runs `DiskCleaner` and never this engine, so offering them there was a switch that did nothing.  `canonicalRuleNames` lost `temp-scratch`, which no category answers to now.

## What HH-180 Means For `xcode-scratch`

HH-180 is still open.  It records that a temp cleanup validates a pathname and acts on it later, and it asks for no permanent-delete fallback or automatic broad cleanup in the Swift temp path.  This rule stays in because it is not broad and it answers the lessons it can:

- Every entry in the tree is inspected.  The top level, `Build` and `SourcePackages` are allowlists, and source may sit only where Xcode generates it: anything in `Intermediates.noindex`, and headers in `Products` and SwiftPM's binary artifacts.  A project file, a note, a key or another repository refuses anywhere.
- The walk is bounded by the budget and by 500,000 entries.  An unreadable folder, too many entries or no time left all refuse.
- Replacement between the scan and the delete, a late leaf write, and source that appears after the scan are all covered by tests, using the recheck.
- It is not atomic.  A writer that starts after the recheck can lose its output, and a rename that lands between the recheck and the `find` is not caught.  What is lost in that window is build output.

The delete is permanent, like every delete in this engine, and it runs at safe tier.

## Decisions And Their Cost

**SwiftPM clones.**  Playbook rule 3 says a nested repository keeps an ignored folder.  A clone at SwiftPM's own path is the one exception, and only with a real `.git` directory, a clean status that counts untracked and ignored files whatever git's config says, no file flagged skip-worktree or assume-unchanged, and every ref reachable from a remote-tracking ref.  A tag is no proof, because a local one is never pushed.

Real SwiftPM clones carry upstream tags no fetched branch reaches, so today every clone on this Mac fails that proof, whatever it holds.  That keeps `ContactLogo/build`, `ContactLogo/.build`, `CodeCaps/.build`, the CodeCaps companion build and `wise-hh-build`.  This was accepted when the proof was tightened.  A later change could compare local tags with upstream's, but nothing here does.

**`stale-build-output` content checks are a list of what to refuse.**  A hand-written file with an ordinary name deep in the tree can still go.  `.janitor-keep` is the answer for that.

**A process running from the repo.**  A process with its working directory in the repo keeps its build output, because a server that read its files and closed them shows nowhere else.  A job that runs from `target/release` between scans and is not running at the time is not seen.

**One Xcode.**  `simctl runtime match list` speaks for the active Xcode, so the rule gives no candidate unless exactly one is found.  It looks in `/Applications`, `~/Applications`, Spotlight and `xcode-select`.  One on a volume Spotlight does not index is the limit of that.

**The simulator service.**  `simulator-runtimes` stays shut while CoreSimulatorService is alive, and asking simctl anything starts it.  So the duplicate rule asks simctl only when the service is already alive, and never starts it.  A run that finds the service down picks nothing there, and a later one may.

**Tool references.**  A running version shows in the listing, and the default launcher's target is always kept.  A link or wrapper is seen in `~/.local/bin`, `~/bin`, `/usr/local/bin`, `/opt/homebrew/bin` and LaunchAgents, not anywhere else on the disk.  A version's access time is the one trace a run leaves, so a backup that reads it only keeps it longer.

## Dropped Or Narrowed

**`.codex/.tmp` reclaims nothing on this Mac.**  `.tmp` is in the transient names as asked, but the tree holds clones with `.git`, and `~/.codex/config.toml` names `.tmp/bundled-marketplaces/openai-bundled` as a live source.  It also holds 74,483 tiny `git-*` scratch folders and was written within the last 90 minutes.  The whole-tree delete would have broken Codex, so the `.git` check refuses it.  The 2.5 GB is in `marketplaces/.staging`: 138 upgrade folders, with clones inside.  The playbook keeps plugin clones out of automatic modes, so it is reported for a person to decide rather than taken.

**Muse prunes itself.**  Its launcher removes old binaries on update, so the store has one file and this rule picks nothing there today.  The rest of the 1.61 GB in `~/.local/bin` carries no version in its names and is left out.  `~/.local/share/claude/stable` is one unversioned copy and is left out too.

**Simulator tier.**  The policy said semi-safe and the code said `expensive`.  Moving the code to semi-safe would have widened a bulk delete.  Nothing reads the JSON's tier, so the policy was corrected to `expensive`, with a `tiers` block that says what each tier means, and a test now reads each rule's tier from its source.  Behavior is unchanged.

## Real Scan

A read-only `--scan --json --band=full --budget-sec=600` on Nov 4 around 3:15pm, with 72.7 GB free, taking 130 seconds, not truncated, nothing applied, and `pressure_rules_open` false.  Sizes are GiB by logical file size.

| Rule | Would pick |
|---|---|
| `tool-versions` | 0.54: `claude/versions/2.1.301` 0.23, cursor-agent `.2026.08.31-4057e58` 0.16, `.2026.09.10-fd3934a` 0.14 |
| `stale-build-output` | 0.36, and only at 25 GB free or less: `Usage-Monitor/.next`.  A later look refused it, because a process had started working in that repo |
| `xcode-scratch` | 0.  `/private/tmp/wise-hh-build` (3.64) passes the content walk and is under 24 hours idle, and with that gate lifted its `sentry-cocoa` clone fails the proof, so it stays |
| `duplicate-sim-runtimes` | 0.  See below |
| `agent-state` | Nothing from `.tmp`, for the reason above |

No `.muse` or BotFleet path is a deletable candidate.  22 such paths are on the report.

From the build output listed in HH-213, nothing goes today, and the report says why:

- `Socratic-Trade/.next` (2.35): the checkout has a `.janitor-keep` from Sep 25, so the rule honors it.
- `CodeCaps/.build` (4.25), `ContactLogo/build` (2.07) and `ContactLogo/.build` (0.43): the clone proof.
- `CodeCaps/ios/CodeCapsCompanion/build` (1.26): changed within 14 days, and the clone proof after that.

So the ~10 GB the issue hoped for from build output is not reclaimed by this rule as it stands.  The first commit's scan picked 2.85.

## The Runtime Images Are Gone

The two iOS 27.2 images the issue measured were not on the Mac when this work reached them.  `xcrun simctl runtime list` reports 0 disk images, and `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime` holds only its catalog files, with the folder last changed at 2:03pm on Nov 4.  This work ran no delete.  What removed them is not known.

So the JSON shape in the rule's tests comes from the fields recorded when the images were measured, not from live output on this branch.  Any shape it does not recognize gives no candidate, including a missing `lastUsedAt` or `kind`, so a mismatch means the rule does nothing, not that it deletes the wrong image.  Check it the next time two images exist.

## Review Of 5cab1de

| # | Severity | Finding | Now |
|---|---|---|---|
| 1 | P1 | A tracked `Build/` passed as `build` on a case-insensitive volume | The name on disk must match exactly |
| 2 | P1 | A server running from the repo passed the gates | A process's working directory in the repo refuses |
| 3 | P1 | The clone proof looked at HEAD only | `--all` against `--remotes`, tags no longer proof |
| 4 | P2 | Git config and skip-worktree hid clone edits | `--untracked-files=all`, and `ls-files -v` flags refuse |
| 5 | P2 | No content check on ignored build output | Keys, archives, notes, project files, other repositories and top-level source refuse |
| 6 | P2 | `xcode-scratch` inspected only the top level | Every entry is judged, and a walk that cannot finish refuses |
| 7 | P2 | Wrappers and outside links were not seen, and the idle gate could not see a run | References are read, access time counts, and the default launcher must prove out or the tool is left out |
| 8, 12 | P3 | The recheck answered from a cached listing | A fresh listing per recheck |
| 9 | P2 | Another Xcode's chosen image could go | No candidate unless exactly one Xcode is found |
| 10 | P2 | A missing `lastUsedAt` read as never used, and `kind` was unread | Both are required, and a victim must be a Disk Image |
| 11 | P2 | The recheck could spend the delete's reserve | A capped slice, a time check after it, and a clock check in the clone loop |
| 13 | P3 | Booting and Shutting Down read as idle | Anything but Shutdown is active |
| 14 | P3 | A rule's own deadline was silent, and an unreached tree left the report | The report says truncated, and only a tree the rule listed leaves it.  Repos are still walked in name order |
| 15 | P3 | `.tmp` candidates had no recheck | They have one |
| 16 | P3 | A refusal counted as a failure | `refused_count` |
| 17 | P3 | A killed simctl delete reported failure without asking | It asks simctl either way |
| 18 | P1 | Semi-safe deletes ran at any free level | The per-rule line above |
| 19 | P1 | The new rule's simctl calls could close `simulator-runtimes` | It asks only when the service is already alive |
| 20 | P2 | A cheap run spent scan share on rules it could not apply | A clean run skips the two pressure rules unless they can apply.  `snapshots` and `simulator-runtimes` are still scanned, as before |
| 21 | P3 | Tier docs contradicted the code | Playbook, policy and code comment corrected |
| 22 | P3 | The four names in `schedulableRules` did nothing | Removed, with behavior tests, and policy tiers are read against each rule's source |
| 23 | P3 | A peer-work test passed without its guard | Replaced, and it fails with the guard removed |

## Verification

- `python3 scripts/test-hoghunter-clean.py`: 179 of 179, up from 88 on `main`
- `python3 scripts/test-robotic-vacuum.py`: 480, OK.  One fake `scan` in that file now accepts the new `skip` argument
- `python3 scripts/test-vacuum-lanes.py`: 210, OK
- `xcodegen generate`, then `xcodebuild -scheme HogHunter -destination 'platform=macOS' test`: 1034, 0 failures

Tests use fake homes, real throwaway git repos and an injected simctl.  Each behavior fix's test was run against `5cab1de` first and failed there.  Six mutations of the engine, one of the Trash map and the removal of the peer-work guard were each caught by the tests meant to catch them.

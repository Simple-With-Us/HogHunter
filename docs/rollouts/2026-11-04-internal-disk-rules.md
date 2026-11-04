# Internal Disk Rules

Fixes HH-213.  Measured on Nov 4 with 59 GB free: the safe tier of `scripts/hoghunter-clean` found about 0 GB, because the caches were already handled and the rest of the space sat outside its rules.  This adds the rules that were missing, closes a path that could empty the Trash, and leaves everything that holds someone's work on the report.

Nothing here was run in apply mode on the Mac.  No launchd job, installed app or live setting changed.  A rule starts deleting only once this lands and the job picks it up.

## The Trash Finding

An unattended regimen could permanently empty `~/.Trash`, against `neverEmptyTrash` in the policy.  The regimen is off by default, so this needed the owner to have turned it on, and nothing else stood in the way.

1. `temp-scratch` is a default rule (`Sources/Storage/CleanRegimen.swift:153`).
2. The rule map sent `.trash` to `temp-scratch` (`Sources/Storage/CleanRegimenRunner.swift:639`, before this change), so `scanCategories` scanned it.
3. A Trash item is selected by default (`Sources/Storage/DiskCleaner.swift:121` and `:1327`), so `pendingItems` kept it.
4. `clean` removes it with `fileManager.removeItem` (`Sources/Storage/DiskCleaner.swift:2254` to `:2256`), not by moving it anywhere.

The safety snapshot, on by default, was the only way back.  `.trash` now answers to no rule, so no regimen scans or selects it.  The old test asserted the mapping and was replaced.  A person can still select Trash in the Disk Cleaner.  Putting the old mapping back fails both new tests, 6 assertions in all.

**Left as it is, and worth a decision.**  The phone's `POST /v1/clean` runs the default selection, and `phoneMayClean` excludes only snapshots, so a confirmed phone clean also permanently empties the Mac's Trash.  A person asks for that one, so it is outside this finding, but they may not expect it.

## The Rules

| Rule | Tier | What it takes |
|---|---|---|
| `duplicate-sim-runtimes` | semi-safe | A second Ready image of one runtime and version, unused or older than the most recently used, reported `deletable`, and not the image `simctl runtime match list` chooses.  Deleted with `xcrun simctl runtime delete <id>`, a new op, and confirmed by asking simctl again |
| `tool-versions` | safe | `muse-bin-*`, `~/.local/share/cursor-agent/versions` and `~/.local/share/claude/versions`.  Keeps the newest 2 by mtime, whatever a symlink resolves to, and what `.muse-version` names.  Idle 7 days |
| `xcode-scratch` | safe | Direct children of `/private/tmp` owned by this user whose top level is only what Xcode writes, with `Build` holding Xcode's output folders and an Xcode cache beside it.  Idle 24 hours, no build running |
| `stale-build-output` | semi-safe | `.build`, `.next`, `build` and `target` directly in `~/Code/<repo>`, plus `CodeCaps/ios/CodeCapsCompanion/build`.  Idle 14 days, ignored, nothing tracked |
| `agent-state` | safe | Now also `.tmp`, and a tree holding any `.git` stays |
| `ask-first` | report | Now also `~/BotFleet-migration-backups`, `~/.botfleet/releases` other than the current one, `~/apps/botfleet-*` trees, `~/Code/*/.muse/worktrees`, `~/.minimax/v2/sqlite/backups` and the Codex marketplace staging.  Stale build output no rule can take stays here with the reason, and every idle `node_modules` and `dist` is listed.  Bound by the scan share |

`is_forbidden` now refuses anything under a `.muse` folder and any `~/apps/botfleet-*` tree, so `apply_delete` turns them down whichever rule names them.

A candidate can carry a `recheck`, which runs right before the delete.  The three tree rules ask every gate again and refuse if the path now holds a different object, and the runtime rule works out its victims again.

The rules are registered in `config/reclaim-policy.json` and `CleanRegimen.schedulableRules`.  They have no Swift cleaner category, so `ruleNames` and `canonicalRuleNames` gained nothing.  `canonicalRuleNames` lost `temp-scratch`, which no category answers to now.

## What HH-180 Means For `xcode-scratch`

HH-180 is still open.  It records that a temp cleanup validates a pathname and acts on it later, and it asks for no permanent-delete fallback or automatic broad cleanup in the Swift temp path.  This rule stays in because it is not broad and it answers the lessons it can:

- The shape is an allowlist, so a tree with a `.git`, a `Package.swift`, a project file or any stray source is not this shape.  A folder's name and age prove nothing.
- Replacement between the scan and the delete, a late leaf write, and source that appears after the scan are all covered by tests, using the recheck.
- It is not atomic.  A writer that starts after the recheck can lose its output, and a rename that lands between the recheck and the `find` is not caught.  What is lost in that window is build output.

The delete is permanent, like every delete in this engine, and the owner should know that it runs at safe tier.

## Decisions That Went Past The Brief

**SwiftPM clones.**  Playbook rule 3 says a nested repository keeps an ignored folder, and most of the measured build output holds SwiftPM clones.  This adds a narrow exception: a clone at SwiftPM's own path passes only with a real `.git` directory, a clean status with ignored files counted, and a HEAD reachable from a remote ref or a tag.  Taking the exception out is a small edit to `regenerable_clones_only`, and `ContactLogo/build` and `ContactLogo/.build` would then stay report-only if they hold such clones.  The lane steps are unchanged.

**`tree_in_use`.**  The new tree rules treat a failed system-wide `lsof` as in use, because the per-path fallback cannot see a file open deeper down.

**`botfleet-rollback`.**  The rule ran but was missing from the policy, so it was listed, and a test now requires every rule to be there.

## Dropped Or Narrowed

**`.codex/.tmp` reclaims nothing on this Mac.**  `.tmp` is in the transient names as asked, but the tree holds clones with `.git`, and `~/.codex/config.toml` names `.tmp/bundled-marketplaces/openai-bundled` as a live source.  It also holds 74,483 tiny `git-*` scratch folders and was written within the last 90 minutes.  The whole-tree delete would have broken Codex, so the `.git` check refuses it.  The 2.5 GB is in `marketplaces/.staging`: 138 upgrade folders, with clones inside.  The playbook keeps plugin clones out of automatic modes, so it is reported for a person to decide rather than taken.

**Muse prunes itself.**  Its launcher removes old binaries on update, so the store has one file and this rule picks nothing there today.  The rest of the 1.61 GB in `~/.local/bin` carries no version in its names and is left out.  `~/.local/share/claude/stable` is one unversioned copy and is left out too.

**`CoreSimulatorService` is not a guard for the duplicate rule.**  Asking simctl anything starts it.  The rule asks whether a device is booted instead.

**Simulator tier.**  The policy said semi-safe and the code said `expensive`.  Moving the code to semi-safe would have widened a bulk delete.  Nothing reads the JSON's tier, so the policy was corrected to `expensive`, with a `tiers` block that says what each tier means.  Behavior is unchanged.

## Real Scan

A read-only `--scan --json --band=full` on Nov 4 around 2:30pm, with 83 GB free, taking 124 seconds and not truncated.  Sizes are GiB by logical file size.

| Rule | Picks |
|---|---|
| `tool-versions` | 0.54: `claude/versions/2.1.301` 0.23, cursor-agent `.2026.08.31-4057e58` 0.16, `.2026.09.10-fd3934a` 0.14 |
| `stale-build-output` | 2.85: `ContactLogo/build` 2.07, `ContactLogo/.build` 0.43, `Usage-Monitor/.next` 0.36 |
| `xcode-scratch` | 0 today.  `/private/tmp/wise-hh-build` (3.64) passes every gate but the 24 hours, so it becomes a candidate after about 12:20am on Nov 5 if nothing touches it |
| `duplicate-sim-runtimes` | 0.  See below |
| `agent-state` | Nothing from `.tmp`, for the reason above |

No `.muse` or BotFleet path is a deletable candidate.  22 such paths are on the report.

From the build output listed in HH-213, three stay for now:

- `Socratic-Trade/.next` (2.35): the checkout has a `.janitor-keep` from Sep 25, so the rule honors it and the report does not list it.
- `CodeCaps/.build` (4.25): touched on Nov 1, and its `sentry-cocoa` clone has a HEAD no local ref reaches.  That is SwiftPM pinning a revision, not proof of local work, but the rule cannot tell, so it stays.
- `CodeCaps/ios/CodeCapsCompanion/build` (1.26): passes every other gate, and the idle gate says it was used within 14 days.

## The Runtime Images Are Gone

The two iOS 27.2 images the issue measured were not on the Mac when this work reached them.  `xcrun simctl runtime list` reports 0 disk images, and `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime` holds only its catalog files, with the folder last changed at 2:03pm on Nov 4.  This work ran no delete.  What removed them is not known.

So the JSON shape in the rule's tests comes from the fields recorded when the images were measured, not from live output on this branch.  Any shape it does not recognize gives no candidate, so a mismatch means the rule does nothing, not that it deletes the wrong image.  Check it the next time two images exist.

## Verification

- `python3 scripts/test-hoghunter-clean.py`: 142 of 142, up from 88
- `python3 scripts/test-robotic-vacuum.py`: 480, OK
- `python3 scripts/test-vacuum-lanes.py`: 210, OK
- `xcodegen generate`, then `xcodebuild -scheme HogHunter -destination 'platform=macOS' test`: 1033, 0 failures

Tests use fake homes, real throwaway git repos and an injected simctl.  Six mutations of the engine and one of the Trash map were each caught by the tests meant to catch them.

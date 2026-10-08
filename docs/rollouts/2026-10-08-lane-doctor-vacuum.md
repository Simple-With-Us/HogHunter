# Lane Doctor Vacuum (2026-10-08)

Thu, Oct 8, 2026.  Seat CLAUDE.  Branch `claude/lane-doctor-vacuum`.  Board `b39e940c`.  Python and docs only.  No Swift file, `project.yml`, or `Sources/` file changed.

## Context & Objective

The Robotic Vacuum retired old git worktrees and cleared build folders using its own heuristics, and those had holes.  `git status --porcelain` does not list ignored files, so an env file or a local database inside a lane would go with `git worktree remove`.  The merged-PR test matched the branch name only, and a squash-merged name can be reused.  There was no unpushed-commit check and no process-cwd check.  The build-folder step globbed flat `~/apps/*`, so nested lanes were invisible.  A failed `pgrep` read as "nothing running".

The fleet now has a read-only lane doctor (installed command `~/apps/lane`, subcommand `ls`).  This change makes the Vacuum act only on the doctor's report plus its own live re-check, fail closed on any doubt, log every real action, and offer a dry run.  The design reference for the three cleanup modes is `docs/DEV-CLEANUP-PLAYBOOK.md`.

## Changes Made

- `scripts/vacuum/lanes.py` (new) — report loading and validation, the live re-check, removal argv, dependency-folder evaluation, and the action log.
- `scripts/vacuum/janitor.py` — old heuristics deleted (name-only PR match, porcelain check, idle-hours test).  `plan_retire_worktrees` and `apply_retire_worktrees` replace them.
- `scripts/vacuum/engine.py` — one doctor run per engine run shared by both lane steps, an itemized `plan`, fail-closed `pgrep`, nested lanes visible to the dependency step.  After review: the older `full` steps gained the policy's gates (see Behavior Changes).
- `scripts/vacuum/config.py` — `DEFAULT_LANES` (the doctor command only), `DEFAULT_OFF_STEPS`, retired-seat handling for the keep regex.
- `scripts/vacuum/scheduler.py` — `run_dry_tick` and a `dry_run` flag on the scheduler tick.
- `scripts/robotic-vacuum.py` — new `--dry-run`.
- `config/robotic-vacuum.json` — new `lanes` block.  The `apps_glob` key is gone.
- `scripts/test-vacuum-lanes.py` (new) and `scripts/test-robotic-vacuum.py` — tests, wired so the existing CI line runs both.
- `docs/DEV-CLEANUP-PLAYBOOK.md` (new), this note, `CHANGELOG.md`, `docs/EFFORT-LOG.md`, `INFISICAL.md`.

## Behavior Changes

- **Retire step.**  A lane is removed only if the doctor lists it as a cleaner candidate and the Vacuum's own re-check agrees, at plan time and again just before removal.  The re-check covers HEAD equal to the reported head sha on the reported branch, and no ignored entry other than regenerable build output (the doctor's own list, matched on the entry's name).  Every ignored folder is walked and must hold no nested git repository.  No skip-worktree or assume-unchanged flag may be set.  The lane must be registered and unlocked, with no other reported checkout inside it, no process cwd or command line naming it, no keep marker, and no never-touch location.  Commits missing from every remote ref are accepted only on the reported branch, where the doctor's MERGED or CLOSED PR covers that HEAD and the branch ref survives the removal.  On a detached HEAD they refuse.  The command is `git -C <main repo> worktree remove <path>` and never forced; code rejects `-f` and `--force`.
- **Fail closed.**  A missing, slow, malformed, stale (over 15 minutes), future-dated, other-home, or low-schema report removes nothing.  So does `lsof` not ok.  Removal also needs `gh` ok.  The step then reports SKIPPED with the reason.  A folder walk that cannot read a folder or passes one million entries refuses too.
- **Dependency step.**  `pressure_apps_deps` reads lanes from the doctor, so nested lanes count.  Fleet lane classes only (`LANE_NESTED`, `LANE_FLAT`, `LANE_FLAT_LEGACY`, `REVIEW`).  Harness-managed worktrees (`MANAGED`: `~/.codex/worktrees`, `~/.grok/worktrees`, `~/Code/<App>/.claude/worktrees`) are left to their harness.  It deletes only named regenerable folders in linked worktrees idle 24 hours or more with a clean tracked tree, no process, and no keep marker.  Right before each delete it checks again that the folder is plain and holds no nested git repository.
- **Never-touch folders.**  Both lane steps refuse anything under the `hoghunter-clean` `FORBIDDEN_PREFIXES` list (`~/.grok/worktrees`, `CoreSimulator/Devices`, `Documents`, `Desktop`, `Pictures`, `Movies`, `CloudStorage`), whatever the report says.
- **Process checks fail closed.**  A `pgrep` exit other than 0 or 1, a timeout, or a missing binary reads as busy, and the npm, pnpm, yarn, and brew steps skip.  A lane path goes to `pgrep -f` with its regular-expression characters escaped, so a lane named `claude-a+b` or `claude-v(2)` still finds a process naming it.  A path with control characters reads as busy.  No step lists process arguments (`hardRules.neverPs`).
- **Older `full` steps.**  `xcode_derived_data` now deletes only project folders untouched 90 minutes, and never while xcodebuild, swift-frontend, or clang runs.  `xcode_device_support` deletes only versions untouched 7 days, behind the same gate, and is off by default.  `simctl_delete_unavailable` no longer runs anything: it would delete simulator devices in `CoreSimulator/Devices`.  `brew_cleanup` runs `brew cleanup --prune=all` and waits for brew and node-gyp.  `npm_cache`, `pnpm_store`, and `yarn_cache` wait for a build.  `npm_cache` keeps `~/.npm/_npx` while a process runs from it.  Details: `docs/DEV-CLEANUP-PLAYBOOK.md`, `The Vacuum's Older Steps`.
- **Load skip.**  The hard-load skip now also covers `pressure_apps_deps`, because it runs the doctor.
- **Keep regex.**  A seat suffix drops out only when `fleet-apps.json` marks every seat with that suffix retired (monet and deepseek today).  The file unreadable means the full list stays.  Nothing is ever added.
- **Dry run.**  `--dry-run` prints one JSON document (`dry_run`, `plan`, `records`) and writes nothing: no history, scheduler state, status, action log, or notification.
- **Alerts.**  The launchd-missing alert needs proof the Vacuum was installed (plist on disk, a real record in `history.json`, or `alerts.alert_when_not_installed`, default false, read from the user config because `config/robotic-vacuum.json` has no `alerts` block); a stale active flag clears without a banner.  `HOGHUNTER_NO_NOTIFY` makes `notify_macos` a no-op, `--dry-run` sets it, and both test files set it, trap unexpected `notify_macos` calls, and pin a git identity and an empty HOME (CI's Ubuntu runner has none).  The 164-test count in Verification State predates these and is stale.
- **Action log.**  `lane-actions.jsonl` in the Vacuum data folder, rotated at 1 MiB, one JSON line per real action with size and the exact command.
- **Config.**  One `lanes` key, `doctor_command`, plus the `HOGHUNTER_LANE_DOCTOR_COMMAND` override.  It names where the doctor is installed, a machine-local path like `hoghunter_clean`.  Everything else is a code constant that config can neither loosen nor tighten: report age 15 minutes, schema 2, doctor timeout 5 minutes, 7 days to retire, 24 hours for dependency folders.  `config/robotic-vacuum.json` still lists the five numeric `lanes` keys from the first draft; the code ignores them, and the block should be cut to `doctor_command`.  `repos`, `janitor.stale_days`, and `janitor.idle_hours` are now unused and left in place.
- **Visible to the Swift view.**  `history.json` shows SKIPPED instead of RAN when nothing is eligible, `bytes_freed` is filled in, and the step reason can reach about 600 characters with absolute paths and the command.  The `StepResult` and `RunRecord` shape is unchanged.

## How To Verify

From the repo root:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-robotic-vacuum.py     # also runs scripts/test-vacuum-lanes.py
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/test-robotic-vacuum.py   # Python 3.9, as launchd runs it
git diff --name-only origin/main -- Sources project.yml              # expect no output
```

Plan without deleting.  This runs the real lane doctor against the real home, read-only, and can take minutes on a loaded Mac:

```bash
python3 scripts/robotic-vacuum.py --dry-run --run-now janitor
python3 scripts/robotic-vacuum.py --dry-run          # the whole due tick
```

Read the `plan` array: each item has `step_id`, `action`, `path`, `size_bytes`, `command`, and `reasons`.  A report problem appears as a SKIPPED record that begins "lane doctor unusable".

## Verification State

| Command | Result |
|---|---|
| `python3 scripts/test-robotic-vacuum.py` | PASS: 184 tests (14 existing plus 170 new), run on this Mac on 2026-10-08 after the review fixes, Python 3.14.  53 seconds at host load 11 |
| Same under `/usr/bin/python3` (3.9) | PASS: 184 tests, run on this Mac on 2026-10-08 after the review fixes (system Python 3.9.6, the version launchd uses) |
| Review findings | Each fix has a test that failed on the pre-fix code (32 failing or erroring) and passes now.  The reviewers' own repro scripts now refuse in every case |
| Re-check replay on the real doctor report | Read-only, with a runner that refuses any write verb.  38 lane-like worktrees rated SAFE-TO-REMOVE with merged evidence, age floor ignored: 29 pass (24 of them through the PR-head rule), 7 refused for SwiftPM nested clones, 2 kept by the keep list |
| `python3 scripts/robotic-vacuum.py --dry-run` | NOT RUN in this lane (it reads the real home) |
| A real removal against the real lanes | NEVER RUN.  Tests use temp repos and fake data |
| Linux CI timing, `release-safety` 5 minute limit | UNVERIFIED |
| Swift tests | NOT RUN.  No Swift file changed |

## What Is Not Live

- The Robotic Vacuum is not loaded on this Mac.  No launch agent for it is installed, and nothing in this change installs, loads, or reloads one.  The owner-run `scripts/robotic-vacuum-migrate.sh` was not run.
- Until it is loaded, nothing here runs unattended.  `--dry-run` and `--run-now` are the only ways to exercise it.
- The `~/apps/lane` command exists on this Mac as of 2026-10-07 and may not on another.  When it is missing, the default `doctor_command` fails with a spawn error and the lane steps remove nothing.
- Host load on 2026-10-08 was 390 to 500, above the plist's `JANITOR_MAX_LOAD` of 250, so all three lane steps would skip as "host under extreme load" if loaded now.
- No developer tier exists.  `docs/DEV-CLEANUP-PLAYBOOK.md` is a design; the Swift side waits on PR #81 and PR #72.

## Rollback

Nothing is loaded, so reverting the merge commit restores the old heuristics with no runtime effect.  If the Vacuum has been loaded since:

- Turn the lane steps off without a code change: `python3 scripts/robotic-vacuum.py --set-step janitor_worktree_retire off`, and the same for `pressure_apps_deps`.  Setting `janitor.reap_worktrees` to false disables retirement only (it then never runs the doctor for that step), and does not stop `pressure_apps_deps`.
- Set `HOGHUNTER_LANE_DOCTOR_COMMAND` to a command that does not exist, which fails closed.
- To unload the agent itself, use `scripts/robotic-vacuum-rollback.sh` with the backup path the migrate script printed (see `2026-10-05-robotic-vacuum.md`).
- A removed lane is not restored from the Vacuum.  By construction its commits are on a remote ref, or in the branch ref the removal leaves behind and under the PR head on GitHub, so `git worktree add <path> <branch>` brings it back.  Ignored build output and `.DS_Store` files are not restored; they regenerate.  `lane-actions.jsonl` lists each removal with its path, branch, head sha, and unpushed count.

## Open Questions

1. **Pruned remote branches (changed after review).**  The Vacuum now matches the doctor.  A lane whose commits are under no remote ref is accepted when it is on the reported branch and the doctor's PR evidence covers its HEAD.  For MERGED, the PR's head contains HEAD.  For CLOSED, the head equals HEAD.  GitHub keeps that PR head, and `git worktree remove` keeps the branch ref (a test proves the ref still resolves after removal).  On a detached HEAD the zero-ahead rule still applies.  This widens the earlier rule on purpose: in the replay, 24 of the 29 lanes that pass do so only through it.  Revert to zero-ahead everywhere if the owner prefers.
2. **`gh` partial.**  Removal needs `gh` ok, so one repo's failed lookup disables retirement for every repo.  It is UNVERIFIED whether a real run with `gh` reports ok.
3. **MERGED or CLOSED.**  The Vacuum accepts both, as the doctor does.  CLOSED means the commits are on GitHub and were never merged.  Tighten to MERGED if wanted.
4. **Managed harness worktrees (closed after review).**  The dependency step no longer touches `MANAGED` worktrees (`~/.codex/worktrees`, `~/.grok/worktrees`, `~/Code/<App>/.claude/worktrees`): a closed but resumable session has no process cwd, so the step could not tell it was still wanted.  On the 2026-10-08 report, 90 lanes pass the report-level gates, all `LANE_FLAT_LEGACY`.  Retirement still accepts a merged `MANAGED` worktree outside the never-touch folders, as the doctor's cleaner list does.  Whether a harness minds losing a merged worktree it created is UNVERIFIED.
5. **Retired seats in the keep regex.**  Dropping monet and deepseek means their old flat lanes are judged by the doctor instead of being kept.  Flip `KEEP_SEAT_SUFFIXES` handling in `config.py` if the intent was the opposite.
6. **Doctor cost.**  The default command is `ls --json` with no `--gh-limit`, so a repo with 500 or more PRs can leave lanes UNKNOWN and unlisted.  The doctor took 174 seconds with `--no-gh` here and 67 seconds with `gh` on an earlier run.  The 300 second timeout fails closed, and it runs once per janitor or pressure run.
7. **Regenerable lists (changed after review).**  Removal now accepts every entry the doctor calls regenerable, matched on the entry's own name.  That is stricter than the doctor, which accepts a match anywhere in the path.  The dependency step still deletes only its own list.  An ignored parent folder that git folds into one entry still blocks retirement and hides nested `node_modules` from the dependency step.  A folder with more than one million entries is refused rather than walked to the end.
8. **Delete call.**  `config/reclaim-policy.json` says deletes go through `find -depth -delete` because a trash layer on this Mac intercepts `rm -rf` and frees nothing.  The dependency step calls `shutil.rmtree`, as several older Vacuum steps already do.  Whether that layer affects a Python call is UNVERIFIED; check reclaim with a fresh `df` on the first real run.
9. **Infisical (changed after review).**  This work adds no tunable.  The five numeric `lanes` values are code constants, and `doctor_command` is a machine-local install path.  `INFISICAL.md` files the Robotic Vacuum under its own heading.  The Vacuum's older settings in `config/robotic-vacuum.json` predate this work and have no Infisical reader.  Whether they should is an owner decision, and no ruling is recorded.
10. **Standard tier reach.**  `.developer` is in the Standard tier and default-selected, and already lists Xcode Archives and iOS DeviceSupport, so the phone's standard clean can reach them.  The playbook recommends moving them to the developer tier.  Not changed here.
11. **Swift labels for changed steps.**  `RoboticVacuumStore.catalog` still titles `simctl_delete_unavailable` "Remove unavailable Simulator runtimes" and shows it on, though the step now never deletes anything; its history line says why.  The Swift view also defaults every catalog toggle to on when the user config has no entry.  `xcode_device_support` is not in that catalog, so its new off default is invisible there.  A Swift change is needed to retitle or drop the row.
12. **DerivedData open handles.**  `hoghunter-clean` also skips a DerivedData folder with an open file handle.  The Vacuum's step relies on the build gate and the 90-minute idle gate instead.

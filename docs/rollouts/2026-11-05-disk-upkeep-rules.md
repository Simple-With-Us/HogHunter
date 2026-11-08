# Disk Upkeep Rules

Refs HH-219.  On Nov 5 the Data volume was 95% full with 24 GB free.  A `--band=full` scan found 0 GB the engine could take on its own and 78 GB of report-only rows.  The owner decided the same day to widen automatic deletes modestly: "train Hog Hunter to do a better job maintaining its disk space."  This change does that for the two places where the space was regenerable, and adds an early warning for the rest.

Nothing here was run in apply mode on the Mac.  The owner was clearing the disk by hand while this was written, and every test uses a temporary home.  A read-only scan of the two rules on the final commit, at 60.6 GB free, found nothing to take: the trees measured below were already gone.

## Where The Space Was

| Where | Size | Now |
|---|---|---|
| `/private/tmp` DerivedData roots (`hh-push-dd`, `hh-main-dd`, `hh-kody-dd`, `wise-hh-build`) | about 3.7 GB each | `xcode-scratch` deletes them |
| `~/.clutch/derived-data` | 3.4 GB | `xcode-scratch` deletes its idle roots |
| `~/.botfleet/releases` and `~/.botfleet-companion/releases` | 4.4 GB each | `botfleet-releases` keeps the current one and the newest 2 others |
| `hh-verify-*` and `hh212-candidate-*` checkouts in `/private/tmp` | 7.6 GB | Not Xcode's shape, so never a delete.  Some were live and some had dirty files |
| `~/BotFleet-migration-backups`, `~/Code/*/.muse/worktrees`, `~/.minimax/v2/sqlite/backups` | 16.6, 12 and 2 GB | Report only.  Other seats' work or backups |
| Swap | 10.5 of 12 GB | No rule.  Deleting files never reduces swap |

## Positive Identification

The Nov 4 version failed two adversarial reviews because each fix was a refuse-list a new case got past.  So `xcode-scratch` now deletes only what it can identify as Xcode's, and reports the rest.  A direct child of `/private/tmp` or `~/.clutch/derived-data` is a delete only when all of these hold.

1. It is a real directory owned by this user, not a symlink and not a mount point, on the home folder's volume and never under `/Volumes`.
2. Its top holds only what Xcode writes there, none of it a link, with `Build/`, an Xcode cache, and `Logs/` or `Index.noindex/`.
3. `info.plist` is a small plain file whose `WorkspacePath` is set.
4. `Build/` holds only `Products` and `Intermediates.noindex`, and `SourcePackages/` only SwiftPM's own stores.
5. No repository anywhere inside, except a SwiftPM clone at SwiftPM's path that is clean and fully held by a remote (the HH-213 clone proof).
6. Nothing at the root or its first two levels changed in 24 hours, nothing anywhere in the tree is newer than that (every entry is walked, and a walk that cannot finish keeps the root), and the root's ctime is older than that too.  A build writes its log into `Logs/Build` and its database into `Build/Intermediates.noindex`, so a build in the last day moves one of them.
7. Nothing anywhere in the tree, at any depth and in `Logs`, the intermediates and the caches as much as the build output, is a key, an archive, a project or a note, and a walk that cannot finish keeps the root.  The rule deletes on this answer, so the whole tree is walked (second review of PR 274).
8. No keep marker on it, above it or inside it.
9. Nothing holds it open on the system-wide listing, no process runs from inside it, and no running process names its path or its folder name (a relative `-derivedDataPath`).

The recheck asks all of it again right before the delete, on a fresh open-file listing, and checks the path still holds the same object.  It does not gate on a build running somewhere else, because builds run on this Mac almost all day and would keep the rule shut: a build that uses the tree moves its top two levels, holds files in it, or names it.

`~/Library/Developer/Xcode/DerivedData` is not repeated here.  `xcode-artifacts` already deletes its idle children.

## The 60 GB Line

`xcode-scratch` deletes only at 60 GB free or less, so always at the 25 GB line.  It is a safe-tier rule, so the watch's cheap band reaches it.  The line uses the mechanism `duplicate-sim-runtimes` has used since HH-213, now a table (`PRESSURE_RULES`) of the tier each rule needs and its line.  A clean run above the line does not scan for the rule, `main` leaves its candidates out, and `apply_candidate` reads df again before each delete.  A df that fails is not pressure.  A read-only `--scan` still lists what it would take.  The report gains `pressure_rules_open_by_rule`, and `pressure_rules_open` keeps its old meaning.

## Superseded Releases

`botfleet-releases` is a new rule.  `botfleet-rollback` covers the server's moved-aside `node_modules` copies in `~/apps`, not the release stores, so there was nothing to extend.  A store reads true only when `releases` is a real folder holding nothing but commit-named folders and `current` resolves to one of them.  It keeps that release, the newest 2 others by mtime, and any release a link, wrapper or LaunchAgent names (the `tool-versions` reader).  The rest go once idle 7 days, with no open handle, no process running from them or naming them, and no keep marker.  Releases are installed read-only, so `apply_delete` makes the release's directories writable after every guard has passed and before `find -delete`.  Files keep their modes, because a file can be a hardlink shared with something outside the release, such as a pnpm store.  Both walks use `-xdev`, so every delete in the engine leaves a volume mounted inside the tree alone.  The ask-first report still lists the releases the rule keeps.

## The Early Warning

Under 40 GB free a run sizes the ask-first trees, which it otherwise reports at 0 bytes.  When the report-only rows add up to more than 10 GB, the JSON carries `top_report_only`: the 8 biggest rows, each with `path`, `bytes` and `rule`, a row inside another listed row not counted twice.  The key is absent otherwise, so an older reader sees no change.  Under 40 GB free a clean run runs the stale build walks too, which it otherwise skips, so the warning sees their rows.  The app does not show it yet.

## What Did Not Change

The Trash, `.muse`, `~/apps/botfleet-*`, `~/apps/lanes`, external volumes and anything with a `.janitor-keep` marker stay out of every delete, and every `hardRules` entry in the policy stands.  `stale-build-output` stays report only.  No Swift changed: the regimen runs `DiskCleaner`, and neither new delete is in `CleanRegimen.schedulableRules`.

## Verification

`python3 scripts/test-hoghunter-clean.py` (220 tests) and `python3 scripts/test-robotic-vacuum.py` (480 tests) pass.  The new tests cover a DerivedData root deleted from both places, a git checkout in `/private/tmp` and a root holding a nested repository left alone, a symlinked child and a symlinked root never walked, a root touched within a day kept, an open file at delete time blocking the delete, nothing deleted above 60 GB, the delete at 25 GB and 59.9 GB on the cheap band, the release store keeping the current one and the newest 2, a store that does not read true left alone, and `top_report_only` present only under its conditions.  After review, more tests cover a fresh or old key, archive or note deep under `Build/Products` or `SourcePackages/artifacts`, a fresh file five levels down, an old root with deep output still deleted, `-xdev` on both walks with only directories unlocked, a hardlinked file keeping its mode, and one path from two rules counted once.  The new gates were mutated one at a time (the `info.plist` check, the two-level idle check, the line at the delete, the number of releases kept, the 10 GB floor) and each mutation failed at least one test.  A second review added tests for a key or note in `Logs`, the intermediates or the caches, one fresh file among 4,100 old ones, a capped or timed-out walk reading as just now, a truncated XML `info.plist`, and the stale build walk on a clean run under 40 GB.

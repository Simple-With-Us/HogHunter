# Retiring lanes that live behind the external symlink (HH-166)

**Date:** 2026-10-19
**Issue:** HH-166 (Linear, HogHunter team)
**Seat:** OpenCode

## Context and objective

Worktree retirement has never removed anything on this Mac.  The Oct 14 audit
recorded 40 janitor runs skipped with "lane doctor unusable: doctor timed out
after 300s" and 11 with "no lanes eligible (2 refused)".  The timeout was one
cause (fixed separately, PR #146) — this is the other, and it was the one that
silently ate every answer the doctor gave.

The fleet keeps its lanes at `~/apps/lanes/<Repo>`, and each `<Repo>` folder is
a **symlink** to `/Volumes/External/Lanes/<Repo>`.  The lane doctor
deliberately reports the `~/apps/lanes` spelling without resolving it, so the
report and the live filesystem agree on the spelling and disagree on the path.

The Vacuum's live re-check compared the lane path with its own `realpath` and
refused anything that resolved elsewhere, with the reason **"path resolves
somewhere else now"**.  On this Mac that is every nested lane: 33 of the
doctor's 35 cleaner candidates are exactly those lanes, and the External disk
is the one with 7 GB free.

## What changed

**`scripts/vacuum/lanes.py`**

- `_live_basics` no longer compares the path with its own realpath.  The path
  itself must still be a plain directory (a symlinked lane could point
  anywhere), and that is now the whole filesystem rule.
- `recheck_for_removal` gained the check the old one really meant: the lane
  must still belong to the **parent repository the doctor recorded**
  (`parent_repo` in the report).  A lane moved to another repository is still
  refused, with the reason "it now belongs to a different repository".
- The process check (`_live_processes`) compares the resolved path as well,
  because lsof reports the physical path the kernel sees.  Without it, a
  process sitting in an external lane went unseen.  (This one came from the
  autofix bot on the PR, and it is right.)
- The never-touch rule is read against the **resolved** path too, and
  containment of a dependency folder is decided on the resolved lane and the
  resolved target.  Allowing a symlinked parent would otherwise have reopened
  the two holes the old path check closed: a lane spelled inside
  `~/apps/lanes` that resolves under `~/Documents` would have passed the
  never-touch rule, and `git worktree remove` would have followed the link and
  deleted the real directory; and every dependency folder behind a symlinked
  parent would have been refused one by one while the lane was still listed
  as cleanable.  (Both from the autofix bot, with regression tests.)

**`scripts/test-vacuum-lanes.py`** — a lane behind a symlinked parent is now
removable, a lane that moved to another repository is still refused, a
symlinked lane is still refused (now as "not a plain directory"), a lane that
resolves into a never-touch folder is still refused, and the dependency step
can clear a lane behind a symlinked parent.

## Decisions and trade-offs

- **The repository is the identity, not the path spelling.**  Where a lane
  lives on disk says nothing; which repository it belongs to says everything.
  That is the check that survives the fleet's symlinked lanes root.
- **The lane path itself must not be a symlink.**  That is the one case where
  a path really could point anywhere, and it is still refused.
- **Every rule that used to read the path now reads the resolved path too**,
  where a resolved path is the one that says where the bytes really are.  The
  never-touch rule and the folder containment check are both decided on it.
  A lane on the external disk resolves outside the home directory and is
  unaffected: the never-touch rule names folders *under* home.
- **No removal is done by this change.**  It only lets the Vacuum reach its
  own gates (merged-PR evidence, seven days idle, a clean tree, no process in
  it) for lanes on the external drive.
- **The size of the prize is modest.**  The 33 eligible lanes add up to
  1.45 GB, not the 144 GB the Oct 14 audit counted, because most of the lanes
  on External are still active, too new, or dirty.  This is worth having, and
  it is not the answer to a full disk.

## Files touched

- `scripts/vacuum/lanes.py`
- `scripts/test-vacuum-lanes.py`

## Verification state

- `python3 scripts/test-vacuum-lanes.py`: 183 tests, OK.
- `python3 scripts/test-robotic-vacuum.py`: OK.
- The finding was reproduced against the live machine first: the doctor report
  from 2026-10-19 (36 minutes to produce, under load 534) was replayed
  through the Vacuum's own live check, and every one of the 33 candidates came
  back "path resolves somewhere else now".
- CI: the Mac test job, the iOS build and the UI smoke test.

## Next steps and blockers

- The Vacuum's own gate still applies: `JANITOR_MAX_LOAD=250` in
  `com.simplewithus.hoghunter.robotic-vacuum.plist` keeps the heavy lane steps
  off while the machine is this loaded, so this fix only bites on a calm box.
- The owner may want to see the plan before anything is retired: the Vacuum's
  dry run lists what it would remove.

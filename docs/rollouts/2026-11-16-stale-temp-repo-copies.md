# Stale Temp Repo Copies — Cleaner Category

Date: 2026-11-16

## Why

The Nov 12 and Nov 15 Mac cleanups each freed tens of GiB, and by Nov 16 the
boot drive was back at 96% used.  The regrowth was /private/tmp: 58 GiB of
git working copies left behind by agent seats (BotFleet, Congress.Trade,
Socratic Trade, AI-Fleet-Coordinator scratch clones).  The cleaner's Temp
Files category deliberately never touches source projects, so nothing
automated could reclaim the single largest regrowth source.

A manual pass on Nov 16 reclaimed the space by verifying each copy against
its remote before deleting it.  This change teaches the cleaner that same
test so the copies are listed — and, under an explicit regimen rule,
cleaned — instead of silently refilling the disk.

## What changed

New Extreme-tier category **Stale Temp Repo Copies** (`staleTempRepos`),
not selected by default, with its own regimen rule `temp-repos` (the
`tmp-files` rule does not reach it).

A direct child of the temp root is listed only when every check passes,
using local data only (remote-tracking refs; nothing fetches):

- It is a standalone clone (`.git` is a directory).  Linked worktrees and
  registered worktrees are never listed.
- Every file in the tree has been untouched for at least 3 days (lstat
  activity: modification, status change, birth, access).  A walk that
  cannot complete inside its budget lists nothing.
- HEAD is contained in a remote-tracking branch.
- No local branch carries commits the remote-tracking refs lack.
- The worktree diff adds or changes no content: file-mode-only churn and
  pure deletions pass, binary diffs fail closed (numstat cannot tell a
  binary deletion from a binary modification).
- Every untracked entry is a known regenerable build-output directory
  (node_modules, dist, build, target, DerivedData, and peers).
- No adjacent fleet lock file, and the name is not conversion-batch
  staging.

Deletion revalidates with the same test (`isSafeToDelete` →
`isStaleTempRepoSafeNow`), so a copy that gained unique work after the
scan is refused.  Git probes run with `--no-optional-locks` so probing
never refreshes an index and makes a copy look freshly touched.

## Nov 16 manual pass (context)

- /private/tmp: 58 GiB → 30 GiB (the remainder is active seat work and
  Wise's copies, preserved per standing precedent).
- ~/apps stale probe/staging copies: ~13.5 GiB archived to the external
  volume and removed.
- Deleting a Nov 15 local Time Machine snapshot released the blocks the
  deletions had pinned: 21 GiB free → 98 GiB free (96% → 77% used).
  The existing APFS Local Snapshots category already covers that half;
  no change was needed there.

## Follow-ups not in this change

- ~/apps holds the same pattern outside the temp root (dated `.bak`
  trees, probe and staging copies).  Extending the verified-copy test
  there needs its own safety review; the lanes tree stays out of scope
  by the owner's 2026-10-21 ruling.
- The Linux companion (hh-agent) autoclean still covers only plain stale
  /tmp files; git-verified repo copies on servers are a separate change.

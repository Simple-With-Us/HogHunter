# One failed gh lookup no longer throws away the whole doctor report (HH-168)

**Date:** 2026-10-19
**Issue:** HH-168 (Linear, HogHunter team)
**Seat:** OpenCode

## Context and objective

The Robotic Vacuum's own history showed the current blocker plainly.  At 18:12
on Oct 19, the janitor skipped with:

    janitor_worktree_retire  skipped  lane doctor unusable: doctor gh status is
    'failed', not 'ok'

The doctor's overall `gh` status says whether **every** repository's PR lookup
came back.  One of them did not: `Simple-With-Us/fleetlink-legacy`, a retired
repository.  The Vacuum then refused the entire report, so not one lane on the
machine could be retired, including the ones whose own repository had looked
up fine — and including the lanes on the external drive that were refused for
a different reason too (HH-166).

## What changed

**`scripts/vacuum/lanes.py`** — `removable_lanes` no longer treats the
doctor's overall gh status as a gate.  The precise gate already exists per
candidate: `report_gate_retire` refuses a candidate whose **own** repository's
lookup failed, and a candidate with no merged-PR evidence has none to trust
either way.  The overall status stays on the report as a fact about it
(`gh_ok`, `gh_reason`), not as a veto.

**`scripts/test-vacuum-lanes.py`** — a failed, partial or skipped overall gh
status no longer refuses the report, while a candidate whose own repository
failed is still refused.

## Decisions and trade-offs

- **No new evidence is trusted.**  A candidate in a repository whose lookup
  failed is refused exactly as before; a candidate in a repository whose
  lookup succeeded keeps the same merged-PR evidence requirement it always
  had.
- **The dependency step was never affected by this gate** and is unchanged.
- **This is a fix only.**  Nothing is removed by the change itself; the
  Vacuum still decides what is eligible.

## Files touched

- `scripts/vacuum/lanes.py`
- `scripts/test-vacuum-lanes.py`

## Verification state

- `python3 scripts/test-vacuum-lanes.py TestReportGates`: 32 tests, OK.
- `python3 scripts/test-vacuum-lanes.py`: 183 tests, OK.
- `python3 scripts/test-robotic-vacuum.py`: OK.
- CI: the Mac test job, the iOS build and the UI smoke test.

## Next steps and blockers

None.  With HH-146 (the doctor's last good report is cached), HH-166 (lanes
behind the external symlink) and this one (one failed lookup no longer
refuses everything), the three reasons worktree retirement never removed
anything are gone.

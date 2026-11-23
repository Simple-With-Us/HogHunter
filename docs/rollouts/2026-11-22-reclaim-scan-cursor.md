# Reclaim engine scan cursor

Date: Nov 22, 2026
Seat: MM
Repo: HogHunter

## What was wrong

The reclaim engine (`scripts/hoghunter-clean`) walks its rules in a fixed order, and the
scan's share of the run budget can run out before the walk finishes. When that happened the
scan simply stopped and the run reported what it had found so far.

The problem was not the stop. The problem was that nothing remembered where the stop
happened. Every later run began again at the first rule, ran the same prefix, ran out of
budget at the same place, and never reached the rules after it.

Measured on this Mac on Nov 22, 2026:

- The data volume was at 97 percent with 15 GiB free, swap at 98 percent, load1 above 190.
- A manual run of `--clean --band=full --budget-sec=240` printed `scan stopped at 60% of
  the budget` and then `nothing reclaimable`, and free space went down 1.91 GB during the
  run.
- The maintain history agreed: every recent run recorded `hoghunter_reclaim` as
  `incomplete`, and the runs that reported bytes had reclaimed only what an earlier
  partial scan had already found.

So the engine was working exactly as written, and as written it could not make progress
on a busy host. The disk filled while every run said there was nothing to do.

## What changed

The engine keeps a scan cursor: the rule name the last truncated scan stopped at.

- `scripts/hoghunter-clean` gains `scan_cursor_path()`, `read_scan_cursor()`,
  `write_scan_cursor()` and `_scan_rule_order()`, and `scan()` takes an
  `advance_cursor` argument.
- The rule walk starts at the cursor and wraps around, so the rules rotate instead of
  repeating.
- Only a `--clean` run advances the cursor. `--scan` is read-only and still writes
  nothing.
- A caller that names its own `--categories` gets exactly those rules: the cursor does
  not apply there, because it would change what the caller asked for.
- A cursor naming a rule that no longer exists is ignored, so a renamed or removed rule
  cannot strand the walk.
- The summary line no longer says `nothing reclaimable` when the scan was cut short. It
  says the run found nothing in the part of the rules it reached, and that the next run
  carries on from where this one stopped.

### The rules are not independent, and the rotation respects that

`botfleet-releases` fills `_RELEASES_TAKEN` and `stale-build-output` fills
`_STALE_BUILD_LISTED`, and `ask-first` reads both of them. A rotation that put
`ask-first` first would have it list the same folder twice, because the memos it reads
would still be empty.

So the rotation does not shuffle the whole list. The two rules that feed `ask-first`
always run first, `ask-first` always runs last, and only the rules that stand alone
rotate.

### Three review findings, and what they changed

The first cut of this change was reviewed on the pull request and three findings came
back. All three were real and all three are fixed here.

1. **A pass that skipped a rule cleared the rotation.** The reset ran whenever the loop
   finished without the budget stopping it, even when a rule had been skipped on
   purpose. That put the rotation back at the start and the prefix repeated, which is
   the failure this change exists to cure. The cursor is now cleared only when every
   rule ran.
2. **The budget running out after the last rule was called a truncated pass.** Nothing
   was left to scan, so the pass was complete, but the run said it was truncated and the
   cursor pointed at a rule that had already run. A pass with nothing left to run is now
   reported as complete.
3. **The cursor path was resolved at import time.** A test that pointed `HOME`
   somewhere else wrote the cursor into the real home directory. It is resolved on every
   call now, so the tests point `HOME` at a temporary directory and the cursor follows
   it.

## What did not change

- No rule was added, removed or widened. The band, the tiers and every gate are the
  same, so the cursor changes which rules a run reaches, never what a rule is allowed to
  delete.
- The cursor is a hint about where to look next. It is written under
  `~/.local/state/hoghunter/`, and a run that cannot write it still works.
- Simulator runtimes, devices and profiles stay protected. The engine's own guards are
  untouched.

## Verification

- `scripts/test-hoghunter-clean.py`: 245 of 245 pass, including six tests for the
  cursor. It advances and rotates, a read-only scan does not move it, a stale rule name
  is ignored, a pass that skipped a rule does not clear it, `ask-first` still runs after
  the rules that feed it, and a budget that runs out after the last rule is a complete
  pass.
- `scripts/test-robotic-vacuum.py`: 480 tests pass.
- `scripts/server-status`: 74 tests pass.
- A live run on Nov 22, 2026 with `--clean --band=full --budget-sec=60` stopped at the
  `agent-state` rule, wrote `{"rule": "agent-state"}` to the cursor file, and reported
  `nothing reclaimable in the part of the rules this run reached; the next run carries on
  from where this one stopped.`

## Note on the other automation path

`scripts/vacuum/` already derives the reclaim step's budget from the tick watchdog, so
the step finishes inside the watchdog and reports its real bytes. The separate
`~/.claude-disk-janitor/janitor.sh` path still calls the engine with `--clean
--band=full` and no `--budget-sec` inside a 300 second watchdog, so that path is killed
mid-run and reports zero bytes. It is a different script from this repo's vacuum
package, and it is tracked as AFC-888.

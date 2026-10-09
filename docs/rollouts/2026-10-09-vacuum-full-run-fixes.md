# Robotic Vacuum Full Run Fixes (2026-10-09)

Board `4ea933f0`, issue #111.  Python only: `scripts/hoghunter-clean`, `scripts/vacuum/engine.py`, `scripts/vacuum/models.py`, `config/robotic-vacuum.json`.  No LaunchAgent, plist, or Swift change.

## What Was Wrong

On Oct 9 the Vacuum made 22 runs (11 watch, 9 janitor, 2 full) and freed 0 bytes.  Every full run, every janitor run, and every watch run that escalated exited 1.

| Step | Symptom | Cause |
|---|---|---|
| `hoghunter_reclaim`, `janitor_cache_reclaim` | "timed out after 900 seconds", every time | `hoghunter-clean` was not hung.  A full read-only scan takes 22 s on a quiet minute and 50 s under today's load.  The scan found 1,710 `.com.openai.codex.*` marker files (66 MiB in all).  The apply loop took them 1 to 3 at a time, then slept 5 to 20 s and re-read the host (`top`, `ps`, `df`, `sysctl`, 4 s or more under load) after every chunk.  With the host throttling (0% idle, load1 357, swap 87%) the chunk is 1 and the pause 20 s, so one sweep needed about 9.5 hours.  The engine killed it at 900 s and learned nothing |
| `spotlight_journals` | "[Errno 1] Operation not permitted" | macOS protects the Spotlight index folder (TCC).  The launchd agent's Python has no Full Disk Access, so listing `~/Library/Metadata/CoreSpotlight/DocumentProcessing/PipelineStorage` is refused, although `stat` on the folder works and the folder is the user's own.  The step ran `killall knowledgeconstructiond corespotlightd mds_stores` first, so it restarted Spotlight on every full run and then failed |
| Any failed step | Whole run exits 1, health "failed", run-failed banner | `RunRecord` exited 1 when any step failed.  The watch tick had its own copy of the same rule |
| Bytes freed | 0 | Reclaim, `antigravity_brain` (12 folders pruned on Oct 9), `grok_sessions`, `vitest_temp_dbs`, `pm2_logs` and the Spotlight step never counted what they removed |

Why janitor runs freed 0 bytes: the janitor trigger has four steps.  `pm2_logs` and `vitest_temp_dbs` had nothing eligible (that part is fine).  `janitor_worktree_retire` never got a lane doctor report: `lane ls --json` took 313 s on this Mac today and the Vacuum waits 300 s (separate from this change, board `b39e940c`).  `janitor_cache_reclaim` runs when free space is under 80 GiB (it is 12 GiB) and hit the 900 s kill.

## What Changed

**`hoghunter-clean`**

- A chunk is a slot of work, not a file.  A heavy candidate (a tree of 8 MiB or more, a snapshot, a WAL, a brew run) takes a slot.  200 light candidates share one.  1,710 markers are 3 chunks, or 9 when the host is throttling, which keeps the owner ruling of 2026-10-02 (divide the work into 2 to 4 smaller tasks, never skip it).
- `--budget-sec N`.  The clock starts at process start, so the scan counts.  No new chunk, delete, or pause starts after the budget, a pause never sleeps past it, and each `find -delete` gets `min(600, time left)`.  It exits 0 and says how much is left.  The next run rescans, so a run that stopped early resumes where it was.  No flag means no limit, as before.
- Work goes snapshots first, then largest first, so a run that stops on its budget has done the valuable part.
- `proc_count` (pgrep) and `open_handles` (lsof) fail closed.  A timeout or error used to read as "nothing running" and "no open handle".  They were unreachable while the cleaner never got past the markers, and they matter now that it does.
- The JSON report adds `applied_bytes`, `applied_count`, `failed_count`, `actionable_count`, `budget_exhausted`, `remaining_count`, and `elapsed_sec`.  Every old key is unchanged.

**Engine**

- `hoghunter_reclaim` and `janitor_cache_reclaim` pass `--json --budget-sec=600` (config `hoghunter_clean_budget_sec`, floor 30), with a hard stop 180 s later that kills the whole process group.  Neither is longer than the old 900 s.  A spent budget is a successful partial run ("removed 600 of 1710 item(s), 1.2 MiB; time budget spent, 1110 left for the next run") and reports the real bytes.  An overrun of the hard stop, a non-zero exit, or every item failing is a failure.
- `spotlight_journals` lists the folder before it touches any daemon.  A refusal is `skipped: needs Full Disk Access (macOS blocks the Spotlight index folder)`.  Nothing tries to get around it.
- Steps that remove files report the bytes they removed.
- `RunRecord.outcome` is `ok`, `partial`, or `failed`.  Partial means a step failed and another one (other than the sampler) ran: it exits 0.  Failed means a step failed and nothing else worked: it exits 1.  The failed step stays `failed` on the record and in the Mac app's step list.  The watch tick and `run()` share one rule.  Old history rows with no `outcome` read as `failed` when they exited non-zero and `ok` otherwise.
- Decision, on purpose: a partial run does not post the run-failed banner and does not change `build_status` health (that function is another lane's, board `5acbcff4`).  The Mac app has no partial state of its own, and its Run Now shows "did not finish cleanly" on any non-zero exit.  `last_run.outcome` is in the status payload for that lane to surface.

## The Permission, If The Owner Wants The Spotlight Step To Work

The step resets Spotlight indexing journals.  It frees little and restarts Spotlight services, so leaving it skipped is a fair choice (`python3 scripts/robotic-vacuum.py --set-step spotlight_journals off` turns it off).  If it should run on the schedule:

- System Settings, Privacy & Security, Full Disk Access, press +, and add the Python that the agent runs.  The plist runs `/usr/bin/python3`, which hands off to `/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app` (the executable `lsof` shows for the live agent).  Press Cmd-Shift-G in the file picker to type the path.
- Full Disk Access on an interpreter covers every script that interpreter runs, not just the Vacuum.  That is a wide grant for a small step.
- A Run Now from the Hog Hunter app runs the same script as a child of the app, so Full Disk Access for Hog Hunter itself covers that path and the scheduled path stays skipped.
- UNVERIFIED: which of the two paths macOS records as the client.  The unified log for the failed run (10:26am) had rotated out, so the denial could not be read back.  After granting, the next full run's `spotlight_journals` row in `history.json` changes from the skip to `journals reset`; if it does not, grant the other path.

## Verification And Its Limits

- `python3 scripts/test-hoghunter-clean.py` (21 tests) and `python3 scripts/test-robotic-vacuum.py` (216 tests, the lane doctor suite included).  The new tests failed against deliberately broken copies (file-counting chunks, a fail-open pgrep).
- The real cleaner ran `--scan --json --budget-sec=120` on this Mac: 1,710 actionable candidates, the new keys present, 50 s.
- `--dry-run` skips both `hoghunter_reclaim` and `spotlight_journals`, and `--scan` does not exercise pacing, and nothing here ran `--clean` by hand, so the end-to-end proof is the next scheduled run: its `history.json` entry should show `hoghunter_reclaim` as `ran` with a byte count and `spotlight_journals` as a skip.

## Follow-ups Not In This Change

- The lane doctor needs about 313 s at today's load and the Vacuum waits 300 s (`vacuum/lanes.py`), so worktree retirement and idle-lane cleanup never run.  Board `b39e940c`.
- `lanes.process_state` gives `pgrep` 3 s.  Under load 600 that times out, so `npm_cache`, `pnpm_store`, `yarn_cache`, and `brew_cleanup` skip as "treated as busy" on most full runs.  Safe, but they free nothing.
- The Codex marker rule in `hoghunter-clean` has no idle gate (the scratch rules around it wait 3 hours).  It deletes markers a running Codex may still use.
- The agent runs `scripts/robotic-vacuum.py` from `~/Code/HogHunter`, the integration tree, which lags `main`.  These fixes reach the agent when that tree updates.

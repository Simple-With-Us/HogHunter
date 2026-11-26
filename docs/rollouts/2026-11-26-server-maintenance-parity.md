# Server Maintenance Parity: Schedule, Reclaimable Bytes and Run History (2026-11-26)

Owner direction, 2026-11-26: "help bring parity to server resource mgmt vs mac resource mgmt, and parity to ios displays+controls vs mac displays+controls".  This note covers the server-resource half; the companion display half of the same batch is its own pull request against this branch's base.  The audit it produces is what the companion server block now carries.

## What the asymmetry was

The Mac's Maintain tab shows three things the server's maintenance could not: when the next run is allowed (the cleaner's interval and the pressure gate), how much a scan found (reclaimable size before deleting), and the last runs with their outcomes (24-hour timeline and recent runs).  The server tool reported only per-strategy candidate and removal counts, the gate constants were stated only in prose, and the only history was the root audit JSONL that nothing read.

## What changed

- `scripts/server-maintenance/maintain.py`: results now carry `thresholds` (the same constants the pressure gate enforces), `started_at`/`finished_at`, and per-strategy `reclaimable_bytes` where an exact value exists — file sizes from the same directory listing, image sizes from the single per-image inspect that already ran, and buildx `Size` strings only when every candidate parsed (strict unit regex; anything unrecognised is omitted rather than guessed).  The top-level `reclaimable_bytes` sums only the strategies that stated one, and `reclaimable_complete` says whether all did.
- `scripts/server-status/supplement.py`: a bounded `maintenance` object in the server snapshot, built from the audit's tail (last 256 KiB, finished records only, newest ten): the threshold values when the newest record carries them, and per run its end time, mode, status, measured signed free-space delta and item counts.  Strategy ids appear only inside counts; no path, argument or owner from the audit record travels, and malformed lines are skipped, never guessed.
- `VPSStatusSnapshot` and the companion `server` block carry `maintenance` as an optional object (both sides tolerate its absence, so an older server keeps working), and the phone's block is bounded to the same ten runs.
- Mac: the Remote Server Maintenance card shows the gate sentence and the last five finished runs (time, mode, status, freed, removed/eligible) from the live snapshot.  iOS: the server Maintenance section gains the same "Recent Server Runs" block, shown under the server-status opt-in like the rest of the block, with the gate sentence from the phone's own formatter.

## What deliberately did not change

Server thresholds and strategy selection stay read-only from the UIs: the scheduled gate and age caps are deployment constants, and editing them over SSH needs its own validated config surface and opt-ins.  No new route, no new snapshot visibility class, and nothing about deletion eligibility changed — the numbers reported are the same ones the tool acted on before.

## Verification

- `scripts/server-maintenance/test_maintain.py`: 54 tests (`size_text_bytes` strictness, file/image/build-cache byte sums, thresholds, timestamps, plus the existing 50).
- `scripts/server-status/test_supplement.py`: 40 tests, including finished-only history, negative-delta refusal, newest-first bound of ten and tail-only reads.
- Swift: 1368 Mac tests, including the new decode and builder tests (bound of ten, ISO timestamps, absent-record tolerance).  One pre-existing `MaintainLayoutTests` width failure reproduces on pristine `main` locally and is green in CI; it is environmental, not this change.
- iOS companion target builds.

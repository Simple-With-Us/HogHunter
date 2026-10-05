# Reclaim script leaves repo trees alone

Sat, Oct 4, 2026

Effort row: `grok-build/hh-log-truncate`, issue #66, pull request #70.  State stays In Progress until that pull request merges.

## Why

`hoghunter-clean --clean` tail-truncated any log over 64 MB under local source-checkout trees.  Those trees are source checkouts.  The same scan split `find` output on newlines, so a path that contained a newline could be truncated or deleted as two different paths.

## What changed

- `scripts/hoghunter-clean` — `log_scan_roots`, `find_paths`, `split_find_output`, `report_path`.
- `scripts/test-hoghunter-clean.py` — newline-in-path, one-line report, and repo-root exclusion.
- `docs/EFFORT-LOG.md` — the in-progress row for this branch.
- `docs/rollouts/2026-10-04-log-truncate-scope.md` — this note.

Log scans now cover user log directories and the BotFleet home logs only.  Path listings use `find -print0`.  Temp-scratch and SQLite WAL scans use the same splitter.  Deletes still use `find -depth -delete` and do not parse a path list.  A non-zero `find` is logged and the paths it did print are kept.  The human report escapes newlines so one candidate stays one line.  The path passed to truncate or delete is unchanged.

## Decisions & Trade-offs

Repo checkouts are out of the default log scan.  A huge build log under `~/Code` will not be tail-truncated by the safe tier.  An operator who wants that file shrunk does it on purpose.  `~/.botfleet` stays in the scan because that tree is the housekeeper's own log, not a source checkout.

`find -print0` keeps a newline inside a path as one path.  `find` often exits non-zero when one subdirectory cannot be read and still prints the rest.  Treating that as an empty tree would skip real logs, so the engine logs the error and keeps the paths.  The human report shows `\n` for a newline.  JSON output lets `json.dumps` escape the real path.

## Verification

`python3 scripts/test-hoghunter-clean.py` — 6/6 passed (2026-10-04), covering the newline-in-path splitter, the one-line report escaping (including non-ASCII and lone-surrogate paths), and the repo-tree exclusion.

## Not in this pull request

Issue #67, shared Application Support folders such as Google or Microsoft, is a separate change.  Pull request #68 already landed the snapshot-safety fix as `3b61d03`.

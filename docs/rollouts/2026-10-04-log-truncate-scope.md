# Reclaim script leaves repo trees alone

Sat, Oct 4, 2026

## Why

`hoghunter-clean --clean` tail-truncated any log over 64 MB under `~/Code` and `~/apps`.  Those trees are source checkouts.  The same scan split `find` output on newlines, so a path that contained a newline could be truncated or deleted as two different paths.

## What

Log scans now cover `~/Library/Logs` and `~/.botfleet` only.  Path listings use `find -print0`.  Temp-scratch and SQLite WAL scans use the same splitter.  Deletes still use `find -depth -delete` and do not parse a path list.

## Verification

`python3 scripts/test-hoghunter-clean.py` — 5 passed, including the newline-in-path case and the repo-root exclusion.

## Not in this change

Extreme Clean can still offer real Application Support folders such as Google or Microsoft (issue #67).  That waits until the snapshot-safety change in PR #68 is on main, because both edit the disk cleaner.

# Server Snapshot Supplement

`supplement.py` is an on-demand helper for the existing storage watch.  It keeps
all existing database, device, CPU, memory and source timestamp fields.  Existing
`st_app_db.samples`, `ct_db.samples` and `um_db.samples` numeric observations are
attached as `database_samples` with their original Unix timestamps, so a valid
24-hour baseline works immediately without waiting for Mac history.  It adds
home-relative coding directory sizes and a fixed tool status list, without
reading command arguments, environment variables, credential files or container
configuration.

Deploy only after reviewing the existing watch and scheduler.  Copy the helper
to a root-owned, non-writable-by-other-users path beside that watch, then call:

```sh
python3 -S /root/vps-status-supplement.py --snapshot /root/vps-storage-status.json --home /root
```

Run it immediately after a successful watch, within the same exclusive scheduler
lock.  Do not create a second independently writing job.  The helper also checks
that its input did not change and publishes with an atomic rename, but that check
is not a replacement for the shared writer lock.  Keep the original watch and
schedule; this supplement does not replace their database checks or alert state.
The audited legacy cron had no writer lock.  Wrap both commands with one `flock`
on `/root/.vps-storage-watch/collector.lock` when integrating it.
Register any deployed helper in the fleet process inventory and its owner note.

Each directory scan has an eight second deadline and stays on one filesystem.
Failed or inaccessible measurements are omitted, preserving an honest gap in
history.  The Mac records source timestamps, so fetching the same snapshot twice
does not create fresh history.  Real 24-hour changes require a baseline collected
by the server or Mac; absent baselines are intentionally unavailable.  New
directory observations persist atomically in the separate
`hoghunter-directory-history.json` under `--history` (default
`/root/.vps-storage-watch`), scoped to snapshot host and retained for 48 hours, at
most 193 quarter-hour samples per path.  Legacy database histories are read only.

Native processes use `/proc` executable identities and `comm`, never argv.
Named fleet service checks request only systemd LoadState and ActiveState.
Interpreted tools without a matching named manager identity remain unknown when
an interpreter is running; they cannot safely be called stopped from executable
identity alone.  Shellular additionally uses its root-only `status-json`
filtered manager helper, validates the expected runtime script identity and live
PID executable, and never places that path or PID in the snapshot.  A green running state means a matching process or active named
service was observed, not an application health probe.  Counts for named services
are service instances, while native process counts are matching processes.

Synthetic verification:

```sh
python3 -m unittest discover -s scripts/server-status -p 'test_*.py'
```

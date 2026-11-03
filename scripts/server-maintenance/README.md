# Server Maintenance

Source-managed, on-demand root tool and compatibility entry point for the existing cron schedules.  Default invocation is `scheduled`.  It measures the root filesystem and skips before cache or Docker inventory when usage is below 80% and available space is at least 25 GiB.  Swap usage never triggers disk deletion.

## Invocation

```sh
sudo -n /usr/local/sbin/hoghunter-maintain scan
sudo -n /usr/local/sbin/hoghunter-maintain plan --strategy package-cache
sudo -n /usr/local/sbin/hoghunter-maintain run --strategy package-cache --confirm --dry-run
sudo -n /usr/local/sbin/hoghunter-maintain run --strategy package-cache --confirm
```

Explicit runs also require disk pressure.  `run` requires at least one named strategy and confirmation.  Duplicate or unknown strategies fail closed.  `scan`, `plan`, and `--dry-run` never acquire locks, create status files or write audits; their inventory commands are read only.  Docker's own read commands may maintain its internal client metadata.

| Strategy | Eligibility | Deletion |
| --- | --- | --- |
| `package-cache` | Single-link `.deb` files in `/var/cache/apt/archives`; mtime and ctime at least seven days old; not open | Unlink exact unchanged files while holding apt's archive lock |
| `rotated-logs` | `*.log.NUMBER.gz` in `/var/log/fleet-backup`; mtime and ctime at least 30 days old; not open; no audit/auth/security name | Unlink exact unchanged files |
| `docker-build-cache` | Default local builder only; regular, private, immutable, reclaimable records unused for seven days | Exact record ID with all age/in-use/type guards repeated in `buildx prune`; at most 20 records |
| `docker-images` | Explicit selection only; dangling, untagged images older than seven days; no `hoghunter.keep` or `janitor-keep` label | Revalidate eligibility; exact image ID removal without force; Docker refuses container references |

Scheduled defaults omit image removal because unused deployment images can still have rollback value.  No package-manager blanket clean, container removal, volume prune, filesystem traversal under data volumes, database manipulation, cache dropping, swap cycling or sysctl exists here.  Case-insensitive `.janitor-keep` on any relevant parent and symlink components refuse work.  The file inventory is shallow and capped at 1,000 directory entries; process inventory is capped at 10,000 entries and 50,000 file descriptors, within the global deadline.  An unreadable or incomplete active-file inventory refuses the file strategy.

## Result Contract

Stdout is exactly one JSON object, `schema_version: 1`, `tool: "hoghunter-server-maintenance"`.  Modes are `scan`, `plan`, `run`, `scheduled`.  Status is `planned`, `ran`, `skipped`, `partial`, `failed`, or `cancelled`.  A strategy reports `candidate_count`, `removed_count` (verified file unlinks), `attempted_count` (accepted Docker operations), `status`, and a bounded reason.  `ran` means eligible operations completed; it does not imply positive physical reclaim.  `partial` means interrupted/incomplete work or mixed successful and failed strategies.  Failed/cancelled/partial exits 1; other outcomes exit 0.

`before` and `after` contain root `free_bytes`, `total_bytes`, and `used_percent`.  `observed_free_delta_bytes` is signed and can include concurrent host activity.  `removed_file_bytes` counts logical bytes successfully unlinked after active-file checks; it does not claim APFS/reflink/other physical allocation recovery.  `reclaimed_bytes` is conservatively zero because this implementation has no authoritative physical reclaim meter.  Never convert an unrelated root free-space gain into attributed reclaim.  Duration, strategy counts, cancellation, and lock acquisition/release evidence travel with every result.

The shared mkdir lock is `/run/fleet-housekeeper.lock`.  Its mode-0600 owner record carries PID, Linux process start ticks, directory inode, and a nonce.  Recovery requires a root-owned record with the exact known schema and a provably dead PID under a separate flock guard; unknown, live, malformed, symlinked or changed records stay held.  No age force-break exists.  Before each external mutation, the tool creates and fsyncs a mode-0600 `dispatch.json` inside the lock and fsyncs the directory before launching its CLI.  Only a confirmed zero exit clears that record.  SIGKILL/OOM of the parent, nonzero exit, timeout or an exception leaves dispatch evidence that blocks release and dead-owner recovery, even if the detached CLI or daemon outlives its parent.  Timeout/cancellation kills and reaps the owned subprocess group before releasing the lock.  A read-only inventory timeout releases the lock after successful owned-group termination and reap.  If group termination or reap cannot be confirmed, the owner record becomes deliberately ineligible for automatic recovery and the lock stays held.  A mutation timeout retains its pre-dispatch marker even after the CLI is killed and reaped, because Docker's daemon may continue a request after its CLI dies.  An operator must establish that work stopped before retiring that lock.

Commands have 20-second deadlines and a 1 MiB stdout cap; each invocation has a 90-second work budget.  Filesystem operations cannot interrupt a stuck kernel syscall.  SIGINT/SIGTERM request cooperative cancellation.  Mutation writes root-only started/finished audit records to `/var/log/hoghunter-maintenance.jsonl`; an unavailable starting audit prevents deletion.  The scheduled cron's existing output capture also receives the final JSON.  No background service or new schedule is installed.

## Deployment

Run only from a reviewed checkout.  The helper defaults to a plan, writes no files in that mode, and prints hashes and modes without displaying the previous script body.

```sh
sudo -n /usr/bin/python3 scripts/server-maintenance/deploy.py
sudo -n /usr/bin/python3 scripts/server-maintenance/deploy.py --apply --expect-legacy-sha256 EXPECTED_HASH
```

Apply requires root and the expected hash of the current compatibility path.  It backs up the original body and mode manifest under `/var/backups/hoghunter-maintenance`, installs an immutable hash-named version at `/usr/local/libexec/hoghunter-maintenance/v1-HASH/maintain.py`, then installs the mode-0700 root launcher and mode-0755 compatibility wrapper.  Paths containing symlinks are refused; writes use sibling temporary files, fsync, atomic replacement and post-install hash/mode/owner verification.  Rechecks protect the legacy cutover from a changed original.  A root-only deployment audit records the manifest.  The helper never invokes maintenance and never changes cron schedules.

The existing wrapper path stays `/etc/cron.daily/coolify-auto-maintenance` and only execs the new launcher in scheduled mode.  Non-root SSH callers require a narrowly authorized `sudo -n` path; Hog Hunter uses that fixed prefix.  Existing direct callers of the root-only executable may fail on permission and must be verified separately.  Rollback is an explicit operator action: preserve the backup; restoring the hazardous old body/executable mode would re-enable its old behavior and is not a routine rollback.

```sh
python3 scripts/server-maintenance/test_maintain.py
python3 -m py_compile scripts/server-maintenance/maintain.py scripts/server-maintenance/deploy.py scripts/vacuum/engine.py
sh -n scripts/server-maintenance/coolify-auto-maintenance
swiftc -frontend -parse Sources/Storage/ServerControl.swift Tests/HogHunterTests/ServerControlTests.swift
```

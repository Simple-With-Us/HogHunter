# Server Snapshot Supplement

`supplement.py` is an on-demand helper for the existing storage watch.  It keeps
all existing database, device, CPU, memory and source timestamp fields.  Existing
`st_app_db.samples`, `ct_db.samples` and `um_db.samples` numeric observations are
attached as `database_samples` with their original Unix timestamps, so a valid
24-hour baseline works immediately without waiting for Mac history.  It adds
home-relative coding directory sizes and a fixed tool status list, without
reading command arguments, environment variables, credential files or container
configuration.

Deploy only after reviewing the existing watch and scheduler.  Copy the helper
to a root-owned, non-writable-by-other-users path beside that watch, then call:

```sh
python3 -S /root/vps-status-supplement.py --snapshot /root/vps-storage-status.json --home /root
```

Run it immediately after a successful watch, within the same exclusive scheduler
lock.  Do not create a second independently writing job.  The helper also checks
that its input did not change and publishes with an atomic rename, but that check
is not a replacement for the shared writer lock.  Keep the original watch and
schedule; this supplement does not replace their database checks or alert state.
The audited legacy cron had no writer lock.  Wrap both commands with one `flock`
on `/root/.vps-storage-watch/collector.lock` when integrating it.
Register any deployed helper in the fleet process inventory and its owner note.

Each directory scan has an eight second deadline and stays on one filesystem.
Failed or inaccessible measurements are omitted, preserving an honest gap in
history.  The Mac records source timestamps, so fetching the same snapshot twice
does not create fresh history.  Real 24-hour changes require a baseline collected
by the server or Mac; absent baselines are intentionally unavailable.  New
directory observations persist atomically in the separate
`hoghunter-directory-history.json` under `--history` (default
`/root/.vps-storage-watch`), scoped to snapshot host and retained for 48 hours, at
most 193 quarter-hour samples per path.  Legacy database histories are read only.

Native processes use `/proc` executable identities and `comm`, never argv.
Named fleet service checks request only systemd LoadState and ActiveState.
Interpreted tools without a matching named manager identity remain unknown when
an interpreter is running; they cannot safely be called stopped from executable
identity alone.  Shellular additionally uses its root-only `status-json`
filtered manager helper, validates the expected runtime script identity and live
PID executable, and never places that path or PID in the snapshot.  A green running state means a matching process or active named
service was observed, not an application health probe.  Counts for named services
are service instances, while native process counts are matching processes.

Synthetic verification:

```sh
python3 -m unittest discover -s scripts/server-status -p 'test_*.py'
```

## Identity-Bound Activity Controls

`control.py` remains an on-demand root helper, installed as `/usr/local/sbin/hoghunter-control`.  The Mac invokes it through a fixed `sudo -n` prefix and confirms mutations in its UI.  Every process action requires `--pid`, Linux `--start-time`, `--boot-id` and `--confirm`; old identity-less calls refuse.  The boot identity prevents a pre-reboot row from naming a new process with matching PID/start ticks.  Quit uses SIGTERM; Force Quit uses SIGKILL; both require pidfd signalling and repeat executable, owner, cgroup and process-start checks after opening the pidfd.  There is no numeric-PID signalling fallback.

Tame uses Linux nice 19 and stores the exact prior priority in root-only identity-keyed state.  Restore Priority requires that record and refuses a priority changed by another tool; it does not blindly reset to zero.  Priority changes are validated before and after the update, but Linux `setpriority` takes a numeric PID: unlike pidfd signalling, it cannot provide an atomic identity-bound mutation.  A process exit/exec race remains between validation and the syscall.  No stop-the-process workaround, cgroup migration, memory-limit change or scheduler-policy change is used.

The process guard checks executable identity, account ownership, cgroup membership, ancestors and named service protections.  Container membership never exempts infrastructure from protections.  Unknown Docker membership refuses mutation, and container-process mutations additionally require `--allow-workload-interruption`.  Coolify/database/fleet infrastructure remains guarded.  Only the exact inspected Coolify type `application` is eligible; `service`, database types and missing or unknown types always refuse, even under generic names.  The collector and mutation paths share this policy.  Workload Stop/Restart require a full container ID, container name and observed start time, plus confirmation and workload-interruption acknowledgement; display names alone cannot authorize an action.  Docker receives the full immutable ID, never an ambiguous display label.  The Docker metadata template requests selected labels/state only and never reads `Config.Env`, arguments or complete inspect objects.

Sample For 3 Seconds reads fixed kernel counters over a measured window and verifies identity at both ends.  It returns CPU share, fault counts, resident/swap bytes, nice level, thread count and process state.  It never attaches a debugger/profiler, pauses a process, reads stacks, argv, environment, mappings or file contents.  The report travels only as the control response; no new companion mutation route is added.

An exclusive root-owned flock serializes process, sample and workload actions across clients.  A starting audit must persist before action, and each final outcome is written to the root-only control audit.  Subprocesses use fixed arguments, bounded time/output and owned process groups; failures produce bounded generic reasons rather than raw Docker stderr.  Tests run harmless Python child processes to verify runner success, nonzero exit, timeout and output limits; all process-control syscalls, Docker/SSH commands and kernel roots are injected in mutation tests.

## Swap And Paging Observations

Process rows add optional `boot_id`, `swap_bytes`, `nice`, `allowed_actions` and `protection_reason`.  VmSwap is the kernel's per-process anonymous swap counter, not an allocation of total host swap.  CPU windows reject PID reuse, use actual elapsed time, and retain leaders from CPU, resident memory and swap so idle memory holders remain visible.  Protected rows remain visible with explicit action limits.

`memory_pressure` has its own `sampled_at` and `duration_seconds`, measured swap-in/out rates from `pswpin`/`pswpout`, and memory PSI `some`/`full` avg10 percentages.  Missing, malformed or reset counters remain unavailable; they never become a fictitious zero.  The Mac decodes old snapshots without these fields and displays source freshness.  No threshold configuration or owner-alert delivery is changed by this telemetry unit.

## Container Storage Diagnostics

The existing single writer now adds optional `storage_diagnostics`: selected Docker root/driver identity, per-category counts and displayed size bytes, and separately labelled engine reclaimable bytes.  Images, build cache, volumes and writable containers remain separate observations; they overlap and must never be added into a filesystem total.  Engine-labelled reclaimable space is not age-qualified cleanup eligibility or proof that an image has no rollback value.

Collection overlaps existing live tasks under a ten-second diagnostics deadline: selected local-socket Docker info gets at most two seconds, aggregate system-df at most eight seconds within the remaining deadline, and a flat-blob child gets at most two seconds within that deadline.  The child runs at nice 19 and idle I/O priority, walks no snapshot contents, follows no symlinks, stays on the root device, reads metadata only, and caps its own flat pass at 1.5 seconds and 20,000 entries.  The existing bounded runner also caps output and owns/reaps the child.  Failed, missing, malformed or over-budget sources remain explicitly unavailable or incomplete; partial totals never establish a baseline.

Blob allocation uses st_blocks rather than apparent length.  Hour/day timestamp cohorts describe allocation currently held by modified files, never net growth or reclaim candidates.  A complete observation may compare with the last complete observation of the same host/device/directory inode, stored only by the existing writer in `hoghunter-storage-baseline.json`.  A first observation, identity change, invalid baseline or failed sample never invents a zero delta.  No direct containerd deletion, snapshot traversal, new scheduler, second writer or retention change is added.  The optional native models and Container Storage rows retain source freshness, explicit missing readings and overlap limitations.

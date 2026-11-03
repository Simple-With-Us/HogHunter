# HH-203 Server Maintenance Core

This source unit replaces the untracked maintenance behavior with a pressure-gated, versioned root tool and a compatibility wrapper.  It does not deploy a server change.  The parent session owns containment, deployment, host verification and the broader Server Activity experience.

The new tool reports scan/plan/run results with exact strategy names, candidate counts, bounded work, shared-lock evidence, before/after root capacity and explicit byte semantics.  Healthy root storage skips without Docker inventory.  Package cache and selected rotated logs require age, unchanged identity, no keep marker, no symlink, no hard link and a complete active-file check.  Docker cache uses exact unused, immutable private regular records; image cleanup requires explicit selection and excludes scheduled defaults.  Data directories, named volumes, databases, backups, active worktrees, swap files and user files are outside its deletion scope.

The compatibility wrapper preserves the existing invocation path and schedules.  Deployment defaults to read-only planning and requires an expected legacy hash for apply; it records a protected backup, installs a versioned root-owned tool and verifies installed hashes/modes.  No maintenance command runs during deployment.  See `scripts/server-maintenance/README.md` for the command and JSON contract, bounded-work limits, conservative reclaim evidence and lock recovery rules.

Hog Hunter's remote maintenance step now invokes the fixed root tool through noninteractive sudo, validates structured output and exit status, and reports failures, skips and timeouts truthfully.  It never invokes the old script.  Server process/workload control now refuses malformed output and numeric JSON booleans, and refuses concurrent actions while a request is suspended.

Validation: hermetic maintenance/caller tests, Python compilation, shell syntax, Swift source parsing and diff whitespace checks.  XCTest regressions cover malformed control output and overlapping requests; hosted XCTest execution remains an integration check.  Server dry-run, root/non-root caller permission checks, installed hash verification and external cron behavior remain deployment checks for the parent session.  Physical reclaimed bytes stay unclaimed until an authoritative attribution source exists; observed free-space delta is a separate metric.

Refs HH-203.  Server Activity process identity, action parity, sampled telemetry, operator-facing history and sustained memory-pressure alerting remain separate work.

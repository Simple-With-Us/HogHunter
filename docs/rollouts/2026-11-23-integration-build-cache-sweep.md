# Integration-tree build caches join xcode-scratch (2026-11-23)

Jay's 2026-11-23 request: "aggressively clean disk space on mac and server and find out why mac keeps getting full so fast and make hog hunter work better at stopping that".  This change is the "work better at stopping that" half for the Mac.

## Root cause

Every `xcodebuild` run without `-derivedDataPath` writes `build/` beside the project file.  The human integration trees under `~/Code` are merged into constantly, so no checkout-activity gate can ever open for them, the caches regenerate between builds, and `xcode-scratch` only looked at `/private/tmp` and `~/.clutch/derived-data`.  Measured this day: `~/Code/HogHunter/build`, 4.1 GB, idle 4 days, removed by hand; free space went from 6.8 GB to 136 GB (the purgeable release did the rest).  The AFC guard regex that protects all of `~/Code` from `mac-auto-cleanup.sh` is untouched and still right for that program: this rule only ever names a checkout's `build/` directory, never sources or `.git`.

## Gates (all reused, none new)

- Positive identification through `_derived_data_identity_refusal`: an `info.plist` naming a `WorkspacePath`, `Build/` holding only Products and Intermediates.noindex, `Logs/` or `Index.noindex/` beside it, no link at the top, on the home folder's volume.
- `has_keep_sentinel` on the path, then the deep `holds_keep_sentinel` walk at scan time; the verdict must be known and clean, and the scan-time verdict is carried so the delete trusts it (PR 274 review).
- `is_forbidden` still applies: nothing under `.muse` or `~/apps/botfleet-*`, and every other forbidden path.
- Idle 24 hours by the newest file in the whole tree (`IDLE_MIN_XCODE_SCRATCH`) with nothing holding it open; at least `MIN_CANDIDATE_BYTES`.
- Only the `build/` directory is named; a symlink `build/` is skipped, and merges touching `.git` and sources do not block a cache that has not been written.

## Pressure line and recheck unchanged

`xcode-scratch` stays in `PRESSURE_RULES`: a delete only happens at 60 GB free or less, so always at or under the 25 GB critical line, and `apply_candidate` reads df again before each delete.  The `recheck` closure re-asks identity, no-running-build, and the 24 h idle gate against a fresh open-file listing inside the capped recheck budget; a refusal there is `refused_count`, not a failure.

## Review round (same day)

The review round on this PR caught three things and each fix landed:

- **The pressure line had no teeth in code.**  The first draft emitted `category="xcode-artifacts"`, which is not in `PRESSURE_RULES`, so `apply_candidate` would have skipped the df re-read and deleted at any free level -- contradicting everything this note says.  Both reviewers caught it; the pool now emits `xcode-scratch` and `test_integration_cache_respects_the_pressure_line` walks the line from both sides.
- **The recheck now re-asks every gate.**  A helper (`_integration_cache_refusal`) holds the whole gate sequence -- plain folder, forbidden, surface marker, processes naming or running from it, Xcode identity, 24 h idle, open handles, deep marker walk -- and the recheck calls it again on a fresh open-file listing, so a marker placed or a handle opened after the scan stops the delete.
- **The scan asks `tree_in_use`, not a raw lsof count.**  The first draft called `open_handles` directly; on Linux CI, where `/usr/sbin/lsof` does not exist, the probe fails closed to "open" and correctly refused every candidate -- the second CI-only failure this branch taught the suite.  `tree_in_use` is the rule-level question the sibling lane sweep already asks, and `gates_open` patches it the same way.

`test_integration_cache_recheck_reruns_the_gates` places a `.janitor-keep` marker after the scan and proves the delete stops.

The second review page asked for the rest of the xcode-scratch chain, and the helper now carries it whole: the three idleness clocks (ctime, shallow, deep), `_derived_data_precious_refusal` (a key, archive, project or note anywhere in the tree keeps it), and `regenerable_clones_only` (no repository inside but a clean SwiftPM clone).  One gate is deliberately left out: `process_names_path(tree.name)`, which `xcode-scratch` runs on distinctive scratch names -- `build` is a word half this Mac's command lines carry (`swift build`, `cargo build`), it would starve the pool, and the full-path probe names the cache specifically already.  The `~/Code` listing is wrapped like the sibling lanes pool, so an unreadable tree costs a log line, not the rest of the rule.  `test_integration_cache_refuses_precious_and_nested_state` covers both refusals and the recovery when the key is removed.

## Tests

Nine new tests in `scripts/test-hoghunter-clean.py`: five from the first draft (swept cache with sources intact, survives active merges, needs the Xcode shape, waits for idleness, keeps `.janitor-keep` markers) and four from the CI and review rounds (the probes answer without BSD `-quit`, the pressure line holds from both sides, the recheck stops a post-scan marker, precious and nested state refuse with recovery).  255/255 pass, including the cross-checks against the real `Sources`, `docs`, and `AGENTS.md`.

## Portable probe flags (CI fix, same day)

The first CI run on this branch caught the real find probes failing closed on Linux: GNU find refuses BSD's `-quit` outright, so `holds_keep_sentinel` answered unknown and `touched_since` read every tree as touched, which correctly refused the new candidates and failed the two acceptance tests.|GAP|Both probes now build their command from `FIND_QUIT` (`-quit` on macOS, absent on Linux), and `test_the_probes_answer_without_bsd_quit` runs both probes with the flag removed.|GAP|Production macOS behavior is unchanged; the Linux probes pay a full bounded walk instead of an early exit.

## Not changed

- No new rule and no cleaner category: the same `xcode-scratch` rule gains a candidate pool, and `config/reclaim-policy.json` wording is updated to match.
- The clean regimen (`DiskCleaner`) is untouched; `CleanRegimen.schedulableRules` does not change.
- `stale-build-output` and `tmp-build-trees` stay report only, under the owner's 2026-11-04 narrowing.

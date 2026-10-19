# Storage Growth And Server Tools

HH-165 adds daily size changes beside database and directory sizes, compact Mac metrics with CPU minute bars, and a visible server tool list.  It extends the server panel from HH-163.

## Size Changes

Rows use two spaces between the label, size, and parenthesized change.  The fraction slash is U+2044 and the `24h` suffix is 3–4 points smaller.  Socratic Trade is displayed with a space.

Magnitude below 0.1% displays `~0%`.  Smaller than 10% uses one significant digit; larger changes use two.  Decreases retain their negative sign beside the down arrow, for example `(↓-12%⁄24h)`.

A real baseline must be within 15 minutes of a full day, with only one minute of timestamp precision tolerance on the short side.  Missing, stale, zero, or invalid baselines display an unavailable change instead of a fabricated percentage.  Re-fetching a server snapshot does not create newer observations.  History is host/metric/path scoped, bounded to 48 hours and quarter-hour buckets, and stored in the app's existing per-user support directory.  Server history imports run away from the main actor.

## Local And Server Collection

The Mac measures Code, task lanes, CLI state/cache roots, Xcode Derived Data, and temporary files every 15 minutes while the panel's collection task runs.  Directory probes have an eight second deadline, avoid duplicate real paths and overlapping roots, and preserve old measurements as unavailable if a scan fails.  CPU bars show 30 one-minute averages collected while Hog Hunter is running; CPU and memory have no daily change badges.

The server supplement preserves the existing watch's database checks, source timestamps, alerts and size fields.  It imports the three existing numeric database histories without modifying those files, so valid database changes are immediately available.  New directory history is separate and needs a full day before daily changes appear.  The directory list is expanded and includes Code, task lanes and CLI/cache roots, alongside existing storage paths.

Tool dots report verified executable or named manager state.  A running process is not a health probe.  Interpreted tools without a trusted manager identity remain unknown rather than falsely stopped.  No process arguments, environment, credential files or database contents are read by the collector.

The original 15-minute cron entry now calls a wrapper holding one writer lock across both the original watch and the supplement.  The original watch is unchanged; private rollback copies of the watch, cron and previous snapshot were saved before activation.  See `scripts/server-status/README.md` for the deployment contract and synthetic checks.  The fleet process inventory and its Coding note track this helper and the separately installed Shellular server host.

## Verification

- Full local macOS suite: 681 passed, no failures.
- Final focused history/store/layout checks passed after tightening baseline age and moving imports off the main actor.
- Server supplement: 12 synthetic Python checks passed.
- Native AppKit renders inspected for compact rows, readable suffixes, visible directory rows, tool dots, and removal of the explanatory subtitle.
- Server wrapper activation: original watch preserved, same cron cadence, collector exit 0, 582 database observations, 13 directory rows, and 12 tool states.

The app UI still requires merge and installation verification.  Shellular has one approved iPhone and no pending devices; a successful phone reconnection has not yet been observed.

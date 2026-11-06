# iPhone Overview and Navigation Parity (HH-212)

The Mac's window is Overview, Activity, Storage (Installed Apps, Disk Cleaner,
Drives & Folders), Maintenance, Network.  The phone had Activity, Storage as
one long list, Network and Server, with Maintain as a section inside Storage.
This change gives the phone the same shape.  No snapshot field, route, opt-in
or server data changes: every pane shows exactly the data the same sections
showed before, and the Mac side is untouched except one shared, additive
ranking helper.

## Tab picker

Six tabs cannot carry their names in one segmented control on a phone, so the
top picker now carries the Mac's own SF Symbols (house, chart.bar.xaxis,
internaldrive, wrench.and.screwdriver, network, server.rack, from
Sources/UI/HogHunterPanel.swift) with the full names kept as accessibility
labels.  Parity of structure and iconography rather than identical desktop
segmentation; VoiceOver still speaks the names.

## Overview

A new first tab, and the new default, matching the Mac's opening tab.  It
leads with the same CPU and memory meters Activity has (extracted into one
`metersAndPills` view both tabs share, so the pair cannot drift), then Top
Activity: the six busiest rows, with an Open Activity jump.

The ranking is `rankedByActivity()` on the shared CompanionRow array: strictly
descending CPU, then memory, then name, then id.  That is a total order, and
it has to be: an epsilon comparator (treat |a-b| < 0.05 as a tie) is not
transitive - CPU 0/memory 3, CPU 0.04/memory 2 and CPU 0.08/memory 1 form a
cycle, which review caught in the first draft.  Activity's own sort is
untouched; the Overview deliberately does not reuse it, so the busiest list
keeps its meaning when Activity is sorted by memory.  The helper lives in
Sources/Companion/CompanionSnapshot.swift so the Mac test bundle covers it:
Tests/HogHunterTests/CompanionOverviewRankingTests.swift pins the descending
order, the epsilon-cycle regression, the tie chain, missing numbers ranking
last, and permutation stability.

The server's strip follows when the snapshot carries a server block: one line
from `CompanionServerStatus.resolvedState()` plus the Mac's own headline
words, so a stale or failed reading says so instead of passing off old
numbers as current, and a jump to the Server tab.  Flagged Issues show on
Overview too, as they already did on Activity and Server.

The meters render from the existing pulse and CPU history, so an older Mac
needs no update.  A Mac too old to send the numeric fields still gets its
rows ranked from its display text, the same kind of fallback the phone's
`CompanionRow.sortCPU`/`sortMemory` apply through `UsageParser`
(ios/Sources/CompanionViews.swift).  The companion side parses with its own
private `CompanionActivityText` (Sources/Companion/CompanionSnapshot.swift),
whose rules match `UsageParser` on ordinary readings with one deliberate
difference: a reading that scales to or past 2^64 bytes (for example
"16777216 TB") is rejected as unparseable instead of trapping the way
`UsageParser.parseMemoryBytes` would, so it counts as no reading.  Text with
in-range digits parses into a ranking value, so those rows can rank among
numbered ones, and only text without digits or out of range - a genuinely
unnumbered row - ranks after numbered rows, because no number is not
evidence of being busiest and the text is already rounded for display.
`testTextFallbackRanksOlderMacRows` pins the ordinary case and
`testOutOfRangeMemoryTextDoesNotTrap` pins the rejection.

## Storage panes

Storage gains a segmented picker with the Mac's three subtabs, shortened to
Apps, Cleaner and Drives so the picker fits.  Drives stays the default pane,
keeping the Mac's disk usage as the first storage a person sees (the
long-standing fix for people mistaking the iPhone's storage for the Mac's).
The existing sections keep their content and order inside each pane:

- Drives: Mac Disk Usage, Mounted Drives, Top Directories, iPhone Storage.
- Apps: Mac Storage by App, Space by Kind, and the scanning hint.
- Cleaner: Disk & System Clutter, Cleanable Categories, Custom Excluded
  Folders.

Two launch flags let the screenshot lane reach the new panes:
`-HogHunterStorageApps` and `-HogHunterStorageCleaner`, used together with the
existing `-HogHunterStorage` tab flag.

## Maintain tab

The Maintain card moves out of Storage into its own tab, the Mac's
Maintenance entry, reached directly or by `-HogHunterMaintain`.  Its
destination (`MaintainView`) is unchanged.

## Screenshots

The dashboard's default tab is now Overview, so the lane's per-format frames
will show Overview instead of Activity: an intended content change.  The
required scenes (widget-preview, clean-confirmation, cleaner-quick,
cleaner-partial) OCR for widget, clean-confirmation and cleaner text only
(scripts/ios_screenshot_checks.py `scene_problem`), and none of it lives on
the dashboard, so they are expected to pass unchanged - an expectation from
reading the lane's source, to be confirmed by actually running it.  Four
best-effort extras join the lane: activity, storage-apps, storage-cleaner and maintain.

## Not verified here

Authored without a Mac toolchain: uncompiled, untested.  The Mac host builds
both targets, runs the Mac test bundle (which now includes the ranking
tests), and drives the simulator; the pixels to check are the icon tab
picker (legibility, selection state, VoiceOver order), the Overview meters
and Top Activity rows, the server strip in each state (ok, stale, error, no
reading, no server block), each Storage pane, and the Maintain tab opening
`MaintainView`.

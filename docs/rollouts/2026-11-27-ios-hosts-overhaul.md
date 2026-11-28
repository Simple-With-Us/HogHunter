# iOS hosts overhaul: Overview, Mac, Server, Upkeep (2026-11-27)

Owner report: the iPhone app felt illogically arranged.  Server was one
small segment on the right of a six-way picker, and the Overview tab
talked only about the Mac.

## What was wrong

The phone put six destinations (Overview, Activity, Storage, Maintain,
Network, Server) in one segmented picker over a single list.  That
flattened two axes the Mac keeps apart (`HostScope` This Mac | Server
crossed with `PanelTab` in `Sources/UI/HogHunterPanel.swift`) into one
row, so a host sat beside features as if they were the same kind of
thing.  Overview showed Mac meters and Mac top activity with the server
as a one-line strip at the bottom.  Maintain spent a whole top-level
slot on a single link row.

## What changed

`ios/Sources/CompanionViews.swift` only.  No route, snapshot field, or
opt-in changed, so the table in `AGENTS.md` stands as written.

- The segmented picker and its "Tap a tab to switch view." caption are
  gone.  A native bottom `TabView` carries four tabs: Overview, Mac,
  Server, Upkeep (`CompanionTab`).
- Overview judges every machine: Flagged Issues lead, then the Mac's
  meters and busiest rows under a Mac header, the server summary
  beside them, and the upkeep state last.  Each part opens the tab
  that owns it.
- The Mac tab holds the Mac window's three viewing panes in a short
  segmented picker (`CompanionMacPane`: Activity, Storage, Network).  Storage keeps its Apps and Drives panes.  Flagged Issues sit on the
  Activity pane, beside quit and tame.
- The Server tab is unchanged inside (`ServerTabContent`, its section
  picker, controls, and Tailscale rules), now a peer of the Mac tab
  instead of the last segment.  Pull to refresh there still asks the
  Mac to read the server.
- The Upkeep tab groups the jobs that change the Mac: Maintenance on
  top, then the Disk Cleaner sections (safe clean, review-and-choose,
  cleanable categories, custom excluded folders) moved whole out of
  Storage.  `CleanerView`, `MaintainView`, the clean deep link, and
  every confirmation keep their old behaviour.
- The connection header (Mac name, freshness) heads the Overview, Mac,
  and Upkeep lists.  The Server tab keeps its own two-machine cards,
  so each tab says which machine its numbers belong to.

Screenshot flags keep their HH-212 names and land on the tab that now
owns the surface: `-HogHunterActivity`, `-HogHunterStorage`, and
`-HogHunterNetwork` open the Mac tab on that pane;
`-HogHunterMaintain` and `-HogHunterStorageCleaner` open Upkeep;
every `-HogHunterServer*` flag opens the Server tab.  The `maintain`
and `storage-cleaner` captures therefore frame the Upkeep tab.

## Widgets follow the same rule

The owner then flagged the large widget: its Clean button was a
full-width hero taller than a meter and clipped by the widget's
bottom edge, and every widget led with the Mac.  In
`ios/Widgets/HogHunterWidgets.swift` and
`ios/Widgets/HogHunterWidgetViews.swift`:

- The widget is configurable (`SelectHostIntent`, parameter Show):
  Mac and Server (the default, today's combined layout), Mac Only,
  or Server Only.  Two pinned instances can watch different machines.
- Three more options ride along: Rank Busy By (CPU or Memory, on the
  shared `rankedByActivity` / `rankedByMemory` total orders), Show
  Clean Button for glance-only widgets, and Tap Opens (Overview,
  Mac, Server, or Upkeep) through `hoghunter://open/<tab>`, which
  `CompanionDeepLink` treats as navigation only and an unknown tab
  still just opens the app.
- One compact `CleanPill` replaces the medium and large hero buttons
  at every size.  On the large widget the clean card became a single
  row (label, status, pill), which also ends the bottom clipping.
- A Server-only instance shows the server's CPU and memory and the
  reading's age, with no Mac rows and no Mac Clean control.  The data
  contract is unchanged: `widgetCopy()` still lets only the state,
  the reading times, and the two percentages cross into the shared
  container, so a Server widget cannot name a host, disk, or process.
- The fixture snapshot gained the same two server percentages, so
  the gallery and screenshot previews show each focus as pinned.

## Verification

- `xcodebuild -scheme HogHunterIOS -destination 'generic/platform=iOS
  Simulator' build` in this lane: succeeded after each stage,
  including the AppIntents widget configuration.
- Simulator visual check on a temporary iPhone 17 Pro device with
  `-HogHunterSample` and `-HogHunterWidgetPreview`, frames inspected
  directly: all four tabs (Overview leading with a server flagged
  issue, Mac with its pane picker, Server with both machine cards,
  Upkeep with Maintenance above the cleaner), combined widgets at
  every size with the compact pill, the Server-only large widget
  (gauges and age, no Clean), and the Mac-only stack (no server
  lines).  CoreSimulator repeatedly shut down or crashed SpringBoard
  under host load during capture; the frames above are the ones that
  rendered, and each was read before this was written.
- `xcodebuild -scheme HogHunter -destination 'platform=macOS' test`:
  1,423 passed, 1 skipped, 1 failed
  (`MaintainLayoutTests/testEveryModeFitsThePanelWidth`, Disk Cleaner
  689 pt against a 687 pt panel).  The Mac test bundle does not
  compile `CompanionViews.swift` (see `project.yml`), so this failure
  does not come from this change; it needs its own look.

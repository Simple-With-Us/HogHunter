# Server status on the main window (HH-163)

**Date:** 2026-10-19
**Issue:** HH-163 (Linear, HogHunter team)
**Seat:** OpenCode

## Context and objective

The remote server's resource card landed in the Maintain tab with the VPS feature
(HH-159, PR #177).  The owner noticed two things about it, and both were right:

- The Maintain tab was **taken over** by the card.  The card is tall (CPU, RAM,
  disks, swap, app databases, largest folders), it sat second in the tab's
  stack, and it pushed the maintenance steps and the run history out of view.
  The tab is about the cleaning that runs; the card was not part of that.
- The server status was **hidden**.  The card was below the status card, so it
  was off the fold of a 620 by 680 panel, and nothing anywhere else in the
  window said a server was even being watched.  The owner did not know the
  feature was there.

The owner's ask: show the server status on the main window, and let the main
window grow a little if it needs to.  The Maintain tab gets its content back.

## What changed

**A new top-level Server tab** (`Sources/UI/HogHunterPanel.swift`,
`PanelTab.server`).  It holds the full card plus a line saying what the
readings are and that they refresh every minute.

**A strip on the Activity tab** (`Sources/UI/VPSStatusStripView.swift`): one
line under the meters with the host, then CPU, RAM and disk, each in its own
severity colour, so a reader sees *which* number is the problem.  The strip is a
button: one click opens the Server tab.  It appears only when a host is
configured — with no server there is nothing to report, and the Server tab
explains how to set one up.

**The Maintain tab gives the card back** (`Sources/UI/MaintainView.swift`).  The
card is gone, and no server figures stay behind it: the tab is about the
cleaning that runs.  The only trace of the server here is the "Remote server
maintenance" step, which appears when a host is configured and says what it
does to it.

**The server is a peer machine, not a Maintain item** (owner, 2026-10-19, in
the thread): "it makes no logical sense that the server's stats are under the
Maintain tab when that is just another computer/operational platform like
another mac would be".  So the server's readings have their own top-level tab
beside Activity, Storage and Network, and the Maintain tab carries none of
them.

**The panel is a little bigger**: 620 by 680 became 680 by 720, which gives the
strip its own line and the four tab segments room for their labels (the picker
went from 290 to 360 points).

**The readings follow the window, not a tab** (`Sources/Storage/VPSStatusStore.swift`).
Before, the server was only fetched while the Maintain tab was on screen, which
is part of why the status was invisible.  The store now counts its owners:
`acquirePolling()` on appear, `releasePolling()` on disappear, and the polling
stops when the last owner lets go.  The panel takes a share while it is open;
the Maintain tab takes one while it is showing.  Neither can switch the other
off, which is what a plain start/stop pair would have done.

**One model, two places** (`Sources/Storage/VPSStatusModels.swift`):
`VPSStatusSnapshot.headline` is the one-line answer (host plus each reading
with its severity), used by the strip, the Maintain line, and the strip's
spoken label.  The label carries the numbers, so a screen reader hears the
server's state instead of the word "server".

## Decisions and trade-offs

- **The strip is hidden when no host is configured.**  A permanent
  "no server configured" line on the main window is noise for someone who does
  not use a remote server.  Discoverability is handled by the Server tab,
  which always exists and says what to do.
- **The Maintain tab keeps no server figures.**  The tab runs remote
  maintenance (`coolify_remote`), so the server belongs to its work, but the
  owner is explicit: the server is a peer platform, and its readings live in
  their own tab.  The step itself names the host it maintains.
- **The panel grew 40 points, not more.**  The strip needs a line, and the four
  tab segments need their labels.  Everything else stayed the size it was, so
  the process list keeps the room it had.
- **No phone change.**  The card was a Mac feature; the phone's Maintain view
  was not part of this.

## Files touched

- `Sources/UI/HogHunterPanel.swift` — the Server tab, the strip, the panel size,
  the accessibility label, and the polling share.
- `Sources/UI/ServerStatusView.swift` — new: the strip and the Server tab.
- `Sources/UI/MaintainView.swift` — the card out, one line in.
- `Sources/UI/VPSResourceCardView.swift` — unchanged; the card itself moved
  hosts, it did not change.
- `Sources/Storage/VPSStatusStore.swift` — owner counting for the polling.
- `Sources/Storage/MaintainStore.swift` — takes and gives back its share.
- `Sources/Storage/VPSStatusModels.swift` — the headline.
- `Sources/App/UISmokeTest.swift` — the Server tab joins the tab-fits check.
- `Tests/HogHunterTests/PanelServerStatusTests.swift` — new.
- `Tests/HogHunterTests/VPSStatusTests.swift` — the headline and the polling
  owners.
- `README.md`, `CHANGELOG.md` — this change.

## Verification state

- `xcodegen generate`, then `xcodebuild -scheme HogHunter -destination 'platform=macOS' test`: **TEST SUCCEEDED**, the whole suite, no failures.
- `python3 scripts/test-hoghunter-clean.py`, `scripts/test-robotic-vacuum.py`,
  `scripts/test-vacuum-lanes.py`: unchanged by this work, green.
- New tests: the panel has a Server tab, the four-segment picker fits the
  panel width, the strip fits the panel width, the spoken label names the host
  and its readings, the headline carries each number with its own severity, and
  the polling survives until the last owner lets go.
- Installed and looked at on this Mac after the merge (see the closeout note).

## Next steps and blockers

None.  The owner asked for the design to be worked out here, and the shape is
as described above: a strip for the answer, a tab for the detail, and the
Maintain tab back to being about maintenance.

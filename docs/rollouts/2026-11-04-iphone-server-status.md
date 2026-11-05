# iPhone Server Status (HH-215, Stage 1)

The iPhone had no view of the server.  Nothing under `Sources/Companion` or `ios/Sources` carried server data, while the Mac reads `/root/vps-storage-status.json` over SSH once a minute.  This stage is read-only: it adds the readings and Flagged Issues to the phone, and no route that can change the server.

## What Travels

The snapshot gains four optional fields, in `Sources/Companion/CompanionSnapshot.swift`.

| Field | Plain snapshot | Detailed snapshot, opt-in on |
|---|---|---|
| `remoteServerStatusAllowed` | yes | yes |
| `server` | never | yes |
| `flaggedIssues` | the Mac's rows only | the Mac's and the server's |
| `flaggedIssuesCoverServer` | false | true |

The plain snapshot is what the shared pairing code reads, and what any credential reads from outside the local network and Tailscale.  The detailed snapshot goes only to a phone's own token from the local network or Tailscale.  This is the existing `maintain.steps` gate in `CompanionHTTP.response`, and no new route or credential check was added.  The two opt-ins are independent: Allow iPhone to Run Maintenance adds only the steps, and Allow iPhone to See Server Status adds only the server's data.

## Why Flagged Issues Are Split

Server rows name the host (`on <host>`), services and mount points, and `server.unreachable` carries the raw SSH error, which can name the host and its address.  Mac rows name only what the plain snapshot's rows and drives already name.  So server rows follow the server block.

That has a consequence for All Systems Calm.  An empty list in the plain snapshot says nothing about the server, so `flaggedIssuesCoverServer` is false and the phone says This Mac Is Calm.  An empty list with a stale or missing reading is the same, because the Mac's evaluator judges only the reading it has.  `CompanionSnapshot.flaggedSummary` decides this in shared code, so the Mac's test bundle covers it.

## States And Missing Numbers

`server.state` is `notConfigured`, `noReading`, `error`, `stale` or `ok`.  It travels as a string, so a state a later Mac adds cannot make an older phone fail to decode the whole snapshot.  A reading older than 15 minutes is stale, the same limit the Mac's pressure and storage readings use, and the phone re-checks it against its own clock, so a reading still ages if the Mac goes quiet.

A number the Mac does not have is nil, and the phone draws a dash.  `VPSMemory.usedPercentage` returns 0 for a zero total, so the builder drops that reading rather than passing on a false zero.  Every `Double` is checked for being finite: `JSONEncoder` refuses NaN and infinity, which would fail the whole snapshot and freeze the phone on its last reading.

`VPSStatusStore.errorMessage` clears as soon as a retry starts, and a retry against a dead host takes up to 15 seconds, so a polling phone would see a failing server flicker to calm.  The store now also keeps `lastReadError`, held until a read succeeds, and the phone's data uses that.  The Mac's own UI is unchanged.

## Identifiers

Process and workload row ids are the first 8 bytes of a SHA-256 of the Mac's own row id, in hex.  No pid, boot id, start time, container id or image reaches the phone.  Stage 2 can hand such an id back and have the Mac resolve it against its own cached reading.

## The Widget

The phone stores each snapshot in the App Group for the widget, which draws nothing from the server.  That copy goes through `withoutServerDetail()`, so server internals do not sit in a shared container after the screen closes.

## Compatibility

Every new field is optional.  An older Mac sends none of them: the Server tab says to update the Mac, and the issues section stays hidden rather than claiming calm.  An older phone ignores the new keys.  Both are tested in `CompanionServerStatusTests.swift`.

## Not Done Here

There are no server control routes yet.  Stage 2 covers process actions, workload stop and restart, and server maintenance.  The Server tab's screenshot flag is `-HogHunterServer`, listed in `scripts/capture-app-screenshots.sh`.

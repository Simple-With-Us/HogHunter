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

Stage 1 had no control routes.  Stage 2 below adds them.  The Server tab's screenshot flag is `-HogHunterServer`, listed in `scripts/capture-app-screenshots.sh`.

# Stage 2: Server Controls

Stage 1 was read-only.  This stage adds three routes, each behind every gate below.

| Route | Body |
|---|---|
| `POST /v1/server/process` | `rowId`, and `action`: `quit`, `forceQuit`, `tame`, `untame` or `sample` |
| `POST /v1/server/workload` | `rowId`, and `action`: `stop` or `restart` |
| `POST /v1/server/maintain` | `mode`: `scan` or `run`, `strategies`, and `acknowledgeImageRemoval` on a run that removes images |

## Why Tailscale Only

The companion link is plain HTTP, and TLS is still open (board `ca962984`).  A token is visible to anyone on the same local network when a phone polls over it.  That is an accepted risk for controlling the Mac, but not for reaching a server that runs other people's work, so a sniffed token has to stop at the local network.

`CompanionPeer.arrivedOverTailscale` is the only thing the gate reads.  It is set only by `provingTailscaleArrival`, on the socket the request arrived on, and needs both of these:

- The client's address is in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`.
- The address it connected to is one this Mac holds on a `utun` interface.

The second check tells Tailscale from a carrier that hands the same `100.64.0.0/10` range to a home router, because there the Mac's own address is on Wi-Fi or Ethernet.  A host on the local network that forges a Tailscale source address does not complete the handshake, because the Mac's reply is routed into the tunnel.  `resolvingForwardedClient` builds a new peer with the flag off, so a forwarded header cannot claim Tailscale, and plain loopback is refused too.

## What This Cannot Prove

These reach the Mac from a Tailscale address and pass, because the Mac cannot tell them apart from a phone on the tailnet.  A valid phone token is still required for each.

- A device behind a tailnet subnet router or an exit node, whose traffic arrives under a tailnet address.
- A process on this Mac connecting to the Mac's own Tailscale address.
- Another VPN that puts an address from those ranges on its own `utun` interface.

A `tailscale serve` proxy goes the other way: it arrives over loopback and is refused.

## The Row Id

The id is the one stage 1 added: the first 8 bytes of a SHA-256 of the Mac's own row id.  The Mac recomputes it over the rows it would send, so a row beyond the block's limit cannot be addressed, and a restarted process has a new start time and so a new id.  Each row also carries `actions`, in the phone's words, so the phone offers only what the Mac would accept.

## What The Mac Checks

The opt-in and the Tailscale rule are read before the body.  Then the body is read whole or not at all, using a key count taken from the bytes, because `JSONSerialization` silently keeps one copy of a repeated key.  Then `CompanionServerActions` needs a current reading, a known row and `can(action:)`, and only then calls `ServerControl` or `ServerMaintenanceControl`.  Those two are unchanged, so the phone reaches the server through the same fixed argument lists and SSH timeouts as the Mac's menus.

Server maintenance has no row, but it follows the same reading rule, so a phone cannot start it while the Mac's reading is stale.  It also waits for a Maintain run on this Mac, as the Mac's card does.  The Mac's own menus and card keep their own control instances, so an action from the Mac can overlap one from the phone.  The server's identity checks and its cleanup lock still apply.

## The Phone

Every action has a confirmation naming the action and the row, and the buttons are named for what they do: Stop Process, Force Quit Process, Tame Process, Restore Priority, Sample Process, Stop Workload, Restart Workload, Scan Server, Run Server Maintenance.  A run with Unused Docker Images asks a second time, in its own alert, with a Remove Images button.

A phone at home polls over Bonjour, which these routes refuse, so `serverControlEndpoint` sends server actions to the saved Tailscale address even while the local one is in use.  With no such address saved, the phone shows the Tailscale sentence and does not offer the actions.  A row with no actions has no button.

An answer that never came is reported as an unknown outcome, not as a failure to act, because a server action may have happened.

## Screenshots

`-HogHunterServerConfirm` opens a Stop Process confirmation on the demo data.  It is an extra screen in `scripts/capture-app-screenshots.sh`, and those are best effort, so the five required format frames are unchanged.

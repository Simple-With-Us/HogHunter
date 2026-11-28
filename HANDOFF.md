# HANDOFF — HH-238 iPhone hosts overhaul (live status)

Update this file after every finished subtask.  Any model picking this up should trust git and this file over chat history, then verify with the commands at the bottom.

## Identity and places

- Seat: MC (Muse Code).  All fleet tools need `AGENT_SEAT=MC` in Bitrig shells, where it starts empty; the bearer-token route then works.  Remote writes also need the per-tool flags: `LINEAR_BOARD_WRITES=1 SIMPLE_BOARD_REMOTE=1 SIMPLE_BOARD_REMOTE_WRITES=1` for simple-board, `SIMPLE_CHAT_REMOTE=1 SIMPLE_CHAT_REMOTE_WRITES=1` for simple-chat, `SIMPLE_RECALL_REMOTE=1 SIMPLE_RECALL_REMOTE_WRITES=1` for recall contribute.  Board and chat writes take `--session 01a22076-d680-73c1-8d6d-657adea0253e` where accepted (chat post refuses it in remote mode; omit there).
- Lane: `/Users/jay/apps/lanes/HogHunter/muse-code-ios-hosts-overhaul` (physical: `/Volumes/External/Lanes/...`).  Branch: `muse-code/ios-hosts-overhaul`, pushed.  Never edit `/Users/jay/Code/HogHunter` (integration tree; the lane guard hook blocks writes there, including scratch files, so run shell work with the lane as workdir).
- Linear: HH-238, claimed by MC, In Progress.  OPS-1138 was a wrong-team stray from filing without `--app`; it is closed as duplicate of HH-238.  Do not reuse it.
- Zulip: #Work-In-Progress topic `HH-238 iPhone hosts overhaul`, claim message id 644320957.  The hosted post route prepends `[MC]` itself; do not add another header.
- PR: https://github.com/Simple-With-Us/HogHunter/pull/415 — `[MC] HH-238: Make iPhone Mac and Server peer tabs and add host-focused widgets`, base main.  MC precedent is the plain `[MC]` title form (verified against merged muse-code PRs).  Kody review NOT yet requested; request it only on the final head (comment line 1 `@kody start-review`, line 2 `[MC]`, then full head SHA and context) and triage every thread before merging.
- Bitrig: this session IS Bitrig on project folder `/Users/jay/Code/HogHunter` (branch main).  Bitrig cannot build the lane directly (`isn't inside a Bitrig project`), but `bitrig run <lane-built .app> -destination 'id=xcode-simulator/f94d3534-bb9a-4b9c-bc93-f701d0dc1337'` from the project folder launches lane builds on the owner's Bitrig iPhone simulator.  Already done once for commit 293c186.  After merge, the project folder needs a pull before `bitrig preview -platform iOS` shows merged code; pulls in that folder are the owner's or need hook approval.

## Done and verified

- Tabs overhaul in `ios/Sources/CompanionViews.swift`: TabView Overview/Mac/Server/Upkeep, `CompanionMacPane` segmented picker, Disk Cleaner moved from Storage to Upkeep as `upkeepCleanerContent`, screenshot flags remapped.  Committed as 293c186 together with widgets v1 and `docs/rollouts/2026-11-27-ios-hosts-overhaul.md`.
- Widgets v1 in `ios/Widgets/`: `AppIntentConfiguration` with Show = Mac and Server / Mac Only / Server Only (`HostFocus`, `SelectHostIntent`, `AppIntentTimelineProvider`), compact `CleanPill` replacing the hero buttons, `ServerWidgetView`, sample fixture gains server CPU/RAM.  Also in 293c186.
- Merged origin/main (through #414 JET HH-237 Mac work, zero iOS overlap, fast-forward).  Post-merge gate: iOS Simulator build green; Mac suite 1,424 passed, 0 failed (`** TEST SUCCEEDED **`).  The earlier `MaintainLayoutTests` width failure reproduced on the pre-merge base and disappeared after #414; it was never caused by this branch.
- Visual frames inspected directly (temporary simulators, since deleted): all four tabs; combined widgets at small/medium/large with the pill; Server-only large; Mac-only stack.  Frames live only under `/tmp/hh-widget-shots/` and `/tmp/hh-overview3.png` on this Mac and may not survive.

## Widget options round 2 (owner: "widgets should have more options") — DONE at 19f3904

All planned steps landed in 19f3904 except the two new-option captures.  BusyRank, WidgetTab, Show Clean Button, and Tap Opens are implemented end to end (intent, entry, provider, views, deep link, model tab request, dashboard consume, preview-host flags `-HogHunterWidgetRankMemory` and `-HogHunterWidgetNoClean`).  Targeted tests pass (CompanionDeepLinkTests, CompanionOverviewRankingTests) and the iOS build is green.  The memory-rank and no-Clean frames could not be captured: CoreSimulator lost its runtime list entirely under host load (Invalid runtime, empty `simctl list runtimes`).  Retry those two frames when the host calms down; the toggles themselves are thin conditionals over already-inspected layouts.

Still to do for HH-238, in order:

1. Push 19f3904 plus the docs commit that carries this update, refresh `pr-body.txt` for the new head (options round, post-merge green suite at 1,424 passed, capture gap for the two new toggles), and `gh pr edit 415 --body-file pr-body.txt`.
2. Request Kody on the final head: comment line 1 `@kody start-review`, line 2 `[MC]`, then the full head SHA and context.  Triage every finding (fix or dispute from the code) and resolve threads before merging; a new head needs a fresh request.
3. Wait for CI (Mac tests plus iOS Simulator build, plus the screenshot lane).  Squash merge with Bitrig's `gh` (the relay `gr_*` tools are not present in a Bitrig session; `gh` here is Bitrig-credentialed).  Never `--admin`.
4. Closeout: Linear HH-238 to completed, Zulip DONE post in the same topic then resolve it, retire the lane with `~/apps/lane retire ios-hosts-overhaul` from outside the lane, delete `commit-msg.txt`, `commit-msg2.txt`, and `pr-body.txt` from the lane root before retiring (untracked scratch from this session; retire refuses a dirty lane), and note in chat that the Bitrig project folder needs a pull for `bitrig preview`.  This file can be deleted in the closeout commit or left as the work record; the rollout doc is the durable summary either way.

## Next unit after HH-238 lands: Mac and server list from the owner

File as its own HH issue and lane.  Items, with what is already traced:

- "Fleet CLI not found" and "Fleet Listener not found" on the server: traced root cause in `scripts/server-status/supplement.py`.  `tool_statuses` marks a tool `absent` when `installed_command` fails, and that checks only the collector user's home (root) plus PATH, while the fleet CLIs live under the jay account.  `fleet-listener` also depends on `operator.service` or an `operator-listener` container match.  Fix by checking the fleet account's bin dirs too; verify against the host before claiming.  Deploy only by the documented `sudo install` path in AGENTS.md, never edit the deployed copy.
- Server maintenance settings appear unconfigurable because Modify Settings lives on the Mac Maintenance tab: check `ServerMaintenanceControl` consumers and `Sources/UI/SettingsView.swift` (SSH destination text at line ~741) against `VPSResourceCardView`; likely add a settings entry on the server surface or clarify the path.
- Root versus jay: the watch and control agent are root-owned by design (AGENTS.md server table: one writer, root-only log), while day-to-day work is jay with passwordless sudo.  Answer with that evidence; only change if the owner directs.
- Unused Docker images: check `hoghunter-maintain` strategies in `scripts/server-status/` (build cache has a strategy; image removal needs `acknowledgeImageRemoval` on the phone route) and the 4-hour cron runbook in Fleet Recall (`hoghunter-server-maintain`, pressure-gated).  Say when images actually get cleaned today before proposing a schedule.
- Storage tab arrangement, "This Mac" to "Mac" naming (careful: `HostScope.mac` rawValue "This Mac" is persisted via AppStorage; rename display only), subheading consistency between Mac and Server storage, container storage readability.
- Activity: CPU/RAM rank toggle for both hosts (Mac Activity already sorts; server processes come from `top_processes` in supplement.py, CPU-ordered), more server process actions toward Mac parity within `ServerControl` policy (quit, forceQuit, tame, untame, sample already exist on the phone route; check the Mac card), and matching the server Activity styling to the Mac's.
- Always show storage and RAM totals, not only used/remaining (Mac pulse text, server headline, and phone meters are the surfaces to audit).

## Commands that work here

- Build: `xcodegen generate` once per lane, then `xcodebuild -scheme HogHunterIOS -destination 'generic/platform=iOS Simulator' build` with no `-derivedDataPath` (DerivedData lands in `~/Library/Caches/HogHunterDerivedData` by design; see AGENTS.md on TCC prompts).
- Tests: `xcodebuild -scheme HogHunter -destination 'platform=macOS' test`.  Verdicts and failures: `xcrun xcresulttool get test-results summary --path <newest .xcresult under the cache Logs/Test>`.
- Board: reads need only `AGENT_SEAT=MC`; writes need the env block above.  `--app hoghunter` is required to file on the HH team, and `--by MC` is required for claim/comment but refused on file.
- Chat: hosted posts refuse `--session` and `--no-tag`; the server prepends `[MC]`.

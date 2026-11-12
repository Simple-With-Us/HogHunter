# External Drive Permission Loop

The owner reported drive-access prompts approximately every ten seconds despite granting access.  The installed app was stopped while repairing the polling paths.  TCC logs showed a Debug XCTest host registered with the production bundle identifier alongside the signed installed app; the test host was unregistered and reversibly retired.  This is evidence of conflicting identity resolution, not proof that it was the only trigger.

- Debug uses `com.simplewithus.hoghunter.macos.development` and the display name `Hog Hunter Dev`.  Release identity and the executable name remain stable.
- The ten-second process refresh no longer reads executable icons or asks LaunchServices for application paths.  Icons come from cached running-app metadata for local application roots; other processes use a generic icon.
- External capacity comes from the cached kernel mount table (`getfsstat`, `MNT_NOWAIT`) and Disk Arbitration BSD-device descriptions.  Discovery does not open mounted folders, enumerate their contents or request per-path resource values.
- XCTest and UI harness modes disable default directory and capacity probes.  UI harnesses also disable automatic storage, network and cleaner scans, the sampler, the updater and startup telemetry/configuration requests.  Injected directory and capacity fixtures remain testable.
- The shared run-mode detector accepts both XCTest class names, both XCTest environment markers, the XCTest launch flag and both UI harness flags.

The bundle identity is a build setting, not an Infisical runtime knob.  The full build and UI gates run on hosted CI; local verification uses small synthetic Swift fixtures and a view-only render.  A cheap metadata-only probe returned both attached storage pools without traversing them.  The signed release must be installed and observed separately before declaring the permission loop fixed in use.  No TCC database reset, privacy bypass or blanket Full Disk Access grant is part of this repair.

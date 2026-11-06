# Glance View In Two Columns

Refs HH-219.  The menu bar quick view (the glance view) was 360 points wide and stacked the Mac above the server in the RAM, storage and activity sections.  It is now 720 points wide, and every section puts the Mac on the left half and the server on the right half, the way CPU already did.

- **Width.**  `HogHunterPanel.panelWidth` is 720.  The height ceiling (`panelHeight`) is unchanged, and the scroll area still caps at 520.
- **RAM.**  `macRAMColumn` and `serverRAMColumn`.  A server that is set up but has no reading yet shows a dash and "Connecting to server…" or "No reading yet" on the right half.
- **Storage.**  `macStorageColumn` holds the internal disk, every mounted drive and the drive pager.  `serverStorageColumn` holds the root disk and `/mnt/fleet-extra`.
- **Top Activity.**  Both lists show at once, so the This Mac and Server toggle is gone.  Hovering either list opens both to six rows.  The server's process actions stay on the right half.
- **No server set up.**  The server column is left out and the Mac column takes the full width, as before.

Verified with `StorageGrowthLayoutTests.testQuickViewSplitsMacLeftAndServerRight`, which renders the panel with a server snapshot and checks the fixed width and the height ceiling.

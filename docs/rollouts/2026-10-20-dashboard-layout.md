# Dashboard And Menu Bar Quick View

The owner approved the independent UX recommendation in `proposal-comparison.html`.  Full activity and storage details now live in a resizable dashboard, while the menu bar shows a compact quick view with Mac health, External and Time Machine capacity, top activity and server freshness.

The dashboard opens on Overview with five homes: Overview, Activity, Storage, Maintenance and Network.  A per-user host scope carries between pages and between the quick view and dashboard; Settings remains in the gear menu.  The window starts at 900 by 700 points and can resize down to 860 by 580.  Overview groups three distinct storage pools, compact CPU history and memory, top activity and the server strip.  Activity gives process rows most of the space.  Storage keeps directory growth and its existing cleaner/report state together, and requires an explicit Scan before starting a cleaner walk.  Maintenance uses the existing shared store and its script/history controls.

Server scope uses the existing compact report and explicitly labels unavailable remote per-process CPU, memory and network coverage.  It never substitutes local process rows for remote data.  Directory and database daily changes retain the shared meaningful-only presentation.  No quit, force-quit, tame, cleaner confirmation, device consent or process identity safeguard changes.

Mounted-drive metadata is shared between dashboard and quick view.  Time Machine is identified by its explicit volume name; other names remain visible as external pools rather than being guessed as backups.  An unidentified or unavailable drive never becomes a zero-byte reading.

Validation includes rendered quick-view and initial Storage fixtures, a full Server report height bound at the default size, and native UI smoke captures at default, minimum and grown window sizes.  CI saves those captures with the existing screenshot artifact.  Local work used parsing, isolated SwiftUI typechecks and focused metadata fixtures; full compilation and rendered results are verified on hosted CI.  Release publication and installation are separate from source completion.

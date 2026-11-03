# Manual Server Maintenance Controls

Refs HH-203 and HH-206.

The server panel previously disabled Run Now when the scheduled remote step was off, although its helper copy suggested manual use.  Its confirmation and catalog copy also promised container, image and container-log pruning that the guarded backend does not do by default.

The panel now provides an explicit read-only Scan and a confirmed Run Now independent of the automatic setting.  Choices default to package cache, rotated backup logs and Docker build cache.  Old untagged Docker images remain off and need an additional rollback/redownload acknowledgement.  An immutable pending request holds the host, mode and selected strategies throughout confirmation; later settings changes cannot retarget that authorization.

Include in Mac Maintenance continues through the existing setStepEnabled/Infisical persistence path.  It controls this Mac’s maintenance schedule only; the server’s native schedule remains independent.  No scheduler, credential route, phone API or automatic deletion policy changes.

The new helper flag --manual permits scan, plan or run on a healthy root filesystem.  Scheduled mode refuses the flag.  Existing/default calls still skip before inventory on healthy disks, and actual runs still require confirmation.  All existing eligibility, identity, keep, local-builder, shared lock, audit and uncertain-dispatch checks remain.  A true manual result marker is additive; legacy consumers need no change.

The injected SSH executor constructs fixed arguments for the root helper, validates the host, caps stdout at 1 MiB and bounds the local SSH child by a monotonic deadline.  Test mode refuses the real transport.  Responses require the matching tool/schema/mode/manual marker, validated disk/count evidence, selected strategy identities and serialized mutation evidence.  Transport and backend diagnostics never become raw UI errors.

Results separate candidates, removed files, Docker requests, logical removed-file bytes and observed signed available-space changes.  Other server activity affects free blocks; neither attempted Docker IDs nor engine-labelled reclaimability prove physical savings.

## Verification And Delivery

Hermetic fixtures cover healthy automatic skipping, explicit manual scan/plan and confirmed runs inside a synthetic root, invalid selectors and scheduled opt-in refusal, retained lock/dispatch protection, immutable confirmation targets, transport failure redaction, structured result validation and concurrent request refusal, plus harmless owned local-child exit, output-cap, timeout, cancellation and explicit reap proof.  No test invokes SSH, Docker mutation or a real cleaner.  Interrupted SSH reports an unconfirmed remote outcome even when its local child exit is confirmed, because remote maintenance may continue under the server lock.

This change is source-only until independent review and explicit release of the new backend hash.  Existing c3, exact-ID guard and collector deployment receipts describe earlier frozen sources and remain unchanged.  Native client compilation and hosted required checks remain delivery gates.

The actual-source standalone SwiftPM fixture passed all 12 tests, including harmless local-child reap checks; all 43 maintenance Python cases passed.  Swift source parsing and diff checks passed.  Full app/native hosted checks and the configured inert panel render remain pending cumulative delivery gates.

## Terminal Result Coverage

Every valid terminal manual response accounts for each frozen selected strategy, including strategies not reached before cancellation, budget exhaustion, lock inspection failure or another early error.  Strategy inventory_complete is false until inventory returns completely; synthetic not-attempted rows have false with zero known candidates/actions, while completed inventories and real removal/attempt counters stay intact.  The sole empty manual exception is a skipped run with the fixed busy reason, unacquired lock without a release claim, no cancellation and zero work totals.  Automatic healthy skips keep their existing empty, no-inventory contract.

The client requires the full selected-ID set for all other terminal statuses and rejects wrong-typed or inconsistent inventory flags.  Eligibility is not inferred from legacy partial, failed or cancelled rows without the flag; the card displays eligibility not determined and still shows known removed files or cleanup attempts.  Legacy successful/planned known rows retain compatibility.  Raw backend reasons remain private to validation and never appear in the panel.  An internal injected-controller initializer supports inert render verification without changing the default transport or XCTest refusal.

This correction is source-only until independent review and separate backend release.  Deploy the corrected producer before relying on complete early-error coverage in the new client; an older incomplete response fails closed as unverified rather than hiding selected work.

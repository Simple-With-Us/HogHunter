# tmp-large-trees: surface large /private/tmp trees at every band (2026-11-24)

Jay's 2026-11-24 request to "continue to aggressively clean space ... and train hog hunter to do better job".  This change is the training half: it makes the app SEE the biggest waste class the engine was blind to, without deleting anything.

## What was measured

The Mac's disk showed 144 GB free -- a healthy band, so every pressure rule was correctly closed -- while `/private/tmp` held 27 GB, of which four trees with ordinary names (`mm-dd-p3s3`, `mm-dd-p3i2`, `mm-dd-p3s3m`, `mm-dd-p3m2`) totalled about 21 GB.  `tmp-build-trees` only names agent candidate and rebase checkouts, and the ask-first inventory does not walk `/private/tmp`, so none of that appeared anywhere in the app.  A person could not review it because the app could not see it.

## What changed

A new report-only rule, `tmp-large-trees`: every real directory directly under `/private/tmp` that holds at least 1 GiB is surfaced as an ask-first row at every disk level, with its size and the newest-write age in the reason, and a `.janitor-keep` marker surfaced with the row instead of hiding it.  Symlinks are never named, the walk respects the rule deadline, and the rule can never delete: it registers with `op: report`, so the report-rule invariants that keep ask-first rows undeletable apply to it wholesale.

## Why report only

HH-222 kept agent temp trees delete-free after two adversarial review rounds, and the 2026-11-04 narrowing was never used for automatic deletes.  The trees this rule surfaces are other seats' scratch by definition -- the measured ones carry another seat's prefix -- so the owner decides per tree, in the app, with the size and idleness on the row.  Jay's 2026-11-24 training request is the owner decision for the REPORT; a delete stays owner-gated.

## Tests

Three new tests: a big oddly-named tree is surfaced while a small one is not (report only, ask-first), a keep-marked tree is surfaced with the marker in its reason while a symlink is never named, and a spent rule deadline reports nothing further.  The suite passes in full, including the report-rule invariants.

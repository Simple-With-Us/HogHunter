# Storage Browser And Marketing Assets

The Drives & Folders browser now combines the existing boot-disk capacity sample with mounted physical external drives.  Previously it rendered only the external-drive store, so an internal disk never appeared in this list.  The boot disk remains visible with an unavailable status if capacity cannot be read; APFS root/Data aliases and duplicate external mount rows are collapsed.  Listing the internal drive does not start a filesystem traversal or broaden external-drive access.

The two original owner screenshots are retained, byte for byte, under `marketing/screenshots/macos/drafts/`.  The root screenshot-output ignore rule is anchored to `/screenshots/`, allowing curated marketing screenshots to be tracked.  These are candidates for future use; selecting assets for a campaign remains separate from preserving originals.

Validation: three actual-source drive-composition scenarios passed (internal only, unavailable capacity, duplicate/APFS aliases); Swift parsing and `git diff --check` passed.  Three XCTest regressions exercise the same cases through the app module in CI.  The original screenshot copies matched SHA-256 hashes and lengths before staging.

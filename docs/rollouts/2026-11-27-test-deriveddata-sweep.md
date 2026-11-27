# The App's Test-Build Cache Joins xcode-scratch (2026-11-27)

Owner direction, 2026-11-27: "aggressively clean hard disk space on mac and server and help hog hunter do better at keeping in check.  don't delete the one ios sim for xcode on mac".  The measured trigger: the app's own test-build cache -- xcodegen-post points this checkout's default DerivedData at `~/Library/Caches/HogHunterDerivedData` -- held 17 GB of repeated full-suite runs while the disk was at 23 GB free.

## The layout, measured

The cache is nested, not flat.  `scripts/xcodegen-post.sh` sets `DerivedDataCustomLocation` to a per-checkout base, `<cache>/<checkout-name>-<12 hex>` ("One folder per checkout, so lanes do not share products"), and a plain workspace build -- the AGENTS.md test command, which passes no `-derivedDataPath` -- appends Xcode's own `HogHunter-<24 hex>` below that.  The DerivedData root (`info.plist`, `Build/`, `Logs/`, `SourcePackages/`, the `.noindex` caches) therefore sits two levels under the cache folder, with ~92 MB of ever-refreshing module and SDK caches beside it in the base.  A build verified this on 2026-11-27; an earlier read that put the structure directly at the cache root had passed `-derivedDataPath` explicitly, which pins the root where it is told (that is what Release and CI do, and why they never land in this cache).  Two review rounds (Seer, Kody) caught both wrong readings before this one settled it.

## What changed

`xcode-scratch`'s roots list gains `~/Library/Caches/HogHunterDerivedData` as a `"test-cache"` root: for each checkout base the rule identifies the DerivedData root by the same shape (base itself, else exactly one root one level down), gates on the identified root (the base's refreshing caches would otherwise never read idle), and deletes the whole base only when everything beside the root is whitelisted build noise; a stray file at the base shrinks the delete to the root alone.  Same idle gate (3 h at heavy pressure, 24 h otherwise), same 60 GB delete line with df re-read, same recheck re-derived on the base.  Policy JSON and AGENTS.md name the layout.

## What deliberately did not change

The one iOS simulator and its runtime: `duplicate-sim-runtimes` targets runtime copies, not devices, and cannot fire above 25 GB free -- and no simulator is deleted in this change or needed to be.  `~/Library/Developer/Xcode/DerivedData` stays xcode-artifacts' job.  Active test builds are protected by the same idle gates as everywhere else: a cache in use never reads as idle, and a lane whose base holds anything but build noise keeps its base.

## Verification

Five tests: the nested base (root plus whitelisted noise) is reclaimed at the pressure line while the cache folder stays; source-shaped content inside the identified root refuses with nothing applied; a stray file at the base spares the base and still reclaims the root; a flat base (explicit `-derivedDataPath` shape) joins the sweep; and the roots list names the test cache with its mode.  The suite passes 275/275.

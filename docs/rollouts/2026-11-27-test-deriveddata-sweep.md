# The App's Test-Build Cache Joins xcode-scratch (2026-11-27)

Owner direction, 2026-11-27: "aggressively clean hard disk space on mac and server and help hog hunter do better at keeping in check.  don't delete the one ios sim for xcode on mac".  The measured trigger: the app's own test-build cache -- xcodegen-post points this checkout's default DerivedData at `~/Library/Caches/HogHunterDerivedData` -- held 17 GB of repeated full-suite runs while the disk was at 23 GB free.

## What changed

`xcode-scratch`'s roots list gains `~/Library/Caches/HogHunterDerivedData`: same positive identification (small `info.plist` naming a WorkspacePath, `Build/` holding only Products and Intermediates.noindex, `Logs/` or `Index.noindex/` beside it, no links at the top, home volume, no repository but a clean SwiftPM clone), same idle gate (3 h at heavy pressure, 24 h otherwise), same 60 GB delete line with df re-read, same recheck.  Policy JSON and AGENTS.md now name the location.

## What deliberately did not change

The one iOS simulator and its runtime: `duplicate-sim-runtimes` targets runtime copies, not devices, and cannot fire above 25 GB free -- and no simulator is deleted in this change or needed to be.  `~/Library/Developer/Xcode/DerivedData` stays `xcode-artifacts' job.  Active test builds are protected by the same idle gates as everywhere else: a cache in use never reads as idle.

## Verification

Three new tests: an Xcode-shaped idle root under the cache is reclaimed at the pressure line while the cache root itself stays; content that looks like source under the cache keeps the root with nothing applied; and the roots list names the test cache.  The suite passes 273/273.

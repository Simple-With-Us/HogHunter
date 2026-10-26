# Version scheme: one number, and it is the version (2026-10-26)

Owner ruling 2026-10-26, HH-191.  Ship tooling and the committed record only:  no app source, no workflow change to a ship path.

## The rule

**One number, and it is a version string.**  `MARKETING_VERSION` (CFBundleShortVersionString) and `CURRENT_PROJECT_VERSION` (CFBundleVersion) carry the **same string**:

```
MARKING_VERSION: "0.1.1"
CURRENT_PROJECT_VERSION: "0.1.1"
```

App Store Connect shows `0.1.1 (0.1.1)`:  one number, written twice, because Apple always shows the build number in parentheses.  There is no second number anywhere:  the repository commit count is retired, every timestamp is retired, and no bare integer sits beside the version.

**The train.**  `<major>.<minor>` is the train the app's numbers live on:

| App | Train | Why |
|---|---|---|
| Hog Hunter | `0.1` | not on the App Store, so its numbers start fresh at `0.1.0` |
| the other apps not on the App Store | `0.1` | same |
| Congress.Trade | `1.1` | on the App Store, and its past numbers already used the `1.0` train, so it has to move up:  `1.1.2` |

**The number.**  It is one past what the train already holds, so a number is never reused.  The train holds:

- the **committed record** (`project.yml` `MARKETING_VERSION`):  the version the last update shipped;
- the **App Store Connect state** (the iOS path only):  the highest patch already used on that train, counting the App Store versions *and* the TestFlight trains, ignoring the retired `1.0.N (N)` drift trains.

Hog Hunter's numbers right now:  `0.1.0` shipped, `0.1.1` next.

## What it replaces

- `docs/rollouts/2026-10-24-version-scheme.md` (2026-10-24, AFC-517):  the scheme where the marketing version and the build number were **independent** numbers.  That scheme is what produced `1.0.237 (2360)`:  the pair read as two numbers.
- the `1.0.<commit_count>` scheme unified in #2801 on 2026-10-18:  the build number was the repository commit count and the marketing version was `1.0.<commit_count>`, so the pair read `1.0.2358 (2358)`.
- every timestamp fallback:  a checkout with no readable git history now **fails loudly** instead of inventing a number.

## Where it lives

| Piece | What it is |
|---|---|
| `scripts/ios-fleet/version-plan.mjs` | the rules as pure functions (no I/O, no network, no environment), with `scripts/ios-fleet/version-plan.test.mjs` as its unit suite |
| `scripts/ios-fleet/version-number.mjs` | the I/O around them:  reads and writes the committed record in `project.yml`, and refuses a checkout with no readable git history |
| `scripts/ios-fleet/version-number.sh` | the thin entry point both ship paths call |
| `project.yml` | the committed record:  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, the same string, on the Mac app, the iPhone app and the widget |
| `scripts/ios-fleet/apps.json` | the app's train (`marketingVersionDefault`); the record wins, and the ship script says so when the two disagree |

## How the two platforms stay in step

Both ship paths read the **same committed record**, so they come out with the same number for one update:

- the **Mac path** (`scripts/install.sh`) has no App Store Connect access:  it takes the number **one past the record**, and writes the record back after a successful install, so the next update takes the next number.
- the **iOS path** (`scripts/ios-fleet/ship-testflight.sh`) takes the **recorded** number when that number is ahead of everything the train holds and its own train holds no build (that is how it picks up the number the Mac path already chose), and otherwise the number one past what the train holds.

The iOS ship log says which one it is:

```
[ios-ship] version plan: record=0.1.0 asc_patch=0 -> version=0.1.1; train builds=0 -> build=0.1.1 (one number)
[ios-ship] agreement: the Mac app takes the next number from the committed record (0.1.0), which is this one
```

### Where the Mac path can be behind

The Mac path cannot see App Store Connect, so when **App Store Connect already holds the next patch** the two paths take different numbers:  the iOS path takes the higher one (it must not reuse a number), and the Mac path is one behind until the record catches up.  The ship log says so:

```
[ios-ship] NOTICE: the committed record is 0.1.0 and this ship carries 0.1.5.
[ios-ship] NOTICE: App Store Connect already holds a higher patch on the 0.1 train, so the Mac app
[ios-ship] NOTICE: (which reads the record only) would take a lower number.
```

That is the one place where "one number across platforms" can fail, and it is visible rather than silent:  update the record in `project.yml` to the shipped number and commit it.

## The release flow

```bash
# The Mac app:  resolves the next number, builds and installs it, and records
# it in project.yml.  Commit project.yml afterwards.
scripts/install.sh

# The iPhone app:  merge to main and let the ship workflow run, or dispatch
# .github/workflows/ios-testflight.yml.  It reads the same record.
```

Both carry the same number for one update.  If the iPhone app ships first and App Store Connect is ahead of the record, the iOS number is the higher one and the Mac app follows it after the record is updated.

## Tests

- `node --test scripts/ios-fleet/version-plan.test.mjs` (the pure rules)
- `node --test scripts/ios-fleet/version-number.test.mjs` (the committed record, the write-back, and the proof that the Mac path and the iOS path take the same number from the same record)

Both run in CI (`.github/workflows/ci.yml`, the `release-safety` job).  Neither touches the network or a credential.

## Risks the owner has to look at

- **Sparkle and the first `0.1.x` build.**  The Mac app's build numbers were commit counts (`152`, `2360`, ...) and are now `0.1.x`.  Sparkle only offers a build whose `CFBundleVersion` is **higher** than the installed one, so the first `0.1.x` release will not appear as an in-app update to a machine still on the old numbering:  it has to be installed once by hand.
- **App Store Connect and the new train.**  The iPhone app moves from the `1.0` train to `0.1`.  Apple requires the build number to increase *inside* a version, and the `0.1` train is empty, so `0.1.1` is fine inside it; whether Apple accepts a build number lower than a previous *train's* build is worth watching on the first upload.
- **`scripts/mac-release-build.sh`** (the notarised Sparkle release path) still derives its build number from the commit count and writes `1.0.<commit_count> (<commit_count>)`.  It was outside this change's scope; it needs the same one-number rule before the next notarised release.

## Not touched

`.github/workflows/ios-testflight.yml` still carries the old scheme in its header comment.  Editing a ship workflow can trigger a real ship, so that wording change belongs in its own deliberate change.  The workflow itself needs no change: the ship script owns the version, exactly as before.

# The housekeeper owner record is one protocol (2026-10-28)

**2026-10-28 · seat MM · board: not filed (the board writes refuse for this seat, see "Still open") · refs AFC-554 (`ea7d7b29`)**

## What was wrong

The housekeeper lock at `~/.claude-disk-janitor/.housekeeper.lock` is shared by four programs: Hog Hunter's Python vacuum (`scripts/vacuum/lock.py`), Hog Hunter's Swift lock (`Sources/Storage/HousekeeperLock.swift`), and AFC's `mac-auto-cleanup.sh` and `mac-resource-watch.py`.  All four write an *owner file* beside the lock directory, and all four read it back to answer one question: is the holder still there?

AFC PR #980 made AFC's two readers enforce ONE strict schema.  The record must have exactly `{pid, host, acquired_at, lock, start}`, every value must be the right type and inside its bounds, the record must be strictly newer than the lock directory it sits beside, and `start` must carry the start time of the holder's process so that a pid the kernel has since handed to somebody else cannot pass for a live holder.

Hog Hunter's two writers still published the old shape.  The Python writer published `{pid, host, acquired_at, lock}` and the Swift writer published `{pid, acquired_at, lock, host?}`.  Neither carried `start`.

So the fleet had one protocol in the readers and two in the writers, and the strict side was the reader side.  A Hog Hunter holder's record was refused outright by AFC's readers, and the answer both of them fall back to is the 120-minute age rule.  A Hog Hunter holder that died was not recovered until the stale window expired.

Measured against the **deployed** AFC reader on this Mac, with a record written by Hog Hunter's own writer:

| Record | The deployed AFC reader | What it meant |
|---|---|---|
| Hog Hunter's old shape | exit 1 — not proven gone | fall back to the 120-minute age rule |
| the same record plus `start` | exit 1 — not proven gone | the holder was alive, so this is the same answer for the right reason |

The direction is safe: no live holder is ever displaced, because a strict reader refuses a record it cannot read rather than believing it.  The cost was liveness only, and it was AFC's PR #980 that introduced it.

## The protocol

One record shape, four implementations:

```
{"pid": 1234, "host": "Mac.Jays.Services", "acquired_at": 1793233478.77,
 "lock": "/Users/jay/.claude-disk-janitor/.housekeeper.lock",
 "start": "Wed Oct 28 19:33:47 2026"}
```

- The key set is exact.  A missing key and an unknown key are the same failure: the record is not the record this protocol publishes.
- Every value is checked for its type and its bounds.  A boolean pid is refused, because `isinstance(True, int)` is true in Python and JSON `true` bridges to `NSNumber` in Swift.
- `start` is an OPAQUE string.  It is compared and never parsed, and it is bounded at 128 characters only so a hostile file cannot put an unbounded string in memory.
- The token comes from one command in one locale: `LC_ALL=C ps -o lstart= -p <pid>`.
- The environment that command runs in is PATH and LC_ALL alone.  This is load-bearing, not tidiness: `ps` renders the start time in the caller's zone, so a TZ in the environment renders the SAME process with a DIFFERENT token.  Measured on this Mac:

| Environment | The token for one pid |
|---|---|
| PATH + LC_ALL only | `Wed Oct 28 19:33:47 2026` |
| the same, with TZ=UTC | `Thu Oct 29 00:33:47 2026` |
| the same, with TZ=America/Los_Angeles | `Wed Oct 28 17:33:47 2026` |

A Swift reader that passed its whole environment along would have disagreed with the Python reader about a live process, and that disagreement reads as "the holder is gone".

The readers agree on the answer:

- a dead pid proves the holder is gone;
- a live pid whose start token DIFFERS from the recorded one proves the holder is gone, because the kernel handed the number to somebody else;
- a live pid whose start token MATCHES is the holder;
- a start token that cannot be read is no evidence at all, and the age rule decides.

On the file itself, one more rule has to be shared: the owner file must be STRICTLY newer than the lock directory beside it, because a holder that never wrote an owner file leaves a leftover beside a fresh lock.  Hog Hunter's two readers compared with `>=` where AFC's two compare with `>`;  they now compare the same way.

And one rule about the removal, which AFC's readers already state and Hog Hunter's two did not: a file that cannot be READ AS AN OWNER RECORD is left alone.  A holder that cannot read the file cannot know whose it is, and deleting it would take away the identity of whoever really holds the lock now.  Hog Hunter's Python side used to delete a file that "named no readable pid", which was safe while every readable record was well formed, and stops being safe the moment an old-shaped record is on disk.

## What changed

**`scripts/vacuum/lock.py`**

- `_parse_owner` is new and is the only way a record is read.  It enforces the exact key set, the type and bound of every value, and it never raises.  `_read_owner` is now a thin wrapper over it.
- `_process_start_token` derives the token, with the minimal environment the protocol requires.
- `_owner_is_gone` is new: it is the one place that answers "is the holder gone", and it is the answer a dead pid, a reused pid and an unreadable token each get.
- `_write_owner` publishes the five keys, writes the file 0600, and writes NOTHING at all when the token cannot be read, because a record without a token cannot tell the holder from a reused pid.
- `_owner_describes_holder` requires the owner file to be strictly newer than the lock directory.
- `_clear_owner` leaves a file it cannot read alone.

**`Sources/Storage/HousekeeperLock.swift`**

- `OwnerRecord` and `ownerRecord()` are new, and mirror the Python parser: the same key set, the same type checks, the same bounds.  `ownerPid()` reads through it, so a malformed record names nobody.
- `processStartToken(_:)` runs the same command with the same minimal environment.  `currentHostName()` uses `gethostname` rather than `ProcessInfo.processInfo.hostName`, because the Python side reads `socket.gethostname()`, which is that very call, so the two are byte-identical by construction rather than by luck.
- `ownerIsGone(_:)` is the static counterpart of the Python helper, and `isOwnerGone` uses it.
- `writeOwnerFile` publishes the five keys, always names the host, writes the file 0600, and writes nothing when the token cannot be read.
- `ownerDescribesHolder` requires the owner file to be strictly newer than the lock directory.
- `removeOwnerFile` leaves a file it cannot read alone.

**Tests**

- The Python cases that wrote a bare `{"pid": ...}` now write a well formed record.  Those cases were passing without testing what they claimed to test, because a record the readers refuse is no evidence of anything.
- New cases on both sides: the published record has exactly the five keys, it carries this process's own start token, it is private to the user, a reused pid is taken over at once, a live holder with the right start token is refused, a record without the start time is not evidence, a record with an unknown key is not evidence, and a record with a boolean pid is not evidence.

## Measured

The cross-implementation check ran the **deployed** AFC reader, extracted verbatim from `/Users/jay/apps/mac-auto-cleanup.sh`, against records written by Hog Hunter's own writer:

| Check | Result |
|---|---|
| BEFORE: the deployed AFC reader refuses a four-key Hog Hunter record | ok |
| AFTER: the record Hog Hunter publishes has five keys | ok |
| AFTER: the deployed AFC reader ACCEPTS a Hog Hunter record | ok |
| AFTER: the deployed AFC reader proves a reused pid gone | ok |
| AFTER: the deployed AFC reader proves a dead pid gone | ok |

## Verify

```bash
# The Python side: the whole suite.
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-robotic-vacuum.py     # 389 tests, OK

# The Swift side is compiled and run by CI on macos-26.
# .github/workflows/ci.yml -> the `test` job: xcodegen generate, build, test.
```

The Swift change was type-checked locally with `swiftc -typecheck` against the macOS 14.0 SDK, with the XCTest framework on the search path, over `Sources/Storage/HousekeeperLock.swift` and `Tests/HogHunterTests/HousekeeperLockTests.swift` together.  That is a type check only: the compiler that runs the tests is CI's.

## Still open

- The board writes refuse for this seat ("no bearer-verified seat: the write verbs refuse"), so there is no Linear row for this work and none could be filed.  AFC's side of it is AFC-554 (`ea7d7b29`).
- The installed copy of the Mac app still writes the old shape until it is rebuilt and released, and an old-shaped record is not evidence to any of the four readers.  That costs liveness only, and it is the state the fleet was already in.
- The shared protocol now has four implementations that must agree.  AFC's own drift guard compares its two readers;  nothing compares Hog Hunter's two against AFC's two, so the agreement is asserted by the tests on each side and by the cross-implementation check above, not enforced by a single tool.

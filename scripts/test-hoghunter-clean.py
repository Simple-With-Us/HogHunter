#!/usr/bin/env python3
"""Regression tests for the Hog Hunter reclaim engine.

Deliberately narrow: these cover the pure functions that can fail SILENTLY.
A reclaim engine that no-ops and reports success is worse than one that is
down, because the operator believes disk was handled.

Run:  python3 scripts/test-hoghunter-clean.py
"""
from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import types
from pathlib import Path
from unittest import mock

ENGINE = Path(__file__).resolve().parent / "hoghunter-clean"


def load_engine():
    loader = importlib.machinery.SourceFileLoader("hoghunter_clean", str(ENGINE))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    # @dataclass resolves annotations via sys.modules[cls.__module__], so the
    # module must be registered BEFORE exec.  Skipping this raises
    # AttributeError: 'NoneType' object has no attribute '__dict__'.
    sys.modules[spec.name] = mod
    loader.exec_module(mod)          # __main__ guard keeps this from running
    return mod


def test_snapshot_timestamp(hh):
    """tmutil wants a bare stamp, not the full snapshot name.

    Regression: passing the full name made tmutil exit 22 with "is not a valid
    disk", so the whole snapshot/SHRINK tier no-opped.  Found 2026-09-30 at
    17G free with two prunable snapshots present.
    """
    cases = {
        "com.apple.TimeMachine.2026-09-30-045412.local": "2026-09-30-045412",
        "com.apple.TimeMachine.2026-09-30-200105.local": "2026-09-30-200105",
        "com.apple.backup.2026-09-30-123456.local":     "2026-09-30-123456",
        # Already-bare input must pass through unchanged (idempotent).
        "2026-09-30-145514":                            "2026-09-30-145514",
    }
    for given, want in cases.items():
        got = hh.snapshot_timestamp(given)
        assert got == want, f"{given!r} -> {got!r}, want {want!r}"
        # A derived stamp must never still carry the prefix or suffix --
        # that is the exact condition that produced exit 22.
        assert not got.startswith("com.apple."), got
        assert not got.endswith(".local"), got


def test_snapshot_derivation_is_lossless(hh):
    """Every real snapshot name must reduce to a non-empty stamp.

    An empty or whitespace stamp would be handed to tmutil as an argument and
    either delete nothing or, worse, target the wrong thing.
    """
    for name in ("com.apple.TimeMachine.2026-01-02-030405.local",
                 "com.apple.backup.2026-12-31-235959.local"):
        stamp = hh.snapshot_timestamp(name)
        assert stamp.strip() == stamp and stamp, f"bad stamp {stamp!r} from {name!r}"
        assert len(stamp) == len("2026-01-02-030405"), stamp


def test_find_output_keeps_a_newline_inside_a_path(hh):
    """find -print0 must not split a path that contains a newline.

    A newline-split path would truncate or delete the wrong file.
    """
    raw = b"/tmp/plain.log\0/tmp/has\nnewline.log\0"
    assert hh.split_find_output(raw) == ["/tmp/plain.log", "/tmp/has\nnewline.log"]
    assert hh.split_find_output(b"") == []
    assert hh.split_find_output(b"\0\0") == []


def test_report_path_stays_on_one_line(hh):
    shown = hh.report_path("/tmp/has\nnewline.log")
    assert shown == "/tmp/has\\nnewline.log"
    assert "\n" not in shown
    assert "\x1b" not in hh.report_path("/tmp/\x1b[2Jcleared")
    assert "\n" not in hh.report_path("oops\npath")
    # Printable non-ASCII must not crash the report or get mangled.
    assert hh.report_path("/tmp/caf\u00e9.log") == "/tmp/caf\u00e9.log"
    assert hh.report_path("/tmp/\u65e5\u672c\u8a9e.log") == "/tmp/\u65e5\u672c\u8a9e.log"
    # Lone surrogates from os.fsdecode become visible \udcXX text, not a crash.
    assert "\\udc80" in hh.report_path("/tmp/\udc80odd.log")


def test_log_scan_skips_repo_trees(hh):
    """~/Code and ~/apps hold source checkouts, not rotatable daemon logs."""
    roots = {p.resolve() for p in hh.log_scan_roots()}
    assert (hh.HOME / "Code").resolve() not in roots
    assert (hh.HOME / "apps").resolve() not in roots
    assert (hh.HOME / "Library/Logs").resolve() in roots


def test_disk_bands(hh):
    """Band thresholds are what decide whether the semi-safe and expensive tiers
    open at all, so they are pinned here instead of left to drift with a
    refactor.  Asserted relative to the module constants so a deliberate
    retune does not need a test edit, but a boundary that is off by one still
    fails."""
    c, a, h = hh.DISK_CRITICAL_GB, hh.DISK_ACUTE_GB, hh.DISK_HEALTHY_GB
    assert c < a < h, f"bands out of order: critical={c} acute={a} healthy={h}"
    cases = [
        (h + 10, "healthy"), (h - 0.1, "ok"),
        (a - 0.1, "acute"),  (c - 0.1, "critical"),
        (c / 2, "critical"), (0, "critical"),
    ]
    for free, want in cases:
        b = hh.Band(disk_free_gb=free, disk_used_pct=0, swap_used_pct=0,
                    load1=0, cheap_only=False)
        assert b.disk_band == want, f"{free}G -> {b.disk_band}, want {want}"


# --------------------------------------------------------------------------
# Pacing, budget, and fail-closed probes (Oct 9 2026, issue #111)
#
# A full read-only scan of this Mac takes about 22 s.  The 900 s timeout was
# the apply loop: 1,710 tiny Codex marker files, chunks of 1 to 3, and a 5 to
# 20 s sleep plus a host re-read after every chunk.  These tests pin the cure.
# --------------------------------------------------------------------------

class FakeClock:
    """A clock that only moves when the code under test sleeps or does work."""

    def __init__(self):
        self.now = 1000.0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


@contextlib.contextmanager
def fake_time(hh, clock):
    """Swap the engine's `time` name for the fake clock, never the real module."""
    real = hh.time
    hh.time = types.SimpleNamespace(
        monotonic=clock.monotonic, sleep=clock.sleep, time=real.time, strftime=real.strftime,
    )
    try:
        yield
    finally:
        hh.time = real
        hh.set_budget(0)


def marker(hh, i, size=2048):
    return hh.Candidate(category="temp-scratch", path=f"/t/.com.openai.codex.{i:04d}", bytes=size,
                        reason="Codex per-run marker file (auto-rotated by Codex)")


def heavy(hh, i, size=64 * 1024 * 1024):
    return hh.Candidate(category="dev-caches", path=f"/c/cache{i}", bytes=size, reason="cache")


def test_plan_chunks_follows_weight_not_file_count(hh):
    """1,710 tiny markers were 570 chunks of 3 with a sleep after each.  A chunk is a slot of work, so they
    are 3 chunks.  Heavy items still take a slot each, three to a chunk."""
    light = [marker(hh, i) for i in range(1710)]
    chunks = hh.plan_chunks(light, 3)
    assert [len(c) for c in chunks] == [600, 600, 510], [len(c) for c in chunks]
    assert hh.plan_chunks(light, 1)[0].__len__() == hh.LIGHT_PER_SLOT
    assert len(hh.plan_chunks(light, 1)) == 9
    big = [heavy(hh, i) for i in range(7)]
    assert [len(c) for c in hh.plan_chunks(big, 3)] == [3, 3, 1]
    snap = hh.Candidate(category="snapshots", path="apfs-snapshot:x", bytes=0, reason="s",
                        tier="semi-safe", op="snapshot-delete")
    assert not hh.is_light(snap), "a snapshot delete is never light"
    assert hh.plan_chunks([], 3) == []


def test_plan_chunks_keeps_every_candidate_once_in_order(hh):
    mixed = []
    for i in range(10):
        mixed.append(heavy(hh, i))
        mixed.extend(marker(hh, 100 * i + j) for j in range(70))
    chunks = hh.plan_chunks(mixed, 2)
    flat = [c for chunk in chunks for c in chunk]
    assert [c.path for c in flat] == [c.path for c in mixed]
    for chunk in chunks:
        weight = sum(1 if hh.is_light(c) else hh.LIGHT_PER_SLOT for c in chunk)
        assert weight <= 2 * hh.LIGHT_PER_SLOT or len(chunk) == 1, weight


def test_apply_order_puts_snapshots_then_the_biggest_first(hh):
    snap = hh.Candidate(category="snapshots", path="apfs-snapshot:x", bytes=0, reason="s",
                        tier="semi-safe", op="snapshot-delete")
    items = [marker(hh, 1), heavy(hh, 1, 10 * 1024 * 1024), snap, heavy(hh, 2, 900 * 1024 * 1024)]
    ordered = sorted(items, key=hh.apply_order)
    assert ordered[0] is snap
    assert [c.bytes for c in ordered[1:]] == sorted((c.bytes for c in items[:2] + items[3:]), reverse=True)


def test_budget_is_unlimited_without_the_flag_and_counts_down_with_it(hh):
    clock = FakeClock()
    with fake_time(hh, clock):
        hh.set_budget(0)
        assert hh.budget_left() == float("inf")
        hh.set_budget(100)
        assert hh.budget_left() == 100
        clock.now += 40
        assert hh.budget_left() == 60
        clock.now += 500
        assert hh.budget_left() == 0, "the budget never goes negative"
    assert hh.budget_left() == float("inf"), "fake_time leaves no budget behind"


def run_main(hh, argv, cands, band, clock, apply_cost=0.0):
    """Run main() against a canned scan.  apply_candidate marks the candidate applied and costs apply_cost
    seconds of fake time.  Returns (exit code, parsed JSON, stderr text)."""
    def fake_apply(c):
        clock.now += apply_cost
        c.applied = True

    out, err = io.StringIO(), io.StringIO()
    with fake_time(hh, clock), \
            mock.patch.object(hh, "scan", return_value=cands), \
            mock.patch.object(hh, "read_band", return_value=band), \
            mock.patch.object(hh, "apply_candidate", side_effect=fake_apply), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = hh.main(argv)
    return code, json.loads(out.getvalue()), err.getvalue()


def calm_band(hh, chunk_size=3, pause=5.0):
    return hh.Band(disk_free_gb=12.0, disk_used_pct=98, swap_used_pct=10, load1=20, cheap_only=False,
                   cpu_idle_pct=40.0, chunk_size=chunk_size, chunk_pause_sec=pause)


def test_the_marker_sweep_finishes_in_a_handful_of_pauses(hh):
    """The regression itself: 1,710 markers on a thrashing host (chunk 1, pause 20 s) used to need 1,709
    sleeps, 9.5 hours.  Now it is 9 chunks and 8 pauses, 160 s, well inside one budget."""
    clock = FakeClock()
    cands = [marker(hh, i) for i in range(1710)]
    band = calm_band(hh, chunk_size=1, pause=20.0)
    code, report, _err = run_main(hh, ["--clean", "--json", "--budget-sec=600"], cands, band, clock)
    assert code == 0
    assert len(clock.sleeps) == 8, clock.sleeps
    assert sum(clock.sleeps) == 160, sum(clock.sleeps)
    assert report["applied_count"] == 1710 and report["actionable_count"] == 1710
    assert report["budget_exhausted"] is False and report["remaining_count"] == 0
    assert report["applied_bytes"] == 1710 * 2048
    assert report["failed_count"] == 0


def test_a_spent_budget_stops_new_work_and_says_what_is_left(hh):
    """Budget 100 s, each heavy item costs 30 s: three fit, the fourth never starts.  The run exits 0, says it
    stopped, and counts the rest, so the caller reports a partial run instead of killing the process."""
    clock = FakeClock()
    cands = [heavy(hh, i) for i in range(10)]
    band = calm_band(hh, chunk_size=1, pause=5.0)
    code, report, err = run_main(hh, ["--clean", "--json", "--budget-sec=100"], cands, band, clock, apply_cost=30.0)
    assert code == 0
    assert report["budget_exhausted"] is True
    assert 1 <= report["applied_count"] < 10
    assert report["remaining_count"] == 10 - report["applied_count"], report
    assert "left for the next run" in err
    assert clock.now - 1000.0 <= 100.0 + 30.0, "overshoots by at most one item, never by a whole queue"
    assert all(s <= 5.0 for s in clock.sleeps)


def test_a_pause_never_sleeps_past_the_budget(hh):
    clock = FakeClock()
    cands = [heavy(hh, i) for i in range(3)]
    band = calm_band(hh, chunk_size=1, pause=50.0)
    _code, report, _err = run_main(hh, ["--clean", "--json", "--budget-sec=20"], cands, band, clock, apply_cost=15.0)
    assert all(s <= 20 for s in clock.sleeps), clock.sleeps
    assert report["budget_exhausted"] is True


def test_no_budget_flag_applies_everything_as_before(hh):
    clock = FakeClock()
    cands = [heavy(hh, i) for i in range(4)]
    band = calm_band(hh, chunk_size=3, pause=5.0)
    code, report, _err = run_main(hh, ["--clean", "--json"], cands, band, clock, apply_cost=500.0)
    assert code == 0
    assert report["applied_count"] == 4 and report["budget_exhausted"] is False
    assert report["applied_mib"] == 256.0


def test_a_scan_reports_the_new_keys_without_applying_anything(hh):
    clock = FakeClock()
    cands = [heavy(hh, 1)]
    code, report, _err = run_main(hh, ["--scan", "--json", "--budget-sec=50"], cands, calm_band(hh), clock)
    assert code == 0
    assert report["applied_count"] == 0 and report["remaining_count"] == 0
    assert report["mode"] == "scan"
    assert {"applied_bytes", "failed_count", "actionable_count", "budget_exhausted", "elapsed_sec"} <= set(report)


def test_the_old_json_keys_are_still_there(hh):
    """The Robotic Vacuum of an older checkout, and scripts/hoghunter-mcp.py, read these."""
    clock = FakeClock()
    _code, report, _err = run_main(hh, ["--clean", "--json"], [heavy(hh, 1)], calm_band(hh), clock)
    assert {"version", "band", "mode", "tiers_applied", "candidates", "reclaimable_mib", "applied_mib"} <= set(report)


def test_apply_delete_cannot_outlive_the_budget(hh):
    """find -depth -delete had a fixed 600 s timeout, so one big tree could run ten minutes past the budget."""
    clock = FakeClock()
    work = Path(tempfile.mkdtemp(prefix="hhclean-test-"))
    try:
        victim = work / "tree"
        (victim / "a").mkdir(parents=True)
        (victim / "a" / "f").write_text("x")
        seen = []

        def fake_run(cmd, **kw):
            seen.append(kw.get("timeout"))
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with fake_time(hh, clock), mock.patch.object(hh.subprocess, "run", side_effect=fake_run):
            hh.set_budget(0)
            hh.apply_delete(str(victim))
            hh.set_budget(30)
            clock.now += 10
            hh.apply_delete(str(victim))
            clock.now += 19.5
            hh.apply_delete(str(victim))
        assert seen[0] == 600.0, seen
        assert seen[1] == 20.0, seen
        assert seen[2] == 5.0, "a floor, so a nearly spent budget still gives find a moment"
    finally:
        shutil.rmtree(work, ignore_errors=True)


def test_apply_delete_trusts_the_size_the_scan_measured(hh):
    work = Path(tempfile.mkdtemp(prefix="hhclean-test-"))
    try:
        f = work / "f.bin"
        f.write_bytes(b"x" * 10)
        with mock.patch.object(hh, "dir_bytes", side_effect=AssertionError("walked the tree twice")):
            freed, err = hh.apply_delete(str(f), known_bytes=4096)
        assert (freed, err) == (4096, ""), (freed, err)
        assert not f.exists()
    finally:
        shutil.rmtree(work, ignore_errors=True)


def completed(code, out=""):
    return subprocess.CompletedProcess([], code, out, "")


def test_proc_count_fails_closed(hh):
    """pgrep that times out is not 'nothing is building'.  Every caller reads a non-zero count as busy."""
    with mock.patch.object(hh.subprocess, "run", side_effect=subprocess.TimeoutExpired("pgrep", 15)):
        assert hh.proc_count("xcodebuild") == hh.PROBE_FAILED
    with mock.patch.object(hh.subprocess, "run", side_effect=OSError("no pgrep")):
        assert hh.proc_count("xcodebuild") == hh.PROBE_FAILED
    with mock.patch.object(hh.subprocess, "run", return_value=completed(2)):
        assert hh.proc_count("(") == hh.PROBE_FAILED, "a pgrep usage error is a failed look"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(1)):
        assert hh.proc_count("xcodebuild") == 0, "exit 1 is pgrep's honest 'no match'"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, "101\n202\n")):
        assert hh.proc_count("xcodebuild") == 2
    assert hh.PROBE_FAILED > 20, "also over the 'node and tsc are building' threshold"


def test_a_failed_pgrep_stops_the_dev_cache_rule(hh):
    """The visible effect: with pgrep unavailable the dev-cache rule offers nothing, instead of offering a cache
    that a build may be using.  The control case proves the fixture would be offered when pgrep says all clear."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cache = home / "Library/Caches/node-gyp"
        cache.mkdir(parents=True)
        big = cache / "headers.tar"
        with big.open("wb") as fh:
            fh.truncate(9 * 1024 * 1024)
        old = hh.time.time() - 5 * 3600
        os.utime(big, (old, old))
        os.utime(cache, (old, old))
        with mock.patch.object(hh, "HOME", home), mock.patch.object(hh, "open_handles", return_value=0):
            with mock.patch.object(hh.subprocess, "run", return_value=completed(1)):
                offered = hh.rule_dev_caches()
            assert [c.path for c in offered] == [str(cache)], offered
            with mock.patch.object(hh.subprocess, "run", side_effect=subprocess.TimeoutExpired("pgrep", 15)):
                assert hh.rule_dev_caches() == []
                assert hh.rule_xcode_artifacts() == []
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_open_handles_fails_closed(hh):
    with mock.patch.object(hh.subprocess, "run", side_effect=subprocess.TimeoutExpired("lsof", 25)):
        assert hh.open_handles("/x") == 1
    with mock.patch.object(hh.subprocess, "run", side_effect=OSError("no lsof")):
        assert hh.open_handles("/x") == 1
    with mock.patch.object(hh.subprocess, "run", return_value=completed(1, "")):
        assert hh.open_handles("/x") == 0, "lsof exits 1 for 'nobody has it open'"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(1, "p123\n")):
        assert hh.open_handles("/x") == 1, "lsof exits 1 after a partial listing too, and the pid still counts"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, "p1\np1\np2\n")):
        assert hh.open_handles("/x") == 2
    with mock.patch.object(hh.subprocess, "run", return_value=completed(2, "")):
        assert hh.open_handles("/x") == 1, "an lsof that errored did not look"


def main() -> int:
    hh = load_engine()
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t(hh)
            print(f"  ok   {t.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL {t.__name__}: {e}")
        except Exception as e:                       # noqa: BLE001
            failed += 1
            print(f"  ERR  {t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

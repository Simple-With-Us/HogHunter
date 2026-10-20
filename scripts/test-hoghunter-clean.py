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


def test_dir_bytes_uses_du_once_without_counting_its_descendants(hh):
    root = Path(tempfile.mkdtemp(prefix="hhclean-dir-bytes-"))
    try:
        deep = root / "child" / "grandchild"
        deep.mkdir(parents=True)
        (deep / "payload").write_bytes(b"x" * 8192)
        seen = []

        def fake_run(cmd, timeout):
            seen.append((cmd, timeout))
            return "8\t"

        with mock.patch.object(hh, "_run", side_effect=fake_run):
            size = hh.dir_bytes(str(root), max_depth=0)
        assert size == 8192, f"deep subtree should be counted once, got {size}"
        assert len(seen) == 1, seen
        assert seen[0][0][-1] == str(root / "child"), seen
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_dir_bytes_cuts_du_timeout_to_remaining_scan_budget(hh):
    root = Path(tempfile.mkdtemp(prefix="hhclean-dir-budget-"))
    try:
        (root / "child").mkdir()
        clock = FakeClock()
        seen = []

        def fake_run(cmd, timeout):
            seen.append(timeout)
            clock.now += timeout
            return "4\t"

        with fake_time(hh, clock):
            hh.set_budget(2.0)
            with mock.patch.object(hh, "_run", side_effect=fake_run):
                size = hh.dir_bytes(str(root), max_depth=0)
            assert size == 4096
            # The du timeout is cut to the SCAN's share of the budget, not the whole run: the
            # deletes need the rest.
            assert len(seen) == 1 and 0 < seen[0] <= 2.0, seen
            assert seen[0] < 2.0, (
                f"the du timeout must be cut to the scan share "
                f"({2.0 * hh.SCAN_BUDGET_FRACTION:.1f}s), not the whole run budget")
            assert hh._SCAN_BUDGET_EXHAUSTED is True
            # And the run budget still has time in it, which is the whole point of the split.
            assert hh.budget_left() > 0, hh.budget_left()
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_the_scan_cannot_spend_the_budget_the_deletes_need(hh):
    """A slow scan used to eat the whole budget: the apply phase then started with nothing, deleted
    nothing, and the next run rescanned the same tree and ate the budget again -- a livelock, not
    progress.  Measured 2026-10-19: a 900 s budget, 1 of 23 applied, zero bytes freed.  The scan now
    gets a fixed share, so the deletes always get the rest."""
    clock = FakeClock()
    called = []

    def slow_rule():
        called.append("slow")
        clock.now += 8.0      # past the scan's 6 s share, short of the 10 s run budget
        return []

    def later_rule():
        called.append("later")
        return []

    original_rules = hh.RULES
    hh.RULES = {"slow": (slow_rule, ""), "later": (later_rule, "")}
    try:
        out, err = io.StringIO(), io.StringIO()
        with fake_time(hh, clock), \
                mock.patch.object(hh, "read_band", return_value=calm_band(hh)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = hh.main(["--scan", "--json", "--budget-sec=10"])
        report = json.loads(out.getvalue())
        assert code == 0
        assert called == ["slow"], called
        assert report["scan_truncated"] is True
        assert report["budget_exhausted"] is True
        # The scan stopped at its share and the run budget still has time for the deletes.
        assert hh.budget_left() > 0, hh.budget_left()
    finally:
        hh.RULES = original_rules


def test_the_report_carries_the_measured_free_space_not_just_the_estimate(hh):
    """`applied_bytes` is the size the scan ESTIMATED before each delete; it is not proof that the
    bytes came back.  A delete can free nothing (the file is open elsewhere) and the host can spend
    what was freed in the same minute, so the report carries df's measured change next to the
    estimate.  (Measured 2026-10-19: 6.48 GB estimated, 0.05 GB of actual change.)"""
    clock = FakeClock()
    cands = [marker(hh, i) for i in range(2)]
    out, err = io.StringIO(), io.StringIO()
    with fake_time(hh, clock), \
            mock.patch.object(hh, "scan", return_value=cands), \
            mock.patch.object(hh, "read_band", side_effect=[
                hh.Band(disk_free_gb=10.0, disk_used_pct=90, swap_used_pct=0, load1=0, cheap_only=False),
                hh.Band(disk_free_gb=11.5, disk_used_pct=88, swap_used_pct=0, load1=0, cheap_only=False),
            ]), \
            mock.patch.object(hh, "apply_candidate", side_effect=lambda c: setattr(c, "applied", True)), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = hh.main(["--clean", "--json", "--budget-sec=60"])
    report = json.loads(out.getvalue())
    assert code == 0
    assert report["disk_free_gb_before"] == 10.0
    assert report["disk_free_gb_after"] == 11.5
    assert report["disk_free_delta_gb"] == 1.5
    # The estimate is still there, and it is still the estimate.
    assert report["applied_bytes"] == 2 * 2048


def test_the_measured_free_space_is_absent_when_the_run_could_not_measure(hh):
    """A run that spends its budget cannot take the final reading.  That is not "freed nothing", so
    the field is absent rather than zero."""
    clock = FakeClock()
    cands = [heavy(hh, i) for i in range(3)]
    band = calm_band(hh, chunk_size=1, pause=0.0)
    # The second heavy item overshoots the deadline, so the run ends with no time left to measure.
    code, report, _err = run_main(hh, ["--clean", "--json", "--budget-sec=100"], cands, band, clock, apply_cost=60.0)
    assert code == 0
    assert report["budget_exhausted"] is True
    assert report["disk_free_delta_gb"] is None
    assert report["disk_free_gb_after"] is None


def test_dir_bytes_keeps_du_timeout_at_30_seconds_without_run_budget(hh):
    root = Path(tempfile.mkdtemp(prefix="hhclean-dir-no-budget-"))
    try:
        (root / "child").mkdir()
        seen = []
        with mock.patch.object(hh, "_run", side_effect=lambda cmd, timeout: seen.append(timeout) or "4\t"):
            assert hh.dir_bytes(str(root), max_depth=0) == 4096
        assert seen == [30.0], seen
    finally:
        shutil.rmtree(root, ignore_errors=True)


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
    """Run main() against a canned scan.  apply_candidate marks the candidate applied; a heavy one costs apply_cost
    seconds of fake time and a light one nothing.  Returns (exit code, parsed JSON, stderr text)."""
    def fake_apply(c):
        if not hh.is_light(c):
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


def test_scan_stops_starting_rules_at_budget_and_reports_exhaustion(hh):
    clock = FakeClock()
    called = []

    def slow_empty_rule():
        called.append("first")
        clock.now += 6
        return []

    def later_rule():
        called.append("later")
        return []

    original_rules = hh.RULES
    hh.RULES = {"first": (slow_empty_rule, ""), "later": (later_rule, "")}
    try:
        out, err = io.StringIO(), io.StringIO()
        with fake_time(hh, clock), \
                mock.patch.object(hh, "read_band", return_value=calm_band(hh)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = hh.main(["--scan", "--json", "--budget-sec=5"])
        report = json.loads(out.getvalue())
        assert code == 0
        assert called == ["first"], called
        assert report["candidates"] == []
        assert report["budget_exhausted"] is True
    finally:
        hh.RULES = original_rules


def test_main_resets_prior_scan_budget_state_when_scan_is_mocked(hh):
    clock = FakeClock()
    hh._SCAN_BUDGET_EXHAUSTED = True
    code, report, _err = run_main(hh, ["--scan", "--json"], [], calm_band(hh), clock)
    assert code == 0
    assert report["budget_exhausted"] is False


def test_snapshot_prune_report_tracks_increased_free_space(hh):
    clock = FakeClock()
    output = []
    for before_free, after_free in ((10.0, 11.0), (11.0, 10.0)):
        out, err = io.StringIO(), io.StringIO()
        with fake_time(hh, clock), \
                mock.patch.object(hh, "scan", return_value=[]), \
                mock.patch.object(hh, "read_band", side_effect=[
                    hh.Band(disk_free_gb=before_free, disk_used_pct=90, swap_used_pct=0,
                            load1=0, cheap_only=False),
                    hh.Band(disk_free_gb=after_free, disk_used_pct=90, swap_used_pct=0,
                            load1=0, cheap_only=False),
                ]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            hh.main(["--clean", "--json", "--budget-sec=60"])
        output.append(err.getvalue())
    assert "disk free increased by 1024M" in output[0], output[0]
    assert "disk free increased" not in output[1], output[1]


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


def test_every_apply_time_command_is_cut_to_the_budget(hh):
    """find had the cut; brew cleanup (600 s) and the tmutil calls (120 s + 60 s) did not, so a candidate that
    started with seconds left could outlive the engine's hard stop and turn a partial run into a kill."""
    clock = FakeClock()
    seen = []

    def fake_run(cmd, timeout=20):
        seen.append((cmd[0].rsplit("/", 1)[-1], timeout))
        return ""

    brew = hh.Candidate(category="brew", path="/opt/homebrew", bytes=0, reason="b", op="brew-cleanup")
    snap = hh.Candidate(category="snapshots", op="snapshot-delete", tier="semi-safe", bytes=0, reason="s",
                        path="apfs-snapshot:com.apple.TimeMachine.2026-10-09-010101.local")
    with fake_time(hh, clock), mock.patch.object(hh, "_run", side_effect=fake_run):
        hh.set_budget(0)
        hh.apply_candidate(brew)
        hh.apply_candidate(snap)
        assert seen == [("brew", 600), ("tmutil", 120), ("tmutil", 60)], seen
        seen.clear()
        hh.set_budget(40)
        clock.now += 10
        hh.apply_candidate(brew)
        hh.apply_candidate(snap)
        assert [t for _n, t in seen] == [30.0, 30.0, 30.0], seen
        seen.clear()
        clock.now += 29
        hh.apply_candidate(brew)
        assert seen == [("brew", 5.0)], "never under the 5 s floor"


def test_a_heavy_item_is_not_started_with_too_little_time_but_a_light_one_is(hh):
    """Two heavy items and three markers, budget 100, the first heavy costs 80 s.  The second heavy needs 30 s
    to start and has 20, so it waits for the next run; the markers are quick and still go."""
    clock = FakeClock()
    cands = [heavy(hh, 1, 900 * 1024 * 1024), heavy(hh, 2, 800 * 1024 * 1024)] + [marker(hh, i) for i in range(3)]
    _code, report, _err = run_main(hh, ["--clean", "--json", "--budget-sec=100"], cands, calm_band(hh, chunk_size=3),
                                   clock, apply_cost=80.0)
    applied = {c["path"] for c in report["candidates"] if c["applied"]}
    assert "/c/cache1" in applied and "/c/cache2" not in applied, applied
    assert sum(1 for p in applied if "codex" in p) == 3
    assert report["applied_count"] == 4 and report["remaining_count"] == 1
    assert report["budget_exhausted"] is True


def test_truncate_keep_size_is_read_once_from_the_detail(hh):
    """apply_candidate parsed `keep last 16M` with two searches; one compiled pattern does it, and a detail with
    no size falls back to 16."""
    seen = []
    with mock.patch.object(hh, "apply_truncate", side_effect=lambda path, keep_mib: seen.append(keep_mib) or (0, "")):
        for detail in ("keep last 32M", "", "no size here"):
            hh.apply_candidate(hh.Candidate(category="logs", path="/x/a.log", bytes=1, reason="r",
                                            op="truncate", detail=detail))
    assert seen == [32, 16, 16], seen


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
    _reset_open_snapshot(hh)
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


def test_cleanmymac_missing_cli_skips(hh):
    """Without the flag the CLI is never touched; with it and no CLI the run
    records a skip and still exits clean.  The CLI is closed-source MacPaw
    software: invoke-only, never vendored, never required."""
    report = {"requested": True, "installed": True, "ran": False, "commands": [], "skipped": None}
    with mock.patch.object(shutil, "which", return_value=None):
        hh.run_cleanmymac_cli(report)
    assert report["installed"] is False
    assert report["ran"] is False
    assert report["commands"] == []
    assert report["skipped"] == "cleanmymac CLI not installed"


def test_cleanmymac_runs_only_its_two_sweeps(hh):
    """The opt-in runs exactly `clean junk --force` and `optimize purgeable`:
    the non-interactive pair.  Interactive-only commands (purge, analyze)
    must never appear here."""
    seen = []

    def fake_run(argv, **kwargs):
        seen.append(list(argv))
        return subprocess.CompletedProcess(argv, 0, stdout="done\n", stderr="")

    report = {"requested": True, "installed": False, "ran": False, "commands": [], "skipped": None}
    with mock.patch.object(shutil, "which", return_value="/opt/homebrew/bin/cleanmymac"), \
         mock.patch.object(hh.subprocess, "run", side_effect=fake_run):
        hh.run_cleanmymac_cli(report)
    assert report["installed"] is True
    assert report["ran"] is True
    assert report["skipped"] is None
    assert seen[0] == ["cleanmymac", "--version"]
    assert seen[1:] == [
        ["cleanmymac", "clean", "junk", "--force"],
        ["cleanmymac", "optimize", "purgeable"],
    ]
    for argv in seen[1:]:
        assert argv[1] in ("clean", "optimize"), argv
    assert [c["exit"] for c in report["commands"]] == [0, 0]


def test_cleanmymac_failure_never_raises(hh):
    """A non-zero exit or a timeout is recorded, not raised: the CLI is an
    extra, and its failure must not fail the reclaim run."""

    def fake_fail(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 2, stdout="", stderr="boom\n")

    report = {"requested": True, "installed": False, "ran": False, "commands": [], "skipped": None}
    with mock.patch.object(shutil, "which", return_value="/opt/homebrew/bin/cleanmymac"), \
         mock.patch.object(hh.subprocess, "run", side_effect=fake_fail):
        hh.run_cleanmymac_cli(report)  # must not raise
    assert report["ran"] is True
    assert report["commands"][0]["exit"] == 2
    assert report["commands"][0]["tail"] == ["boom"]


def test_cleanmymac_spent_budget_skips(hh):
    """With a budget and no time left, the sweeps wait for the next run
    instead of starting work that would be killed half done."""
    report = {"requested": True, "installed": False, "ran": False, "commands": [], "skipped": None}
    with mock.patch.object(shutil, "which", return_value="/opt/homebrew/bin/cleanmymac"), \
         mock.patch.object(hh, "budget_left", return_value=0.0), \
         mock.patch.object(hh.subprocess, "run") as run:
        hh.run_cleanmymac_cli(report, budget_sec=600)
    assert report["ran"] is False
    assert report["skipped"] == "budget spent"
    run.assert_not_called()


def test_botfleet_rollback_lists_only_stale_versioned_copies(hh):
    """A rollback is safe-tier 24h after its newest file, never before, and the
    glob can never match the live tree (it needs the versioned infix plus a suffix)."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        apps = home / "apps"
        apps.mkdir()
        old = apps / ".botfleet-server.node_modules.rollback-old"
        new = apps / ".botfleet-server.node_modules.rollback-new"
        live = apps / ".botfleet-server"
        for d in (old, new, live):
            d.mkdir()
            (d / "package.json").write_text("{}\n", encoding="utf-8")
        ancient = hh.time.time() - 25 * 3600
        for p in (old / "package.json",):
            os.utime(p, (ancient, ancient))
        # The fresh copy reads newer than the mocked clock below, so only the
        # old copy passes both the file-age and the ctime grace gates.
        ahead = hh.time.time() + 2 * 3600
        os.utime(new / "package.json", (ahead, ahead))
        with mock.patch.object(hh, "HOME", home), mock.patch.object(hh, "open_handles", return_value=0):
            # The fixture directories were just created (ctime is now), so run
            # the rule a day later: only then is the grace period over.
            with mock.patch.object(hh.time, "time", return_value=hh.time.time() + 25 * 3600):
                offered = hh.rule_botfleet_rollback()
        assert [c.path for c in offered] == [str(old)], offered
        assert offered[0].tier == "safe", "cheap band must pick this up with no flag"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_ask_first_reports_idle_build_output_only(hh):
    """Main checkouts are never lanes, so .build/.next trees idle 7 days with
    no open files are inventoried report-only.  Fresh trees, non-repos, and
    symlinks stay out."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        repo = home / "Code" / "FakeRepo"
        (repo / ".git").mkdir(parents=True)
        idle = repo / ".build"
        busy = repo / ".next"
        for d in (idle, busy):
            d.mkdir(parents=True)
            (d / "out.o").write_text("x\n", encoding="utf-8")
        plain = home / "Code" / "NotARepo"
        plainbuild = plain / ".build"
        plainbuild.mkdir(parents=True)
        (plainbuild / "out.o").write_text("x\n", encoding="utf-8")
        old = hh.time.time() - 8 * 24 * 3600
        for p in (idle / "out.o", plainbuild / "out.o"):
            os.utime(p, (old, old))
        with mock.patch.object(hh, "HOME", home), mock.patch.object(hh, "open_handles", return_value=0):
            found = {c.path: c for c in hh.rule_ask_first_inventory() if "regenerable build output" in c.reason}
        assert list(found) == [str(idle)], found
        assert found[str(idle)].tier == "ask-first"
        assert found[str(idle)].op == "report", "build output is inventoried, never applied"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_botfleet_rollback_holds_a_moved_in_old_tree(hh):
    """A moved-in old tree keeps its file mtimes: only the directory's own
    ctime (refreshed by the move) proves it just arrived, so it still gets
    its grace day."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        apps = home / "apps"
        apps.mkdir()
        moved = apps / ".botfleet-server.node_modules.rollback-moved"
        moved.mkdir()
        old_file = moved / "package.json"
        old_file.write_text("{}\n", encoding="utf-8")
        ancient = hh.time.time() - 30 * 24 * 3600
        os.utime(old_file, (ancient, ancient))
        with mock.patch.object(hh, "HOME", home), mock.patch.object(hh, "open_handles", return_value=0):
            assert hh.rule_botfleet_rollback() == [], "a just-moved tree is not listed on day zero"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_ask_first_reports_dated_drive_copies_only(hh):
    """The orphan glob matches 'GoogleDrive-<account> (<date> <time>)' with any
    separator (the real one is a narrow no-break space), never the live folder,
    and always as report-only."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cloud = home / "Library/CloudStorage"
        cloud.mkdir(parents=True)
        live = cloud / "GoogleDrive-user@gmail.com"
        orphan = cloud / "GoogleDrive-user@gmail.com (10-14-26 12:59 AM)"
        other = cloud / "Dropbox"
        for d in (live, orphan, other):
            d.mkdir()
        with mock.patch.object(hh, "HOME", home):
            found = {c.path: c for c in hh.rule_ask_first_inventory() if "orphaned Drive copy" in c.reason}
        assert list(found) == [str(orphan)], found
        assert found[str(orphan)].tier == "ask-first"
        assert found[str(orphan)].op == "report", "an orphan is inventoried, never applied"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_app_staging_offers_idle_shipit_in_the_safe_tier(hh):
    """Updater leftovers ride the cheap band: an idle ShipIt staging dir with no
    owner process is a safe-tier candidate, so band=cheap already covers the
    2.5 GB class the audit found."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        shipit = home / "Library/Caches/com.anthropic.claudefordesktop.ShipIt"
        shipit.mkdir(parents=True)
        pkg = shipit / "staging.pkg"
        pkg.write_text("x\n", encoding="utf-8")
        old = hh.time.time() - 2 * 3600
        os.utime(pkg, (old, old))
        with mock.patch.object(hh, "HOME", home), mock.patch.object(hh, "open_handles", return_value=0):
            with mock.patch.object(hh.subprocess, "run", return_value=completed(1)):
                offered = hh.rule_app_staging()
        assert [c.path for c in offered] == [str(shipit)], offered
        assert offered[0].tier == "safe"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_touched_since_catches_a_recent_file_past_the_walk_cap(hh):
    """newest_file_age_min stops at 4000 entries, so a recent file past the cap
    reads as idle.  The find probe has no cap: it answers on the first recent
    file, and a failed look reads as touched."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        old_dir = home / "old-build"
        old_dir.mkdir()
        old_file = old_dir / "out.o"
        old_file.write_text("x\n", encoding="utf-8")
        old = hh.time.time() - 8 * 24 * 3600
        os.utime(old_file, (old, old))
        assert hh.touched_since(str(old_dir), 7) is False
        fresh_dir = home / "fresh-build"
        fresh_dir.mkdir()
        (fresh_dir / "out.o").write_text("x\n", encoding="utf-8")
        assert hh.touched_since(str(fresh_dir), 7) is True
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_touched_since_asks_find_for_a_parseable_cutoff(hh):
    """The idle gate runs `find -newermt`, and find rejects a fractional unit.

    IDLE_MIN_OK is 90 minutes, which reaches this call as 0.0625 days.  Both
    GNU and BSD find refuse "-0.0625 days", exit non-zero, and this fails
    closed to "touched" -- so every app cache reads as busy and the rule frees
    nothing while looking perfectly healthy.  Every other app-caches test mocks
    touched_since out, so nothing else here would notice.  Assert the argv.
    """
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, "")) as run:
        hh.touched_since("/tmp", 90 / (24 * 60))
    stamp = run.call_args[0][0][5]
    assert stamp == "-90 minutes", f"find cannot parse {stamp!r}; it fails closed to 'touched'"
    # The whole-day call site has to keep working the same way.
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, "")) as run:
        hh.touched_since("/tmp", 7)
    assert run.call_args[0][0][5] == "-10080 minutes"


def test_idle_build_output_survives_a_blind_capped_walk(hh):
    """Even when the capped walk swears a tree is idle, the uncapped find probe
    still refuses a tree holding a recent file."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        repo = home / "Code" / "FakeRepo"
        build = repo / ".build"
        build.mkdir(parents=True)
        (repo / ".git").mkdir()
        (build / "out.o").write_text("x\n", encoding="utf-8")
        with mock.patch.object(hh, "HOME", home), mock.patch.object(hh, "open_handles", return_value=0):
            with mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9):
                found = [c for c in hh.rule_ask_first_inventory() if "regenerable build output" in c.reason]
        assert found == [], "the probe overrules a blind capped walk"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _reset_open_snapshot(hh):
    """The engine memoizes one snapshot for a while; a test has to start over."""
    hh._OPEN_SNAPSHOT = None
    hh._OPEN_SNAPSHOT_AT = 0.0
    hh._OPEN_INDEX = None


def test_one_lsof_snapshot_answers_every_candidate(hh):
    """The old shape asked lsof about each path separately, and lsof times out
    under load.  With hundreds of candidates that is hours of blocked scanning,
    and a scan that never reaches a decision deletes nothing: the safe tier
    found 41.9 MB across 915 items and freed nothing else.

    One snapshot turns the per-path cost into a single bounded one.
    """
    _reset_open_snapshot(hh)
    listing = "p1\nfcwd\nn/tmp\nf3\nn/Users/jay/Library/Caches/Foo/blob.bin\n"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, listing)) as run:
        assert hh.open_handles("/Users/jay/Library/Caches/Foo") == 1
        assert hh.open_handles("/Users/jay/Library/Caches/Bar") == 0
        assert hh.open_handles("/Users/jay/Library/Caches") == 1
    assert run.call_count == 1, "the snapshot must be taken once, not once per path"


def test_the_open_handle_lookup_does_not_walk_every_path(hh):
    """The answer came from scanning the whole open-path set for every
    candidate, which is O(candidates x paths).  On a busy Mac that is millions
    of string comparisons, and the scan that costs that much never reaches a
    delete.  The index answers from a count per ancestor directory."""
    _reset_open_snapshot(hh)
    listing = "p1\nf3\nn/Users/jay/Library/Caches/Foo/blob.bin\n"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, listing)):
        assert hh.open_handles("/Users/jay/Library/Caches/Foo") == 1
        assert hh.open_handles("/Users/jay/Library/Caches") == 1
        assert hh.open_handles("/Users/jay/Library") == 1
        assert hh.open_handles("/Users/jay/Library/Caches/Bar") == 0
    assert hh._OPEN_INDEX is not None, "the index must be built with the snapshot"
    # Every ancestor of the open path is in the index.
    assert hh._OPEN_INDEX["/Users/jay/Library/Caches/Foo"] == 1
    assert hh._OPEN_INDEX["/Users/jay/Library/Caches"] == 1
    assert hh._OPEN_INDEX["/Users/jay/Library"] == 1
    assert "/Users/jay/Library/Caches/Bar" not in hh._OPEN_INDEX


def test_the_index_answers_the_same_way_the_old_scan_did(hh):
    """A path that is itself open, a path under it, and a path that merely
    shares a prefix all have to answer the same as the old prefix scan."""
    _reset_open_snapshot(hh)
    listing = "p1\nf3\nn/Users/jay/work/thing.bin\n"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, listing)):
        # The exact path is open.
        assert hh.open_handles("/Users/jay/work/thing.bin") == 1
        # Its parent holds it.
        assert hh.open_handles("/Users/jay/work") == 1
        # A sibling that only shares a prefix is not under it.
        assert hh.open_handles("/Users/jay/workspace") == 0
        assert hh.open_handles("/Users/jay/work/other") == 0


def test_the_snapshot_resolves_a_relative_name_against_the_working_directory(hh):
    """lsof prints a relative name for a file opened relative to a cwd.  An
    unresolved name would silently hide an open handle."""
    _reset_open_snapshot(hh)
    listing = "p1\nfcwd\nn/Users/jay/work\nf3\nn./thing.bin\n"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, listing)):
        # Both the cwd itself and the resolved ./thing.bin live under
        # /Users/jay/work, so a candidate for that directory counts 2.  A
        # snapshot that dropped the relative name would count only the cwd.
        assert hh.open_handles("/Users/jay/work") == 2
        assert hh.open_handles("/Users/jay/other") == 0


def test_a_snapshot_that_exited_badly_is_not_cached(hh):
    """lsof can print part of its listing and still fail.  Caching a partial
    set reads every file it failed to mention as closed, and the "no open
    handles" gate would pass on a directory a live process is holding."""
    _reset_open_snapshot(hh)
    listing = "p1\nf3\nn/Users/jay/work/thing.bin\n"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(1, listing)) as run:
        assert hh.open_handles("/Users/jay/work") == 1
    assert hh._OPEN_SNAPSHOT is None, "a partial listing must not be cached"
    assert run.call_count == 2, "one rejected snapshot attempt plus one per-path check"


def test_the_snapshot_is_retaken_once_it_goes_stale(hh):
    """A scan runs for the whole time budget, and the per-path lsof this
    snapshot replaced answered each candidate as it went.  A listing kept for
    the whole process answers for a candidate examined minutes later, so a
    file opened in between reads as absent."""
    _reset_open_snapshot(hh)
    hh._OPEN_SNAPSHOT_MAX_AGE_SEC = 60.0
    first = "p1\nf3\nn/Users/jay/work/first.bin\n"
    second = "p1\nf3\nn/Users/jay/work/second.bin\n"
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, first)):
        assert hh.open_handles("/Users/jay/work/second.bin") == 0
    with mock.patch.object(hh.time, "monotonic", return_value=hh.time.monotonic() + 600.0), \
         mock.patch.object(hh.subprocess, "run", return_value=completed(0, second)):
        assert hh.open_handles("/Users/jay/work/first.bin") == 0
        assert hh.open_handles("/Users/jay/work/second.bin") == 1


def test_the_snapshot_age_is_stamped_after_the_listing_lands(hh):
    """The max-age clock used to start before the lsof pass, so a listing that
    took longer than the max age to produce arrived already stale and the next
    candidate paid for another system-wide lsof.  Stamped before the pass, a
    70s listing would be discarded the moment it finished."""
    _reset_open_snapshot(hh)
    hh._OPEN_SNAPSHOT_MAX_AGE_SEC = 60.0
    first = "p1\nf3\nn/Users/jay/work/first.bin\n"
    second = "p1\nf3\nn/Users/jay/work/second.bin\n"
    clock = hh.time.monotonic()

    def listing_takes_70s(*_a, **_kw):
        # The lsof pass itself consumes more than the whole max age.
        nonlocal clock
        clock += 70.0
        return completed(0, first)

    with mock.patch.object(hh.subprocess, "run", side_effect=listing_takes_70s):
        with mock.patch.object(hh.time, "monotonic", side_effect=lambda: clock):
            assert hh.open_handles("/Users/jay/work/second.bin") == 0

    # The listing is fresh the moment it lands, so the next candidate is
    # answered from it instead of paying for another system-wide lsof.
    with mock.patch.object(hh.subprocess, "run", return_value=completed(0, second)) as run:
        with mock.patch.object(hh.time, "monotonic", side_effect=lambda: clock):
            assert hh.open_handles("/Users/jay/work/first.bin") == 1
            assert hh.open_handles("/Users/jay/work/second.bin") == 0
    assert run.call_count == 0, "a listing that just landed must not be re-taken"


def test_the_snapshot_matches_a_candidate_spelled_through_a_symlink(hh):
    """lsof answers with resolved vnode paths, so a handle under the per-user
    TMPDIR arrives as /private/var/... while `getconf DARWIN_USER_TEMP_DIR`
    hands the rule the /var/... spelling.  Matched as plain strings, every open
    handle in TMPDIR reads as absent and an in-use scratch dir gets deleted."""
    _reset_open_snapshot(hh)
    real = Path(tempfile.mkdtemp(prefix="hhclean-real-"))
    holder = Path(tempfile.mkdtemp(prefix="hhclean-link-"))
    link = holder / "var"
    try:
        link.symlink_to(real)
        listing = f"p1\nf3\nn{real}/ssr-abc/thing.bin\n"
        with mock.patch.object(hh.subprocess, "run", return_value=completed(0, listing)):
            assert hh.open_handles(str(link / "ssr-abc")) == 1
            assert hh.open_handles(str(link / "other")) == 0
    finally:
        shutil.rmtree(real, ignore_errors=True)
        shutil.rmtree(holder, ignore_errors=True)


def test_an_untrustworthy_snapshot_falls_back_to_the_per_path_check(hh):
    """lsof answered but found nothing at all, which on a live Mac is not
    believable.  Treat it as untrustworthy rather than as 'nothing open'."""
    _reset_open_snapshot(hh)
    with mock.patch.object(hh.subprocess, "run", return_value=completed(1, "")) as run:
        assert hh.open_handles("/x") == 0
    assert run.call_count == 2, "one snapshot attempt plus one per-path check"


def test_a_snapshot_that_never_answers_falls_back_to_the_per_path_check(hh):
    _reset_open_snapshot(hh)
    with mock.patch.object(hh.subprocess, "run", side_effect=subprocess.TimeoutExpired("lsof", 180)):
        assert hh.open_handles("/x") == 1, "a look that failed is not an empty room"


def test_app_caches_finds_an_idle_app_cache(hh):
    """The measured hog on this Mac was ~/Library/Caches/org.swift.swiftpm at
    3.6 GB.  The old rule set named a few toolchain caches and nothing else,
    so a host whose space went into app caches got nothing back."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cache = home / "Library" / "Caches" / "SomeApp"
        cache.mkdir(parents=True)
        (cache / "blob.bin").write_bytes(b"x" * 1024)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            found = hh.rule_app_caches()
        assert [c.path for c in found] == [str(cache)]
        assert found[0].category == "app-caches"
        assert found[0].tier == "safe"
        assert found[0].op == "delete"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_app_caches_leaves_a_busy_cache_alone(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cache = home / "Library" / "Caches" / "BusyApp"
        cache.mkdir(parents=True)
        (cache / "blob.bin").write_bytes(b"x" * 1024)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=1), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            assert hh.rule_app_caches() == []
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_app_caches_leaves_the_botfleet_update_generations_alone(hh):
    """The ask-first inventory reports BotFleet's update generations and never
    deletes them.  This rule works on whole directories, so without a skip it
    would purge a pending update before BotFleet ever applied it."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        gens = home / "Library" / "Caches" / "BotFleet" / "updates" / "gen-2"
        gens.mkdir(parents=True)
        (gens / "app.bin").write_bytes(b"x" * 1024)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            assert hh.rule_app_caches() == []
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_app_caches_does_not_call_a_big_active_cache_idle(hh):
    """newest_file_age_min stops after 4000 entries, so an application cache
    tree bigger than that (Chrome, Slack, Electron are all past it) can hide a
    recent write past the cap and read as idle.  The uncapped touched_since
    probe answers on the first recent file, so the tree is left alone."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cache = home / "Library" / "Caches" / "BigApp"
        cache.mkdir(parents=True)
        (cache / "blob.bin").write_bytes(b"x" * 1024)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=True), \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            assert hh.rule_app_caches() == [], "a cache with a recent write is not idle"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_agent_state_reports_sessions_instead_of_deleting_them(hh):
    """The transient parts rebuild; the sessions are Jay's history."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        logs = home / ".claude" / "logs"
        logs.mkdir(parents=True)
        (logs / "a.log").write_text("x", encoding="utf-8")
        sessions = home / ".claude" / "sessions"
        sessions.mkdir(parents=True)
        (sessions / "s.jsonl").write_text("x", encoding="utf-8")
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=128 * 1024 * 1024):
            found = hh.rule_agent_state()
        by_path = {c.path: c for c in found}
        assert by_path[str(logs)].tier == "safe", "transient state is safe to clear"
        assert by_path[str(sessions)].tier == "ask-first", "session history is not cache"
        assert by_path[str(sessions)].op == "report"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_agent_state_leaves_a_project_working_tree_alone(hh):
    """`~/.gemini/tmp` is named like scratch but holds a `.project_root`
    marker per project the agent has opened -- a working copy of Jay's real
    code, with chat history beside it.  The name is not enough to call it
    transient."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        tmp = home / ".gemini" / "tmp"
        proj = tmp / "code"
        proj.mkdir(parents=True)
        (proj / ".project_root").write_text("/Users/jay/Code\n", encoding="utf-8")
        (proj / "blob.bin").write_bytes(b"x" * 1024)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=128 * 1024 * 1024):
            found = hh.rule_agent_state()
        assert [c.path for c in found] == [], "a project working tree is not transient state"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_a_path_two_rules_name_is_only_claimed_once(hh):
    """dev-caches and app-caches can both name the same directory.  It has to
    be deleted once, not twice."""
    cand = hh.Candidate(category="dev-caches", path="/x/Cache", bytes=10, reason="r")
    with mock.patch.dict(hh.RULES, {"dev-caches": (lambda: [cand], "a"),
                                    "app-caches": (lambda: [cand], "b")}):
        found = hh.scan(["dev-caches", "app-caches"])
    assert len(found) == 1


def main() -> int:
    hh = load_engine()
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            # The engine keeps one lsof snapshot per process.  Reset it so a
            # test never inherits an earlier test's answer.
            _reset_open_snapshot(hh)
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

#!/usr/bin/env python3
"""Regression tests for the Hog Hunter reclaim engine.

Deliberately narrow: these cover the pure functions that can fail SILENTLY.
A reclaim engine that no-ops and reports success is worse than one that is
down, because the operator believes disk was handled.

Run:  python3 scripts/test-hoghunter-clean.py
"""
from __future__ import annotations

import ast
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
import time
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


def test_the_scan_probes_are_bounded_by_the_scan_share(hh):
    """Every probe a scan rule starts has to be bounded by the scan's share of
    the budget.  The lsof pass and the find walk run once per candidate, and
    a host that is too loaded to answer answers none of them, so a fixed
    timeout lets repeated hangs eat the share the deletes need."""
    hh.set_budget(600)
    try:
        # A scan with a generous share gets its usual limits.
        assert hh.scan_op_timeout(180.0) == 180.0
        assert hh.scan_op_timeout(25.0) == 25.0
        # A scan with almost nothing left must not start a long command.
        hh._SCAN_DEADLINE = time.monotonic() + 0.5
        assert hh.scan_op_timeout(180.0) <= 1.0
        # A scan that has spent its share answers in the minimum.
        hh._SCAN_DEADLINE = time.monotonic() - 1.0
        assert hh.scan_op_timeout(180.0) == 1.0
    finally:
        hh.set_budget(0)


def test_the_lsof_snapshot_is_bounded_by_the_scan_share(hh):
    """The system-wide lsof pass used a fixed 180s timeout.  It runs once per
    candidate while the snapshot is young, so repeated hangs could spend the
    whole scan share."""
    _reset_open_snapshot(hh)
    hh.set_budget(600)
    hh._SCAN_PHASE = True          # a probe takes the clock of its phase
    try:
        hh._SCAN_DEADLINE = time.monotonic() - 1.0
        with mock.patch.object(hh.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired("lsof", 1)) as run:
            assert hh.open_handles("/Users/jay/work") == 1, "a failed look is not an empty room"
        assert run.call_args.kwargs["timeout"] == 1.0, "the timeout must follow the scan share"
    finally:
        hh.set_budget(0)
        hh._SCAN_PHASE = False
        _reset_open_snapshot(hh)


def test_the_find_probe_is_bounded_by_the_scan_share(hh):
    """The find walk in touched_since used a fixed 120s timeout and runs once
    per candidate, so it could spend the whole scan share."""
    hh.set_budget(600)
    hh._SCAN_PHASE = True          # a probe takes the clock of its phase
    try:
        hh._SCAN_DEADLINE = time.monotonic() - 1.0
        with mock.patch.object(hh.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired("find", 1)) as run:
            assert hh.touched_since("/Users/jay/work", 0.0625) is True, "a failed look reads as touched"
        assert run.call_args.kwargs["timeout"] == 1.0
    finally:
        hh.set_budget(0)
        hh._SCAN_PHASE = False


def test_the_candidate_loops_stop_when_the_scan_share_is_spent(hh):
    """The rules walk whole trees per candidate.  Without a deadline check the
    loop can spend the scan share and leave the deletes with nothing -- the
    livelock the budget split exists to stop."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cache = home / "Library" / "Caches" / "SomeApp"
        cache.mkdir(parents=True)
        (cache / "blob.bin").write_bytes(b"x" * 1024)
        hh.set_budget(600)
        try:
            hh._SCAN_DEADLINE = time.monotonic() - 1.0
            with mock.patch.object(hh, "HOME", home), \
                 mock.patch.object(hh, "open_handles", return_value=0), \
                 mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
                 mock.patch.object(hh, "touched_since", return_value=False), \
                 mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
                assert hh.rule_app_caches() == [], "the scan is over, so no candidate is chosen"
                assert hh.rule_agent_state() == []
            assert hh._SCAN_BUDGET_EXHAUSTED is True, "the run has to say the scan hit its share"
        finally:
            hh.set_budget(0)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_the_probe_timeout_follows_the_phase_it_runs_in(hh):
    """Round 5: the rules that predate the budget split started their own
    subprocesses with a FIXED timeout (90 s, 60 s, 15 s).  `scan()` only
    checks the deadline BETWEEN rules, so a rule that started with its share
    nearly spent could still run a 90 s walk and eat the reserve the deletes
    need -- the exact livelock the budget split exists to break.

    Every probe now takes its timeout from the clock of the phase it runs in:
    the scan share during the scan, the whole budget after it.
    """
    hh.set_budget(600)
    try:
        # The scan share is nearly spent.
        hh._SCAN_DEADLINE = time.monotonic() + 0.5
        hh._SCAN_PHASE = True
        try:
            assert hh.probe_timeout(90.0) <= 1.0, hh.probe_timeout(90.0)
            assert hh.probe_timeout(60.0) <= 1.0, hh.probe_timeout(60.0)
            assert hh.probe_timeout(15.0) <= 1.0, hh.probe_timeout(15.0)
            # A generous share still gets the usual limits.
            hh._SCAN_DEADLINE = time.monotonic() + 300
            assert hh.probe_timeout(90.0) == 90.0, hh.probe_timeout(90.0)
        finally:
            hh._SCAN_PHASE = False
        # Outside the scan the WHOLE budget applies, not the scan share.
        assert hh.probe_timeout(90.0) == 90.0, hh.probe_timeout(90.0)
        # With the whole budget nearly spent the probe is cut to what is left.
        hh._DEADLINE = time.monotonic() + 0.5
        assert hh.probe_timeout(90.0) <= 5.0, hh.probe_timeout(90.0)
    finally:
        hh.set_budget(0)
        hh._SCAN_PHASE = False


def test_the_rule_deadline_follows_the_phase_it_runs_in(hh):
    """A rule's own wall clock must not outlive the phase it runs in.  A rule
    that starts with the scan share nearly spent cannot then walk for another
    90 s and eat the reserve the deletes need -- that is the round-5 bug in
    its loop form."""
    hh.set_budget(600)
    try:
        hh._SCAN_DEADLINE = time.monotonic() + 20
        hh._SCAN_PHASE = True
        try:
            # 20 s of scan share left, so the rule's deadline is 20 s away --
            # not its own 90 s.
            left = hh.rule_deadline() - time.time()
            assert left <= 20.0, left
            assert left < hh.RULE_BUDGET_SEC, left
        finally:
            hh._SCAN_PHASE = False
        # Outside the scan the whole budget applies, so the rule may use its
        # own budget.
        assert hh.rule_deadline() - time.time() > 20.0
    finally:
        hh.set_budget(0)
        hh._SCAN_PHASE = False


def test_the_scan_phase_flag_is_set_while_the_rules_run_and_cleared_after(hh):
    """The phase flag must be a MODULE global.  A flag assigned inside a
    function without `global` is a local: the report never learns the truth.
    (Lesson: contrib/MM/2026-10-20/fbab9520.)

    Assert it from OUTSIDE the function, where a local assignment would be
    invisible, and assert it is cleared even when a rule raises.
    """
    seen = {}

    def probe_rule():
        seen["phase"] = hh._SCAN_PHASE
        return []

    def boom_rule():
        raise RuntimeError("boom")

    original = hh.RULES
    try:
        hh.RULES = {"probe": (probe_rule, "a test rule")}
        hh.scan(["probe"])
        assert seen["phase"] is True, "the rules run in the scan phase"
        assert hh._SCAN_PHASE is False, "the flag is cleared after the scan"
        hh.RULES = {"probe": (boom_rule, "a test rule")}
        hh.scan(["probe"])
        assert hh._SCAN_PHASE is False, "a broken rule must not leave the scan flag set"
    finally:
        hh.RULES = original
        hh._SCAN_PHASE = False


def test_no_scan_rule_probe_outlives_the_scan_share(hh):
    """Round 5, end to end: run the REAL scan with the scan share nearly
    spent and check every subprocess it starts.  A rule that keeps a fixed
    90 s or 60 s timeout shows up here as a timeout far above the share --
    and that rule would have eaten the reserve the deletes need.
    """
    recorded = []

    def fake_run(cmd, **kwargs):
        recorded.append(kwargs.get("timeout"))
        return subprocess.CompletedProcess(cmd, 1, "", "")

    original_rules = hh.RULES
    try:
        hh.set_budget(600)
        try:
            hh._SCAN_DEADLINE = time.monotonic() + 0.5
            with mock.patch.object(hh.subprocess, "run", side_effect=fake_run):
                hh.scan(None)
        finally:
            hh.set_budget(0)
        assert recorded, "the scan started no probe at all, so this guard proves nothing"
        unbounded = [t for t in recorded if t is None]
        assert not unbounded, f"a subprocess ran with no timeout at all: {unbounded}"
        too_long = [t for t in recorded if t > 1.0]
        assert not too_long, f"probes outlived the scan share: {too_long}"
    finally:
        hh.RULES = original_rules


def test_no_subprocess_timeout_bypasses_the_budget_clocks(hh):
    """Round 5, structural half: a subprocess timeout must come from one of
    the budget clocks, or be a bare literal no longer than
    MIN_HEAVY_START_SEC.  A fixed 90 s or 60 s timeout is longer than the
    scan share on its own, so one rule could spend the whole budget.

    This walks the source, so the next fixed timeout fails here instead of
    waiting for the next review round to find it.
    """
    tree = ast.parse(ENGINE.read_text())
    helpers = {"probe_timeout", "op_timeout", "scan_op_timeout",
               "apply_probe_timeout", "budget_left", "scan_budget_left"}

    def mentions_budget(node):
        for n in ast.walk(node):
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) \
                    and n.func.id in helpers:
                return True
        return False

    # Functions that take the timeout as a parameter: the CALLER owns the
    # clock, so those call sites are checked separately.
    param_owners = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef):
            for a in list(node.args.args) + list(node.args.kwonlyargs):
                if a.arg == "timeout":
                    param_owners.add(node.name)

    def timeout_arg(call):
        for kw in call.keywords:
            if kw.arg == "timeout":
                return kw.value
        return None

    problems = []

    class V(ast.NodeVisitor):
        def __init__(self):
            self.timeout_param = None
            self.derived = set()

        def visit_FunctionDef(self, node):
            prev_param, prev_derived = self.timeout_param, self.derived
            self.timeout_param = None
            self.derived = set()
            for a in list(node.args.args) + list(node.args.kwonlyargs):
                if a.arg == "timeout":
                    self.timeout_param = a.arg
            for sub in ast.walk(node):
                if isinstance(sub, ast.Assign) and mentions_budget(sub.value):
                    for t in sub.targets:
                        if isinstance(t, ast.Name):
                            self.derived.add(t.id)
            self.generic_visit(node)
            self.timeout_param, self.derived = prev_param, prev_derived

        def visit_Call(self, node):
            fname = None
            if isinstance(node.func, ast.Attribute) and node.func.attr == "run" \
                    and isinstance(node.func.value, ast.Name) \
                    and node.func.value.id == "subprocess":
                fname = "subprocess.run"
            elif isinstance(node.func, ast.Name) and node.func.id == "_run":
                fname = "_run"
            if fname:
                arg = timeout_arg(node)
                if fname == "_run" and arg is None and node.args:
                    arg = node.args[-1]
                if arg is None:
                    problems.append((fname, node.lineno, "no timeout"))
                elif isinstance(arg, ast.Name) and self.timeout_param \
                        and arg.id == self.timeout_param:
                    # The enclosing function owns it; its call sites are checked.
                    pass
                elif mentions_budget(arg):
                    pass
                elif isinstance(arg, ast.Constant) and isinstance(arg.value, (int, float)):
                    if arg.value > hh.MIN_HEAVY_START_SEC:
                        problems.append((fname, node.lineno, ast.unparse(arg)))
                elif isinstance(arg, ast.Name) and arg.id in self.derived:
                    pass
                else:
                    problems.append((fname, node.lineno, ast.unparse(arg)))
            # A call to a function that takes a timeout parameter must pass a
            # budget clock, or that function is unbounded by construction.
            if isinstance(node.func, ast.Name) and node.func.id in param_owners:
                arg = timeout_arg(node)
                if arg is None and node.args:
                    arg = node.args[-1]
                if arg is None:
                    problems.append((node.func.id, node.lineno, "no timeout argument"))
                elif not mentions_budget(arg):
                    problems.append((node.func.id, node.lineno, ast.unparse(arg)))
            self.generic_visit(node)

    V().visit(tree)
    assert not problems, problems

    # Every use of RULE_BUDGET_SEC must be a default handed to a timeout helper
    # (which clamps it to the phase clock), or live in one of the two places
    # that build a deadline the phase clock caps on top of.  A rule that builds
    # its own deadline from the raw constant can walk for 90 s even with 20 s
    # of the scan share left -- the round-5 bug in its loop form.
    allowed_rule_budget = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                and node.func.id in {"probe_timeout", "op_timeout", "scan_op_timeout"}:
            for a in list(node.args) + [k.value for k in node.keywords]:
                for n in ast.walk(a):
                    if isinstance(n, ast.Name) and n.id == "RULE_BUDGET_SEC":
                        allowed_rule_budget.add(id(n))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name in ("rule_deadline", "dir_bytes"):
            for n in ast.walk(node):
                if isinstance(n, ast.Name) and n.id == "RULE_BUDGET_SEC":
                    allowed_rule_budget.add(id(n))
    loose = [n.lineno for n in ast.walk(tree)
             if isinstance(n, ast.Name) and n.id == "RULE_BUDGET_SEC"
             and isinstance(n.ctx, ast.Load)
             and id(n) not in allowed_rule_budget]
    assert not loose, f"RULE_BUDGET_SEC used outside a clamped deadline: lines {loose}"


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
    """find -depth -delete had a fixed 600 s timeout, so one big tree could run ten minutes past the budget.
    The marker probe that guards the tree is bounded the same way."""
    clock = FakeClock()
    work = Path(tempfile.mkdtemp(prefix="hhclean-test-"))
    try:
        victim = work / "tree"
        (victim / "a").mkdir(parents=True)
        (victim / "a" / "f").write_text("x")
        seen = []

        def fake_run(cmd, **kw):
            seen.append((cmd, kw.get("timeout")))
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with fake_time(hh, clock), mock.patch.object(hh.subprocess, "run", side_effect=fake_run):
            hh.set_budget(0)
            hh.apply_delete(str(victim))
            hh.set_budget(30)
            clock.now += 10
            hh.apply_delete(str(victim))
            clock.now += 19.5
            hh.apply_delete(str(victim))
        # The marker probe comes first and the delete second, and both are
        # cut to what is left of the budget.
        deletes = [t for cmd, t in seen if "-delete" in cmd]
        probes = [t for cmd, t in seen if ".janitor-keep" in cmd]
        assert deletes == [600.0, 20.0, 5.0], seen
        # The probe walks the SAME tree the delete walks, so it is a second
        # full walk of it.  It gets at most a tenth of what is left of the
        # budget, never the whole thing: 30 s of guard per candidate could
        # eat the delete reserve and free nothing.
        assert probes == [30.0, 2.0, 1.0], seen
        assert deletes[-1] == 5.0, "a floor, so a nearly spent budget still gives find a moment"
        assert probes[-1] >= 1.0, "the probe gets a floor, so it can still answer"
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


def test_the_open_handles_probes_are_cut_to_the_budget(hh):
    """The system-wide lsof (180 s) and the uncapped find (120 s) were the
    last two probes whose timeouts ignored the budget, so a candidate could
    block for three minutes while the run's hard stop closed on it.

    The bound is the SCAN share, not the whole budget.  One candidate's
    three probes add up to more than the scan share, so a probe that may
    use the whole budget lets the scan eat the time the deletes need."""
    clock = FakeClock()
    seen = []

    def fake_run(cmd, **kw):
        seen.append((cmd[0].rsplit("/", 1)[-1], kw.get("timeout")))
        # -F pfn field output: the system-wide pass lists a name, the
        # per-path pass lists pids.
        return completed(0, "p1\nn/x/blob.bin\n") if cmd[0].endswith("lsof") else completed(0, "")

    with fake_time(hh, clock), \
            mock.patch.object(hh.subprocess, "run", side_effect=fake_run):
        hh.set_budget(0)
        hh._SCAN_PHASE = True       # a probe takes the clock of its phase
        try:
            hh.open_handles("/x")
            hh.touched_since("/x", 7)
            assert seen == [("lsof", 180.0), ("find", 120.0)], seen
            seen.clear()
            hh.set_budget(40)
            clock.now += 10
            _reset_open_snapshot(hh)   # the first pass memoized its answer
            hh.open_handles("/x")
            hh.touched_since("/x", 7)
            # 40 s of budget is a 24 s scan share; 10 s of it is already gone,
            # so 14 s is left for the scan and a probe gets no more than that.
            assert [t for _n, t in seen] == [14.0, 14.0], seen
            for _name, timeout in seen:
                assert timeout <= hh.scan_budget_left(), "a probe may not outlive the scan share"
        finally:
            hh._SCAN_PHASE = False


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


def test_the_pgrep_probe_is_bounded_by_the_scan_share(hh):
    """`proc_count` passed a fixed 15s timeout, and it runs several times per
    rule (builds, dev caches, brew) from the scan, so a loaded host that makes
    pgrep hang could spend the share the deletes need -- the livelock the budget
    split exists to stop."""
    hh.set_budget(600)
    hh._SCAN_PHASE = True          # a probe takes the clock of its phase
    try:
        hh._SCAN_DEADLINE = time.monotonic() - 1.0
        with mock.patch.object(hh.subprocess, "run",
                               return_value=completed(1)) as run:
            assert hh.proc_count("xcodebuild") == 0
        assert run.call_args.kwargs["timeout"] == 1.0, "the timeout must follow the scan share"
        # A scan with its share intact still gets the usual limit.
        hh._SCAN_DEADLINE = time.monotonic() + 300.0
        with mock.patch.object(hh.subprocess, "run",
                               return_value=completed(1)) as run:
            hh.proc_count("xcodebuild")
        assert run.call_args.kwargs["timeout"] == 15.0
    finally:
        hh.set_budget(0)
        hh._SCAN_PHASE = False


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


def test_proc_count_exact_checks_the_executable_name_and_fails_closed(hh):
    with mock.patch.object(hh.subprocess, "run", return_value=completed(1)) as run:
        assert hh.proc_count_exact("xcodebuild") == 0
    assert run.call_args.args[0] == ["/usr/bin/pgrep", "-x", "xcodebuild"]
    with mock.patch.object(hh.subprocess, "run", side_effect=subprocess.TimeoutExpired("pgrep", 15)):
        assert hh.proc_count_exact("xcodebuild") == hh.PROBE_FAILED
    with mock.patch.object(hh.subprocess, "run", return_value=completed(2)):
        assert hh.proc_count_exact("xcodebuild") == hh.PROBE_FAILED


def test_dev_cache_gate_ignores_unrelated_argv_text_but_blocks_real_builder(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cache = home / "Library/Caches/node-gyp"
        cache.mkdir(parents=True)
        big = cache / "headers.tar"
        big.write_bytes(b"x" * (9 * 1024 * 1024))
        old = hh.time.time() - 5 * 3600
        os.utime(big, (old, old))
        os.utime(cache, (old, old))

        def fake_run(argv, **kwargs):
            # An idle xcodebuildmcp launcher has xcodebuild in argv, but is not
            # the xcodebuild executable.  Exact-name probes remain clear.
            if argv[1] == "-x":
                return completed(1)
            return completed(0 if argv[-1] == "xcodebuild" else 1, "123\n")

        with mock.patch.object(hh, "HOME", home), mock.patch.object(hh, "open_handles", return_value=0), \
                mock.patch.object(hh, "dir_bytes", return_value=9 * 1024 * 1024):
            with mock.patch.object(hh.subprocess, "run", side_effect=fake_run):
                assert hh.proc_count("xcodebuild") == 1  # the launcher argv contains the name
                assert [c.path for c in hh.rule_dev_caches()] == [str(cache)]

            def real_builder(argv, **kwargs):
                return completed(0, "123\n") if argv[1] == "-x" and argv[2] == "xcodebuild" else completed(1)

            with mock.patch.object(hh.subprocess, "run", side_effect=real_builder):
                assert hh.rule_dev_caches() == []
    finally:
        shutil.rmtree(home, ignore_errors=True)


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
    hh._OPEN_CWDS = set()
    hh._REPORT_DEPENDENCY_TREES = True
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


def test_app_caches_leaves_a_kept_cache_alone(hh):
    """A `.janitor-keep` marker is the operator's hands-off contract, and this
    rule deletes whole app-cache trees.  Nothing pinned that gate for this
    rule, so it could be dropped without a single test failing."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cache = home / "Library" / "Caches" / "KeptApp"
        cache.mkdir(parents=True)
        (cache / ".janitor-keep").write_text("", encoding="utf-8")
        (cache / "blob.bin").write_bytes(b"x" * 1024)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            assert hh.rule_app_caches() == [], "a kept cache is not a candidate"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_app_caches_leaves_a_cache_with_a_marker_inside_it_alone(hh):
    """A marker DEEPER in the tree protects the tree as well.  The rule deletes
    the whole tree, so a marker inside it would be deleted with the data the
    operator marked hands off, and the policy says a marked path is
    ask-first."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        cache = home / "Library" / "Caches" / "MarkedInside"
        (cache / "inner").mkdir(parents=True)
        (cache / "inner" / ".janitor-keep").write_text("", encoding="utf-8")
        (cache / "blob.bin").write_bytes(b"x" * 1024)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            assert hh.rule_app_caches() == [], "a marked tree is not a candidate"
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_a_marker_inside_a_tree_is_matched_case_insensitively(hh):
    """`find -iname` is the only thing that makes `.JANITOR-KEEP` inside a tree
    protect it.  The sibling `has_keep_sentinel` resolves the same marker with
    `Path.exists()`, which is case-insensitive on the default APFS volume, so
    with `-name` a differently cased marker was honored at a tree root and
    invisible inside one, and the walk deleted the tree and the marker
    together.  Both probes must recognize exactly the same markers."""
    root = Path(tempfile.mkdtemp(prefix="hhclean-case-"))
    try:
        (root / "inner").mkdir()
        (root / "inner" / ".JANITOR-KEEP").write_text("", encoding="utf-8")
        verdict = hh.holds_keep_sentinel(str(root), 30.0)
        assert verdict.found is True, verdict
        assert verdict.known is True, verdict
        # ...and a tree with no marker of any casing is still unmarked, so the
        # walk did not turn into "always true".
        (root / "inner" / ".JANITOR-KEEP").unlink()
        verdict = hh.holds_keep_sentinel(str(root), 30.0)
        assert verdict.found is False, verdict
        assert verdict.known is True, verdict
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_a_failed_marker_probe_is_not_a_marker(hh):
    """A probe that cannot answer is NOT the same as a probe that found a
    marker, and reading find's EXIT CODE as the answer is how an ordinary
    unreadable cache directory turned into a permanent "the operator marked
    this" block that recurred every run and reclaimed nothing.

    Measured on this Mac: 1247 real candidate trees, none exited nonzero, so
    the false positive is latent rather than active -- but the exit code is
    not a reliable answer and the report must not claim a marker that was
    never found.
    """
    def verdict_for(rc, out="", err=""):
        with mock.patch.object(hh.subprocess, "run",
                               return_value=subprocess.CompletedProcess([], rc, out, err)):
            return hh.holds_keep_sentinel("/x", 30.0)

    # find exits nonzero when it cannot read a subdirectory, and it still
    # prints every marker it did find.  The OUTPUT is the answer.
    v = verdict_for(1, "", "find: /x/inner: Permission denied")
    assert v.found is False, v
    assert v.known is True, v

    # A marker printed despite the nonzero exit is a marker.
    v = verdict_for(1, "/x/inner/.janitor-keep\n", "find: /x/inner: Permission denied")
    assert v.found is True, v
    assert v.known is True, v

    # A clean walk with no marker is a clean answer.
    v = verdict_for(0, "")
    assert v.found is False and v.known is True, v

    # A walk that failed for a reason OTHER than an unreadable subdirectory
    # is unknown, not a marker and not a clear answer.
    v = verdict_for(2, "", "find: illegal option")
    assert v.found is False, v
    assert v.known is False, v
    assert v.reason, v

    # A timeout is unknown too.
    with mock.patch.object(hh.subprocess, "run",
                           side_effect=subprocess.TimeoutExpired("find", 30)):
        v = hh.holds_keep_sentinel("/x", 30.0)
    assert v.found is False, v
    assert v.known is False, v
    assert "timed out" in v.reason, v


def test_an_unreadable_subdirectory_is_not_a_marker(hh):
    """The real thing, not a mock: a tree with an unreadable subdirectory and
    no marker anywhere.  find exits nonzero and prints nothing, and the
    verdict has to be "no marker" -- the unreadable parts are unreadable to
    the delete as well, so a marker inside one of them survives the delete
    instead of being taken with it."""
    root = Path(tempfile.mkdtemp(prefix="hhclean-perm-"))
    closed = root / "closed"
    try:
        (root / "open").mkdir()
        (root / "open" / "f.txt").write_text("x")
        closed.mkdir()
        (closed / "hidden").write_text("y")
        os.chmod(closed, 0o000)
        verdict = hh.holds_keep_sentinel(str(root), 30.0)
        assert verdict.found is False, "an unreadable subdirectory is not a marker"
        assert verdict.known is True, verdict
    finally:
        try:
            os.chmod(closed, 0o755)
        except OSError:
            pass
        shutil.rmtree(root, ignore_errors=True)


def test_the_delete_says_the_probe_failed_and_not_that_the_operator_marked_it(hh):
    """The report has to tell the two apart.  A blocked tree that was never
    marked must not be counted against the operator's marker."""
    work = Path(tempfile.mkdtemp(prefix="hhclean-fail-"))
    try:
        tree = work / "tree"
        tree.mkdir()
        (tree / "f").write_text("x")
        with mock.patch.object(hh, "holds_keep_sentinel",
                               return_value=hh.MarkerVerdict(False, False, "probe timed out")):
            freed, err = hh.apply_delete(str(tree))
        assert freed == 0, freed
        assert "probe failed" in err, err
        assert "sentinel" not in err, err
        assert tree.exists(), "an unprovable tree is never deleted"
    finally:
        shutil.rmtree(work, ignore_errors=True)


def test_the_apply_phase_does_not_walk_the_tree_again(hh):
    """The scan already asked whether the tree holds a marker, and the delete
    walks the tree anyway.  Asking again is a second full walk of the same
    tree -- measured at up to 5.99 s on one real cache tree -- so the verdict
    is carried on the candidate."""
    work = Path(tempfile.mkdtemp(prefix="hhclean-carry-"))
    try:
        tree = work / "tree"
        tree.mkdir()
        (tree / "f").write_text("x")
        with mock.patch.object(hh, "holds_keep_sentinel",
                               side_effect=AssertionError("walked the tree twice")) as probe:
            cand = hh.Candidate(category="app-caches", path=str(tree), bytes=10,
                                reason="r", keep_verdict=hh.MarkerVerdict(False, True, ""))
            hh.apply_candidate(cand)
        assert probe.call_count == 0, "the scan verdict was carried, so no second walk"
        assert not tree.exists(), "the delete still happened"
    finally:
        shutil.rmtree(work, ignore_errors=True)


def test_the_delete_refuses_a_tree_with_a_marker_inside_it(hh):
    """`apply_delete` is the choke point every delete passes through, so the
    check lands there and covers every rule, not only the new ones."""
    root = Path(tempfile.mkdtemp(prefix="hhclean-del-"))
    try:
        tree = root / "tree"
        (tree / "inner").mkdir(parents=True)
        (tree / "inner" / ".janitor-keep").write_text("", encoding="utf-8")
        (tree / "blob.bin").write_bytes(b"x" * 1024)
        freed, err = hh.apply_delete(str(tree))
        assert freed == 0, "nothing was deleted"
        assert "janitor-keep" in err, err
        assert tree.exists(), "the tree is still there"
        assert (tree / "inner" / ".janitor-keep").exists(), "the marker is still there"
    finally:
        shutil.rmtree(root, ignore_errors=True)


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
             mock.patch.object(hh, "touched_since", return_value=False) as touched, \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            found = hh.rule_app_caches()
        assert [c.path for c in found] == [str(cache)]
        assert found[0].category == "app-caches"
        assert found[0].tier == "safe"
        assert found[0].op == "delete"
        # The window is the gate: a wider one would delete a cache the app
        # wrote to in the last 90 minutes.
        touched.assert_called_once_with(str(cache), hh.IDLE_MIN_OK / (24 * 60))
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _hoghunter_debug_builds(home):
    root = home / "Library" / "Caches" / "HogHunterDerivedData"
    for lane in ("lane-one-aaaa", "lane-two-bbbb"):
        (root / lane).mkdir(parents=True)
        (root / lane / "blob.bin").write_bytes(b"x" * 1024)
    return root


def test_xcode_artifacts_sweeps_each_idle_hoghunter_checkout(hh):
    """Debug builds moved to the internal disk to stop permission prompts, at
    about 3.8 GB per lane, so they have to go when idle."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        root = _hoghunter_debug_builds(home)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "proc_count", return_value=0), \
             mock.patch.object(hh, "proc_count_exact", return_value=0), \
             mock.patch.object(hh, "tree_in_use", return_value=False), \
             mock.patch.object(hh, "touched_since", return_value=False) as touched, \
             mock.patch.object(hh, "dir_bytes", return_value=4 * 1024 ** 3):
            found = hh.rule_xcode_artifacts()
        assert sorted(c.path for c in found) == [str(root / "lane-one-aaaa"), str(root / "lane-two-bbbb")]
        assert {c.category for c in found} == {"xcode-artifacts"}
        assert {c.tier for c in found} == {"safe"}
        touched.assert_any_call(str(root / "lane-one-aaaa"), hh.IDLE_MIN_OK / (24 * 60))
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_xcode_artifacts_keeps_hoghunter_checkouts_during_a_build(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        _hoghunter_debug_builds(home)
        for busy in ("xcodebuild", "clang", "swift-frontend"):
            with mock.patch.object(hh, "HOME", home), \
                 mock.patch.object(hh, "proc_count", side_effect=lambda name: int(name == busy)), \
                 mock.patch.object(hh, "proc_count_exact", side_effect=lambda name: int(name == busy)), \
                 mock.patch.object(hh, "tree_in_use", return_value=False), \
                 mock.patch.object(hh, "touched_since", return_value=False):
                assert hh.rule_xcode_artifacts() == [], busy
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_xcode_artifacts_reads_a_failed_build_probe_as_busy(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        _hoghunter_debug_builds(home)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "proc_count", return_value=hh.PROBE_FAILED), \
             mock.patch.object(hh, "proc_count_exact", return_value=hh.PROBE_FAILED), \
             mock.patch.object(hh, "tree_in_use", return_value=False), \
             mock.patch.object(hh, "touched_since", return_value=False):
            assert hh.rule_xcode_artifacts() == []
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_one_busy_hoghunter_checkout_does_not_keep_the_others(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        root = _hoghunter_debug_builds(home)
        busy, held = str(root / "lane-one-aaaa"), str(root / "lane-two-bbbb")
        idle = root / "lane-three-cccc"
        idle.mkdir()
        (idle / "blob.bin").write_bytes(b"x")
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "proc_count", return_value=0), \
             mock.patch.object(hh, "proc_count_exact", return_value=0), \
             mock.patch.object(hh, "tree_in_use", side_effect=lambda p: p == held), \
             mock.patch.object(hh, "touched_since", side_effect=lambda p, _d: p == busy), \
             mock.patch.object(hh, "dir_bytes", return_value=4 * 1024 ** 3):
            found = hh.rule_xcode_artifacts()
        assert [c.path for c in found] == [str(idle)]
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_a_keep_marker_protects_a_hoghunter_checkout(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        root = _hoghunter_debug_builds(home)
        (root / "lane-one-aaaa" / "Build").mkdir()
        (root / "lane-one-aaaa" / "Build" / hh.KEEP_SENTINEL).write_text("")
        (root / "lane-two-bbbb" / hh.KEEP_SENTINEL).write_text("")
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "proc_count", return_value=0), \
             mock.patch.object(hh, "proc_count_exact", return_value=0), \
             mock.patch.object(hh, "tree_in_use", return_value=False), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=4 * 1024 ** 3):
            assert hh.rule_xcode_artifacts() == []
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_a_failed_lsof_listing_keeps_a_hoghunter_checkout(hh):
    """The per-path fallback cannot see a Debug host running from deep in the
    tree, so a listing that failed has to read as in use."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        _hoghunter_debug_builds(home)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "proc_count", return_value=0), \
             mock.patch.object(hh, "proc_count_exact", return_value=0), \
             mock.patch.object(hh, "_load_open_snapshot", return_value=None), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=4 * 1024 ** 3):
            assert hh.rule_xcode_artifacts() == []
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _hoghunter_lane_candidate(hh, home):
    """One lane the scan accepted, and the root it lives in."""
    root = _hoghunter_debug_builds(home)
    shutil.rmtree(root / "lane-two-bbbb")
    with mock.patch.object(hh, "HOME", home), \
         mock.patch.object(hh, "proc_count", return_value=0), \
         mock.patch.object(hh, "proc_count_exact", return_value=0), \
         mock.patch.object(hh, "tree_in_use", return_value=False), \
         mock.patch.object(hh, "touched_since", return_value=False), \
         mock.patch.object(hh, "dir_bytes", return_value=4 * 1024 ** 3):
        found = hh.rule_xcode_artifacts()
    assert len(found) == 1, found
    return found[0], root / "lane-one-aaaa"


def _apply_with_open_gates(hh, candidate, **overrides):
    gates = {"proc_count": 0, "proc_count_exact": 0, "tree_in_use": False, "touched_since": False}
    gates.update(overrides)
    with mock.patch.object(hh, "proc_count", return_value=gates["proc_count"]), \
         mock.patch.object(hh, "proc_count_exact", return_value=gates["proc_count_exact"]), \
         mock.patch.object(hh, "tree_in_use", return_value=gates["tree_in_use"]), \
         mock.patch.object(hh, "touched_since", return_value=gates["touched_since"]):
        hh.apply_candidate(candidate)


def test_a_hoghunter_checkout_is_deleted_when_its_gates_still_hold(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        candidate, lane = _hoghunter_lane_candidate(hh, home)
        assert candidate.recheck is not None
        _apply_with_open_gates(hh, candidate)
        assert candidate.applied, candidate
        assert not candidate.refused
        assert not lane.exists()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_a_build_started_after_the_scan_keeps_a_hoghunter_checkout(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        for probe in ("proc_count", "proc_count_exact"):
            candidate, lane = _hoghunter_lane_candidate(hh, home)
            _apply_with_open_gates(hh, candidate, **{probe: 1})
            assert candidate.refused == "a build is running", candidate
            assert not candidate.applied
            assert lane.is_dir()
            shutil.rmtree(lane.parent)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_a_hoghunter_checkout_used_after_the_scan_is_kept(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        for gate, why in (("touched_since", "touched in the last 90 minutes"), ("tree_in_use", "held open")):
            candidate, lane = _hoghunter_lane_candidate(hh, home)
            _apply_with_open_gates(hh, candidate, **{gate: True})
            assert candidate.refused == why, candidate
            assert lane.is_dir()
            shutil.rmtree(lane.parent)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_a_keep_marker_added_after_the_scan_keeps_a_hoghunter_checkout(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        candidate, lane = _hoghunter_lane_candidate(hh, home)
        (lane / "Build").mkdir()
        (lane / "Build" / hh.KEEP_SENTINEL).write_text("")
        _apply_with_open_gates(hh, candidate)
        assert candidate.refused, candidate
        assert not candidate.applied
        assert (lane / "Build" / hh.KEEP_SENTINEL).exists()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_a_hoghunter_checkout_swapped_after_the_scan_is_kept(hh):
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        candidate, lane = _hoghunter_lane_candidate(hh, home)
        shutil.rmtree(lane)
        lane.mkdir()
        (lane / "other.bin").write_bytes(b"x")
        _apply_with_open_gates(hh, candidate)
        assert candidate.refused == "the path now holds something else", candidate
        assert (lane / "other.bin").exists()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_app_caches_leaves_the_hoghunter_debug_builds_to_xcode_artifacts(hh):
    """app-caches has no build gate and would treat every lane as one tree."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        _hoghunter_debug_builds(home)
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=4 * 1024 ** 3):
            assert hh.rule_app_caches() == []
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_app_caches_stops_at_its_own_deadline(hh):
    """Every candidate pays for two uncapped probes, so the rule's candidate
    loop has to consult the scan deadline itself.  Otherwise one rule overruns
    the 60% scan share inside the rule and the deletes get nothing."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    clock = FakeClock()
    try:
        root = home / "Library" / "Caches"
        root.mkdir(parents=True)
        for name in ("One", "Two", "Three"):
            (root / name).mkdir()
        probes = []

        def probing_age(_path, *a, **k):
            probes.append(_path)
            clock.now += 3.0     # three candidates x 3 s past a 6 s scan share
            return 10 ** 9

        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", probing_age), \
             mock.patch.object(hh, "touched_since", return_value=False), \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            with fake_time(hh, clock):
                hh.set_budget(10.0)
                found = hh.rule_app_caches()
                exhausted = hh._SCAN_BUDGET_EXHAUSTED
        assert len(probes) < 3, f"the loop kept probing past its deadline: {probes}"
        assert exhausted is True, "a truncated scan has to say so"
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
             mock.patch.object(hh, "touched_since", return_value=True) as touched, \
             mock.patch.object(hh, "dir_bytes", return_value=64 * 1024 * 1024):
            assert hh.rule_app_caches() == [], "a cache with a recent write is not idle"
            # The window is the gate, and this is the destructive path: a
            # wider one would delete a cache the app wrote to recently.
            touched.assert_called_once_with(str(cache), hh.IDLE_MIN_OK / (24 * 60))
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


def test_agent_state_does_not_call_a_big_active_tree_idle(hh):
    """newest_file_age_min stops after 4000 entries, so an agent tree bigger
    than that can hide a recent write past the cap and read as idle.  The
    uncapped touched_since probe answers on the first recent file, so a tree
    the agent is still writing to is left alone."""
    home = Path(tempfile.mkdtemp(prefix="hhclean-home-"))
    try:
        logs = home / ".claude" / "logs"
        logs.mkdir(parents=True)
        (logs / "a.log").write_text("x", encoding="utf-8")
        with mock.patch.object(hh, "HOME", home), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
             mock.patch.object(hh, "touched_since", return_value=True) as touched, \
             mock.patch.object(hh, "dir_bytes", return_value=128 * 1024 * 1024):
            assert hh.rule_agent_state() == [], "a tree with a recent write is not idle"
            # The window is the gate: a wider one would delete a tree the
            # agent wrote to in the last 90 minutes.
            touched.assert_called_once_with(str(logs), hh.IDLE_MIN_OK / (24 * 60))
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


def test_codex_markers_are_held_until_idle_and_unheld(hh):
    """The Codex markers are files, so the scratch gate reads the file itself.  A marker
    touched just now or still held open belongs to a running Codex, and only an old
    marker nobody holds is a candidate."""
    root = Path(tempfile.mkdtemp(prefix="hhclean-codex-"))
    try:
        fresh = root / ".com.openai.codex.fresh"
        idle = root / ".com.openai.codex.idle"
        held = root / ".com.openai.codex.held"
        for path in (fresh, idle, held):
            path.write_text("x\n", encoding="utf-8")
        old = time.time() - 4 * 3600
        for path in (idle, held):
            os.utime(path, (old, old))

        def handles(path):
            return 1 if path == str(held) else 0

        with mock.patch.object(hh, "_run", return_value=f"{root}/\n"), \
             mock.patch.object(hh, "open_handles", side_effect=handles), \
             mock.patch.object(hh, "rule_deadline", return_value=time.time() + 60):
            found = hh.rule_temp_scratch()
        by_path = {c.path: c for c in found if c.category == "temp-scratch"}
        assert str(idle) in by_path, by_path
        assert str(fresh) not in by_path, "a marker touched just now is not idle"
        assert str(held) not in by_path, "a marker still held open is not a candidate"
        assert by_path[str(idle)].reason == "Codex per-run marker file, no handles, idle over 3h"
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_codex_markers_respect_keep_sentinel_and_forbidden_paths(hh):
    """An old, unheld marker is still left alone when the operator marked its parent or
    policy forbids the path.  The scratch rules around it already honour both gates."""
    root = Path(tempfile.mkdtemp(prefix="hhclean-codex-"))
    try:
        marker = root / ".com.openai.codex.kept"
        marker.write_text("x\n", encoding="utf-8")
        old = time.time() - 4 * 3600
        os.utime(marker, (old, old))
        (root / ".janitor-keep").write_text("", encoding="utf-8")
        with mock.patch.object(hh, "_run", return_value=f"{root}/\n"), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "rule_deadline", return_value=time.time() + 60):
            kept = hh.rule_temp_scratch()
        assert str(marker) not in {c.path for c in kept}, "a kept marker is not a candidate"
        (root / ".janitor-keep").unlink()
        with mock.patch.object(hh, "_run", return_value=f"{root}/\n"), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "rule_deadline", return_value=time.time() + 60), \
             mock.patch.object(hh, "is_forbidden", side_effect=lambda path: path == str(marker)):
            forbidden = hh.rule_temp_scratch()
        assert str(marker) not in {c.path for c in forbidden}, "a forbidden marker is not a candidate"
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_codex_markers_stop_at_the_rule_deadline(hh):
    """The marker loop stops when the rule deadline has passed, like the loops
    above it.  A scan out of time returns what it found instead of walking on."""
    root = Path(tempfile.mkdtemp(prefix="hhclean-codex-"))
    try:
        marker = root / ".com.openai.codex.idle"
        marker.write_text("x\n", encoding="utf-8")
        old = time.time() - 4 * 3600
        os.utime(marker, (old, old))
        with mock.patch.object(hh, "_run", return_value=f"{root}/\n"), \
             mock.patch.object(hh, "open_handles", return_value=0), \
             mock.patch.object(hh, "rule_deadline", return_value=time.time() - 1):
            found = hh.rule_temp_scratch()
        assert str(marker) not in {c.path for c in found}, "the deadline is spent, so no marker is chosen"
    finally:
        shutil.rmtree(root, ignore_errors=True)


# --------------------------------------------------------------------------
# HH-213: the rules for the hogs the engine used to miss.  Fake homes and
# injected commands only: nothing here reads the real disk or runs simctl.
# --------------------------------------------------------------------------

RUNTIME_A = "14C02085-0000-4000-8000-000000000001"
RUNTIME_B = "9BB3D710-0000-4000-8000-000000000002"
IOS_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
GIB = 1024 ** 3
SIMCTL_FAILED = object()


def runtime_image(identifier, build, last_used="2026-11-04T10:00:00Z", **over):
    image = {"identifier": identifier, "build": build, "deletable": True, "kind": "Disk Image",
             "lastUsedAt": last_used, "runtimeIdentifier": IOS_RUNTIME, "sizeBytes": 8 * GIB,
             "state": "Ready", "version": "27.2"}
    image.update(over)
    return image


class FakeSimctl:
    """Answers simctl from canned JSON and records every call."""

    def __init__(self, images=None, match=None, devices=None):
        self.images = images if images is not None else {
            RUNTIME_A: runtime_image(RUNTIME_A, "24B8117"),
            RUNTIME_B: runtime_image(RUNTIME_B, "24B91016s", last_used=None),
        }
        self.match = match if match is not None else {
            "iphoneos27.2": {"chosenRuntimeBuild": "24B8117", "sdkVersion": "27.2"}}
        self.devices = devices if devices is not None else {"devices": {IOS_RUNTIME: []}}
        self.calls = []

    @staticmethod
    def _answer(value):
        if value is SIMCTL_FAILED:
            return None
        return value if isinstance(value, str) else json.dumps(value)

    def __call__(self, args, timeout):
        args = list(args)
        self.calls.append(args)
        if args[:2] == ["list", "devices"]:
            return self._answer(self.devices)
        if args[:2] == ["runtime", "list"]:
            return self._answer(self.images)
        if args[:3] == ["runtime", "match", "list"]:
            return self._answer(self.match)
        if args[:2] == ["runtime", "delete"]:
            self.images.pop(args[2], None)
            return ""
        raise AssertionError(f"unexpected simctl call {args}")

    def deletes(self):
        return [c for c in self.calls if c[:2] == ["runtime", "delete"]]


@contextlib.contextmanager
def simctl_env(hh, fake, exact=0, pattern=0):
    with mock.patch.object(hh, "_simctl", fake), \
            mock.patch.object(hh, "proc_count_exact", return_value=exact) as exact_mock, \
            mock.patch.object(hh, "proc_count", return_value=pattern), \
            mock.patch.object(hh, "_simulator_service_alive", return_value=True, create=True), \
            mock.patch.object(hh, "_installed_xcodes", return_value=["/Applications/Xcode.app"], create=True), \
            mock.patch.object(hh, "read_disk_free", return_value=10.0, create=True):
        yield exact_mock


def test_duplicate_runtimes_picks_the_unused_image_and_never_the_chosen_one(hh):
    fake = FakeSimctl()
    with simctl_env(hh, fake):
        found = hh.rule_duplicate_sim_runtimes()
    assert [c.path for c in found] == [f"sim-runtime:{RUNTIME_B}"], found
    c = found[0]
    assert (c.tier, c.op, c.bytes, c.category) == (
        "semi-safe", "simctl-runtime-delete", 8 * GIB, "duplicate-sim-runtimes")
    assert fake.deletes() == [], "a scan deletes nothing"


def test_duplicate_runtimes_picks_an_image_older_than_the_most_recent(hh):
    fake = FakeSimctl(images={
        RUNTIME_A: runtime_image(RUNTIME_A, "24B8117", last_used="2026-11-01T10:00:00Z"),
        RUNTIME_B: runtime_image(RUNTIME_B, "24B91016s", last_used="2026-10-01T10:00:00Z"),
    })
    with simctl_env(hh, fake):
        assert [c.path for c in hh.rule_duplicate_sim_runtimes()] == [f"sim-runtime:{RUNTIME_B}"]


def test_duplicate_runtimes_keeps_the_most_recent_even_when_it_is_not_chosen(hh):
    fake = FakeSimctl(images={
        RUNTIME_A: runtime_image(RUNTIME_A, "24B8117", last_used="2026-10-01T10:00:00Z"),
        RUNTIME_B: runtime_image(RUNTIME_B, "24B91016s", last_used="2026-11-01T10:00:00Z"),
    })
    with simctl_env(hh, fake):
        assert hh.rule_duplicate_sim_runtimes() == []


def test_duplicate_runtimes_refusals(hh):
    one = {RUNTIME_A: runtime_image(RUNTIME_A, "24B8117")}
    other_version = {
        RUNTIME_A: runtime_image(RUNTIME_A, "24B8117"),
        RUNTIME_B: runtime_image(RUNTIME_B, "24A1", last_used=None, version="27.1"),
    }
    not_deletable = {
        RUNTIME_A: runtime_image(RUNTIME_A, "24B8117"),
        RUNTIME_B: runtime_image(RUNTIME_B, "24B91016s", last_used=None, deletable=False),
    }
    deletable_text = {
        RUNTIME_A: runtime_image(RUNTIME_A, "24B8117"),
        RUNTIME_B: runtime_image(RUNTIME_B, "24B91016s", last_used=None, deletable="true"),
    }
    other_not_ready = {
        RUNTIME_A: runtime_image(RUNTIME_A, "24B8117", state="Unusable"),
        RUNTIME_B: runtime_image(RUNTIME_B, "24B91016s", last_used=None),
    }
    both_chosen = FakeSimctl(match={"a": {"chosenRuntimeBuild": "24B8117"},
                                    "b": {"chosenRuntimeBuild": "24B91016s"}})
    cases = {
        "only one image": FakeSimctl(images=one),
        "another version is no duplicate": FakeSimctl(images=other_version),
        "not deletable": FakeSimctl(images=not_deletable),
        "deletable must be true, not truthy": FakeSimctl(images=deletable_text),
        "the other image is not Ready": FakeSimctl(images=other_not_ready),
        "chosen image is the unused one": FakeSimctl(
            match={"iphoneos27.2": {"chosenRuntimeBuild": "24B91016s"}}),
        "both are chosen by some SDK": both_chosen,
        "a simulator is booted": FakeSimctl(
            devices={"devices": {IOS_RUNTIME: [{"state": "Booted", "udid": "x"}]}}),
    }
    for why, fake in cases.items():
        with simctl_env(hh, fake):
            assert hh.rule_duplicate_sim_runtimes() == [], why


def test_duplicate_runtimes_refuses_while_a_build_or_simulator_runs(hh):
    for name in ("xcodebuild", "Simulator"):
        fake = FakeSimctl()
        with mock.patch.object(hh, "_simctl", fake), \
                mock.patch.object(hh, "proc_count", return_value=0), \
                mock.patch.object(hh, "proc_count_exact", side_effect=lambda n: int(n == name)):
            assert hh.rule_duplicate_sim_runtimes() == [], name
    # A failed look at the process table is a busy answer.
    with simctl_env(hh, FakeSimctl(), exact=hh.PROBE_FAILED):
        assert hh.rule_duplicate_sim_runtimes() == []


def test_duplicate_runtimes_fails_closed_on_bad_tool_output(hh):
    good_a = runtime_image(RUNTIME_A, "24B8117")
    good_b = runtime_image(RUNTIME_B, "24B91016s", last_used=None)
    cases = {
        "list is not JSON": FakeSimctl(images="not json {"),
        "list failed": FakeSimctl(images=SIMCTL_FAILED),
        "list is empty": FakeSimctl(images={}),
        "list is an array": FakeSimctl(images="[]"),
        "match is not JSON": FakeSimctl(match="<<<"),
        "match failed": FakeSimctl(match=SIMCTL_FAILED),
        "match is empty": FakeSimctl(match={}),
        "match has no chosen build": FakeSimctl(match={"iphoneos27.2": {"defaultBuild": "24B8117"}}),
        "chosen build is empty": FakeSimctl(match={"iphoneos27.2": {"chosenRuntimeBuild": ""}}),
        "chosen build is not installed": FakeSimctl(match={"iphoneos27.2": {"chosenRuntimeBuild": "24B8118"}}),
        "devices are not JSON": FakeSimctl(devices="nope"),
        "devices failed": FakeSimctl(devices=SIMCTL_FAILED),
        "devices have no devices key": FakeSimctl(devices={"other": {}}),
        "an image is not an object": FakeSimctl(images={RUNTIME_A: good_a, RUNTIME_B: "text"}),
        "lastUsedAt is garbage": FakeSimctl(images={
            RUNTIME_A: good_a, RUNTIME_B: runtime_image(RUNTIME_B, "24B91016s", last_used="yesterday")}),
        "lastUsedAt is a number": FakeSimctl(images={
            RUNTIME_A: good_a, RUNTIME_B: runtime_image(RUNTIME_B, "24B91016s", last_used=12)}),
        "no runtime identifier": FakeSimctl(images={
            RUNTIME_A: good_a, RUNTIME_B: {k: v for k, v in good_b.items() if k != "runtimeIdentifier"}}),
        "no build": FakeSimctl(images={
            RUNTIME_A: good_a, RUNTIME_B: {k: v for k, v in good_b.items() if k != "build"}}),
        "no reported size": FakeSimctl(images={
            RUNTIME_A: good_a, RUNTIME_B: {k: v for k, v in good_b.items() if k != "sizeBytes"}}),
        "size is a string": FakeSimctl(images={
            RUNTIME_A: good_a, RUNTIME_B: dict(good_b, sizeBytes="8")}),
        "identifier could be read as a flag": FakeSimctl(images={
            RUNTIME_A: good_a, RUNTIME_B: dict(good_b, identifier="--notUsedSinceDays")}),
    }
    for why, fake in cases.items():
        with simctl_env(hh, fake):
            assert hh.rule_duplicate_sim_runtimes() == [], why
        assert fake.deletes() == [], why


def test_duplicate_runtime_delete_goes_through_simctl_and_is_verified(hh):
    fake = FakeSimctl()
    with simctl_env(hh, fake):
        c = hh.rule_duplicate_sim_runtimes()[0]
        hh.apply_candidate(c)
    assert fake.deletes() == [["runtime", "delete", RUNTIME_B]], fake.calls
    assert c.applied and not c.error, c.error
    assert c.bytes == 8 * GIB, "the reported size stands"


def test_duplicate_runtime_delete_is_refused_when_things_change_after_the_scan(hh):
    fake = FakeSimctl()
    with simctl_env(hh, fake):
        c = hh.rule_duplicate_sim_runtimes()[0]
        fake.devices = {"devices": {IOS_RUNTIME: [{"state": "Booted"}]}}
        hh.apply_candidate(c)
    assert fake.deletes() == [], "a simulator booted after the scan stops the delete"
    assert not c.applied and c.refused and not c.error, (c.refused, c.error)

    fake = FakeSimctl()
    with simctl_env(hh, fake):
        c = hh.rule_duplicate_sim_runtimes()[0]
        fake.match = {"iphoneos27.2": {"chosenRuntimeBuild": "24B91016s"}}
        hh.apply_candidate(c)
    assert fake.deletes() == [], "the chooser moved onto it"


def test_duplicate_runtime_delete_reports_a_delete_that_did_not_take(hh):
    fake = FakeSimctl()
    real_call = fake.__call__

    def keeps_the_image(args, timeout):
        if list(args)[:2] == ["runtime", "delete"]:
            fake.calls.append(list(args))
            return ""
        return real_call(args, timeout)

    with simctl_env(hh, keeps_the_image):
        c = hh.rule_duplicate_sim_runtimes()[0]
        hh.apply_candidate(c)
    assert not c.applied and "still present" in c.error, c.error

    def fails(args, timeout):
        return None if list(args)[:2] == ["runtime", "delete"] else real_call(args, timeout)

    with simctl_env(hh, fails):
        c = hh.rule_duplicate_sim_runtimes()[0]
        hh.apply_candidate(c)
    assert not c.applied and "failed" in c.error, c.error


def test_new_rules_scan_makes_no_change(hh):
    """--scan with every new rule, on a fake home where each one has work."""
    with fake_home(hh) as home, gates_open(hh):
        version_store(home)
        tree = xcode_tree(home)
        repo = git_repo(home / "Code" / "App")
        target = old_tree(repo / ".build")
        before = sorted(str(p) for p in home.rglob("*"))
        fake = FakeSimctl()
        out, err = io.StringIO(), io.StringIO()
        band = hh.Band(100.0, 50.0, 0.0, 1.0, False, cpu_idle_pct=50.0)
        with mock.patch.object(hh, "_simctl", fake), \
                mock.patch.object(hh, "read_band", return_value=band), \
                mock.patch.object(hh, "apply_delete", side_effect=AssertionError("deleted in a scan")), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = hh.main(["--scan", "--json", "--band=full",
                            "--categories=duplicate-sim-runtimes,tool-versions,xcode-scratch,stale-build-output"])
        assert code == 0
        report = json.loads(out.getvalue())
        names = {c["category"] for c in report["candidates"]}
        assert names == {"duplicate-sim-runtimes", "tool-versions", "xcode-scratch", "stale-build-output"}, names
        assert report["applied_count"] == 0
        assert sorted(str(p) for p in home.rglob("*")) == before, "the fake home changed"
        assert fake.deletes() == []
        assert tree.is_dir() and target.is_dir()


def test_semi_safe_rules_wait_for_the_full_band(hh):
    clock = FakeClock()
    band = hh.Band(20.0, 50.0, 0.0, 1.0, False, cpu_idle_pct=50.0)
    runtime = hh.Candidate("duplicate-sim-runtimes", f"sim-runtime:{RUNTIME_B}", GIB, "x",
                           tier="semi-safe", op="simctl-runtime-delete")
    snapshot = hh.Candidate("snapshots", "apfs-snapshot:x", 0, "x", tier="semi-safe", op="snapshot-delete")
    _code, cheap, _err = run_main(hh, ["--clean", "--json"], [runtime, snapshot], band, clock)
    assert cheap["applied_count"] == 0, "the watch's cheap band never reaches semi-safe"
    _code, full, _err = run_main(hh, ["--clean", "--json", "--band=full"], [runtime, snapshot], band, clock)
    assert full["applied_count"] == 2


# --- a fake home ----------------------------------------------------------

@contextlib.contextmanager
def fake_home(hh):
    """A temporary home, with /private/tmp's rule pointed inside it.

    `realpath` so a macOS temp path spelled through /var compares equal to the
    resolved spelling, and the tree walks see no symlink above the home.
    """
    home = Path(os.path.realpath(tempfile.mkdtemp(prefix="hhclean-home-")))
    scratch = home / "private-tmp"
    scratch.mkdir()
    (home / "Code").mkdir()
    try:
        with mock.patch.object(hh, "HOME", home), mock.patch.object(hh, "XCODE_SCRATCH_ROOT", scratch):
            hh._STALE_BUILD_MEMO.clear()
            yield home
    finally:
        shutil.rmtree(home, ignore_errors=True)


@contextlib.contextmanager
def gates_open(hh):
    """Every process and handle probe says quiet, and ctime cannot be faked."""
    with mock.patch.object(hh, "tree_in_use", return_value=False), \
            mock.patch.object(hh, "process_names_path", return_value=False), \
            mock.patch.object(hh, "_build_running", return_value=False), \
            mock.patch.object(hh, "changed_age_min", return_value=10.0 ** 9), \
            mock.patch.object(hh, "proc_count_exact", return_value=0), \
            mock.patch.object(hh, "proc_count", return_value=0), \
            mock.patch.object(hh, "repo_has_process_cwd", return_value=False, create=True), \
            mock.patch.object(hh, "_simulator_service_alive", return_value=True, create=True), \
            mock.patch.object(hh, "_installed_xcodes", return_value=["/Applications/Xcode.app"], create=True), \
            mock.patch.object(hh, "read_disk_free", return_value=10.0, create=True):
        yield


def age(path, days):
    when = time.time() - days * 24 * 3600
    os.utime(path, (when, when))


def blob(path, days=30, size=64 * 1024 * 1024):
    """A sparse file: 64 MiB by st_size, which is what dir_bytes reads."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as fh:
        fh.truncate(size)
    age(path, days)
    return path


def old_tree(path, days=30):
    blob(path / "out.o", days)
    return path


def age_all(path, days):
    """Everything under path, as if it had sat there this long."""
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            full = os.path.join(root, name)
            if not os.path.islink(full):
                age(full, days)


def run_git(repo, *args):
    subprocess.run(["/usr/bin/git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.com",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)


def git_repo(path, ignore=".build/\n.next/\nbuild/\ntarget/\ndist/\nnode_modules/\n"):
    path.mkdir(parents=True)
    run_git(path, "init", "-q")
    (path / ".gitignore").write_text(ignore, encoding="utf-8")
    (path / "main.swift").write_text("print(1)\n", encoding="utf-8")
    run_git(path, "add", ".")
    run_git(path, "commit", "-q", "-m", "first")
    return path


def rule_paths(found):
    return {c.path for c in found}


# --- peer work ------------------------------------------------------------

def test_peer_work_is_forbidden_at_the_delete_choke_point(hh):
    with fake_home(hh) as home:
        for rel in ("Code/BotFleet/.muse/worktrees/mc-one", "apps/botfleet-mm-mcode"):
            tree = old_tree(home / rel)
            assert hh.is_forbidden(str(tree)), rel
            freed, err = hh.apply_delete(str(tree))
            assert (freed, err) == (0, "forbidden path"), rel
            assert tree.is_dir(), rel
        rollback = home / "apps/.botfleet-server.node_modules.rollback-1"
        assert not hh.is_forbidden(str(rollback)), "the rollback rule's own path stays open"
        assert not hh.is_forbidden(str(home / "Code/App/.build"))


# --- agent-state .tmp -----------------------------------------------------

@contextlib.contextmanager
def agent_gates(hh):
    with mock.patch.object(hh, "open_handles", return_value=0), \
            mock.patch.object(hh, "newest_file_age_min", return_value=10 ** 9), \
            mock.patch.object(hh, "touched_since", return_value=False), \
            mock.patch.object(hh, "dir_bytes", return_value=128 * 1024 * 1024):
        yield


def test_agent_state_refuses_a_tree_that_holds_a_checkout(hh):
    """A clone is not scratch whatever its folder is called."""
    with fake_home(hh) as home:
        tmp = home / ".codex" / "tmp"
        (tmp / "marketplaces" / "composio" / ".git").mkdir(parents=True)
        with agent_gates(hh):
            assert hh.rule_agent_state() == [], "a checkout inside is not scratch"
        shutil.rmtree(tmp / "marketplaces")
        # A linked worktree's `.git` is a file, and it counts the same.
        (tmp / "deep" / "er" / "lane").mkdir(parents=True)
        (tmp / "deep" / "er" / "lane" / ".git").write_text("gitdir: /x\n", encoding="utf-8")
        with agent_gates(hh):
            assert hh.rule_agent_state() == [], "a linked worktree inside is not scratch"


def test_agent_state_tmp_keeps_the_existing_gates(hh):
    with fake_home(hh) as home:
        tmp = home / ".codex" / "tmp"
        tmp.mkdir(parents=True)
        (tmp / "x").write_text("x", encoding="utf-8")
        with agent_gates(hh), mock.patch.object(hh, "open_handles", return_value=1):
            assert hh.rule_agent_state() == [], "held open"
        with agent_gates(hh), mock.patch.object(hh, "touched_since", return_value=True):
            assert hh.rule_agent_state() == [], "recently written"
        (tmp / "proj").mkdir()
        (tmp / "proj" / ".project_root").write_text("/x\n", encoding="utf-8")
        with agent_gates(hh):
            assert hh.rule_agent_state() == [], "an agent's project working tree"
        (tmp / "proj" / ".project_root").unlink()
        (tmp / "proj" / hh.KEEP_SENTINEL).write_text("", encoding="utf-8")
        with agent_gates(hh):
            assert hh.rule_agent_state() == [], "a keep marker inside"


def test_agent_state_refuses_when_the_checkout_probe_cannot_answer(hh):
    with fake_home(hh) as home:
        tmp = home / ".codex" / "tmp"
        tmp.mkdir(parents=True)
        real = hh.holds_keep_sentinel

        def git_probe_fails(path, timeout, name=hh.KEEP_SENTINEL):
            if name == ".git":
                return hh.MarkerVerdict(False, False, "probe timed out")
            return real(path, timeout)

        with agent_gates(hh), mock.patch.object(hh, "holds_keep_sentinel", side_effect=git_probe_fails):
            assert hh.rule_agent_state() == []


# --- tool-versions --------------------------------------------------------

def version_store(home):
    """The Claude Code layout: three versions, the newest linked from bin."""
    store = home / ".local/share/claude/versions"
    for name, days in (("2.1.301", 30), ("2.1.302", 20), ("2.1.303", 10)):
        blob(store / name, days)
    bin_dir = home / ".local/bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / "claude").symlink_to(store / "2.1.303")
    return store


def cursor_store(home):
    store = home / ".local/share/cursor-agent/versions"
    for name, days in ((".2026.08.31-4057e58", 60), ("2026.08.01-aaaaaaa", 90),
                       ("2026.09.26-dd393fe", 30), ("2026.10.14-941492e", 20)):
        old_tree(store / name, days)
        age(store / name, days)
    bin_dir = home / ".local/bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / "cursor-agent").symlink_to(store / "2026.10.14-941492e" / "out.o")
    return store


def muse_store(home, active="1.4.14-R7309.1"):
    bin_dir = home / ".local/bin"
    for version, days in (("1.4.10-R1", 40), ("1.4.12-R2.1", 30), ("1.4.14-R7309.1", 20)):
        blob(bin_dir / f"muse-bin-{version}", days)
    (bin_dir / "muse").write_text("#!/bin/bash\n", encoding="utf-8")
    (bin_dir / ".muse-version").write_text(active + "\n", encoding="utf-8")
    return bin_dir


def test_tool_versions_keeps_the_two_newest_and_what_a_symlink_names(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        found = hh.rule_tool_versions()
        assert rule_paths(found) == {str(store / "2.1.301")}, found
        assert found[0].tier == "safe" and found[0].op == "delete"
        hh.apply_candidate(found[0])
        assert found[0].applied, found[0].error
        assert not (store / "2.1.301").exists() and (store / "2.1.302").exists()
        assert (store / "2.1.303").exists()


def test_tool_versions_a_symlink_keeps_an_old_version(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        (home / ".local/bin/claude-old").symlink_to(store / "2.1.301")
        assert hh.rule_tool_versions() == []


def test_tool_versions_needs_to_know_which_version_is_live(hh):
    with fake_home(hh) as home, gates_open(hh):
        version_store(home)
        (home / ".local/bin/claude").unlink()
        assert hh.rule_tool_versions() == [], "no symlink means nobody knows what is active"


def test_tool_versions_leaves_an_ambiguous_layout_alone(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        (store / "notes.txt").write_text("x", encoding="utf-8")
        assert hh.rule_tool_versions() == [], "a store that holds more than versions"
        (store / "notes.txt").unlink()
        (store / ".DS_Store").write_text("x", encoding="utf-8")
        assert len(hh.rule_tool_versions()) == 1, "Finder's file is not a layout change"
        (store / "2.1.299").mkdir()
        assert hh.rule_tool_versions() == [], "a directory where versions are files"


def test_tool_versions_per_version_refusals(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        victim = store / "2.1.301"
        for name, days in (("2.1.301", 6), ("2.1.302", 5), ("2.1.303", 4)):
            age(store / name, days)
        assert hh.rule_tool_versions() == [], "under 7 days"
        for name, days in (("2.1.301", 30), ("2.1.302", 20), ("2.1.303", 10)):
            age(store / name, days)
        with mock.patch.object(hh, "tree_in_use", return_value=True):
            assert hh.rule_tool_versions() == [], "held open"
        with mock.patch.object(hh, "process_names_path", return_value=True):
            assert hh.rule_tool_versions() == [], "a running process"
        with mock.patch.object(hh, "changed_age_min", return_value=60.0):
            assert hh.rule_tool_versions() == [], "just moved into place"
        locks = home / ".local/state/claude/locks"
        locks.mkdir(parents=True)
        (locks / "2.1.301.lock").write_text("", encoding="utf-8")
        assert hh.rule_tool_versions() == [], "the tool holds a lock on it"
        (locks / "2.1.301.lock").unlink()
        (store.parent / hh.KEEP_SENTINEL).write_text("", encoding="utf-8")
        assert hh.rule_tool_versions() == [], "a keep marker on a parent"
        (store.parent / hh.KEEP_SENTINEL).unlink()
        with victim.open("wb") as fh:
            fh.truncate(1024)
        age(victim, 30)
        assert hh.rule_tool_versions() == [], "too small to be worth the delete"


def test_tool_versions_cursor_layout(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = cursor_store(home)
        found = hh.rule_tool_versions()
        assert rule_paths(found) == {str(store / ".2026.08.31-4057e58"), str(store / "2026.08.01-aaaaaaa")}, found


def test_tool_versions_a_new_dotted_copy_does_not_push_out_a_real_version(hh):
    """A dotted copy is never one of the two newest, so a fresh one cannot make
    a version anyone could be running look old."""
    with fake_home(hh) as home, gates_open(hh):
        store = cursor_store(home)
        fresh = store / ".2026.10.30-ccccccc"
        old_tree(fresh, 8)
        age(fresh, 8)
        found = rule_paths(hh.rule_tool_versions())
        assert str(store / "2026.09.26-dd393fe") not in found, found
        assert str(store / "2026.10.14-941492e") not in found, found


def test_tool_versions_a_marker_inside_a_version_directory_keeps_it(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = cursor_store(home)
        (store / "2026.08.01-aaaaaaa" / "sub").mkdir()
        (store / "2026.08.01-aaaaaaa" / "sub" / hh.KEEP_SENTINEL).write_text("", encoding="utf-8")
        age_all(store / "2026.08.01-aaaaaaa", 90)
        assert str(store / "2026.08.01-aaaaaaa") not in rule_paths(hh.rule_tool_versions())


def test_tool_versions_muse_layout(hh):
    with fake_home(hh) as home, gates_open(hh):
        bin_dir = muse_store(home)
        found = hh.rule_tool_versions()
        assert rule_paths(found) == {str(bin_dir / "muse-bin-1.4.10-R1")}, found
        (bin_dir / ".muse-version").write_text("1.4.10-R1\n", encoding="utf-8")
        assert hh.rule_tool_versions() == [], "the pointer names the oldest one; the other is inside the newest two"
        (bin_dir / ".muse-version").write_text("9.9.9\n", encoding="utf-8")
        assert hh.rule_tool_versions() == [], "the pointer names something not installed"
        (bin_dir / ".muse-version").unlink()
        assert hh.rule_tool_versions() == [], "no pointer"


def test_tool_versions_refuses_at_apply_when_the_path_was_replaced(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        c = hh.rule_tool_versions()[0]
        (store / "2.1.301").unlink()
        blob(store / "2.1.301", 30)
        hh.apply_candidate(c)
        assert not c.applied and c.refused and not c.error, (c.refused, c.error)
        assert (store / "2.1.301").exists()


# --- xcode-scratch --------------------------------------------------------

def xcode_tree(home, name="seat-build", days=3):
    tree = home / "private-tmp" / name
    blob(tree / "Build" / "Products" / "Debug" / "App.app" / "App", days)
    (tree / "Build" / "Intermediates.noindex").mkdir(parents=True)
    (tree / "CompilationCache.noindex").mkdir()
    (tree / "ModuleCache.noindex").mkdir()
    (tree / "info.plist").write_text("<plist/>\n", encoding="utf-8")
    age(tree / "info.plist", days)
    return tree


def test_xcode_scratch_refuses_anything_that_looks_like_source(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home)
        (tree / ".git").mkdir()
        assert hh._xcode_scratch_refusal(tree) is not None, ".git"
        (tree / ".git").rmdir()
        for name in ("Package.swift", "main.swift", "README.md", "x.txt"):
            (tree / name).write_text("x", encoding="utf-8")
            assert hh._xcode_scratch_refusal(tree) is not None, name
            (tree / name).unlink()
        for name in ("App.xcodeproj", "App.xcworkspace", "Sources"):
            (tree / name).mkdir()
            assert hh._xcode_scratch_refusal(tree) is not None, name
            (tree / name).rmdir()
        assert hh._xcode_scratch_refusal(tree) is None, "and the clean tree still passes"


def test_xcode_scratch_needs_the_whole_shape(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home)
        shutil.rmtree(tree / "CompilationCache.noindex")
        shutil.rmtree(tree / "ModuleCache.noindex")
        assert hh._xcode_scratch_refusal(tree) is not None, "no Xcode cache"
        (tree / "CompilationCache.noindex").mkdir()
        shutil.rmtree(tree / "Build" / "Intermediates.noindex")
        shutil.rmtree(tree / "Build" / "Products")
        assert hh._xcode_scratch_refusal(tree) is not None, "Build holds none of Xcode's folders"
        shutil.rmtree(tree / "Build")
        assert hh._xcode_scratch_refusal(tree) is not None, "no Build"


def test_xcode_scratch_refuses_links_and_other_owners(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home)
        link = home / "private-tmp" / "link-to-it"
        link.symlink_to(tree)
        assert rule_paths(hh.rule_xcode_scratch()) == {str(tree)}, "a symlink is not followed"
        (tree / "Logs").symlink_to(home)
        assert hh._xcode_scratch_refusal(tree) is not None, "a link inside at the top"
        (tree / "Logs").unlink()
        with mock.patch.object(hh.os, "getuid", return_value=os.getuid() + 1):
            assert hh._xcode_scratch_refusal(tree) is not None, "another user's tree"


def test_xcode_scratch_per_tree_findings(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home, days=0.5)
        assert "24 hours" in str(hh._xcode_scratch_refusal(tree))
        shutil.rmtree(tree)
        tree = xcode_tree(home)
        assert hh._xcode_scratch_refusal(tree) is None, "the control"
        with mock.patch.object(hh, "tree_in_use", return_value=True):
            assert "held open" in str(hh._xcode_scratch_refusal(tree))
        with mock.patch.object(hh, "process_names_path", return_value=True):
            assert "names it" in str(hh._xcode_scratch_refusal(tree))
        with mock.patch.object(hh, "changed_age_min", return_value=60.0):
            assert "24 hours" in str(hh._xcode_scratch_refusal(tree))
        with mock.patch.object(hh, "_build_running", return_value=True):
            assert "a build is running" in hh.rule_xcode_scratch()[0].reason
        deep = tree / "Build" / "Products" / hh.KEEP_SENTINEL
        deep.write_text("", encoding="utf-8")
        age_all(tree, 3)
        assert "marker" in str(hh._xcode_scratch_refusal(tree))
        deep.unlink()
        (tree / "Build" / "Products" / "Debug" / "App.app" / "App").unlink()
        assert hh.rule_xcode_scratch() == [], "too small to be worth a row"


def test_xcode_scratch_nested_repositories(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home)
        (tree / "Build" / "Products" / "clone").mkdir()
        (tree / "Build" / "Products" / "clone" / ".git").mkdir()
        assert hh._xcode_scratch_refusal(tree) is not None, "a repository outside SwiftPM's folder"
        shutil.rmtree(tree / "Build" / "Products" / "clone")
        clone = upstream_clone(home, tree / "SourcePackages" / "checkouts" / "dep")
        age_all(tree, 3)
        assert hh._xcode_scratch_refusal(tree) is None, "a clean SwiftPM clone of its upstream rebuilds"
        (clone / "edit.swift").write_text("x", encoding="utf-8")
        age(clone / "edit.swift", 3)
        assert hh._xcode_scratch_refusal(tree) is not None, "an edit in the clone keeps the tree"
        (clone / "edit.swift").unlink()
        shutil.rmtree(clone / ".git")
        (clone / ".git").write_text("gitdir: /elsewhere\n", encoding="utf-8")
        age_all(tree, 3)
        assert hh._xcode_scratch_refusal(tree) is not None, "a linked worktree at SwiftPM's path"


# --- stale-build-output ---------------------------------------------------

def test_stale_build_takes_a_named_nested_path_and_no_other(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "CodeCaps")
        nested = old_tree(repo / "ios" / "CodeCapsCompanion" / "build")
        unnamed = old_tree(repo / "ios" / "Other" / "build")
        assert rule_paths(hh.rule_stale_build_output()) == {str(nested)}
        assert unnamed.is_dir()
        (repo / "ios" / "CodeCapsCompanion" / ".git").write_text("gitdir: /x\n", encoding="utf-8")
        hh._STALE_BUILD_MEMO.clear()
        assert hh.rule_stale_build_output() == [], "a nested repo between the repo and the tree"


def test_stale_build_refusals(hh):
    def refusal(repo, rel=".build"):
        return hh.stale_build_refusal(repo, rel)

    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        target = old_tree(repo / ".build")
        assert refusal(repo) is None, refusal(repo)

        # 14 days is the line, including just inside it.
        age(target / "out.o", 13)
        assert "14 days" in str(refusal(repo)), refusal(repo)
        age(target / "out.o", 30)

        (repo / ".gitignore").write_text("", encoding="utf-8")
        assert "does not ignore" in str(refusal(repo)), refusal(repo)
        (repo / ".gitignore").write_text(".build/\n", encoding="utf-8")

        # Tracked after it was ignored: git stops calling the folder ignored,
        # and the tracked check stands behind that if it ever answers otherwise.
        small = target / "tracked.txt"
        small.write_text("x", encoding="utf-8")
        age(small, 30)
        run_git(repo, "add", "-f", ".build/tracked.txt")
        assert "does not ignore" in str(refusal(repo)), refusal(repo)
        run_git(repo, "reset", "-q")
        small.unlink()

        def ignored_but_tracked(_cwd, *args):
            out = "x\0" if args[0] == "ls-files" else ""
            return subprocess.CompletedProcess([], 0, out, "")

        with mock.patch.object(hh, "_git", side_effect=ignored_but_tracked):
            assert "tracks" in str(refusal(repo)), refusal(repo)

        with mock.patch.object(hh, "tree_in_use", return_value=True):
            assert "held open" in str(refusal(repo)), refusal(repo)
        with mock.patch.object(hh, "process_names_path", return_value=True):
            assert "process" in str(refusal(repo)), refusal(repo)
        with mock.patch.object(hh, "changed_age_min", return_value=60.0):
            assert "14 days" in str(refusal(repo)), refusal(repo)
        (target / "sub").mkdir()
        (target / "sub" / hh.KEEP_SENTINEL).write_text("", encoding="utf-8")
        age_all(target, 30)
        assert "marker" in str(refusal(repo)), refusal(repo)
        shutil.rmtree(target / "sub")
        (repo / hh.KEEP_SENTINEL).write_text("", encoding="utf-8")
        assert refusal(repo) == "protected"
        (repo / hh.KEEP_SENTINEL).unlink()
        with mock.patch.object(hh.os, "getuid", return_value=os.getuid() + 1):
            assert "someone else" in str(refusal(repo)), refusal(repo)
        assert refusal(repo) is None, refusal(repo)


def test_stale_build_refuses_symlinks_at_every_step(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        elsewhere = old_tree(home / "elsewhere" / ".build")
        (repo / ".build").symlink_to(elsewhere)
        assert hh.rule_stale_build_output() == [], "a symlinked tree"
        assert "symlink" in hh.stale_build_refusal(repo, ".build")
        (repo / ".build").unlink()

        real = git_repo(home / "real" / "Linked")
        old_tree(real / ".build")
        (home / "Code" / "Linked").symlink_to(real)
        assert hh.rule_stale_build_output() == [], "a symlinked repo"
        assert real.joinpath(".build").is_dir()


def test_stale_build_refuses_worktrees_and_never_names_them(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        old_tree(repo / ".build")
        muse = repo / ".muse" / "worktrees" / "mc-lane"
        run_git(repo, "worktree", "add", "-q", "-b", "mc-lane", str(muse))
        old_tree(muse / ".build")
        claude = repo / ".claude" / "worktrees" / "c-lane"
        run_git(repo, "worktree", "add", "-q", "-b", "c-lane", str(claude))
        old_tree(claude / ".build")
        found = rule_paths(hh.rule_stale_build_output())
        assert found == {str(repo / ".build")}, found
        # Even asked directly about these, the answer is no.
        for rel in (".muse/worktrees/mc-lane/.build", ".claude/worktrees/c-lane/.build"):
            assert hh.stale_build_refusal(repo, rel) is not None, rel
        # A checkout whose `.git` is a file is a linked worktree of something.
        linked = home / "Code" / "Linked"
        run_git(repo, "worktree", "add", "-q", "-b", "linked", str(linked))
        old_tree(linked / ".build")
        (linked / ".gitignore").write_text(".build/\n", encoding="utf-8")
        hh._STALE_BUILD_MEMO.clear()
        assert str(linked / ".build") not in rule_paths(hh.rule_stale_build_output())
        assert "linked worktree" in hh.stale_build_refusal(linked, ".build")


def test_stale_build_refuses_nested_repositories_except_a_provable_swiftpm_clone(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        target = old_tree(repo / ".build")

        hidden = target / "deep" / "clone"
        hidden.mkdir(parents=True)
        (hidden / ".git").mkdir()
        assert "nested repository" in hh.stale_build_refusal(repo, ".build")
        shutil.rmtree(target / "deep")

        clone = upstream_clone(home, target / "checkouts" / "dep")
        age_all(target, 30)
        assert hh.stale_build_refusal(repo, ".build") is None, "a clean clone of its upstream rebuilds"

        (clone / "edit.swift").write_text("x", encoding="utf-8")
        age_all(target, 30)
        assert "local changes" in hh.stale_build_refusal(repo, ".build")
        run_git(clone, "add", ".")
        run_git(clone, "commit", "-q", "-m", "local")
        age_all(target, 30)
        assert "no remote holds" in hh.stale_build_refusal(repo, ".build"), "a commit only this clone has"
        shutil.rmtree(target / "checkouts")

        # `checkouts/` directly under `build/` is not where SwiftPM puts clones.
        other = old_tree(repo / "build")
        (other / "checkouts" / "dep" / ".git").mkdir(parents=True)
        assert "nested repository" in hh.stale_build_refusal(repo, "build")
        shutil.rmtree(other / "checkouts")
        upstream_clone(home, other / "derivedData" / "SourcePackages" / "checkouts" / "dep2")
        age_all(other, 30)
        assert hh.stale_build_refusal(repo, "build") is None, "SwiftPM's folder inside derived data"


def test_stale_build_fails_closed_when_git_cannot_answer(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        old_tree(repo / ".build")
        with mock.patch.object(hh, "_git", return_value=None):
            assert hh.rule_stale_build_output() == []
        hh._STALE_BUILD_MEMO.clear()
        broke = subprocess.CompletedProcess([], 128, "", "fatal")
        with mock.patch.object(hh, "_git", return_value=broke):
            assert hh.rule_stale_build_output() == []
        hh._STALE_BUILD_MEMO.clear()
        with mock.patch.object(hh, "find_paths", side_effect=subprocess.TimeoutExpired("find", 1)):
            assert hh.rule_stale_build_output() == [], "a nested-repo walk that timed out"
        hh._STALE_BUILD_MEMO.clear()
        with mock.patch.object(hh, "touched_since", return_value=True):
            assert hh.rule_stale_build_output() == [], "a failed find reads as touched"


def test_stale_build_never_takes_node_modules_or_dist(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        old_tree(repo / "node_modules")
        old_tree(repo / "dist")
        assert hh.rule_stale_build_output() == []
        assert hh.stale_build_refusal(repo, "node_modules") is not None
        assert hh.stale_build_refusal(repo, "dist") is not None
        with mock.patch.object(hh, "open_handles", return_value=0):
            report = {c.path: c for c in hh.rule_ask_first_inventory()}
        for name in ("node_modules", "dist"):
            assert report[str(repo / name)].op == "report", name


def test_stale_build_ask_first_reports_only_what_the_rule_cannot_take(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App", ignore=".next/\n")
        eligible = old_tree(repo / ".next")
        not_ignored = old_tree(repo / ".build")
        hh.rule_stale_build_output()
        with mock.patch.object(hh, "open_handles", return_value=0):
            report = {c.path: c for c in hh.rule_ask_first_inventory()}
        assert str(eligible) not in report, "the rule owns it"
        c = report[str(not_ignored)]
        assert (c.tier, c.op) == ("ask-first", "report")
        assert "does not ignore" in c.reason, c.reason


def test_stale_build_stops_with_the_scan_share(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        old_tree(repo / ".build")
        clock = FakeClock()
        with fake_time(hh, clock):
            hh.set_budget(100)
            clock.now += 61
            hh._SCAN_BUDGET_EXHAUSTED = False
            assert hh.rule_stale_build_output() == []
            assert hh._SCAN_BUDGET_EXHAUSTED, "the report has to learn the scan was cut short"
            hh.set_budget(0)


# --- ask-first peer work --------------------------------------------------

def peer_work_home(home):
    (home / "BotFleet-migration-backups" / "20261030-mac").mkdir(parents=True)
    releases = home / ".botfleet" / "releases"
    (releases / "aaaa").mkdir(parents=True)
    (releases / "bbbb").mkdir()
    (home / ".botfleet" / "current").symlink_to(releases / "bbbb")
    (home / "apps" / "botfleet-mm-mcode").mkdir(parents=True)
    (home / "apps" / "botfleet-companion-start.sh").write_text("x", encoding="utf-8")
    (home / "apps" / "botfleet-linked").symlink_to(home / "apps" / "botfleet-mm-mcode")
    (home / "Code" / "BotFleet" / ".muse" / "worktrees" / "one").mkdir(parents=True)
    (home / ".minimax" / "v2" / "sqlite" / "backups").mkdir(parents=True)
    (home / ".codex" / ".tmp" / "marketplaces" / ".staging" / "marketplace-upgrade-x").mkdir(parents=True)


def test_ask_first_surfaces_peer_work_and_never_applies_it(hh):
    with fake_home(hh) as home:
        peer_work_home(home)
        found = {c.path: c for c in hh.rule_ask_first_inventory()}
        want = [
            home / "BotFleet-migration-backups",
            home / ".botfleet" / "releases" / "aaaa",
            home / "apps" / "botfleet-mm-mcode",
            home / "Code" / "BotFleet" / ".muse" / "worktrees",
            home / ".minimax" / "v2" / "sqlite" / "backups",
            home / ".codex" / ".tmp" / "marketplaces" / ".staging",
        ]
        for path in want:
            assert str(path) in found, path
            c = found[str(path)]
            assert (c.tier, c.op) == ("ask-first", "report"), path
            hh.apply_candidate(c)
            assert not c.applied and path.exists(), path
        assert str(home / ".botfleet" / "releases" / "bbbb") not in found, "the current release"
        assert str(home / "apps" / "botfleet-companion-start.sh") not in found, "a file is not a tree"
        assert str(home / "apps" / "botfleet-linked") not in found, "a symlink is not a tree"


def test_ask_first_does_not_size_peer_work_unless_asked(hh):
    with fake_home(hh) as home:
        peer_work_home(home)
        blob(home / "BotFleet-migration-backups" / "big.bin", 1)
        with mock.patch.object(hh, "dir_bytes", side_effect=AssertionError("sized")):
            found = {c.path: c for c in hh.rule_ask_first_inventory()}
        assert found[str(home / "BotFleet-migration-backups")].bytes == 0
        with mock.patch.object(hh, "SIZE_ASK_FIRST", True):
            found = {c.path: c for c in hh.rule_ask_first_inventory()}
        assert found[str(home / "BotFleet-migration-backups")].bytes >= 64 * 1024 * 1024


def test_ask_first_peer_work_stops_with_the_scan_share(hh):
    with fake_home(hh) as home:
        peer_work_home(home)
        clock = FakeClock()
        with fake_time(hh, clock):
            hh.set_budget(100)
            clock.now += 61
            hh._SCAN_BUDGET_EXHAUSTED = False
            assert hh._ask_first_peer_work(lambda _p: 0) == []
            assert hh._SCAN_BUDGET_EXHAUSTED
            hh.set_budget(0)


# --- gate helpers ---------------------------------------------------------

def test_tree_in_use_treats_a_failed_snapshot_as_in_use(hh):
    with mock.patch.object(hh, "_load_open_snapshot", return_value=None), \
            mock.patch.object(hh, "open_handles", return_value=0):
        assert hh.tree_in_use("/some/tree"), "the per-path fallback cannot see deep files"
    with mock.patch.object(hh, "_load_open_snapshot", return_value={"/x"}), \
            mock.patch.object(hh, "open_handles", return_value=0):
        assert not hh.tree_in_use("/some/tree")
    with mock.patch.object(hh, "_load_open_snapshot", return_value={"/x"}), \
            mock.patch.object(hh, "open_handles", return_value=2):
        assert hh.tree_in_use("/some/tree")


def test_process_names_path_passes_the_path_as_a_literal_and_fails_busy(hh):
    with mock.patch.object(hh, "proc_count", return_value=0) as count:
        assert not hh.process_names_path("/private/tmp/a.b (c)")
    pattern = count.call_args.args[0]
    assert pattern == r"/private/tmp/a\.b \(c\)", pattern
    with mock.patch.object(hh, "proc_count", return_value=hh.PROBE_FAILED):
        assert hh.process_names_path("/x"), "a failed look is busy"


def test_a_recheck_that_raises_deletes_nothing(hh):
    with fake_home(hh) as home:
        tree = old_tree(home / "tree")

        def broken():
            raise OSError("nope")

        c = hh.Candidate("x", str(tree), 1, "x", recheck=broken)
        hh.apply_candidate(c)
        assert not c.applied and "nope" in c.error
        assert tree.is_dir()


def test_a_recheck_is_not_in_the_report(hh):
    c = hh.Candidate("x", "/x", 1, "x", recheck=lambda: None)
    assert "recheck" not in c.as_dict()
    json.dumps(c.as_dict())


# --- policy registration --------------------------------------------------

def test_every_rule_is_in_the_policy_and_the_engine_only_rules_are_not_schedulable(hh):
    policy = json.loads(hh.POLICY_PATH.read_text())
    rules = {r["name"]: r for r in policy["rules"]}
    missing = [name for name in hh.RULES if name not in rules]
    assert not missing, f"a rule that is not in the policy: {missing}"
    swift = (ENGINE.parent.parent / "Sources/Storage/CleanRegimen.swift").read_text()
    block = swift.split("schedulableRules: [String] = [", 1)[1].split("]", 1)[0]
    for name, tier, op in (("duplicate-sim-runtimes", "semi-safe", "simctl-runtime-delete"),
                           ("stale-build-output", "ask-first", "report"),
                           ("tool-versions", "safe", "delete"),
                           ("xcode-scratch", "ask-first", "report")):
        assert rules[name]["tier"] == tier, name
        assert rules[name]["op"] == op, name
        assert f'"{name}"' not in block, f"the regimen cannot run {name}, so it must not offer it"


def test_the_policy_states_the_tier_the_simulator_rule_really_runs_at(hh):
    """The code files whole runtimes under `expensive`, opened only at real space
    pressure, and the policy said semi-safe.  Nothing reads the JSON's tier, so
    the code was right and the words were wrong."""
    policy = json.loads(hh.POLICY_PATH.read_text())
    rule = next(r for r in policy["rules"] if r["name"] == "simulator-runtimes")
    assert rule["tier"] == "expensive"
    assert "expensive" in policy["tiers"]
    src = ENGINE.read_text()
    body = src.split("def rule_simulator_runtimes", 1)[1].split("def split_find_output", 1)[0]
    assert 'tier="expensive"' in body


# --------------------------------------------------------------------------
# HH-213 review of 5cab1de: one regression per confirmed finding, each built
# from the reviewer's scenario in a fake home.  F<n> is the finding's number.
# --------------------------------------------------------------------------

def upstream_clone(home, clone):
    """A real clone of a real upstream, the way SwiftPM's checkouts are."""
    up = home / "upstream" / clone.name
    if not up.exists():
        git_repo(up, ignore="")
    clone.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/git", "clone", "-q", str(up), str(clone)], check=True, capture_output=True)
    return clone


def seed_open_snapshot(hh, paths=("/unrelated/path",), cwds=()):
    """A trustworthy lsof listing, without running lsof."""
    hh._OPEN_SNAPSHOT = set(paths)
    hh._OPEN_INDEX = hh._build_open_index(hh._OPEN_SNAPSHOT)
    hh._OPEN_CWDS = set(cwds)
    hh._OPEN_SNAPSHOT_AT = time.monotonic()


def test_f1_a_tracked_folder_differing_only_in_case_is_not_build_output(hh):
    with fake_home(hh) as home, gates_open(hh):
        for on_disk, rel, ignore in (("Build", "build", "build/\n"), ("Target", "target", "/target\n")):
            repo = git_repo(home / "Code" / f"App{on_disk}", ignore=ignore)
            blob(repo / on_disk / "big.bin", 30)
            (repo / on_disk / "deploy.sh").write_text("v1\n", encoding="utf-8")
            run_git(repo, "add", "-f", f"{on_disk}/deploy.sh")
            run_git(repo, "commit", "-q", "-m", "tracked")
            (repo / on_disk / "deploy.sh").write_text("uncommitted edit\n", encoding="utf-8")
            age_all(repo / on_disk, 30)
            refusal = hh.stale_build_refusal(repo, rel)
            assert refusal is not None, f"tracked {on_disk}/ passed as {rel}"
            hh._STALE_BUILD_MEMO.clear()
            assert str(repo / rel) not in rule_paths(hh.rule_stale_build_output()), on_disk
            assert (repo / on_disk / "deploy.sh").read_text(encoding="utf-8") == "uncommitted edit\n"


def test_f2_a_process_running_from_the_repo_keeps_its_build_output(hh):
    """`next start` reads .next and closes it, and `python3 build/server.py`
    has only a relative path in argv.  Neither holds anything open under the
    tree, so only the process's working directory shows it."""
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        old_tree(repo / ".next")
        with mock.patch.object(hh, "repo_has_process_cwd", side_effect=None, return_value=True, create=True):
            assert "working directory" in str(hh.stale_build_refusal(repo, ".next"))
    with fake_home(hh) as home:
        repo = git_repo(home / "Code" / "App")
        old_tree(repo / ".next")
        seed_open_snapshot(hh, cwds=[str(repo)])
        with mock.patch.object(hh, "process_names_path", return_value=False), \
                mock.patch.object(hh, "changed_age_min", return_value=10.0 ** 9):
            assert "working directory" in str(hh.stale_build_refusal(repo, ".next"))
            seed_open_snapshot(hh, cwds=[str(repo / "src" / "deep")])
            assert "working directory" in str(hh.stale_build_refusal(repo, ".next")), "a subfolder counts"
            seed_open_snapshot(hh, cwds=[str(repo) + "-other"])
            assert hh.stale_build_refusal(repo, ".next") is None, "a sibling's name is not inside"


def test_f2_the_listing_records_working_directories_and_fails_closed(hh):
    listing = "p41\nfcwd\nn/some/repo\nf3\nn/some/file\nfrtd\nn/\n"
    with mock.patch.object(hh.subprocess, "run",
                           return_value=subprocess.CompletedProcess([], 0, listing, "")):
        assert hh.repo_has_process_cwd("/some/repo")
        assert not hh.repo_has_process_cwd("/some/file"), "an open file is not a working directory"
        assert not hh.repo_has_process_cwd("/other"), "the root directory line is not a cwd"
    hh._OPEN_SNAPSHOT = None
    with mock.patch.object(hh, "_load_open_snapshot", return_value=None):
        assert hh.repo_has_process_cwd("/other"), "no listing means nobody can tell"


def test_f3_a_clone_proof_counts_stashes_local_branches_and_local_tags(hh):
    def scene(name, act):
        with fake_home(hh) as home, gates_open(hh):
            repo = git_repo(home / "Code" / "App")
            target = old_tree(repo / ".build")
            clone = upstream_clone(home, target / "checkouts" / "dep")
            age_all(target, 30)
            assert hh.stale_build_refusal(repo, ".build") is None, f"{name}: the clean clone is the control"
            act(clone)
            age_all(target, 30)
            assert "no remote holds" in str(hh.stale_build_refusal(repo, ".build")), name

    def stash(c):
        (c / "main.swift").write_text("edit\n", encoding="utf-8")
        run_git(c, "stash")

    def local_branch(c):
        run_git(c, "checkout", "-q", "-b", "wip")
        (c / "wip.swift").write_text("x\n", encoding="utf-8")
        run_git(c, "add", ".")
        run_git(c, "commit", "-q", "-m", "wip")
        run_git(c, "checkout", "-q", "-")

    def local_tag(c):
        (c / "wip.swift").write_text("x\n", encoding="utf-8")
        run_git(c, "add", ".")
        run_git(c, "commit", "-q", "-m", "wip")
        run_git(c, "tag", "wip")
        run_git(c, "reset", "-q", "--hard", "HEAD~1")

    scene("stash", stash)
    scene("local branch", local_branch)
    scene("local tag", local_tag)


def test_f4_a_clone_proof_ignores_git_config_that_hides_files_and_skip_worktree(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        target = old_tree(repo / ".build")
        clone = upstream_clone(home, target / "checkouts" / "dep")
        run_git(clone, "config", "status.showUntrackedFiles", "no")
        (clone / "handwritten.swift").write_text("x\n", encoding="utf-8")
        age_all(target, 30)
        assert "local changes" in str(hh.stale_build_refusal(repo, ".build"))
        (clone / "handwritten.swift").unlink()

        for flag in ("--skip-worktree", "--assume-unchanged"):
            run_git(clone, "update-index", flag, "main.swift")
            (clone / "main.swift").write_text("hidden edit\n", encoding="utf-8")
            age_all(target, 30)
            assert "hides edits" in str(hh.stale_build_refusal(repo, ".build")), flag
            run_git(clone, "update-index", "--no-" + flag[2:], "main.swift")
            run_git(clone, "checkout", "--", "main.swift")


def test_f5_ignored_build_output_with_precious_contents_stays(hh):
    secret_name = "." + "env.local"
    cases = ("release-key.p12", "signing.pem", "App.xcarchive/Info.plist", "notes.md", "sub/dir/notes.md",
             "backup.git/config", "foo/.hg/store", "foo/.jj/repo", "foo/.svn/entries",
             "plain-bare/HEAD", "data.sqlite", secret_name, "sub/App.xcodeproj/project.pbxproj",
             "sub/Package.swift", "main.swift")
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        target = old_tree(repo / "build")
        assert hh.stale_build_refusal(repo, "build") is None, "the control is plain build output"
        for rel in cases:
            path = target / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("x", encoding="utf-8")
            if rel == "plain-bare/HEAD":
                (path.parent / "objects").mkdir()
                (path.parent / "refs").mkdir()
            age_all(target, 30)
            assert hh.stale_build_refusal(repo, "build") is not None, rel
            shutil.rmtree(target / Path(rel).parts[0]) if len(Path(rel).parts) > 1 else path.unlink()
        assert hh.stale_build_refusal(repo, "build") is None, "and it passes again once they are gone"


def test_f5_generated_files_a_build_really_makes_do_not_refuse(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        target = old_tree(repo / ".next")
        for rel in ("package.json", "server/chunks/a.js", "types/routes.d.ts", "trace"):
            path = target / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("x", encoding="utf-8")
        target2 = old_tree(repo / ".build")
        for rel in ("build.db", "debug.yaml", "arm64-apple-macosx/debug/App.derived/resource.swift",
                    "artifacts/dep/Headers/a.h"):
            path = target2 / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("x", encoding="utf-8")
        age_all(repo / ".next", 30)
        age_all(repo / ".build", 30)
        assert hh.stale_build_refusal(repo, ".next") is None, hh.stale_build_refusal(repo, ".next")
        assert hh.stale_build_refusal(repo, ".build") is None, hh.stale_build_refusal(repo, ".build")


def test_f5_a_folder_in_a_swiftpm_store_that_is_not_a_clone_keeps_the_tree(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        target = old_tree(repo / ".build")
        (target / "checkouts" / "mine").mkdir(parents=True)
        (target / "checkouts" / "mine" / "secrets.p12").write_text("x", encoding="utf-8")
        age_all(target, 30)
        assert hh.stale_build_refusal(repo, ".build") is not None


def test_f6_xcode_scratch_inspects_the_whole_tree_for_source(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home)
        (tree / "Logs").mkdir()
        (tree / "SourcePackages").mkdir()
        assert hh._xcode_scratch_refusal(tree) is None, "the control"
        for rel in ("Build/Package.swift", "Build/main.swift", "Logs/notes.md",
                    "SourcePackages/mine/App.xcodeproj/project.pbxproj",
                    "Build/Products/Debug/stray.swift", "Build/Products/Debug/App.xcworkspace/contents",
                    "Build/Intermediates.noindex/Package.swift", "Build/Intermediates.noindex/x.py",
                    "ModuleCache.noindex/draft.m", "Logs/deep/down/key.p12"):
            path = tree / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("x", encoding="utf-8")
            age_all(tree, 3)
            assert hh._xcode_scratch_refusal(tree) is not None, rel
            first = Path(rel).parts
            if first[0] == "Logs" and len(first) > 2:
                shutil.rmtree(tree / "Logs" / first[1])
            elif first[0] == "SourcePackages":
                shutil.rmtree(tree / "SourcePackages" / first[1])
            elif "xcworkspace" in rel:
                shutil.rmtree(path.parent)
            else:
                path.unlink()
        assert hh._xcode_scratch_refusal(tree) is None, "and the clean tree still passes"


def test_f6_xcode_scratch_allows_what_xcode_generates(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home)
        for rel in ("Build/Intermediates.noindex/App.build/gen.swift",
                    "Build/Intermediates.noindex/App.build/gen.h",
                    "Build/Intermediates.noindex/XCBuildData/manifest.txt",
                    "Build/Products/Debug/Dep.framework/Headers/Dep.h",
                    "SourcePackages/artifacts/dep/Headers/a.h",
                    "SourcePackages/workspace-state.json"):
            path = tree / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("x", encoding="utf-8")
        age_all(tree, 3)
        assert hh._xcode_scratch_refusal(tree) is None, hh._xcode_scratch_refusal(tree)


def test_f6_a_walk_that_cannot_finish_fails_closed(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home)
        with mock.patch.object(hh, "_MAX_WALK_ENTRIES", 2, create=True):
            assert hh._xcode_scratch_refusal(tree) is not None, "too many entries to inspect"
        with mock.patch.object(hh, "probe_timeout", return_value=-1.0):
            assert hh._xcode_scratch_refusal(tree) is not None, "out of time"
        assert tree.is_dir()


def test_f7_a_wrapper_or_outside_symlink_keeps_an_old_version(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        wrapper = home / ".local/bin/claude-pinned"
        wrapper.write_text(f'#!/bin/sh\nexec "{store}/2.1.301" "$@"\n', encoding="utf-8")
        assert hh.rule_tool_versions() == [], "a wrapper names it"
        wrapper.unlink()
        (home / "bin").mkdir()
        (home / "bin" / "claude-lts").symlink_to(store / "2.1.301")
        assert hh.rule_tool_versions() == [], "a symlink in ~/bin resolves to it"
        (home / "bin" / "claude-lts").unlink()
        agents = home / "Library/LaunchAgents"
        agents.mkdir(parents=True)
        (agents / "com.x.plist").write_text(f"<string>{store}/2.1.301</string>", encoding="utf-8")
        assert hh.rule_tool_versions() == [], "a LaunchAgent runs it"
        (agents / "com.x.plist").unlink()
        assert len(hh.rule_tool_versions()) == 1, "the control"


def test_f7_a_version_run_recently_stays_by_access_time(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        old = time.time() - 30 * 24 * 3600
        os.utime(store / "2.1.301", (time.time(), old))
        assert hh.rule_tool_versions() == [], "mtime says old and atime says it ran today"
        os.utime(store / "2.1.301", (old, old))
        cursor = cursor_store(home)
        victim = cursor / "2026.08.01-aaaaaaa"
        assert str(victim) in rule_paths(hh.rule_tool_versions())
        os.utime(victim / "out.o", (time.time(), old))
        assert str(victim) not in rule_paths(hh.rule_tool_versions()), "a file at the top of the version"


def test_f7_the_default_launcher_must_resolve_or_the_tool_is_left_out(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        launcher = home / ".local/bin/claude"
        launcher.unlink()
        (home / ".local/bin/claude-other").symlink_to(store / "2.1.303")
        assert hh.rule_tool_versions() == [], "another link does not say what `claude` runs"
        launcher.write_text("#!/bin/sh\nexec something\n", encoding="utf-8")
        assert hh.rule_tool_versions() == [], "a launcher that is not a link cannot be proved"
        launcher.unlink()
        launcher.symlink_to(home / "elsewhere" / "claude")
        assert hh.rule_tool_versions() == [], "a launcher that resolves outside the store"
        launcher.unlink()
        launcher.symlink_to(store / "2.1.301")
        assert hh.rule_tool_versions() == [], "the launcher's own version is the oldest, and stays"


def test_f7_a_running_version_stays(hh):
    with fake_home(hh) as home, gates_open(hh):
        store = version_store(home)
        running = str(store / "2.1.301")
        with mock.patch.object(hh, "tree_in_use", side_effect=lambda p: p == running):
            assert hh.rule_tool_versions() == []
    with fake_home(hh) as home, gates_open(hh):
        version_store(home)
        with mock.patch.object(hh, "tree_in_use", wraps=None, return_value=True):
            assert hh.rule_tool_versions() == [], "no trustworthy listing means no pick"


def test_f8_f12_the_recheck_takes_a_fresh_lsof_listing(hh):
    with fake_home(hh) as home:
        tree = old_tree(home / "tree")
        seed_open_snapshot(hh)
        assert not hh.tree_in_use(str(tree)), "the cached listing says closed"
        fresh = f"p7\nf3\nn{tree}/out.o\n"
        runs = []

        def lsof(argv, **kw):
            runs.append(argv)
            return subprocess.CompletedProcess(argv, 0, fresh, "")

        c = hh.Candidate("x", str(tree), 1, "x",
                         recheck=lambda: "held open" if hh.tree_in_use(str(tree)) else None)
        with mock.patch.object(hh.subprocess, "run", side_effect=lsof), \
                mock.patch.object(hh, "apply_delete", side_effect=AssertionError("deleted")):
            hh.apply_candidate(c)
        assert runs and runs[0][0].endswith("lsof"), runs
        assert not c.applied and c.refused == "held open", (c.applied, c.refused)
        assert tree.is_dir()


def test_f11_the_recheck_cannot_spend_the_deletes_reserve(hh):
    clock = FakeClock()
    with fake_time(hh, clock):
        hh.set_budget(100)
        seen = []

        def recheck():
            seen.append(hh.probe_timeout(600.0))
            clock.now += 50
            return None

        c = hh.Candidate("x", "/fake/tree", 64 * 1024 * 1024, "x", recheck=recheck)
        clock.now += 60  # 40 s left
        with mock.patch.object(hh, "apply_delete", side_effect=AssertionError("started a delete it cannot finish")):
            hh.apply_candidate(c)
        assert seen[0] <= 10.0, f"a recheck gets a slice, not all of what is left: {seen[0]}"
        assert not c.applied and c.deferred, (c.applied, c.deferred, c.refused)
        assert not c.error, "out of time is not a failure"
        hh.set_budget(0)


def test_f11_the_clone_loop_stops_when_the_clock_runs_out(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        target = old_tree(repo / ".build")
        upstream_clone(home, target / "checkouts" / "dep")
        clock = FakeClock()
        with fake_time(hh, clock):
            hh.set_budget(100)
            clock.now += 200
            with mock.patch.object(hh, "_git", side_effect=AssertionError("kept going")):
                assert "time" in str(hh.regenerable_clones_only(target))
            hh.set_budget(0)


def test_f9_more_than_one_xcode_gives_no_candidate(hh):
    fake = FakeSimctl()
    with simctl_env(hh, fake), \
            mock.patch.object(hh, "_installed_xcodes", return_value=["/Applications/Xcode.app", "/Applications/Xcode-beta.app"], create=True):
        assert hh.rule_duplicate_sim_runtimes() == []
    with simctl_env(hh, FakeSimctl()), \
            mock.patch.object(hh, "_installed_xcodes", return_value=None, create=True):
        assert hh.rule_duplicate_sim_runtimes() == [], "the list of Xcodes could not be read"
    with simctl_env(hh, FakeSimctl()), \
            mock.patch.object(hh, "_installed_xcodes", return_value=[], create=True):
        assert hh.rule_duplicate_sim_runtimes() == [], "no Xcode found means nothing is proved"


def test_f9_the_installed_xcodes_are_read_from_every_source(hh):
    with fake_home(hh) as home:
        apps = home / "Applications"
        (apps / "Xcode.app").mkdir(parents=True)

        def run(argv, **kw):
            if argv[0].endswith("mdfind"):
                return subprocess.CompletedProcess(argv, 0, "/Volumes/X/Xcode-beta.app\n", "")
            return subprocess.CompletedProcess(argv, 0, "/Applications/Xcode.app/Contents/Developer\n", "")

        with mock.patch.object(hh.subprocess, "run", side_effect=run):
            found = hh._installed_xcodes()
        assert set(found) == {str(apps / "Xcode.app"), "/Volumes/X/Xcode-beta.app", "/Applications/Xcode.app"}, found
        failed = subprocess.CompletedProcess([], 1, "", "")
        with mock.patch.object(hh.subprocess, "run", return_value=failed):
            assert hh._installed_xcodes() is None, "a look that failed does not say one"


def test_f10_an_absent_or_renamed_last_used_gives_no_candidate(hh):
    a = runtime_image(RUNTIME_A, "24B8117", last_used="2026-01-01T00:00:00Z")
    b = runtime_image(RUNTIME_B, "24B91016s", last_used=None)
    del b["lastUsedAt"]
    renamed = dict(b, lastMountedAt="2026-11-04T00:00:00Z")
    for image in (b, renamed):
        with simctl_env(hh, FakeSimctl(images={RUNTIME_A: a, RUNTIME_B: image})):
            assert hh.rule_duplicate_sim_runtimes() == [], image


def test_f10_only_a_disk_image_is_a_victim(hh):
    a = runtime_image(RUNTIME_A, "24B8117")
    for kind in ("Legacy Download", "Bundled with Xcode", None):
        b = runtime_image(RUNTIME_B, "24B91016s", last_used=None, kind=kind)
        with simctl_env(hh, FakeSimctl(images={RUNTIME_A: a, RUNTIME_B: b})):
            assert hh.rule_duplicate_sim_runtimes() == [], kind


def test_f13_any_device_not_shut_down_counts_as_active(hh):
    for state in ("Booting", "Shutting Down", "Creating", "Booted", None):
        fake = FakeSimctl(devices={"devices": {IOS_RUNTIME: [{"state": state, "udid": "x"}]}})
        with simctl_env(hh, fake):
            assert hh.rule_duplicate_sim_runtimes() == [], state
    fake = FakeSimctl(devices={"devices": {IOS_RUNTIME: [{"state": "Shutdown", "udid": "x"}]}})
    with simctl_env(hh, fake):
        assert len(hh.rule_duplicate_sim_runtimes()) == 1, "a shut down device is not in use"


def test_f14_a_rules_own_deadline_is_reported_as_truncation(hh):
    for rule, build in ((hh.rule_stale_build_output, lambda home: old_tree(git_repo(home / "Code" / "App") / ".build")),
                        (hh.rule_xcode_scratch, xcode_tree),
                        (hh.rule_tool_versions, version_store)):
        with fake_home(hh) as home, gates_open(hh):
            build(home)
            hh._SCAN_BUDGET_EXHAUSTED = False
            with mock.patch.object(hh, "rule_deadline", return_value=0.0):
                assert rule() == [], rule.__name__
            assert hh._SCAN_BUDGET_EXHAUSTED, f"{rule.__name__} stopped early without saying so"
            hh._SCAN_BUDGET_EXHAUSTED = False


def test_f14_a_tree_no_rule_listed_stays_on_the_report(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        eligible = old_tree(repo / ".next")
        with mock.patch.object(hh, "rule_deadline", return_value=0.0):
            hh.rule_stale_build_output()
        hh._SCAN_BUDGET_EXHAUSTED = False
        with mock.patch.object(hh, "open_handles", return_value=0):
            report = {c.path: c for c in hh.rule_ask_first_inventory()}
        assert str(eligible) in report, "neither a candidate nor a report row"
        assert "not checked" in report[str(eligible)].reason


def test_f14_the_report_row_walks_nothing_of_its_own(hh):
    """The expensive answer belongs to the rule.  A cheap-band run that skipped
    the rule must not pay for it on the report."""
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        old_tree(repo / ".next")
        with mock.patch.object(hh, "open_handles", return_value=0), \
                mock.patch.object(hh, "stale_build_refusal", side_effect=AssertionError("walked")):
            assert any(".next" in c.path for c in hh.rule_ask_first_inventory())


def test_f16_a_recheck_refusal_is_not_a_failure_in_the_report(hh):
    clock = FakeClock()
    band = hh.Band(20.0, 95.0, 0.0, 1.0, False, cpu_idle_pct=50.0)

    def refuses():
        return "a build is running"

    c = hh.Candidate("xcode-scratch", "/fake/tree", 64 * 1024 * 1024, "x", recheck=refuses)
    out, err = io.StringIO(), io.StringIO()
    with fake_time(hh, clock), \
            mock.patch.object(hh, "scan", return_value=[c]), \
            mock.patch.object(hh, "read_band", return_value=band), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        assert hh.main(["--clean", "--json"]) == 0
    report = json.loads(out.getvalue())
    assert report["failed_count"] == 0, report
    assert report["refused_count"] == 1, report
    assert report["applied_count"] == 0
    assert report["candidates"][0]["refused"] == "a build is running"
    assert report["candidates"][0]["error"] == ""
    assert "applied 0" in err.getvalue(), err.getvalue()
    assert report["remaining_count"] == 0, "a refusal was handled, not left over"


def test_f17_a_killed_runtime_delete_asks_simctl_before_calling_it_failed(hh):
    fake = FakeSimctl()
    real = fake.__call__

    def killed_but_gone(args, timeout):
        if list(args)[:2] == ["runtime", "delete"]:
            fake.images.pop(args[2], None)
            return None
        return real(args, timeout)

    with simctl_env(hh, killed_but_gone):
        c = hh.rule_duplicate_sim_runtimes()[0]
        hh.apply_candidate(c)
    assert c.applied and not c.error, c.error

    fake = FakeSimctl()
    real = fake.__call__

    def killed_and_still_there(args, timeout):
        return None if list(args)[:2] == ["runtime", "delete"] else real(args, timeout)

    with simctl_env(hh, killed_and_still_there):
        c = hh.rule_duplicate_sim_runtimes()[0]
        hh.apply_candidate(c)
    assert not c.applied and "failed" in c.error, c.error


def test_f18_read_band_says_when_it_could_not_read_the_disk(hh):
    with mock.patch.object(hh, "_run", return_value=""), \
            mock.patch.object(hh, "_read_cpu_pressures", return_value=(50.0, 0.0)):
        assert hh.read_band().disk_free_known is False
        assert hh.read_disk_free() is None


def test_f19_the_new_rule_never_starts_the_simulator_service(hh):
    """simulator-runtimes stays shut while CoreSimulatorService is alive, and
    asking simctl anything starts it.  So this rule only asks when it is
    already alive, and the older reclaim path is exactly as it was."""
    fake = FakeSimctl()
    with simctl_env(hh, fake), mock.patch.object(hh, "_simulator_service_alive", return_value=False, create=True):
        assert hh.rule_duplicate_sim_runtimes() == []
        assert hh.duplicate_runtime_victims() == []
    assert fake.calls == [], fake.calls
    with mock.patch.object(hh, "proc_count", return_value=0) as count:
        assert hh._simulator_service_alive() is False
    assert count.call_args.args[0] == "CoreSimulatorService"
    with mock.patch.object(hh, "proc_count", return_value=1):
        assert hh._simulator_service_alive() is True
    with mock.patch.object(hh, "proc_count", return_value=hh.PROBE_FAILED):
        assert hh._simulator_service_alive() is False, "a failed look must not start it"


def test_f22_the_policy_tier_is_a_tier_the_rule_really_gives_its_candidates(hh):
    """Read from each rule's own source, for every rule, so a tier that drifts
    between the words and the code fails here."""
    policy = {r["name"]: r for r in json.loads(hh.POLICY_PATH.read_text())["rules"]}
    tree = ast.parse(ENGINE.read_text())
    funcs = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}

    def tiers_in(fn):
        out = set()
        for node in ast.walk(fn):
            if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "Candidate":
                kw = {k.arg: k.value for k in node.keywords}
                t = kw.get("tier")
                out.add(t.value if isinstance(t, ast.Constant) else "safe" if t is None else "?")
        return out

    for name, (fn, _desc) in hh.RULES.items():
        got = tiers_in(funcs[fn.__name__])
        assert policy[name]["tier"] in got, f"{name}: policy says {policy[name]['tier']}, code gives {got}"
    assert hh.Candidate("x", "/x", 1, "x").tier == "safe", "the default this test assumes"


def test_f23_peer_work_is_surfaced_and_a_rule_naming_it_deletes_nothing(hh):
    """A rule that did name a peer tree is what the guard is for, so that is what
    this feeds it.  With is_peer_work out of is_forbidden, this fails."""
    with fake_home(hh) as home, gates_open(hh):
        peer_work_home(home)
        worktree = home / "Code" / "BotFleet" / ".muse" / "worktrees" / "one"
        lane_build = old_tree(worktree / ".build")
        tree_build = old_tree(home / "apps" / "botfleet-mm-mcode" / ".build")
        with mock.patch.object(hh, "open_handles", return_value=0):
            report = {c.path: c for c in hh.rule_ask_first_inventory()}
        for path in (worktree.parent, home / "apps" / "botfleet-mm-mcode"):
            assert report[str(path)].op == "report", path

        def rogue_rule():
            return [hh.Candidate("rogue", str(lane_build), GIB, "x"),
                    hh.Candidate("rogue", str(tree_build), GIB, "x")]

        with mock.patch.dict(hh.RULES, {"rogue": (rogue_rule, "")}, clear=True):
            found = hh.scan(None)
        assert len(found) == 2
        for c in found:
            hh.apply_candidate(c)
            assert not c.applied and c.error == "forbidden path", (c.path, c.error)
        assert lane_build.is_dir() and tree_build.is_dir()


# --------------------------------------------------------------------------
# Second review: stale-build-output and xcode-scratch became report-only, and
# `.tmp` left the delete targets.  A refuse-list kept leaking.
# --------------------------------------------------------------------------

def test_report_rules_can_never_produce_a_deletable_candidate(hh):
    """With every gate open and the disk at the line, at the rule, the run and
    the delete itself."""
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        targets = [old_tree(repo / n) for n in (".build", ".next", "build", "target")]
        tree = xcode_tree(home)

        rows = hh.rule_stale_build_output() + hh.rule_xcode_scratch()
        assert rule_paths(rows) == {str(t) for t in targets} | {str(tree)}, rows
        for c in rows:
            assert (c.tier, c.op) == ("ask-first", "report"), c
            assert c.recheck is None, c
            assert "report only" in c.reason, c.reason
            hh.apply_candidate(c)
            assert not c.applied, c.path
        assert tree.is_dir() and all(t.is_dir() for t in targets)

        band = hh.Band(1.0, 99.0, 0.0, 1.0, False, cpu_idle_pct=50.0)
        for argv in (["--clean", "--json", "--band=full"], ["--scan", "--json", "--band=full"]):
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(hh, "read_band", return_value=band), \
                    mock.patch.object(hh, "apply_delete", side_effect=AssertionError("deleted")), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                assert hh.main(argv + ["--categories=stale-build-output,xcode-scratch"]) == 0
            report = json.loads(out.getvalue())
            assert report["actionable_count"] == 0 and report["applied_count"] == 0, report
        assert tree.is_dir() and all(t.is_dir() for t in targets)


def test_report_rules_have_no_way_to_build_a_deleting_candidate(hh):
    tree = ast.parse(ENGINE.read_text())
    funcs = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
    for name in ("rule_stale_build_output", "rule_xcode_scratch"):
        calls = [n for n in ast.walk(funcs[name])
                 if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "Candidate"]
        assert calls, name
        for call in calls:
            kw = {k.arg: k.value for k in call.keywords}
            assert kw["tier"].value == "ask-first" and kw["op"].value == "report", name
            assert "recheck" not in kw, name
    assert not hh.PRESSURE_ONLY_RULES & hh.REPORT_ONLY_WALK_RULES


def test_stale_build_lists_each_name_with_nothing_found_against_it(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        old_tree(repo / ".build")
        old_tree(repo / "dist")
        found = hh.rule_stale_build_output()
        assert rule_paths(found) == {str(repo / ".build")}, found


def test_xcode_scratch_lists_what_it_found_and_ignores_what_is_not_xcode(hh):
    with fake_home(hh) as home, gates_open(hh):
        tree = xcode_tree(home)
        other = home / "private-tmp" / "not-xcode"
        old_tree(other, 30)
        found = {c.path: c for c in hh.rule_xcode_scratch()}
        assert list(found) == [str(tree)], found
        assert "nothing the checks can see" in found[str(tree)].reason
        with mock.patch.object(hh, "tree_in_use", return_value=True):
            assert "held open" in hh.rule_xcode_scratch()[0].reason


def test_a_clean_run_does_not_walk_for_report_rows_or_a_closed_pressure_rule(hh):
    def rules_scanned(argv, free):
        ran = []
        fakes = {}
        for name in hh.RULES:
            def fn(name=name):
                ran.append(name)
                return []
            fakes[name] = (fn, "")
        band = hh.Band(free, 50.0, 0.0, 1.0, False, cpu_idle_pct=50.0)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(hh, "RULES", fakes), mock.patch.object(hh, "read_band", return_value=band), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            assert hh.main(argv) == 0
        return set(ran)

    report = {"stale-build-output", "xcode-scratch"}
    dup = "duplicate-sim-runtimes"
    assert not (report | {dup}) & rules_scanned(["--clean", "--json"], 10.0), "cheap band"
    assert not (report | {dup}) & rules_scanned(["--clean", "--json", "--band=full"], 80.0), "above the line"
    at_line = rules_scanned(["--clean", "--json", "--band=full"], 10.0)
    assert dup in at_line and not report & at_line, "at the line"
    for argv in (["--scan", "--json"], ["--scan", "--json", "--band=full"]):
        assert report | {dup} <= rules_scanned(argv, 80.0), "a read-only scan shows what they see"
    assert "snapshots" in rules_scanned(["--clean", "--json"], 80.0), "older rules are not skipped"
    order = list(hh.RULES)
    for name in report:
        assert order.index(name) > order.index("brew"), "report rows cost nothing the safe rules need"


def test_the_duplicate_rule_applies_only_at_25_gb_free_or_less(hh):
    def run(free, known=True, argv=("--clean", "--json", "--band=full")):
        clock = FakeClock()
        band = hh.Band(free, 50.0, 0.0, 1.0, False, cpu_idle_pct=50.0, disk_free_known=known)
        cands = [
            hh.Candidate("duplicate-sim-runtimes", f"sim-runtime:{RUNTIME_B}", GIB, "x",
                         tier="semi-safe", op="simctl-runtime-delete"),
            hh.Candidate("snapshots", "apfs-snapshot:x", 0, "x", tier="semi-safe", op="snapshot-delete"),
        ]
        _code, report, _err = run_main(hh, list(argv), cands, band, clock)
        return {c["category"] for c in report["candidates"] if c["applied"]}

    dup = "duplicate-sim-runtimes"
    assert dup in run(25.0), "25 GB is inside the line"
    assert dup in run(10.0)
    assert dup not in run(25.01), "just above the line"
    assert dup not in run(78.14), "the measured 15 GB drop at 78 GB free"
    assert dup not in run(0.0, known=False), "a df that failed reads as 0.0 and is not pressure"
    assert "snapshots" in run(200.0), "an existing semi-safe rule keeps its schedule"
    assert dup not in run(10.0, argv=("--clean", "--json")), "and the cheap band never reaches it"


def test_the_duplicate_rule_rereads_free_space_at_the_delete(hh):
    fake = FakeSimctl()
    for free, why in ((26.0, "the disk has recovered"), (None, "df could not answer")):
        with simctl_env(hh, fake), mock.patch.object(hh, "read_disk_free", return_value=free):
            c = hh.rule_duplicate_sim_runtimes()[0]
            hh.apply_candidate(c)
        assert not c.applied and c.refused and not c.error, why
        assert fake.deletes() == [], why
    with simctl_env(hh, fake), mock.patch.object(hh, "read_disk_free", return_value=24.0):
        c = hh.rule_duplicate_sim_runtimes()[0]
        hh.apply_candidate(c)
    assert c.applied and fake.deletes() == [["runtime", "delete", RUNTIME_B]], (c.error, c.refused)


def test_the_policy_and_docs_state_the_line_and_the_report_rules(hh):
    policy = json.loads(hh.POLICY_PATH.read_text())
    rules = {r["name"]: r for r in policy["rules"]}
    assert hh.PRESSURE_RULE_FREE_GB == 25.0
    assert set(hh.PRESSURE_ONLY_RULES) == {"duplicate-sim-runtimes"}
    assert rules["duplicate-sim-runtimes"]["maxFreeGb"] == hh.PRESSURE_RULE_FREE_GB
    for name in hh.REPORT_ONLY_WALK_RULES:
        assert (rules[name]["tier"], rules[name]["op"]) == ("ask-first", "report"), name
        assert "maxFreeGb" not in rules[name], name
    root = ENGINE.parent.parent
    for doc in ("docs/DEV-CLEANUP-PLAYBOOK.md", "AGENTS.md", "docs/rollouts/2026-11-04-internal-disk-rules.md"):
        text = (root / doc).read_text(encoding="utf-8").replace("\u00a0", " ")
        assert "25 GB" in text and "duplicate-sim-runtimes" in text, doc
        assert "report only" in text.lower() or "report-only" in text.lower(), doc
        assert "not used" in text, f"{doc} must say the Nov 4 narrowing was not used"


def test_a_clean_run_does_not_walk_node_modules_for_the_report(hh):
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App")
        modules = old_tree(repo / "node_modules")
        band = hh.Band(100.0, 50.0, 0.0, 1.0, False, cpu_idle_pct=50.0)

        def rows(argv):
            walked = []
            real = hh.touched_since

            def spy(path, days):
                walked.append(path)
                return real(path, days)

            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(hh, "read_band", return_value=band), \
                    mock.patch.object(hh, "open_handles", return_value=0), \
                    mock.patch.object(hh, "touched_since", side_effect=spy), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                assert hh.main(argv) == 0
            return walked, {c["path"] for c in json.loads(out.getvalue())["candidates"]}

        walked, found = rows(["--clean", "--json", "--categories=ask-first"])
        assert str(modules) not in walked and str(modules) not in found
        walked, found = rows(["--scan", "--json", "--categories=ask-first"])
        assert str(modules) in walked and str(modules) in found, "a scan still shows it"


def test_agent_state_asks_about_a_checkout_only_after_the_cheap_gates(hh):
    with fake_home(hh) as home:
        tmp = home / ".claude" / "logs"
        tmp.mkdir(parents=True)
        (tmp / "a.log").write_text("x", encoding="utf-8")
        names = []
        real = hh.holds_keep_sentinel

        def spy(path, timeout, name=hh.KEEP_SENTINEL):
            names.append(name)
            return real(path, timeout, name=name)

        with agent_gates(hh), mock.patch.object(hh, "holds_keep_sentinel", side_effect=spy), \
                mock.patch.object(hh, "touched_since", return_value=True):
            assert hh.rule_agent_state() == []
        assert ".git" not in names, "an active tree is turned away without that walk"


def test_a_dot_tmp_is_never_a_delete_even_with_no_checkout_in_it(hh):
    """A live source with no `.git`: ~/.codex/config.toml names
    ~/.codex/.tmp/bundled-marketplaces/openai-bundled, and only a sibling clone
    was keeping the tree from being deleted."""
    with fake_home(hh) as home:
        tmp = home / ".codex" / ".tmp"
        bundled = tmp / "bundled-marketplaces" / "openai-bundled"
        blob(bundled / "plugins.bin", 30, 9 * 1024 * 1024)
        (home / ".codex" / "config.toml").write_text(f'source = "{bundled}"\n', encoding="utf-8")
        assert ".tmp" not in hh._AGENT_TRANSIENT
        with agent_gates(hh):
            found = hh.rule_agent_state()
        assert str(tmp) not in rule_paths(found), found
        report = {c.path: c for c in hh.rule_ask_first_inventory()}
        assert report[str(tmp)].op == "report", "and it stays visible"
        assert report[str(tmp)].tier == "ask-first"
        (home / ".grok" / "sub" / ".tmp").mkdir(parents=True)
        with agent_gates(hh):
            assert not any(c.path.endswith("/.tmp") for c in hh.rule_agent_state()), "a level down too"


def test_git_answers_for_the_repo_it_was_asked_about(hh):
    """GIT_DIR outranks -C, so a wrapper or hook that exported it had the tracked
    and ignored checks answer for another repository."""
    with fake_home(hh) as home, gates_open(hh):
        repo = git_repo(home / "Code" / "App", ignore="")
        blob(repo / "build" / "deploy.bin", 30)
        run_git(repo, "add", "build/deploy.bin")
        run_git(repo, "commit", "-q", "-m", "tracked")
        age_all(repo / "build", 30)
        assert "does not ignore" in str(hh.stale_build_refusal(repo, "build")), "the control"
        other = git_repo(home / "other", ignore="build/\n")
        for env in ({"GIT_DIR": str(other / ".git")},
                    {"GIT_DIR": str(other / ".git"), "GIT_WORK_TREE": str(other)},
                    {"GIT_INDEX_FILE": str(other / ".git" / "index")}):
            with mock.patch.dict(os.environ, env):
                assert "does not ignore" in str(hh.stale_build_refusal(repo, "build")), env
        names = {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES"}
        with mock.patch.dict(os.environ, {n: "/x" for n in names} | {"HOME": str(home)}):
            env = hh._git_env()
        assert not names & set(env), env
        assert env["HOME"] == str(home) and env["GIT_OPTIONAL_LOCKS"] == "0"
    assert ENGINE.read_text().count('"/usr/bin/git"') == 1, "every git call goes through _git"


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

#!/usr/bin/env python3
"""Regression tests for the Hog Hunter reclaim engine.

Deliberately narrow: these cover the pure functions that can fail SILENTLY.
A reclaim engine that no-ops and reports success is worse than one that is
down, because the operator believes disk was handled.

Run:  python3 scripts/test-hoghunter-clean.py
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import sys
from pathlib import Path

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

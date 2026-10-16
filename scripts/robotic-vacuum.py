#!/usr/bin/env python3
"""Backward-compatible entry for launchd and shims.  Prefer scripts/maintain.py."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_MAINTAIN_PATH = Path(__file__).resolve().with_name("maintain.py")
_spec = importlib.util.spec_from_file_location("hoghunter_maintain_cli", _MAINTAIN_PATH)
_mod = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_mod)
main = _mod.main
# Tests load this module and patch these names the way maintain.py binds them at import.
NO_NOTIFY_ENV = _mod.NO_NOTIFY_ENV
evaluate_alerts = _mod.evaluate_alerts
notify_macos = _mod.notify_macos

if __name__ == "__main__":
    raise SystemExit(main())

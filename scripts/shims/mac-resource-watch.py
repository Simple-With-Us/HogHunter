#!/usr/bin/env python3
"""Thin shim — forwards to Hog Hunter Robotic Vacuum watch tick."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

# Fleet registry (high level): docs/mac-local-processes-shims.md
def _repo_root() -> Path:
    env = os.environ.get("HOGHUNTER_REPO", "").strip()
    if env:
        return Path(env)
    here = Path(__file__).resolve()
    return here.parents[2]


REPO = _repo_root()
cmd = [sys.executable, str(REPO / "scripts" / "robotic-vacuum.py"), "--run-now", "watch"]
if "--once" in sys.argv:
    pass
raise SystemExit(subprocess.call(cmd))

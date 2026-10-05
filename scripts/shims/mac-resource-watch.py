#!/usr/bin/env python3
"""Thin shim — forwards to Hog Hunter Robotic Vacuum watch tick."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

# Fleet registry: docs/mac-local-processes-shims.md (mirror to ~/apps/MAC-LOCAL-PROCESSES.md on Mac).
REPO = Path(os.environ.get("HOGHUNTER_REPO", Path.home() / "Code" / "HogHunter"))
cmd = [sys.executable, str(REPO / "scripts" / "robotic-vacuum.py"), "--run-now", "watch"]
if "--once" in sys.argv:
    pass
raise SystemExit(subprocess.call(cmd))

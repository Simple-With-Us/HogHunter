#!/usr/bin/env python3
"""Thin shim - forwards to Hog Hunter Robotic Vacuum watch tick."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

# Fleet registry (high level): docs/mac-local-processes-shims.md


def _resolve_repo() -> Path:
    env = os.environ.get("HOGHUNTER_REPO", "").strip()
    if env:
        return Path(env)
    here = Path(__file__).resolve()
    bundled = here.parents[2]
    if (bundled / "scripts" / "robotic-vacuum.py").is_file():
        return bundled
    home = Path.home()
    for candidate in (home / "Code" / "HogHunter", home / "apps" / "HogHunter"):
        if (candidate / "scripts" / "robotic-vacuum.py").is_file():
            return candidate
    return bundled


def main() -> int:
    repo = _resolve_repo()
    script = repo / "scripts" / "robotic-vacuum.py"
    if not script.is_file():
        print("set HOGHUNTER_REPO to the Hog Hunter clone", file=sys.stderr)
        return 2
    cmd = [sys.executable, str(script), "--run-now", "watch"]
    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())

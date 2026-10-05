from __future__ import annotations

import re
import subprocess
import sys
import time
from typing import Any, Optional


def _run(cmd: list[str], timeout: int = 20) -> str:
    if sys.platform != "darwin":
        return ""
    try:
        return subprocess.check_output(cmd, text=True, timeout=timeout, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def sample_mac() -> dict[str, Any]:
    """Sample disk, swap, and load.  On Linux returns zeros for tests."""
    if sys.platform != "darwin":
        return {
            "at": int(time.time()),
            "disk_free_gb": 100.0,
            "disk_used_pct": 50.0,
            "swap_total_gb": 0.0,
            "swap_used_gb": 0.0,
            "swap_used_pct": 0.0,
            "load1": 0.0,
            "load5": 0.0,
            "load15": 0.0,
        }

    df = _run(["/bin/df", "-k", "/System/Volumes/Data"]) or _run(["/bin/df", "-k", "/"])
    disk_free_gb = disk_used_pct = 0.0
    for line in df.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 5:
            avail_k = float(parts[3])
            cap = parts[4].rstrip("%")
            disk_free_gb = avail_k / 1024 / 1024
            try:
                disk_used_pct = float(cap)
            except ValueError:
                disk_used_pct = 0.0
            break

    vm = _run(["/usr/sbin/sysctl", "-n", "vm.swapusage"])
    swap_total_gb = swap_used_gb = 0.0
    m = re.search(r"total\s*=\s*([\d.]+)M.*?used\s*=\s*([\d.]+)M", vm)
    if m:
        swap_total_gb = float(m.group(1)) / 1024
        swap_used_gb = float(m.group(2)) / 1024
    swap_used_pct = (swap_used_gb / swap_total_gb * 100) if swap_total_gb else 0.0

    up = _run(["/usr/bin/uptime"])
    load1 = load5 = load15 = 0.0
    lm = re.search(r"load averages?:\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)", up)
    if lm:
        load1, load5, load15 = (float(lm.group(i)) for i in (1, 2, 3))

    return {
        "at": int(time.time()),
        "disk_free_gb": round(disk_free_gb, 2),
        "disk_used_pct": round(disk_used_pct, 1),
        "swap_total_gb": round(swap_total_gb, 2),
        "swap_used_gb": round(swap_used_gb, 2),
        "swap_used_pct": round(swap_used_pct, 1),
        "load1": round(load1, 2),
        "load5": round(load5, 2),
        "load15": round(load15, 2),
    }


def evaluate_hits(sample: dict[str, Any], prev_free: Optional[float], rw_cfg: dict[str, Any]) -> list[dict[str, Any]]:
    hits: list[dict[str, Any]] = []
    free = float(sample.get("disk_free_gb", 0))
    crit = float(rw_cfg.get("disk_free_crit_gb", 15))
    warn = float(rw_cfg.get("disk_free_warn_gb", 25))
    drop_thr = float(rw_cfg.get("disk_drop_alert_gb", 15))
    swap_pct_thr = float(rw_cfg.get("swap_used_pct", 90))
    swap_gb_thr = float(rw_cfg.get("swap_used_gb", 32))
    load_thr = float(rw_cfg.get("load1_threshold", 65))

    if free <= crit:
        hits.append({"metric": "disk_free_gb", "severity": "critical", "threshold": crit, "value": free})
    elif free <= warn:
        hits.append({"metric": "disk_free_gb", "severity": "warn", "threshold": warn, "value": free})

    if prev_free is not None:
        drop = prev_free - free
        if drop >= drop_thr:
            hits.append({"metric": "disk_drop_gb", "severity": "warn", "threshold": drop_thr, "value": round(drop, 2)})

    swap_pct = float(sample.get("swap_used_pct", 0))
    swap_used_gb = float(sample.get("swap_used_gb", 0))
    if swap_pct >= swap_pct_thr and swap_used_gb >= swap_gb_thr:
        critical_swap = swap_pct >= max(swap_pct_thr + 5.0, 95.0)
        hits.append({
            "metric": "swap",
            "severity": "critical" if critical_swap else "warn",
            "threshold": swap_pct_thr,
            "value": swap_pct,
        })

    if float(sample.get("load1", 0)) >= load_thr:
        hits.append({"metric": "load_1m", "severity": "warn", "threshold": load_thr, "value": sample["load1"]})
    return hits


def janitor_pressure_mode(sample: dict[str, Any], janitor_cfg: dict[str, Any]) -> str:
    """Return hard, lean, or normal."""
    load1 = float(sample.get("load1", 0))
    swap_pct = float(sample.get("swap_used_pct", 0))
    if load1 > float(janitor_cfg.get("max_load_hard", 250)) or swap_pct >= float(janitor_cfg.get("max_swap_pct_hard", 98)):
        return "hard"
    if load1 >= float(janitor_cfg.get("soft_load", 150)) or swap_pct >= float(janitor_cfg.get("soft_swap_pct", 90)):
        return "lean"
    return "normal"

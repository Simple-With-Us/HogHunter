#!/usr/bin/env python3
"""HogHunter MCP Server & Agent Backend.

Provides a Model Context Protocol (MCP) stdio interface and CLI for AI agents to
monitor system hogs (CPU, Memory, Network), inspect storage clutter, audit
re-download churn risk, safely clean disposable artifacts, and terminate runaway processes.

Usage as MCP server (stdio):
  python3 scripts/hoghunter-mcp.py

Usage as CLI:
  python3 scripts/hoghunter-mcp.py --cli top [--sort-by cpu|memory] [--window now|1h|24h] [--limit N]
  python3 scripts/hoghunter-mcp.py --cli network [--limit N]
  python3 scripts/hoghunter-mcp.py --cli scan [--tier standard|extreme]
  python3 scripts/hoghunter-mcp.py --cli audit [--path PATH]
  python3 scripts/hoghunter-mcp.py --cli clean <path1> [path2...] [--dry-run] [--no-snapshot]
  python3 scripts/hoghunter-mcp.py --cli quit <PID> [--force]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "hoghunter-mcp", "version": "1.0.0"}

HOME = Path.home()
HOGHUNTER_DB_PATH = HOME / "Library" / "Application Support" / "HogHunter" / "history.sqlite"

# High-churn / instant re-download cache identifiers
# Deleting these causes applications to immediately saturate bandwidth and I/O re-downloading
HIGH_CHURN_PATTERNS = [
    (r"com\.spotify\.client", "Spotify streaming & offline media cache"),
    (r"com\.apple\.music", "Apple Music streaming audio cache"),
    (r"com\.apple\.podcasts", "Apple Podcasts episode download cache"),
    (r"com\.apple\.itunescloudd", "iTunes Cloud media streaming cache"),
    (r"com\.apple\.applemediaservices", "Apple Media Services streaming cache"),
    (r"com\.google\.googledrive", "Google Drive cloud file streaming cache"),
    (r"dropbox", "Dropbox cloud file cache"),
    (r"onedrive", "Microsoft OneDrive cloud file cache"),
    (r"com\.apple\.safari", "Safari active web session & site cache"),
    (r"google/chrome", "Chrome active web session & service worker cache"),
    (r"\.cache/huggingface", "Hugging Face AI model weights repository"),
    (r"\.ollama/models", "Ollama local LLM model weights library"),
    (r"torch/kernels", "PyTorch compiled kernel cache")
]

PROHIBITED_EXACT_ROOTS = [
    Path("/"),
    Path("/System"),
    Path("/Library"),
    Path("/usr"),
    Path("/bin"),
    Path("/sbin"),
    Path("/Applications"),
    Path("/Users"),
    HOME,
    HOME / "Library",
    HOME / "Desktop",
    HOME / "Documents",
    HOME / "Downloads",
    HOME / "Code",
    HOME / "apps"
]

PROTECTED_SUBTREE_ROOTS = [
    Path("/System"),
    Path("/Library"),
    Path("/usr"),
    Path("/bin"),
    Path("/sbin"),
    Path("/Applications"),
    HOME / "Code",
    HOME / "apps"
]

SENSITIVE_USER_DIRECTORIES = [
    HOME / ".ssh",
    HOME / ".gnupg",
    HOME / ".aws",
    HOME / ".config",
    HOME / ".secrets",
    HOME / "Library" / "Mail",
    HOME / "Library" / "Messages",
    HOME / "Library" / "Keychains",
    HOME / "Library" / "Photos",
    HOME / "Library" / "Safari",
    HOME / "Library" / "Calendars",
    HOME / "Library" / "Containers",
    HOME / "Pictures",
    HOME / "Music",
    HOME / "Movies"
]

SYSTEM_CRITICAL_PROCESS_NAMES = {
    "launchd", "kernel_task", "windowserver", "loginwindow", "systemuiserver",
    "controlcenter", "notificationcenter", "finder", "dock", "coreaudiod",
    "hoghunter", "securityd", "opendirectoryd", "diskarbitrationd"
}


def format_bytes(num_bytes: int) -> str:
    """Format bytes into human-readable string."""
    if num_bytes < 1024:
        return f"{num_bytes} B"
    for unit in ["KB", "MB", "GB", "TB"]:
        num_bytes /= 1024.0
        if num_bytes < 1024.0:
            return f"{num_bytes:.1f} {unit}"
    return f"{num_bytes:.1f} PB"


def get_live_top_processes(sort_by: str = "cpu", limit: int = 10) -> List[Dict[str, Any]]:
    """Query live processes using ps."""
    try:
        output = subprocess.check_output(
            ["ps", "-eo", "pid,ppid,%cpu,%mem,rss,time,comm"],
            text=True,
            stderr=subprocess.DEVNULL
        )
    except Exception as exc:
        return [{"error": f"Failed to run ps: {exc}"}]

    lines = output.strip().splitlines()
    if len(lines) <= 1:
        return []

    processes = []
    for line in lines[1:]:
        parts = line.strip().split(maxsplit=6)
        if len(parts) < 7:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
            cpu = float(parts[2])
            mem_pct = float(parts[3])
            rss_kb = int(parts[4])
            cpu_time = parts[5]
            comm = parts[6]
            name = Path(comm).name

            # Skip kernel / systemidle
            if pid == 0:
                continue

            processes.append({
                "pid": pid,
                "ppid": ppid,
                "name": name,
                "path": comm,
                "cpu_percent": cpu,
                "memory_percent": mem_pct,
                "memory_bytes": rss_kb * 1024,
                "memory_human": format_bytes(rss_kb * 1024),
                "cpu_time": cpu_time,
                "is_hog": cpu >= 50.0 or (rss_kb * 1024) >= 1_000_000_000
            })
        except ValueError:
            continue

    if sort_by == "memory":
        processes.sort(key=lambda p: p["memory_bytes"], reverse=True)
    else:
        processes.sort(key=lambda p: p["cpu_percent"], reverse=True)

    return processes[:limit]


def get_historical_top_processes(window: str = "1h", sort_by: str = "cpu", limit: int = 10) -> List[Dict[str, Any]]:
    """Query historical samples from HogHunter SQLite database."""
    if not HOGHUNTER_DB_PATH.exists():
        return [{
            "status": "unavailable",
            "error": f"HogHunter historical database not found at {HOGHUNTER_DB_PATH}. History is recorded when the Hog Hunter app is running.",
            "window": window
        }]

    seconds = 3600 if window == "1h" else 86400
    cutoff = int(time.time()) - seconds

    try:
        conn = sqlite3.connect(f"file:{HOGHUNTER_DB_PATH}?mode=ro", uri=True)
        cursor = conn.cursor()
        order_col = "avg_mem" if sort_by == "memory" else "avg_cpu"
        query = f"""
            WITH win AS (SELECT COUNT(*) AS n FROM ticks WHERE ts >= ?),
            per_ts AS (
              SELECT ts, pid, name, bundle,
                     SUM(cpu) AS cpu, SUM(mem) AS mem
              FROM samples WHERE ts >= ? GROUP BY ts, pid, name
            )
            SELECT pid, MIN(name) AS name, MIN(bundle) AS bundle,
                   SUM(cpu) * 1.0 / MAX(win.n, 1) as avg_cpu,
                   MAX(cpu) as max_cpu,
                   SUM(mem) * 1.0 / MAX(win.n, 1) as avg_mem,
                   MAX(mem) as max_mem,
                   COUNT(*) as sample_count,
                   win.n as total_ticks
            FROM per_ts, win
            GROUP BY pid, name
            ORDER BY {order_col} DESC
            LIMIT ?
        """
        cursor.execute(query, (cutoff, cutoff, limit))
        rows = cursor.fetchall()
        conn.close()

        results = []
        for row in rows:
            results.append({
                "last_sampled_pid": row[0],
                "name": row[1],
                "bundle_id": row[2],
                "avg_cpu_percent": round(row[3], 1),
                "max_cpu_percent": round(row[4], 1),
                "avg_memory_bytes": int(row[5]),
                "avg_memory_human": format_bytes(int(row[5])),
                "max_memory_bytes": int(row[6]),
                "max_memory_human": format_bytes(int(row[6])),
                "samples_recorded": row[7],
                "window": window,
                "note": "Historical sample PID; do not pass directly to quit_process as PIDs may have been recycled. Use 'now' window for live termination."
            })
        return results
    except Exception as exc:
        return [{
            "status": "unavailable",
            "error": f"Failed to query historical database: {exc}",
            "window": window
        }]


def get_network_activity(limit: int = 10) -> List[Dict[str, Any]]:
    """Query active established TCP connections grouped by process."""
    try:
        output = subprocess.check_output(
            ["lsof", "-nP", "-iTCP", "-sTCP:ESTABLISHED"],
            text=True,
            stderr=subprocess.DEVNULL
        )
    except Exception as exc:
        return [{"error": f"Failed to run lsof: {exc}"}]

    lines = output.strip().splitlines()
    if len(lines) <= 1:
        return []

    # Map: pid -> {name, established_count, endpoints: set}
    process_conns: Dict[int, Dict[str, Any]] = {}

    for line in lines[1:]:
        parts = line.strip().split()
        if len(parts) < 9:
            continue
        comm = parts[0]
        try:
            pid = int(parts[1])
        except ValueError:
            continue

        endpoint_info = parts[8] if len(parts) >= 9 else ""
        if "->" in endpoint_info:
            remote = endpoint_info.split("->")[1]
        else:
            remote = endpoint_info

        if pid not in process_conns:
            process_conns[pid] = {
                "pid": pid,
                "name": comm,
                "established_count": 0,
                "remote_hosts": set()
            }

        process_conns[pid]["established_count"] += 1
        if remote:
            # Strip port
            remote_host = remote.rsplit(":", 1)[0]
            process_conns[pid]["remote_hosts"].add(remote_host)

    results = []
    for pid, data in process_conns.items():
        results.append({
            "pid": pid,
            "name": data["name"],
            "established_connections": data["established_count"],
            "unique_remote_hosts": len(data["remote_hosts"]),
            "sample_remote_hosts": sorted(list(data["remote_hosts"]))[:5]
        })

    results.sort(key=lambda x: (x["established_connections"], x["unique_remote_hosts"]), reverse=True)
    return results[:limit]


def audit_path_churn_risk(path_str: str) -> Dict[str, Any]:
    """Check if a path has high re-download / churn penalty."""
    p = Path(path_str)
    p_lower = path_str.lower()

    if p.is_dir() and (p / "Chrome").exists():
        return {
            "path": path_str,
            "is_high_churn": True,
            "risk_level": "high",
            "reason": "Contains Google Chrome active web session & service worker cache",
            "recommendation": "Do not delete by default. Chrome will immediately re-download active web assets."
        }

    for pattern, reason in HIGH_CHURN_PATTERNS:
        if re.search(pattern, p_lower):
            return {
                "path": path_str,
                "is_high_churn": True,
                "risk_level": "high",
                "reason": reason,
                "recommendation": "Do not delete by default. App will immediately re-download this data over the network."
            }

    # Safe transient patterns
    if any(k in p_lower for k in [
        "deriveddata", "cacache", ".botfleet-server.node_modules.",
        ".botfleet.update-", "diagnosticreports", "crashreporter"
    ]):
        return {
            "path": path_str,
            "is_high_churn": False,
            "risk_level": "zero",
            "reason": "Abandoned build, package cache, crash trace, or failed update debris",
            "recommendation": "Safe to delete. Zero bandwidth re-download penalty."
        }

    return {
        "path": path_str,
        "is_high_churn": False,
        "risk_level": "normal",
        "reason": "Standard cache or temporary directory",
        "recommendation": "Inspect before cleaning if associated application is actively running."
    }


def scan_storage_clutter(tier: str = "standard", include_details: bool = True) -> Dict[str, Any]:
    """Scan macOS storage across categories including BotFleet update debris."""
    categories: Dict[str, List[Dict[str, Any]]] = {
        "user_caches": [],
        "developer": [],
        "ai_artifacts": [],
        "logs_diagnostics": [],
        "trash": [],
        "botfleet_debris": []
    }

    # 1. BotFleet update & failed node_modules debris (up to 12+ GB)
    apps_dir = HOME / "apps"
    if apps_dir.exists():
        for item in apps_dir.glob(".botfleet-server.node_modules.*"):
            if item.is_dir():
                size = get_dir_size(item)
                if size > 0:
                    categories["botfleet_debris"].append({
                        "name": item.name,
                        "path": str(item),
                        "bytes": size,
                        "human_size": format_bytes(size),
                        "detail": "Failed or rollback node_modules directory left by BotFleet updater",
                        "churn_risk": "zero"
                    })

    # ~/.BotFleet.update-* in home (must be older than 7 days to not interrupt active downloads)
    for item in HOME.glob(".BotFleet.update-*"):
        try:
            mtime = item.stat().st_mtime
            if time.time() - mtime < 7 * 86400:
                continue
            size = get_dir_size(item) if item.is_dir() else item.stat().st_size
            if size > 0:
                categories["botfleet_debris"].append({
                    "name": item.name,
                    "path": str(item),
                    "bytes": size,
                    "human_size": format_bytes(size),
                    "detail": "Stale BotFleet update package in home directory (inactive > 7 days)",
                    "churn_risk": "zero"
                })
        except OSError:
            pass

    # ~/.botfleet/native rotated logs
    bf_native = HOME / ".botfleet" / "native"
    if bf_native.exists():
        for log_file in bf_native.glob("*.ndjson.1"):
            try:
                size = log_file.stat().st_size
                if size > 0:
                    categories["botfleet_debris"].append({
                        "name": log_file.name,
                        "path": str(log_file),
                        "bytes": size,
                        "human_size": format_bytes(size),
                        "detail": "Rotated agent transcript log dump",
                        "churn_risk": "zero"
                    })
            except OSError:
                pass

    # 2. Developer caches
    dev_targets = [
        ("Xcode DerivedData", HOME / "Library" / "Developer" / "Xcode" / "DerivedData"),
        ("Xcode Archives", HOME / "Library" / "Developer" / "Xcode" / "Archives"),
        ("Homebrew Cache", HOME / "Library" / "Caches" / "Homebrew"),
        ("npm Cache", HOME / ".npm" / "_cacache"),
        ("pnpm Cache", HOME / "Library" / "Caches" / "pnpm"),
        ("Yarn Cache", HOME / "Library" / "Caches" / "Yarn"),
        ("Go Build Cache", HOME / "Library" / "Caches" / "go-build")
    ]
    for name, p in dev_targets:
        if p.exists():
            size = get_dir_size(p)
            if size > 0:
                categories["developer"].append({
                    "name": name,
                    "path": str(p),
                    "bytes": size,
                    "human_size": format_bytes(size),
                    "detail": "Developer build artifacts & package manager cache",
                    "churn_risk": "zero"
                })

    # 3. User caches (with churn evaluation and Chrome subfolder inspection)
    user_caches_dir = HOME / "Library" / "Caches"
    if user_caches_dir.exists():
        try:
            children = list(user_caches_dir.iterdir())
        except OSError:
            children = []

        for child in children:
            if child.name in ["Homebrew", "pnpm", "Yarn", "go-build", "CocoaPods", "pip", "com.apple.dt.Xcode"]:
                continue
            if "hoghunter" in child.name.lower():
                continue

            targets = [child]
            if child.is_dir() and child.name in ["Google"]:
                try:
                    subs = [c for c in child.iterdir() if c.is_dir()]
                    if subs:
                        targets = subs
                except OSError:
                    pass

            for target in targets:
                try:
                    size = get_dir_size(target) if target.is_dir() else get_allocated_size(target)
                    if size >= 10 * 1024 * 1024:  # >= 10 MB
                        audit = audit_path_churn_risk(str(target))
                        display_name = f"{child.name}/{target.name}" if target != child else child.name
                        categories["user_caches"].append({
                            "name": display_name,
                            "path": str(target),
                            "bytes": size,
                            "human_size": format_bytes(size),
                            "detail": audit["reason"],
                            "churn_risk": audit["risk_level"],
                            "recommendation": audit["recommendation"]
                        })
                except OSError:
                    continue

    # 4. Trash
    trash_dir = HOME / ".Trash"
    if trash_dir.exists():
        try:
            for child in trash_dir.iterdir():
                if child.name.startswith(".DS_Store"):
                    continue
                size = get_dir_size(child) if child.is_dir() else child.stat().st_size
                if size > 0:
                    categories["trash"].append({
                        "name": child.name,
                        "path": str(child),
                        "bytes": size,
                        "human_size": format_bytes(size),
                        "detail": "Sitting in Trash",
                        "churn_risk": "zero"
                    })
        except OSError:
            pass

    # 5. Extreme tier additions: AI artifacts, logs & diagnostics, large/old files
    if tier == "extreme":
        ai_dirs = [
            ("HuggingFace Cache", HOME / ".cache" / "huggingface"),
            ("Ollama Models", HOME / ".ollama" / "models"),
            ("PyTorch Kernels & Cache", HOME / ".cache" / "torch"),
            ("vLLM Cache", HOME / ".cache" / "vllm")
        ]
        for name, p in ai_dirs:
            if p.exists():
                size = get_dir_size(p)
                if size > 0:
                    audit = audit_path_churn_risk(str(p))
                    categories["ai_artifacts"].append({
                        "name": name,
                        "path": str(p),
                        "bytes": size,
                        "human_size": format_bytes(size),
                        "detail": audit["reason"],
                        "churn_risk": audit["risk_level"],
                        "recommendation": audit["recommendation"]
                    })

        # CrashReporter
        crash_reporter = HOME / "Library" / "Application Support" / "CrashReporter"
        if crash_reporter.exists():
            size = get_dir_size(crash_reporter)
            if size >= 1024 * 1024:
                categories["logs_diagnostics"].append({
                    "name": "CrashReporter",
                    "path": str(crash_reporter),
                    "bytes": size,
                    "human_size": format_bytes(size),
                    "detail": "Application crash reporter traces",
                    "churn_risk": "zero"
                })

        # User Diagnostic Reports
        diag_reports = HOME / "Library" / "Logs" / "DiagnosticReports"
        if diag_reports.exists():
            size = get_dir_size(diag_reports)
            if size >= 1024 * 1024:
                categories["logs_diagnostics"].append({
                    "name": "User Diagnostic Reports",
                    "path": str(diag_reports),
                    "bytes": size,
                    "human_size": format_bytes(size),
                    "detail": "System and user diagnostic crash reports",
                    "churn_risk": "zero"
                })

        # Other logs in ~/Library/Logs excluding DiagnosticReports to avoid double-counting
        user_logs = HOME / "Library" / "Logs"
        if user_logs.exists():
            try:
                for child in user_logs.iterdir():
                    if child.name in ["DiagnosticReports", ".DS_Store"] or "hoghunter" in child.name.lower():
                        continue
                    size = get_dir_size(child) if child.is_dir() else get_allocated_size(child)
                    if size >= 1024 * 1024:
                        categories["logs_diagnostics"].append({
                            "name": f"User Logs ({child.name})",
                            "path": str(child),
                            "bytes": size,
                            "human_size": format_bytes(size),
                            "detail": "Application log files",
                            "churn_risk": "zero"
                        })
            except OSError:
                pass

        categories["large_and_old_files"] = []
        for search_folder in [HOME / "Downloads", HOME / "Desktop", HOME / "Documents"]:
            if search_folder.exists():
                try:
                    for root, dirs, files in os.walk(search_folder, topdown=True):
                        # Prune hidden subtrees, node_modules, and build directories before descent
                        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ["node_modules", "DerivedData", "Pods", "vendor", ".git"]]
                        for f in files:
                            if f.startswith("."):
                                continue
                            fp = Path(root) / f
                            try:
                                st = fp.stat()
                                if st.st_size >= 100 * 1024 * 1024:  # >= 100 MB
                                    age_days = (time.time() - st.st_mtime) / 86400
                                    if age_days >= 30:
                                        alloc_size = get_allocated_size(fp)
                                        categories["large_and_old_files"].append({
                                            "name": f,
                                            "path": str(fp),
                                            "bytes": alloc_size,
                                            "human_size": format_bytes(alloc_size),
                                            "detail": f"Large file ({format_bytes(alloc_size)}) not modified in {int(age_days)} days",
                                            "churn_risk": "zero"
                                        })
                            except OSError:
                                pass
                except OSError:
                    pass

    # Compute summary
    summary = {}
    total_reclaimable = 0
    total_high_churn = 0

    for cat_name, items in categories.items():
        cat_total = sum(i["bytes"] for i in items)
        summary[cat_name] = {
            "item_count": len(items),
            "bytes": cat_total,
            "human_size": format_bytes(cat_total)
        }
        for item in items:
            if item.get("churn_risk") == "high":
                total_high_churn += item["bytes"]
            else:
                total_reclaimable += item["bytes"]

    return {
        "scanned_at": datetime.now(timezone.utc).isoformat(),
        "tier": tier,
        "total_safe_reclaimable_bytes": total_reclaimable,
        "total_safe_reclaimable_human": format_bytes(total_reclaimable),
        "total_high_churn_bytes": total_high_churn,
        "total_high_churn_human": format_bytes(total_high_churn),
        "summary": summary,
        "categories": categories if include_details else {}
    }


def get_allocated_size(path: Path) -> int:
    """Calculate allocated disk bytes using st_blocks * 512 consistently."""
    try:
        if path.is_symlink() or not path.exists():
            return 0
        if path.is_file():
            st = path.stat()
            blocks = getattr(st, "st_blocks", 0)
            return blocks * 512 if blocks > 0 else st.st_size
        total = 0
        for root, dirs, files in os.walk(path, topdown=True):
            # Guard against runaway recursion
            if ".git" in dirs:
                dirs.remove(".git")
            for f in files:
                try:
                    fp = os.path.join(root, f)
                    if not os.path.islink(fp):
                        st = os.stat(fp)
                        blocks = getattr(st, "st_blocks", 0)
                        total += blocks * 512 if blocks > 0 else st.st_size
                except OSError:
                    continue
        return total
    except OSError:
        return 0


def get_dir_size(path: Path) -> int:
    """Calculate allocated bytes of directory safely."""
    return get_allocated_size(path)


def is_safe_to_delete(path_str: str) -> Tuple[bool, str]:
    """Strict safety validator for deleting paths."""
    resolved_path = Path(path_str).resolve()
    resolved = str(resolved_path)

    # 1. Enforce real home-directory boundary
    try:
        resolved_path.relative_to(HOME.resolve())
    except ValueError:
        return False, "Prohibited: path is outside user home directory"

    if resolved_path == HOME.resolve():
        return False, "Prohibited: cannot delete user home directory itself"

    # 2. Reject sensitive user directories (SSH keys, GPG, Mail, Messages, etc.)
    for sensitive in SENSITIVE_USER_DIRECTORIES:
        sens_path = sensitive.resolve()
        if resolved_path == sens_path:
            return False, f"Prohibited: path is protected sensitive directory ({sensitive})"
        try:
            resolved_path.relative_to(sens_path)
            return False, f"Prohibited: path is inside protected sensitive directory ({sensitive})"
        except ValueError:
            pass

    # 3. Reject exact prohibited roots
    for prohibited in PROHIBITED_EXACT_ROOTS:
        prohibited_path = prohibited.resolve()
        if resolved_path == prohibited_path:
            return False, f"Prohibited: path matches critical root folder ({prohibited})"

    # 4. Reject protected source trees and system folders (with BotFleet updater exception)
    for protected in PROTECTED_SUBTREE_ROOTS:
        protected_path = protected.resolve()
        try:
            rel = resolved_path.relative_to(protected_path)
            # Allowed exception: BotFleet update debris in ~/apps
            # e.g., ~/apps/.botfleet-server.node_modules.*
            if protected_path == (HOME / "apps").resolve():
                parts = rel.parts
                if parts and parts[0].startswith(".botfleet-server.node_modules."):
                    continue
            return False, f"Prohibited: path is inside protected folder ({protected})"
        except ValueError:
            pass

    if "/.git/" in resolved or resolved.endswith("/.git") or "/.secrets" in resolved:
        return False, "Prohibited: git directory or secrets directory"

    return True, "Safe"


def clean_clutter(paths: List[str], dry_run: bool = True, create_snapshot: bool = True) -> Dict[str, Any]:
    """Execute clutter cleanup with trash and APFS snapshot protection."""
    results = []
    total_permanently_reclaimed = 0
    total_moved_to_trash = 0
    total_planned_reclaimable = 0
    snapshot_name = None

    # Pre-validate paths before invoking tmutil to avoid creating empty snapshots
    validated_items: List[Tuple[str, Path, int]] = []
    for p_str in paths:
        path = Path(p_str).expanduser()
        if not path.exists():
            results.append({"path": p_str, "status": "skipped", "error": "Path does not exist"})
            continue

        safe, reason = is_safe_to_delete(str(path))
        if not safe:
            results.append({"path": p_str, "status": "rejected", "error": reason})
            continue

        size = get_allocated_size(path)
        validated_items.append((p_str, path, size))

    if create_snapshot and not dry_run and validated_items:
        try:
            out = subprocess.check_output(["tmutil", "localsnapshot"], text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                if "Created local snapshot with date:" in line:
                    snapshot_name = line.split(":")[-1].strip()
                    break
        except Exception:
            snapshot_name = "Snapshot creation unavailable"

    trash_dir = (HOME / ".Trash").resolve()

    for p_str, path, size in validated_items:
        if dry_run:
            results.append({
                "path": p_str,
                "status": "dry_run",
                "bytes_reclaimable": size,
                "human_size": format_bytes(size)
            })
            total_planned_reclaimable += size
        else:
            try:
                # Move to macOS Trash via file system move, or remove if already in ~/.Trash
                trash_target = HOME / ".Trash" / path.name
                counter = 1
                while trash_target.exists():
                    trash_target = HOME / ".Trash" / f"{path.stem}.{int(time.time())}.{counter}{path.suffix}"
                    counter += 1

                is_in_trash = False
                try:
                    path.resolve().relative_to(trash_dir)
                    is_in_trash = True
                except ValueError:
                    is_in_trash = False

                if is_in_trash:
                    # Item is already in ~/.Trash, permanently remove it
                    if path.is_dir():
                        shutil.rmtree(path)
                    else:
                        path.unlink()
                    total_permanently_reclaimed += size
                    results.append({
                        "path": p_str,
                        "status": "permanently_deleted",
                        "bytes_permanently_reclaimed": size,
                        "human_size": format_bytes(size)
                    })
                else:
                    # Move to Trash
                    shutil.move(str(path), str(trash_target))
                    total_moved_to_trash += size
                    results.append({
                        "path": p_str,
                        "status": "moved_to_trash",
                        "bytes_moved_to_trash": size,
                        "human_size": format_bytes(size)
                    })
            except Exception as exc:
                results.append({"path": p_str, "status": "failed", "error": str(exc)})

    return {
        "dry_run": dry_run,
        "snapshot": snapshot_name,
        "total_bytes_permanently_reclaimed": total_permanently_reclaimed,
        "total_human_permanently_reclaimed": format_bytes(total_permanently_reclaimed),
        "total_bytes_moved_to_trash": total_moved_to_trash,
        "total_human_moved_to_trash": format_bytes(total_moved_to_trash),
        "total_bytes_planned_reclaimable": total_planned_reclaimable if dry_run else 0,
        "total_human_planned_reclaimable": format_bytes(total_planned_reclaimable if dry_run else 0),
        "items": results
    }


def quit_process(pid: int, force: bool = False) -> Dict[str, Any]:
    """Request a process to quit safely."""
    if pid <= 1:
        return {"success": False, "error": "Cannot terminate PID <= 1"}

    try:
        proc_name = subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], text=True).strip()
    except Exception:
        return {"success": False, "error": f"Process {pid} not found"}

    try:
        uid_str = subprocess.check_output(["ps", "-p", str(pid), "-o", "uid="], text=True).strip()
        if int(uid_str) != os.getuid():
            return {"success": False, "error": f"Process {pid} is owned by another user (UID {uid_str})"}
    except Exception:
        pass

    base_name = Path(proc_name).name.lower()
    if base_name in SYSTEM_CRITICAL_PROCESS_NAMES:
        return {"success": False, "error": f"Refusing to kill critical system process: {base_name}"}

    if not force:
        try:
            # Try graceful AppleScript quit first if it's an app
            script = f'tell application "System Events" to set procName to name of first process whose unix id is {pid}\n' \
                     f'tell application procName to quit'
            res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=2)
            if res.returncode == 0:
                return {"success": True, "method": "applescript", "pid": pid, "name": base_name}
        except Exception:
            pass

    sig = 9 if force else 15
    try:
        os.kill(pid, sig)
        return {"success": True, "method": "SIGKILL" if force else "SIGTERM", "pid": pid, "name": base_name}
    except Exception as exc:
        return {"success": False, "error": str(exc)}


# MARK: - MCP Server Protocol Handling

TOOLS = [
    {
        "name": "hoghunter_top_processes",
        "description": "Get current or historical top CPU and memory hog processes on macOS. Pulls live process data or historical snapshots from HogHunter's SQLite database.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "window": {"type": "string", "enum": ["now", "1h", "24h"], "default": "now", "description": "Time window for aggregation ('now' = live ps, '1h' = 1-hour average, '24h' = 24-hour average)."},
                "sort_by": {"type": "string", "enum": ["cpu", "memory"], "default": "cpu", "description": "Sort metric."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "Max processes to return."}
            }
        }
    },
    {
        "name": "hoghunter_network_activity",
        "description": "Inspect active established TCP network connections on macOS, grouped by process and remote endpoints, identifying network hogs and external destinations.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "Max processes to return."}
            }
        }
    },
    {
        "name": "hoghunter_scan_storage",
        "description": "Scan macOS storage for clutter across categories (user caches, logs, trash, developer artifacts, orphaned data, AI agent sessions/artifacts, and large/old files). Includes BotFleet update and build debris.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "tier": {"type": "string", "enum": ["standard", "extreme"], "default": "standard", "description": "Scan depth tier."},
                "include_details": {"type": "boolean", "default": True, "description": "Whether to return itemized path details."}
            }
        }
    },
    {
        "name": "hoghunter_audit_churn_risk",
        "description": "Audit directories and cache folders to evaluate churn and instant re-download penalty. Distinguishes safe-to-delete transient build/log/updater debris from high-penalty media streaming (Spotify, Music), cloud sync (Google Drive, Dropbox), and AI model weight stores (HuggingFace, Ollama) that would immediately re-download gigabytes over the network if deleted.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Optional specific directory or cache path to evaluate. If omitted, audits all major cache categories."}
            }
        }
    },
    {
        "name": "hoghunter_clean_clutter",
        "description": "Safely delete approved clutter items on macOS. Moves items to the macOS Trash (or purges from ~/.Trash) with safety bounds preventing deletion of critical system, user, or code directories. Supports creating an APFS safety snapshot prior to deletion.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "paths": {"type": "array", "items": {"type": "string"}, "description": "List of file/folder paths to clean."},
                "dry_run": {"type": "boolean", "default": True, "description": "If true, simulates deletion and reports bytes reclaimable."},
                "create_snapshot": {"type": "boolean", "default": True, "description": "If true, creates an APFS local snapshot before moving files."}
            },
            "required": ["paths"]
        }
    },
    {
        "name": "hoghunter_quit_process",
        "description": "Request a process to quit safely. Tries AppleScript quit for GUI applications, or SIGTERM/SIGKILL for command-line processes. Refuses to terminate system-critical processes (launchd, WindowServer, kernel_task, HogHunter).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pid": {"type": "integer", "description": "Process PID to terminate."},
                "force": {"type": "boolean", "default": False, "description": "If true, sends SIGKILL instead of SIGTERM."}
            },
            "required": ["pid"]
        }
    }
]


def handle_tool_call(name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
    """Execute requested MCP tool and return tool result."""
    if name == "hoghunter_top_processes":
        window = arguments.get("window", "now")
        sort_by = arguments.get("sort_by", "cpu")
        limit = arguments.get("limit", 10)
        if window == "now":
            data = get_live_top_processes(sort_by=sort_by, limit=limit)
        else:
            data = get_historical_top_processes(window=window, sort_by=sort_by, limit=limit)
        return {"content": [{"type": "text", "text": json.dumps(data, indent=2)}]}

    elif name == "hoghunter_network_activity":
        limit = arguments.get("limit", 10)
        data = get_network_activity(limit=limit)
        return {"content": [{"type": "text", "text": json.dumps(data, indent=2)}]}

    elif name == "hoghunter_scan_storage":
        tier = arguments.get("tier", "standard")
        include_details = arguments.get("include_details", True)
        data = scan_storage_clutter(tier=tier, include_details=include_details)
        return {"content": [{"type": "text", "text": json.dumps(data, indent=2)}]}

    elif name == "hoghunter_audit_churn_risk":
        path = arguments.get("path")
        if path:
            data = audit_path_churn_risk(path)
        else:
            scan = scan_storage_clutter(tier="standard", include_details=True)
            data = {
                "high_churn_items": [
                    item for cat in scan["categories"].values() for item in cat if item.get("churn_risk") == "high"
                ],
                "safe_zero_churn_items": [
                    item for cat in scan["categories"].values() for item in cat if item.get("churn_risk") == "zero"
                ]
            }
        return {"content": [{"type": "text", "text": json.dumps(data, indent=2)}]}

    elif name == "hoghunter_clean_clutter":
        paths = arguments.get("paths", [])
        dry_run = arguments.get("dry_run", True)
        create_snapshot = arguments.get("create_snapshot", True)
        data = clean_clutter(paths, dry_run=dry_run, create_snapshot=create_snapshot)
        return {"content": [{"type": "text", "text": json.dumps(data, indent=2)}]}

    elif name == "hoghunter_quit_process":
        pid = arguments.get("pid")
        force = arguments.get("force", False)
        data = quit_process(pid, force=force)
        return {"content": [{"type": "text", "text": json.dumps(data, indent=2)}]}

    else:
        return {"isError": True, "content": [{"type": "text", "text": f"Unknown tool: {name}"}]}


def run_stdio_mcp_server() -> None:
    """Run JSON-RPC 2.0 stdio MCP server."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            err_res = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": "Parse error: Invalid JSON"}
            }
            sys.stdout.write(json.dumps(err_res) + "\n")
            sys.stdout.flush()
            continue

        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params", {})

        # Handle notifications: Per JSON-RPC 2.0, the server MUST NOT reply to notifications.
        if req_id is None or (method and method.startswith("notifications/")):
            continue

        if method == "initialize":
            res = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "serverInfo": SERVER_INFO,
                    "capabilities": {"tools": {}}
                }
            }
        elif method == "ping":
            res = {"jsonrpc": "2.0", "id": req_id, "result": {}}
        elif method == "tools/list":
            res = {"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}}
        elif method == "tools/call":
            tool_name = params.get("name")
            arguments = params.get("arguments", {})
            try:
                result = handle_tool_call(tool_name, arguments)
                res = {"jsonrpc": "2.0", "id": req_id, "result": result}
            except Exception as exc:
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32603, "message": str(exc)}
                }
        else:
            res = {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"}
            }

        sys.stdout.write(json.dumps(res) + "\n")
        sys.stdout.flush()


def run_cli(args: argparse.Namespace) -> None:
    """Execute command-line mode."""
    cmd = args.command
    if cmd == "top":
        if args.window == "now":
            data = get_live_top_processes(sort_by=args.sort_by, limit=args.limit)
        else:
            data = get_historical_top_processes(window=args.window, sort_by=args.sort_by, limit=args.limit)
        print(json.dumps(data, indent=2))

    elif cmd == "network":
        data = get_network_activity(limit=args.limit)
        print(json.dumps(data, indent=2))

    elif cmd == "scan":
        data = scan_storage_clutter(tier=args.tier, include_details=not args.summary_only)
        print(json.dumps(data, indent=2))

    elif cmd == "audit":
        if args.path:
            data = audit_path_churn_risk(args.path)
        else:
            scan = scan_storage_clutter(tier="standard", include_details=True)
            data = {
                "high_churn_items": [
                    item for cat in scan["categories"].values() for item in cat if item.get("churn_risk") == "high"
                ],
                "safe_zero_churn_items": [
                    item for cat in scan["categories"].values() for item in cat if item.get("churn_risk") == "zero"
                ]
            }
        print(json.dumps(data, indent=2))

    elif cmd == "clean":
        data = clean_clutter(args.paths, dry_run=args.dry_run, create_snapshot=not args.no_snapshot)
        print(json.dumps(data, indent=2))

    elif cmd == "quit":
        pid = args.pid
        if pid is None and args.paths:
            try:
                pid = int(args.paths[0])
            except ValueError:
                pass
        if pid is None:
            print(json.dumps({"success": False, "error": "Missing PID. Use --pid <PID> or pass <PID> as positional argument."}))
            sys.exit(1)
        data = quit_process(pid, force=args.force)
        print(json.dumps(data, indent=2))

    else:
        print("Specify a command: top, network, scan, audit, clean, or quit")
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description="HogHunter MCP Server & Agent Backend")
    parser.add_argument("--cli", dest="command", choices=["top", "network", "scan", "audit", "clean", "quit"],
                        help="Run in CLI mode")
    parser.add_argument("--window", default="now", choices=["now", "1h", "24h"])
    parser.add_argument("--sort-by", default="cpu", choices=["cpu", "memory"])
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--tier", default="standard", choices=["standard", "extreme"])
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--path", help="Path for audit")
    parser.add_argument("paths", nargs="*", help="Paths for clean command")
    parser.add_argument("--dry-run", action="store_true", default=False)
    parser.add_argument("--no-snapshot", action="store_true", default=False)
    parser.add_argument("--pid", type=int, help="PID for quit command")
    parser.add_argument("--force", action="store_true", default=False)

    args = parser.parse_args()

    if args.command:
        run_cli(args)
    else:
        run_stdio_mcp_server()


if __name__ == "__main__":
    main()

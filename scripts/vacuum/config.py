from __future__ import annotations

import json
import os
import re
from copy import deepcopy
from pathlib import Path
from typing import Any, Mapping

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_POLICY = REPO_ROOT / "config" / "robotic-vacuum.json"

# Step metadata: default enabled, which triggers include the step.
STEP_CATALOG: dict[str, dict[str, Any]] = {
    "resource_sample": {
        "title": "Check disk and memory",
        "triggers": ["watch"],
    },
    "xcode_device_support": {
        "title": "Clear old iPhone debug symbols",
        "triggers": ["full"],
    },
    "xcode_derived_data": {
        "title": "Clear Xcode build cache",
        "triggers": ["full"],
    },
    "core_simulator_caches": {
        "title": "Clear Simulator cache folders",
        "triggers": ["full"],
    },
    "simctl_delete_unavailable": {
        "title": "Remove unavailable Simulator runtimes",
        "triggers": ["full"],
    },
    "npm_cache": {
        "title": "Trim npm download cache",
        "triggers": ["full"],
    },
    "pnpm_store": {
        "title": "Trim pnpm package store",
        "triggers": ["full"],
    },
    "yarn_cache": {
        "title": "Trim Yarn cache",
        "triggers": ["full"],
    },
    "brew_cleanup": {
        "title": "Homebrew cleanup",
        "triggers": ["full"],
    },
    "hoghunter_reclaim": {
        "title": "Hog Hunter disk reclaim",
        "triggers": ["full", "pressure"],
    },
    "pm2_logs": {
        "title": "Cap oversized PM2 logs",
        "triggers": ["full", "janitor"],
    },
    "vitest_temp_dbs": {
        "title": "Remove stale test databases",
        "triggers": ["full", "janitor"],
    },
    "spotlight_journals": {
        "title": "Reset Spotlight indexing journals",
        "triggers": ["full"],
    },
    "codex_archived_sessions": {
        "title": "Clear archived Codex sessions",
        "triggers": ["full"],
    },
    "grok_sessions": {
        "title": "Prune old Grok chat sessions",
        "triggers": ["full", "pressure"],
    },
    "antigravity_brain": {
        "title": "Prune old Antigravity brain folders",
        "triggers": ["full"],
    },
    "pressure_apps_deps": {
        "title": "Clear idle app build folders under pressure",
        "triggers": ["pressure"],
    },
    "coolify_remote": {
        "title": "Remote server maintenance",
        "triggers": ["full"],
    },
    "janitor_worktree_retire": {
        "title": "Retire old merged git worktrees",
        "triggers": ["janitor", "pressure"],
    },
    "janitor_cache_reclaim": {
        "title": "Reclaim caches when disk is low",
        "triggers": ["janitor"],
    },
}


DEFAULT_DATA_DIR = "~/Library/Application Support/HogHunter/RoboticVacuum"
# How many runs history.json keeps.  Every run is a record, the five minute watch tick included (about 290 a day, with
# about 55 janitor and full runs), and the Mac's Recent Runs line counts "checks today" from this file.  The cap has to
# reach back past local midnight (see test_default_cap_reaches_back_past_midnight), so a janitor or full run also stays
# on record for more than a day.  config/robotic-vacuum.json carries the same number; this is the fallback.
DEFAULT_HISTORY_MAX_RUNS = 500
DEFAULT_HOUSEKEEPER_LOCK = "~/.claude-disk-janitor/.housekeeper.lock"

# Lane doctor settings (see vacuum/lanes.py).  The only setting is where the doctor is installed, a machine-local
# path like hoghunter_clean.  The report age, schema, timeout, and age limits are code constants in lanes.py, and
# numeric keys in a `lanes` config block are ignored.
DEFAULT_LANES: dict[str, Any] = {
    # Argv, never a shell.  A leading ~ means the Vacuum's home.  HOGHUNTER_LANE_DOCTOR_COMMAND overrides it.
    "doctor_command": ["~/apps/lane", "ls", "--json"],
}

# Steps that stay off until the owner turns them on (--set-step STEP on).  iOS DeviceSupport is a Mode 3 item in
# docs/DEV-CLEANUP-PLAYBOOK.md: it re-downloads only when that device is attached again.
DEFAULT_OFF_STEPS: frozenset[str] = frozenset({"xcode_device_support"})

# Seat suffixes the keep regex protects in flat lanes (~/apps/<prefix>-<suffix>).  Order is part of the pattern.
KEEP_SEAT_SUFFIXES: tuple[str, ...] = (
    "claude",
    "codex",
    "live",
    "antigravity",
    "cursor",
    "monet",
    "grok",
    "grok-build",
    "deepseek",
    "minimax",
    "mm",
)


def expand_path(value: str, home: Path | None = None) -> Path:
    home = home or Path.home()
    if not value or not str(value).strip():
        raise ValueError("path value is empty; refusing to alias it to the home directory")
    return Path(value.replace("~", str(home))).expanduser()


def find_fleet_apps_json(home: Path, env: Mapping[str, str] | None = None) -> Path | None:
    env = os.environ if env is None else env
    override = (env.get("FLEET_APPS_JSON") or "").strip()
    for candidate in ([Path(override)] if override else []) + [home / "apps" / "lane-tools" / "fleet-apps.json"]:
        if candidate.is_file():
            return candidate
    return None


def retired_seat_suffixes(path: Path | None) -> set[str]:
    """Worktree suffixes whose seats are ALL marked retired in fleet-apps.json.  Empty on any doubt: a missing
    file, bad JSON, or an unexpected shape returns nothing, so the keep list stays as it is."""
    if path is None:
        return set()
    try:
        seats = json.loads(path.read_text(encoding="utf-8")).get("seats")
    except (OSError, ValueError, AttributeError):
        return set()
    if not isinstance(seats, list):
        return set()
    retired: dict[str, bool] = {}
    for seat in seats:
        if not isinstance(seat, dict):
            continue
        suffix = seat.get("worktreeSuffix")
        if not isinstance(suffix, str) or not suffix:
            continue
        retired[suffix] = retired.get(suffix, True) and seat.get("retired") is True
    return {suffix for suffix, all_retired in retired.items() if all_retired}


def default_keep_worktree_regex(home: Path, env: Mapping[str, str] | None = None) -> str:
    """Generic fleet layout; owner-specific keep list lives in Application Support config.json.

    Seats that fleet-apps.json marks retired stop being force-kept, so their old lanes are judged by the lane
    doctor like any other.  When the file is not reachable the full list stays.  Nothing is ever added."""
    retired = retired_seat_suffixes(find_fleet_apps_json(home, env))
    seats = "|".join(s for s in KEEP_SEAT_SUFFIXES if s not in retired)
    code = re.escape(str(home / "Code"))
    apps = re.escape(str(home / "apps"))
    return rf"^({code}/[^/]+|{apps}/[a-z0-9]+-({seats}))$"


def default_repos(home: Path) -> list[str]:
    code = home / "Code"
    if not code.is_dir():
        return []
    repos: list[str] = []
    for child in sorted(code.iterdir()):
        if child.is_dir() and ((child / ".git").is_dir() or (child / ".git").is_file()):
            repos.append(str(child))
    return repos


def load_config(path: Path | None = None, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    path = path or (expand_path("~/Library/Application Support/HogHunter/RoboticVacuum/config.json", home))
    base: dict[str, Any] = {}
    if DEFAULT_POLICY.is_file():
        base = json.loads(DEFAULT_POLICY.read_text(encoding="utf-8"))
    if path.is_file():
        user = json.loads(path.read_text(encoding="utf-8"))
        base = _deep_merge(base, user)
    if not str(base.get("data_dir") or "").strip():
        base["data_dir"] = DEFAULT_DATA_DIR
    if not str(base.get("housekeeper_lock") or "").strip():
        base["housekeeper_lock"] = DEFAULT_HOUSEKEEPER_LOCK
    if not base.get("repos"):
        base["repos"] = default_repos(home)
    if not base.get("keep_worktree_regex"):
        base["keep_worktree_regex"] = default_keep_worktree_regex(home)
    if not base.get("hoghunter_clean"):
        candidate = REPO_ROOT / "scripts" / "hoghunter-clean"
        if candidate.is_file():
            base["hoghunter_clean"] = str(candidate)
        else:
            base["hoghunter_clean"] = str(home / "Code" / "HogHunter" / "scripts" / "hoghunter-clean")
    lanes = base.get("lanes")
    base["lanes"] = _deep_merge(DEFAULT_LANES, lanes if isinstance(lanes, dict) else {})
    janitor = base.setdefault("janitor", {})
    env_max_load = os.environ.get("JANITOR_MAX_LOAD")
    if env_max_load:
        try:
            janitor["max_load_hard"] = float(env_max_load)
        except ValueError:
            pass
    steps = base.setdefault("steps", {})
    for step_id in STEP_CATALOG:
        steps.setdefault(step_id, {"enabled": step_id not in DEFAULT_OFF_STEPS})
    return base


def _deep_merge(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    out = deepcopy(a)
    for k, v in b.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def step_enabled(cfg: dict[str, Any], step_id: str) -> bool:
    return bool(cfg.get("steps", {}).get(step_id, {}).get("enabled", step_id not in DEFAULT_OFF_STEPS))


def steps_for_trigger(cfg: dict[str, Any], trigger: str, pressure: bool = False) -> list[str]:
    out: list[str] = []
    for step_id, meta in STEP_CATALOG.items():
        if not step_enabled(cfg, step_id):
            continue
        triggers = list(meta.get("triggers") or [])
        if trigger in triggers:
            out.append(step_id)
        elif pressure and "pressure" in triggers and trigger in ("watch", "full"):
            out.append(step_id)
    return out

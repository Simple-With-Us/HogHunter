from __future__ import annotations

import json
import os
import re
from copy import deepcopy
from pathlib import Path
from typing import Any

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
DEFAULT_HOUSEKEEPER_LOCK = "~/.claude-disk-janitor/.housekeeper.lock"


def expand_path(value: str, home: Path | None = None) -> Path:
    home = home or Path.home()
    if not value or not str(value).strip():
        raise ValueError("path value is empty; refusing to alias it to the home directory")
    return Path(value.replace("~", str(home))).expanduser()


def default_keep_worktree_regex(home: Path) -> str:
    """Generic fleet layout; owner-specific keep list lives in Application Support config.json."""
    code = re.escape(str(home / "Code"))
    apps = re.escape(str(home / "apps"))
    return (
        rf"^({code}/[^/]+|"
        rf"{apps}/[a-z0-9]+-(claude|codex|live|antigravity|cursor|monet|grok|grok-build|deepseek|minimax|mm))$"
    )


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
    janitor = base.setdefault("janitor", {})
    env_max_load = os.environ.get("JANITOR_MAX_LOAD")
    if env_max_load:
        try:
            janitor["max_load_hard"] = float(env_max_load)
        except ValueError:
            pass
    steps = base.setdefault("steps", {})
    for step_id in STEP_CATALOG:
        steps.setdefault(step_id, {"enabled": True})
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
    return bool(cfg.get("steps", {}).get(step_id, {}).get("enabled", True))


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

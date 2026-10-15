"""Inventory of maintenance scripts on this Mac.

The registry lives at ~/.hoghunter/maintenance/registry.json.  Each entry is OWNED
(the Maintain engine or the Mac app may invoke it) or OBSERVED (listed for fleet
inventory only; the engine never runs it, so launchd or another owner keeps
control).  Scope is local (this Mac) or remote (SSH to another host).
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Literal, Mapping

Mode = Literal["owned", "observed"]
Scope = Literal["local", "remote"]

REGISTRY_VERSION = 1
REGISTRY_DIR_NAME = ".hoghunter/maintenance"
REGISTRY_FILE_NAME = "registry.json"


def registry_dir(home: Path) -> Path:
    return home / ".hoghunter" / "maintenance"


def registry_path(home: Path) -> Path:
    return registry_dir(home) / REGISTRY_FILE_NAME


def load_registry(home: Path) -> dict[str, Any]:
    path = registry_path(home)
    if not path.is_file():
        return {"version": REGISTRY_VERSION, "scripts": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"version": REGISTRY_VERSION, "scripts": []}
    if not isinstance(data, dict):
        return {"version": REGISTRY_VERSION, "scripts": []}
    scripts = data.get("scripts")
    if not isinstance(scripts, list):
        data["scripts"] = []
    return data


def save_registry(home: Path, data: Mapping[str, Any]) -> None:
    directory = registry_dir(home)
    directory.mkdir(parents=True, exist_ok=True)
    registry_path(home).write_text(json.dumps(dict(data), indent=2) + "\n", encoding="utf-8")


def is_invokable(entry: Mapping[str, Any]) -> bool:
    """True only for OWNED entries.  OBSERVED scripts are never run from here."""
    return str(entry.get("mode") or "").lower() == "owned"


def _entry(
    entry_id: str,
    *,
    path: str,
    mode: Mode,
    scope: Scope,
    owner: str,
    argv: list[str] | None = None,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": entry_id,
        "path": path,
        "mode": mode,
        "scope": scope,
        "owner": owner,
    }
    if argv:
        out["argv"] = argv
    return out


def default_registry(repo_root: Path, home: Path, cfg: Mapping[str, Any] | None = None) -> dict[str, Any]:
    cfg = cfg or {}
    scripts_dir = repo_root / "scripts"
    maintain = scripts_dir / "maintain.py"
    host = str(cfg.get("coolify_ssh_host") or "").strip()
    coolify_mode: Mode = "owned" if host else "observed"
    return {
        "version": REGISTRY_VERSION,
        "scripts": [
            _entry(
                "maintain_scheduler",
                path=str(maintain),
                argv=["--tick", "scheduler"],
                mode="owned",
                scope="local",
                owner="launchd: Hog Hunter Maintain scheduler (installed plist label unchanged)",
            ),
            _entry(
                "maintain_cli",
                path=str(maintain),
                mode="owned",
                scope="local",
                owner="Hog Hunter app / maintain.py CLI",
            ),
            _entry(
                "hoghunter_clean",
                path=str(cfg.get("hoghunter_clean") or scripts_dir / "hoghunter-clean"),
                mode="owned",
                scope="local",
                owner="Maintain step hoghunter_reclaim / janitor_cache_reclaim",
            ),
            _entry(
                "shim_mac_auto_cleanup",
                path=str(scripts_dir / "shims" / "mac-auto-cleanup.sh"),
                mode="observed",
                scope="local",
                owner="legacy caller paths (forwards to maintain.py)",
            ),
            _entry(
                "shim_janitor",
                path=str(scripts_dir / "shims" / "janitor.sh"),
                mode="observed",
                scope="local",
                owner="legacy caller paths (forwards to maintain.py)",
            ),
            _entry(
                "shim_mac_resource_watch",
                path=str(scripts_dir / "shims" / "mac-resource-watch.py"),
                mode="observed",
                scope="local",
                owner="legacy caller paths (forwards to maintain.py)",
            ),
            _entry(
                "coolify_remote",
                path="/etc/cron.daily/coolify-auto-maintenance",
                mode=coolify_mode,
                scope="remote",
                owner=f"ssh:{host}" if host else "unconfigured (set coolify_ssh_host to enable)",
            ),
        ],
    }


def bootstrap_registry(home: Path, repo_root: Path, cfg: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Write the registry when missing or older than the shipped schema.  Never drops owner edits."""
    desired = default_registry(repo_root, home, cfg)
    current = load_registry(home)
    if int(current.get("version") or 0) < REGISTRY_VERSION or not current.get("scripts"):
        save_registry(home, desired)
        return desired
    return current


def summary_for_status(home: Path) -> list[dict[str, str]]:
    """Compact list for status.json: no paths, only how each script is classified."""
    reg = load_registry(home)
    out: list[dict[str, str]] = []
    for entry in reg.get("scripts") or []:
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id:
            continue
        out.append(
            {
                "id": entry_id,
                "mode": str(entry.get("mode") or ""),
                "scope": str(entry.get("scope") or ""),
                "owner": str(entry.get("owner") or ""),
            }
        )
    return out

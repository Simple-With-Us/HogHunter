from __future__ import annotations

import re
import subprocess
import time
from pathlib import Path
from typing import Any, Callable, Optional  # noqa: F401 — Callable used in signatures

KEEP_SENTINEL = ".janitor-keep"
GENERATED_UNTRACKED = re.compile(
    r"^\?\? (node_modules/|\.next/|next-env\.d\.ts$|tsconfig\.tsbuildinfo$|\.DS_Store$|[^ ]*\.log$|data/app\.db(-wal|-shm)?$)"
)


def wt_blocking_dirt(worktree: Path, git: Callable[..., subprocess.CompletedProcess]) -> bool:
    try:
        res = git(["-C", str(worktree), "status", "--porcelain"], capture_output=True, text=True, timeout=5)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return True
    if res.returncode != 0:
        return True
    for line in res.stdout.splitlines():
        if GENERATED_UNTRACKED.match(line):
            continue
        return True
    return False


def main_repo_root(worktree: Path, git: Callable[..., subprocess.CompletedProcess]) -> Path:
    """Git worktree remove must run from the main repository, not a linked worktree's parent dir."""
    try:
        res = git(
            ["-C", str(worktree), "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return worktree
    if res.returncode != 0:
        return worktree
    common = Path(res.stdout.strip())
    if not common.is_absolute():
        common = (worktree / common).resolve()
    return common.parent


def github_repo(worktree: Path, git: Callable[..., subprocess.CompletedProcess]) -> Optional[str]:
    try:
        res = git(["-C", str(worktree), "remote", "get-url", "origin"], capture_output=True, text=True, timeout=5)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None
    if res.returncode != 0:
        return None
    url = res.stdout.strip()
    url = url.removesuffix(".git")
    for prefix in ("git@github.com:", "https://github.com/", "http://github.com/", "ssh://git@github.com/"):
        if url.startswith(prefix):
            url = url[len(prefix) :]
            break
    return url if "/" in url else None


def pr_merged(worktree: Path, branch: str, git: Callable[..., subprocess.CompletedProcess], gh: Callable[..., subprocess.CompletedProcess]) -> bool:
    br = branch.removeprefix("refs/heads/")
    if not br or br == "HEAD":
        return False
    repo = github_repo(worktree, git)
    if not repo:
        return False
    try:
        res = gh(
            ["pr", "list", "--repo", repo, "--head", br, "--state", "merged", "--json", "number", "--jq", "length"],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False
    if res.returncode != 0:
        return False
    try:
        return int((res.stdout or "0").strip() or "0") > 0
    except ValueError:
        return False


def worktree_idle_hours(worktree: Path, idle_hours: float) -> bool:
    cutoff = time.time() - idle_hours * 3600
    skip_dirs = {".git", "node_modules", ".next", ".turbo"}
    for root, dirs, files in os_walk(worktree):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for name in files:
            try:
                if Path(root, name).stat().st_mtime >= cutoff:
                    return False
            except OSError:
                continue
    return True


def os_walk(path: Path):
    import os

    for root, dirs, files in os.walk(path):
        yield root, dirs, files


def retire_candidate(
    wt_path: str,
    branch: str,
    keep_re: re.Pattern[str],
    stale_days: float,
    idle_hours: float,
    git: Callable[..., subprocess.CompletedProcess],
    gh: Callable[..., subprocess.CompletedProcess],
) -> bool:
    wt = Path(wt_path)
    if keep_re.match(wt_path):
        return False
    if (wt / KEEP_SENTINEL).exists():
        return False
    if wt_blocking_dirt(wt, git):
        return False
    if not worktree_idle_hours(wt, idle_hours):
        return False
    if not pr_merged(wt, branch, git, gh):
        return False
    try:
        mtime = wt.stat().st_mtime
        if time.time() - mtime < stale_days * 86400:
            return False
    except OSError:
        return False
    return True


def plan_retire_worktrees(
    cfg: dict[str, Any],
    home: Path,
    git: Callable[..., subprocess.CompletedProcess],
    gh: Callable[..., subprocess.CompletedProcess],
) -> list[tuple[str, str]]:
    """Expensive git/gh checks without holding the housekeeper lock."""
    janitor_cfg = cfg.get("janitor", {})
    if not janitor_cfg.get("reap_worktrees", True):
        return []
    keep_re = re.compile(cfg.get("keep_worktree_regex") or "")
    stale_days = float(janitor_cfg.get("stale_days", 7))
    idle_hours = float(janitor_cfg.get("idle_hours", 4))
    candidates: list[tuple[str, str]] = []

    for repo in cfg.get("repos") or []:
        repo_path = Path(repo)
        if not repo_path.is_dir():
            continue
        try:
            res = git(["-C", str(repo_path), "worktree", "list", "--porcelain"], capture_output=True, text=True, timeout=30)
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            continue
        if res.returncode != 0:
            continue
        wt_path = ""
        branch = ""
        for line in res.stdout.splitlines():
            if line.startswith("worktree "):
                wt_path = line.split(" ", 1)[1].strip()
            elif line.startswith("branch "):
                branch = line.split(" ", 1)[1].strip()
            elif line == "" and wt_path:
                if retire_candidate(wt_path, branch, keep_re, stale_days, idle_hours, git, gh):
                    candidates.append((wt_path, branch))
                wt_path = ""
                branch = ""
    return candidates


def apply_retire_worktrees(
    candidates: list[tuple[str, str]],
    git: Callable[..., subprocess.CompletedProcess],
    dry_run: bool = False,
) -> tuple[int, int, str]:
    """Remove planned worktrees; keep this fast for the housekeeper lock."""
    retired = 0
    detail_parts: list[str] = []
    for wt_path, _branch in candidates:
        if dry_run:
            detail_parts.append(f"would-retire {wt_path}")
            continue
        wt = Path(wt_path)
        try:
            if wt_blocking_dirt(wt, git):
                detail_parts.append(f"skipped {wt_path}: dirty since planning")
                continue
            repo_root = main_repo_root(wt, git)
            res = git(["-C", str(repo_root), "worktree", "remove", str(wt)], capture_output=True, text=True, timeout=30)
            if res.returncode == 0:
                retired += 1
                detail_parts.append(f"retired {wt_path}")
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass
    return retired, 0, "; ".join(detail_parts) if detail_parts else "no worktrees retired"


def retire_worktrees(
    cfg: dict[str, Any],
    home: Path,
    git: Callable[..., subprocess.CompletedProcess],
    gh: Callable[..., subprocess.CompletedProcess],
    dry_run: bool = False,
    candidates: list[tuple[str, str]] | None = None,
) -> tuple[int, int, str]:
    """Return (retired_count, bytes_estimate, detail)."""
    janitor_cfg = cfg.get("janitor", {})
    if not janitor_cfg.get("reap_worktrees", True):
        return 0, 0, "worktree retirement disabled"
    planned = candidates if candidates is not None else plan_retire_worktrees(cfg, home, git, gh)
    if not planned:
        return 0, 0, "no worktrees retired"
    return apply_retire_worktrees(planned, git, dry_run=dry_run)


def _maybe_retire(
    wt_path: str,
    branch: str,
    keep_re: re.Pattern[str],
    stale_days: float,
    idle_hours: float,
    git: Callable[..., subprocess.CompletedProcess],
    gh: Callable[..., subprocess.CompletedProcess],
    dry_run: bool,
    on_retire: Callable[[], None],
    detail_parts: list[str],
) -> None:
    if not retire_candidate(wt_path, branch, keep_re, stale_days, idle_hours, git, gh):
        return
    if dry_run:
        detail_parts.append(f"would-retire {wt_path}")
        return
    wt = Path(wt_path)
    if wt_blocking_dirt(wt, git):
        detail_parts.append(f"skipped {wt_path}: dirty since planning")
        return
    try:
        repo_root = main_repo_root(wt, git)
        res = git(["-C", str(repo_root), "worktree", "remove", str(wt)], capture_output=True, text=True, timeout=30)
        if res.returncode == 0:
            on_retire()
            detail_parts.append(f"retired {wt_path}")
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

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


def is_retired_kimi_or_scratch(worktree: str, branch: str) -> bool:
    br = branch.removeprefix("refs/heads/")
    if br.startswith("kimi/") or br.startswith("KIMI/"):
        return True
    if "/.claude/worktrees/" in worktree or "/.grok/worktrees/" in worktree:
        return True
    if worktree.startswith("/private/tmp/") or worktree.startswith("/tmp/"):
        return True
    base = worktree.rstrip("/").split("/")[-1]
    if re.search(r"-kimi($|-)", base):
        if re.search(r"-(claude|codex|live|antigravity|cursor|monet|grok|grok-build|deepseek|minimax|mm)-", base):
            return False
        return True
    return False


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


def retire_worktrees(
    cfg: dict[str, Any],
    home: Path,
    git: Callable[..., subprocess.CompletedProcess],
    gh: Callable[..., subprocess.CompletedProcess],
    dry_run: bool = False,
) -> tuple[int, int, str]:
    """Return (retired_count, bytes_estimate, detail)."""
    janitor_cfg = cfg.get("janitor", {})
    if not janitor_cfg.get("reap_worktrees", True):
        return 0, 0, "worktree retirement disabled"
    keep_re = re.compile(cfg.get("keep_worktree_regex") or "")
    stale_days = float(janitor_cfg.get("stale_days", 7))
    idle_hours = float(janitor_cfg.get("idle_hours", 4))
    retired = 0
    detail_parts: list[str] = []

    def bump() -> None:
        nonlocal retired
        retired += 1

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
                _maybe_retire(
                    wt_path,
                    branch,
                    keep_re,
                    stale_days,
                    idle_hours,
                    git,
                    gh,
                    dry_run,
                    on_retire=bump,
                    detail_parts=detail_parts,
                )
                wt_path = ""
                branch = ""
    return retired, 0, "; ".join(detail_parts) if detail_parts else "no worktrees retired"


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
    wt = Path(wt_path)
    if keep_re.match(wt_path):
        return
    if (wt / KEEP_SENTINEL).exists():
        return
    if wt_blocking_dirt(wt, git):
        return
    if not worktree_idle_hours(wt, idle_hours):
        return
    if not is_retired_kimi_or_scratch(wt_path, branch) and not pr_merged(wt, branch, git, gh):
        return
    try:
        mtime = wt.stat().st_mtime
        if time.time() - mtime < stale_days * 86400:
            return
    except OSError:
        return
    if dry_run:
        detail_parts.append(f"would-retire {wt_path}")
        return
    try:
        res = git(["-C", str(wt.parent if (wt / ".git").is_file() else wt), "worktree", "remove", str(wt)], capture_output=True, text=True, timeout=30)
        if res.returncode == 0:
            on_retire()
            detail_parts.append(f"retired {wt_path}")
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

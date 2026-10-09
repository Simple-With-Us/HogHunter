"""Lane doctor integration for the Robotic Vacuum.

The fleet's lane doctor (installed as ~/apps/lane, subcommand ls) is a read-only inventory of every git
checkout on this Mac.  Its report names the checkouts a cleaner may remove (cleaner_candidates).  This
module turns that report into two answers and nothing else:

* removable lanes: linked worktrees that the doctor lists AND that pass the Vacuum's own re-check.
* dependency lanes: idle lanes whose regenerable build folders (node_modules and friends) may go.

Rules this module lives by:

* Never remove on a guess.  A missing, stale, malformed or partial fact means do nothing, and the reason
  string says why so the log can show it.  A walk that cannot read a folder, or hits its cap, refuses.
* A fresh, clean, 0-ahead lane is NOT safe.  Only merged-PR evidence, from the doctor, makes a lane
  removable, and the Vacuum then re-checks the live tree itself.
* What git hides still counts: ignored files other than regenerable build output, index flags that hide
  edits (skip-worktree, assume-unchanged), and nested git repositories inside ignored folders all refuse.
* Removal is `git worktree remove` WITHOUT force.  remove_argv refuses any argv that carries a force flag.
* Every function takes an injectable runner and clock so tests need no real processes except temp repos.

Python 3.9 compatible on purpose: launchd runs this under /usr/bin/python3.
"""
from __future__ import annotations

import datetime as _dt
import fnmatch
import json
import math
import os
import re
import shlex
import signal
import stat
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Optional

from .config import DEFAULT_LANES

Runner = Callable[..., "subprocess.CompletedProcess[str]"]
DoctorRunner = Callable[[list, float], "subprocess.CompletedProcess[str]"]

KEEP_SENTINEL = ".janitor-keep"
DOCTOR_ENV_VAR = "HOGHUNTER_LANE_DOCTOR_COMMAND"

# The doctor's location classes where a lane may live.  Anything else (FORBIDDEN_*, UNSANCTIONED,
# INTEGRATION_TREE, a class this code has never heard of) is refused.
LANE_LIKE_CLASSES = frozenset({"LANE_NESTED", "LANE_FLAT_LEGACY", "LANE_FLAT", "REVIEW", "MANAGED"})
# The dependency step works only in lanes the fleet cut by hand.  MANAGED worktrees belong to a harness
# (~/.codex/worktrees, ~/.grok/worktrees, ~/Code/<App>/.claude/worktrees), and a closed but resumable session
# has no process in it, so its folders are left to that harness.
DEPENDENCY_LANE_CLASSES = frozenset({"LANE_NESTED", "LANE_FLAT_LEGACY", "LANE_FLAT", "REVIEW"})
# Folders under home that no lane step touches, whatever the report says.  Mirrors FORBIDDEN_PREFIXES in
# scripts/hoghunter-clean ("Never touch these, no matter what a scan finds").
NEVER_TOUCH_UNDER_HOME = (
    "Library/CloudStorage",
    "Documents",
    "Pictures",
    "Movies",
    "Desktop",
    "Library/Developer/CoreSimulator/Devices",
    ".grok/worktrees",
)
# The doctor's merged-PR evidence states (MERGED, or CLOSED on an exact head match).
MERGED_EVIDENCE_STATES = frozenset({"MERGED", "CLOSED"})
# The only ignored folders the dependency step may delete, and ignored folders that never block removal.
# A safety invariant, not a tunable: widening it is a code change, never a config value.
REGENERABLE_NAMES = frozenset(
    {
        "node_modules",
        ".next",
        ".turbo",
        "dist",
        "build",
        ".gradle",
        "DerivedData",
        "Pods",
        "__pycache__",
        ".venv",
        ".pytest_cache",
    }
)
# Ignored entries the lane doctor also calls regenerable (doctor.py _REGENERABLE_NAMES and _REGENERABLE_GLOBS).
# They do not block REMOVAL, because `git worktree remove` takes them with the lane, but the dependency step
# never deletes them on its own.  Matched on the entry's own name only, never on a parent folder's name, so
# `build/app.db` inside a tracked build folder still blocks.
REMOVAL_ONLY_DIR_NAMES = frozenset({".build", "venv", ".mypy_cache", ".ruff_cache"})
REMOVAL_ONLY_DIR_GLOBS = ("dist-*",)
REMOVAL_ONLY_FILE_NAMES = frozenset({".DS_Store"})
REMOVAL_ONLY_FILE_GLOBS = ("*.pyc", "*.tsbuildinfo")
# Untracked (not ignored) folders the dependency step may still delete.  Narrower than REGENERABLE_NAMES:
# an untracked dist or build folder could be somebody's hand-made output, so those need git to say ignored.
UNTRACKED_REGENERABLE_NAMES = frozenset({"node_modules", ".next", ".turbo", "__pycache__", ".pytest_cache"})

FUTURE_SKEW_SECONDS = 300.0
# Report and age limits.  Code constants, not knobs: config cannot loosen or tighten them (only the doctor
# command is configurable).  Changing one is a code change with a test.
REPORT_MAX_AGE_SECONDS = 900.0
MIN_SCHEMA = 2
DOCTOR_TIMEOUT_SECONDS = 300.0
RETIRE_MIN_DAYS = 7.0
DEPS_MIN_HOURS = 24.0
LSOF_CACHE_SECONDS = 30.0
WALK_FILE_CAP = 200_000
# Entries a nested-repository walk may visit in one folder before it gives up and refuses.  Deleting the folder
# visits every entry anyway, so the walk costs no more than the delete it guards.
NESTED_WALK_CAP = 1_000_000
ACTION_LOG_NAME = "lane-actions.jsonl"
ACTION_LOG_MAX_BYTES = 1_048_576


# --------------------------------------------------------------------------- settings


@dataclass(frozen=True)
class LaneSettings:
    command: tuple
    max_report_age_seconds: float
    min_schema: int
    timeout_seconds: float
    retire_min_days: float
    deps_min_hours: float


def _expand_arg(arg: str, home: Path) -> str:
    if arg == "~":
        return str(home)
    if arg.startswith("~/"):
        return str(home) + arg[1:]
    return arg


def lane_settings(cfg: Mapping[str, Any], home: Path, env: Optional[Mapping[str, str]] = None) -> LaneSettings:
    """Read the doctor command from the `lanes` block of the Vacuum config (or HOGHUNTER_LANE_DOCTOR_COMMAND).
    Everything else is a code constant: report age 15 minutes, schema 2, doctor timeout 5 minutes, 7 days to
    retire, 24 hours for dependency folders.  Numeric `lanes` keys in a config file are ignored, so a stray
    value can neither loosen nor tighten a safety limit."""
    env = os.environ if env is None else env
    raw: dict = dict(DEFAULT_LANES)
    block = cfg.get("lanes")
    if isinstance(block, dict) and "doctor_command" in block:
        raw["doctor_command"] = block["doctor_command"]

    command: Any = raw.get("doctor_command")
    override = env.get(DOCTOR_ENV_VAR)
    if override and override.strip():
        try:
            command = shlex.split(override)
        except ValueError:
            command = []
    elif isinstance(command, str):
        try:
            command = shlex.split(command)
        except ValueError:
            command = []
    if not isinstance(command, (list, tuple)) or not all(isinstance(part, str) and part for part in command):
        command = []
    argv = tuple(_expand_arg(part, home) for part in command)
    return LaneSettings(
        command=argv,
        max_report_age_seconds=REPORT_MAX_AGE_SECONDS,
        min_schema=MIN_SCHEMA,
        timeout_seconds=DOCTOR_TIMEOUT_SECONDS,
        retire_min_days=RETIRE_MIN_DAYS,
        deps_min_hours=DEPS_MIN_HOURS,
    )


# --------------------------------------------------------------------------- running things


def git_env() -> dict:
    env = {k: v for k, v in os.environ.items() if k not in _STRIPPED_GIT_ENV}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["LC_ALL"] = "C"
    return env


_STRIPPED_GIT_ENV = frozenset({"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY"})


def _default_runner(argv: list, **kwargs: Any) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, **kwargs)


def call(runner: Runner, argv: list, timeout: float, env: Optional[dict] = None):
    """Run argv through the injected runner.  Returns (completed process or None, error text)."""
    kwargs: dict = {"capture_output": True, "text": True, "timeout": timeout}
    if env is not None:
        kwargs["env"] = env
    try:
        res = runner(argv, **kwargs)
    except subprocess.TimeoutExpired:
        return None, f"{argv[0]} timed out after {timeout:g}s"
    except (OSError, ValueError) as exc:  # missing binary, permission, undecodable output
        return None, f"{argv[0]} could not run ({type(exc).__name__})"
    return res, ""


def _git(runner: Runner, path: str, args: list, timeout: float = 60.0):
    argv = ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path] + list(args)
    return call(runner, argv, timeout, env=git_env())


def run_doctor_process(argv: list, timeout: float) -> "subprocess.CompletedProcess[str]":
    """Default doctor runner: no shell, its own session so a timeout kills the whole process group."""
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.communicate(timeout=5)
        except (subprocess.TimeoutExpired, OSError, ValueError):
            pass
        raise
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


# --------------------------------------------------------------------------- the report


@dataclass
class LaneReport:
    """The doctor's report after the gates that apply to every use.  ok is False when ANY of them fails;
    gh_ok is a separate gate because only removal (not dependency folders) needs the PR lookups."""

    ok: bool
    reason: str = ""
    gh_ok: bool = False
    gh_reason: str = ""
    data: dict = field(default_factory=dict)
    by_real: dict = field(default_factory=dict)
    generated_at: Optional[float] = None
    generated_at_text: str = ""
    command: tuple = ()
    seconds: float = 0.0


def _fail(reason: str, **extra: Any) -> LaneReport:
    return LaneReport(ok=False, reason=reason, **extra)


def parse_timestamp(value: Any) -> Optional[float]:
    """ISO-8601 with an explicit zone to epoch seconds, or None.  A naive time is unusable: its zone is a guess."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text[-1] in "Zz":
        text = text[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.timestamp()


def load_report(
    settings: LaneSettings,
    home: Path,
    doctor_runner: Optional[DoctorRunner] = None,
    clock: Callable[[], float] = time.time,
) -> LaneReport:
    """Run the doctor and validate its report.  Never raises; any problem is a fail-closed LaneReport."""
    argv = list(settings.command)
    if not argv:
        return _fail("no doctor command configured")
    exe = argv[0]
    if os.sep in exe and not os.path.exists(exe):
        return _fail(f"doctor command missing: {exe}", command=tuple(argv))
    runner = doctor_runner or run_doctor_process
    started = clock()
    try:
        res = runner(argv, settings.timeout_seconds)
    except subprocess.TimeoutExpired:
        return _fail(f"doctor timed out after {settings.timeout_seconds:g}s", command=tuple(argv))
    except (OSError, ValueError) as exc:
        return _fail(f"doctor could not run ({type(exc).__name__})", command=tuple(argv))
    seconds = max(clock() - started, 0.0)
    if res.returncode != 0:
        tail = " ".join((res.stderr or "").split())[:160]
        return _fail(f"doctor exited {res.returncode}" + (f": {tail}" if tail else ""), command=tuple(argv), seconds=seconds)
    try:
        data = json.loads(res.stdout or "")
    except ValueError:
        return _fail("doctor output is not valid JSON", command=tuple(argv), seconds=seconds)
    report = validate_report(data, settings, home, clock)
    report.command = tuple(argv)
    report.seconds = seconds
    return report


def validate_report(data: Any, settings: LaneSettings, home: Path, clock: Callable[[], float] = time.time) -> LaneReport:
    """The gates that empty the whole result.  Per-candidate gates live in the selectors below."""
    if not isinstance(data, dict):
        return _fail("doctor report is not a JSON object")
    schema = data.get("schema")
    if isinstance(schema, bool) or not isinstance(schema, int):
        return _fail("doctor report has no schema number")
    if schema < settings.min_schema:
        return _fail(f"doctor schema {schema} is below the required {settings.min_schema}")
    stamp = data.get("generated_at")
    generated = parse_timestamp(stamp)
    if generated is None:
        return _fail("doctor generated_at is missing or unparseable")
    now = clock()
    if generated > now + FUTURE_SKEW_SECONDS:
        return _fail(f"doctor generated_at is {generated - now:.0f}s in the future")
    age = now - generated
    if age > settings.max_report_age_seconds:
        return _fail(f"doctor report is stale ({age:.0f}s old, limit {settings.max_report_age_seconds:g}s)")
    if data.get("lsof") != "ok":
        return _fail(f"doctor lsof status is {data.get('lsof')!r}, not 'ok'; process cwd facts are unreliable")
    report_home = data.get("home")
    if not isinstance(report_home, str) or os.path.realpath(report_home) != os.path.realpath(str(home)):
        return _fail("doctor report is for a different home directory")
    checkouts = data.get("checkouts")
    if not isinstance(checkouts, list):
        return _fail("doctor report has no checkouts list")
    by_real: dict = {}
    for co in checkouts:
        if isinstance(co, dict) and isinstance(co.get("realpath"), str) and co["realpath"]:
            by_real[co["realpath"]] = co
    gh_status = data.get("gh")
    gh_ok = gh_status == "ok"
    return LaneReport(
        ok=True,
        gh_ok=gh_ok,
        gh_reason="" if gh_ok else f"doctor gh status is {gh_status!r}, not 'ok'",
        data=data,
        by_real=by_real,
        generated_at=generated,
        generated_at_text=str(stamp),
    )


# --------------------------------------------------------------------------- what a choice looks like


@dataclass
class LaneChoice:
    """A lane that passed every gate.  checkout is the doctor's row, kept for the re-check at removal time."""

    path: str
    branch: str
    head_sha: str
    owner_repo: str
    location_class: str
    size_bytes: Optional[int]
    reasons: list
    command: list = field(default_factory=list)
    targets: list = field(default_factory=list)
    checkout: dict = field(default_factory=dict, repr=False)

    def as_dict(self) -> dict:
        out = {
            "path": self.path,
            "branch": self.branch,
            "head_sha": self.head_sha,
            "owner_repo": self.owner_repo,
            "location_class": self.location_class,
            "size_bytes": self.size_bytes,
            "reasons": list(self.reasons),
        }
        if self.command:
            out["command"] = shlex.join(self.command)
        if self.targets:
            out["targets"] = [dict(t) for t in self.targets]
        return out


@dataclass
class LaneScan:
    """ok False means the doctor was unusable and nothing may be removed; reason says why."""

    ok: bool
    reason: str = ""
    choices: list = field(default_factory=list)
    refused: list = field(default_factory=list)
    generated_at: str = ""
    doctor_seconds: float = 0.0

    def as_dict(self) -> dict:
        return {
            "ok": self.ok,
            "reason": self.reason,
            "report_generated_at": self.generated_at,
            "doctor_seconds": round(self.doctor_seconds, 1),
            "choices": [c.as_dict() for c in self.choices],
            "refused": list(self.refused),
        }


class LaneContext:
    """What the live re-check needs: home, keep regex, settings, runner, clock.  Holds a short-lived lsof cache."""

    def __init__(
        self,
        home: Path,
        keep_re: "re.Pattern[str]",
        settings: LaneSettings,
        runner: Optional[Runner] = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.home = Path(home)
        self.home_real = os.path.realpath(str(home))
        self.keep_re = keep_re
        self.settings = settings
        self.runner: Runner = runner or _default_runner
        self.clock = clock
        self._cwds: Optional[list] = None
        self._cwds_at = 0.0
        self._cwds_err = ""

    def cwd_paths(self):
        """Every process's cwd (lsof), refreshed after LSOF_CACHE_SECONDS.  (None, reason) when lsof is unusable."""
        now = self.clock()
        if self._cwds is not None or self._cwds_err:
            if now - self._cwds_at < LSOF_CACHE_SECONDS:
                return self._cwds, self._cwds_err
        res, err = call(self.runner, ["lsof", "-d", "cwd", "-Fn"], 60.0)
        self._cwds_at = now
        self._cwds = None
        self._cwds_err = ""
        if res is None:
            self._cwds_err = err
        elif res.returncode not in (0, 1):
            self._cwds_err = f"lsof exited {res.returncode}"
        else:
            paths = [line[1:] for line in (res.stdout or "").splitlines() if line.startswith("n") and len(line) > 1]
            if not paths:
                self._cwds_err = "lsof listed no process directories"
            else:
                self._cwds = paths
        return self._cwds, self._cwds_err


# --------------------------------------------------------------------------- git helpers


@dataclass
class StatusScan:
    tracked_dirty: list = field(default_factory=list)
    untracked: list = field(default_factory=list)
    ignored_other: list = field(default_factory=list)
    regen_ignored: list = field(default_factory=list)
    regen_untracked: list = field(default_factory=list)
    # Ignored entries the doctor calls regenerable that removal may take but the dependency step never deletes.
    removal_only_dirs: list = field(default_factory=list)
    removal_only_files: list = field(default_factory=list)
    # Ignored entries with no trailing slash named like a regenerable folder (a `node_modules` symlink, say).
    # They pass only once the caller has seen on disk that they are symlinks; a plain file named build blocks.
    link_candidates: list = field(default_factory=list)

    def removal_blocker(self, verified_links=()) -> str:
        """Why a lane with this status may not be removed, or an empty string when it may.  verified_links are
        the link_candidates the caller confirmed are symlinks; the rest count as ignored local state."""
        parts = []
        if self.tracked_dirty:
            parts.append(f"tracked changes: {_sample(self.tracked_dirty)}")
        if self.untracked:
            parts.append(f"untracked files: {_sample(self.untracked)}")
        verified = set(verified_links)
        ignored = list(self.ignored_other) + [p for p in self.link_candidates if p not in verified]
        if ignored:
            parts.append(f"ignored local state: {_sample(ignored)}")
        return "; ".join(parts)

    def removal_walk_dirs(self) -> list:
        """Ignored folders that stay in a lane git is about to delete, so each must be proven free of a nested
        repository first."""
        return list(self.regen_ignored) + list(self.removal_only_dirs)


def _sample(items: list, limit: int = 3) -> str:
    shown = ", ".join(items[:limit])
    return shown + (f" (+{len(items) - limit} more)" if len(items) > limit else "")


def _clean_rel(path: str) -> str:
    """A safe relative path (no empty, '.', or '..' part, not absolute), else an empty string."""
    if path.startswith("/"):
        return ""
    parts = path.split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        return ""
    return "/".join(parts)


def _clean_dir_entry(path: str) -> str:
    """A directory entry from git status (trailing slash) with a safe relative path, else an empty string."""
    if not path.endswith("/"):
        return ""
    return _clean_rel(path[:-1])


def _matches(name: str, names: frozenset, globs: tuple = ()) -> bool:
    return name in names or any(fnmatch.fnmatchcase(name, pattern) for pattern in globs)


def _classify_ignored(scan: StatusScan, path: str) -> None:
    rel = _clean_dir_entry(path)
    if rel:
        name = rel.rsplit("/", 1)[-1]
        if name in REGENERABLE_NAMES:
            scan.regen_ignored.append(rel)
        elif _matches(name, REMOVAL_ONLY_DIR_NAMES, REMOVAL_ONLY_DIR_GLOBS):
            scan.removal_only_dirs.append(rel)
        else:
            scan.ignored_other.append(path)
        return
    rel = "" if path.endswith("/") else _clean_rel(path)
    name = rel.rsplit("/", 1)[-1] if rel else ""
    if name and _matches(name, REMOVAL_ONLY_FILE_NAMES, REMOVAL_ONLY_FILE_GLOBS):
        scan.removal_only_files.append(rel)
    elif name and _matches(name, REGENERABLE_NAMES | REMOVAL_ONLY_DIR_NAMES, REMOVAL_ONLY_DIR_GLOBS):
        scan.link_candidates.append(rel)
    else:
        scan.ignored_other.append(path)


def parse_status(output: str) -> StatusScan:
    """Parse `git status --porcelain -z --ignored --untracked-files=normal`.

    An ignored FOLDER whose own name is in REGENERABLE_NAMES is regenerable: it does not block removal and the
    dependency step may delete it.  An ignored folder or file the doctor also calls regenerable (.build, venv,
    .mypy_cache, .ruff_cache, dist-*, .DS_Store, *.pyc, *.tsbuildinfo) does not block removal, and nothing deletes
    it on its own.  Everything else (an env file, a database, a data folder) lands in ignored_other and blocks."""
    scan = StatusScan()
    tokens = output.split("\0")
    i = 0
    while i < len(tokens):
        token = tokens[i]
        i += 1
        if not token:
            continue
        if len(token) < 4 or token[2] != " ":
            scan.tracked_dirty.append(token[:80])
            continue
        code, path = token[:2], token[3:]
        if "R" in code or "C" in code:
            i += 1  # the next token is the origin path of a rename or copy
        if code == "!!":
            _classify_ignored(scan, path)
        elif code == "??":
            scan.untracked.append(path)
            rel = _clean_dir_entry(path)
            if rel and rel.rsplit("/", 1)[-1] in UNTRACKED_REGENERABLE_NAMES:
                scan.regen_untracked.append(rel)
        else:
            scan.tracked_dirty.append(f"{code.strip() or '?'} {path}")
    return scan


def parse_worktrees(text: str) -> list:
    """`git worktree list --porcelain` into dicts with path, branch (full ref or ''), locked."""
    entries: list = []
    current: dict = {}
    for line in text.splitlines():
        if not line.strip():
            if current:
                entries.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        if key == "worktree":
            if current:
                entries.append(current)
            current = {"path": value, "branch": "", "locked": False}
        elif key == "branch":
            current["branch"] = value
        elif key == "locked":
            current["locked"] = True
    if current:
        entries.append(current)
    return entries


def _same_path(a: str, b: str) -> bool:
    return os.path.realpath(a).casefold() == os.path.realpath(b).casefold()


def dir_size_bytes(path: str, runner: Runner) -> Optional[int]:
    """Size from du (kilobytes).  None when it cannot be measured, so the log says unknown instead of guessing."""
    res, _err = call(runner, ["du", "-sk", "-x", path], 120.0)
    if res is None or res.returncode != 0:
        return None
    try:
        return int((res.stdout or "").split()[0]) * 1024
    except (ValueError, IndexError):
        return None


def format_size(size: Optional[int]) -> str:
    if size is None:
        return "size unknown"
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"


def process_state(runner: Runner, pattern: str, what: str = "a running process matches") -> tuple:
    """pgrep -f with an extended regular expression.  Returns (busy, reason).  Exit 0 is busy, 1 is free, and
    ANYTHING else (a pgrep error, a missing binary, a timeout) is treated as busy: a failed look is not an empty
    room.  pgrep prints process ids only, never argv (config/reclaim-policy.json, hardRules.neverPs)."""
    res, err = call(runner, ["pgrep", "-f", pattern], 3.0)
    if res is None:
        return True, f"pgrep failed ({err}); treated as busy"
    if res.returncode == 0:
        return True, what
    if res.returncode == 1:
        return False, ""
    return True, f"pgrep exited {res.returncode}; treated as busy"


_ERE_SPECIAL = re.compile(r"([.\[\\()*+?{|^$])")


def ere_escape(text: str) -> str:
    """Escape the characters that are special in a POSIX extended regular expression, so pgrep -f matches the
    literal text.  `]` and `}` are left alone: outside a bracket or an interval they are ordinary, and escaping
    them is undefined in POSIX."""
    return _ERE_SPECIAL.sub(r"\\\1", text)


def path_process_state(runner: Runner, path: str) -> tuple:
    """Is any process's command line naming this path?  The path is matched literally (ERE-escaped), so a lane
    named claude-a+b or claude-v(2) still finds its process.  A path with control characters cannot be matched
    reliably, so it reads as busy."""
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in path):
        return True, "path has control characters, so a process search cannot match it; treated as busy"
    return process_state(runner, ere_escape(path), "a running process mentions this path")


def _walk_dirs(root: str, cap: int, skip_names: frozenset = frozenset()):
    """Yield (directory, entries) for every directory under root, root included, without following symlinks
    and without entering folders named in skip_names.  Raises OSError when a directory cannot be listed and
    _WalkCap when more than cap entries were seen, so a caller can never mistake an unread subtree for an
    empty one."""
    seen = 0
    stack = [root]
    while stack:
        current = stack.pop()
        with os.scandir(current) as listing:
            entries = list(listing)
        seen += len(entries)
        if seen > cap:
            raise _WalkCap(cap)
        yield current, entries
        for entry in entries:
            if entry.name not in skip_names and entry.is_dir(follow_symlinks=False):
                stack.append(entry.path)


class _WalkCap(Exception):
    pass


def nested_repo_blocker(folder: str, cap: int = NESTED_WALK_CAP) -> str:
    """Why this folder may not be deleted (or left inside a lane that git will delete), or an empty string.

    git does not look inside an ignored folder, so a clone under .venv/src/<pkg> (pip install -e git+...) or under
    build/ shows only as `!! .venv/`, and `git worktree remove` or rmtree would take its local-only commits.  Any
    entry named .git (a folder, a gitfile, or a link) refuses.  So does an unreadable folder or a tree larger than
    cap entries.  Symlinks are not followed: removing a link never touches what it points to."""
    try:
        st = os.lstat(folder)
    except FileNotFoundError:
        return ""
    except OSError as exc:
        return f"cannot read {folder} ({type(exc).__name__})"
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        return ""
    try:
        for current, entries in _walk_dirs(folder, cap):
            for entry in entries:
                if entry.name.casefold() == ".git":
                    return f"a nested git repository at {entry.path}"
    except _WalkCap:
        return f"more than {cap} entries under {folder}, too many to prove no nested git repository is inside"
    except OSError as exc:
        return f"cannot read everything under {folder} ({type(exc).__name__}), so a nested git repository cannot be ruled out"
    return ""


def tree_changed_within(
    path: str,
    within_seconds: float,
    clock: Callable[[], float] = time.time,
    skip_names: frozenset = frozenset(),
    cap: int = WALK_FILE_CAP,
) -> bool:
    """True when any file under path changed within the window.  Also True when the tree cannot be read fully
    (a folder that cannot be listed, a file that cannot be stat'ed, or more than cap entries): an unread tree
    cannot be called idle.  Folders named in skip_names are not entered.  Symlinks are not followed."""
    cutoff = clock() - within_seconds
    try:
        for _current, entries in _walk_dirs(path, cap, skip_names):
            for entry in entries:
                if entry.is_dir(follow_symlinks=False):
                    continue
                if entry.stat(follow_symlinks=False).st_mtime >= cutoff:
                    return True
    except (_WalkCap, OSError):
        return True
    return False


def recently_modified(path: str, within_seconds: float, clock: Callable[[], float] = time.time) -> bool:
    """True when any file outside .git and the regenerable folders changed within the window, or when the tree
    cannot be read fully."""
    return tree_changed_within(path, within_seconds, clock, frozenset({".git"}) | REGENERABLE_NAMES)


# --------------------------------------------------------------------------- report-level gates


def _num(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if math.isnan(value) or math.isinf(value):
        return None
    return float(value)


def _keep_veto(ctx: LaneContext, co: dict, path: str) -> str:
    for candidate in (path, str(co.get("path") or "")):
        if candidate and ctx.keep_re.match(candidate):
            return "matches the keep list"
    return ""


def report_gate_common(co: dict, ctx: LaneContext) -> str:
    """Doctor facts every lane needs, for removal and for dependency folders.  Empty string means pass."""
    if co.get("location_class") not in LANE_LIKE_CLASSES:
        return f"location class {co.get('location_class')!r} is not a lane location"
    if co.get("kind") != "LINKED-WORKTREE":
        return f"kind is {co.get('kind')!r}, not a linked worktree"
    if co.get("registered") is not True:
        return "not registered with its parent repository"
    if co.get("tool_cache") is not False:
        return "tool cache"
    read_errors = co.get("read_errors")
    if not isinstance(read_errors, list) or read_errors:
        return "the doctor could not read it fully"
    if co.get("janitor_keep") is not False:
        return "keep marker (.janitor-keep)"
    if co.get("cwd_procs") != [] or co.get("active") is not False:
        return "a process is using it"
    return ""


def report_gate_retire(co: dict, report: LaneReport, ctx: LaneContext) -> str:
    gate = report_gate_common(co, ctx)
    if gate:
        return gate
    gh_repos = report.data.get("gh_repos")
    repo = co.get("owner_repo")
    if not isinstance(repo, str) or not repo:
        return "no owner repository, so no PR lookup applies"
    if not isinstance(gh_repos, dict) or gh_repos.get(repo) != "ok":
        state = gh_repos.get(repo) if isinstance(gh_repos, dict) else None
        return f"gh lookup for {repo} is {state!r}, not 'ok'"
    if co.get("safety") != "SAFE-TO-REMOVE":
        return f"safety is {co.get('safety')!r}"
    if co.get("pr_state") not in MERGED_EVIDENCE_STATES:
        return f"no merged-PR evidence (PR state {co.get('pr_state')!r})"
    floor = ctx.settings.retire_min_days
    for key in ("lane_age_days", "idle_days"):
        value = _num(co.get(key))
        if value is None:
            return f"{key} unknown"
        if value < floor:
            return f"{key} {value:.1f} is under {floor:g} days"
    head = co.get("head_sha")
    if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{40,64}", head):
        return "report has no head sha, so the PR evidence cannot be tied to a commit"
    return ""


def report_gate_deps(co: dict, ctx: LaneContext) -> str:
    if co.get("location_class") not in DEPENDENCY_LANE_CLASSES:
        return f"location class {co.get('location_class')!r} is not a fleet lane; harness worktrees are left to their harness"
    gate = report_gate_common(co, ctx)
    if gate:
        return gate
    floor_days = ctx.settings.deps_min_hours / 24.0
    for key in ("lane_age_days", "idle_days"):
        value = _num(co.get(key))
        if value is None:
            return f"{key} unknown"
        if value < floor_days:
            return f"{key} {value:.2f} is under {ctx.settings.deps_min_hours:g} hours"
    dirty = co.get("dirty_tracked")
    if isinstance(dirty, bool) or not isinstance(dirty, int) or dirty != 0:
        return f"tracked tree is not known clean (dirty_tracked {dirty!r})"
    return ""


# --------------------------------------------------------------------------- live re-checks


def never_touch_reason(path: str, home_real: str) -> str:
    """Non-empty when path is at or under a NEVER_TOUCH_UNDER_HOME folder.  Case-insensitive, as APFS is."""
    folded = path.casefold()
    for rel in NEVER_TOUCH_UNDER_HOME:
        root = os.path.join(home_real, rel).casefold()
        if folded == root or folded.startswith(root + os.sep):
            return f"under ~/{rel}, which no cleanup step ever touches"
    return ""


def _live_basics(path: str, co: dict, ctx: LaneContext) -> str:
    """Filesystem facts that do not need git.  Empty string means pass."""
    if os.path.realpath(path) != path:
        return "path resolves somewhere else now"
    if os.path.islink(path) or not os.path.isdir(path):
        return "path is not a plain directory"
    if not path.startswith(ctx.home_real + os.sep):
        return "outside the home directory"
    why = never_touch_reason(path, ctx.home_real)
    if why:
        return why
    git_entry = os.path.join(path, ".git")
    if os.path.islink(git_entry) or not os.path.isfile(git_entry):
        return "not a linked worktree (.git is not a file)"
    if os.path.lexists(os.path.join(path, KEEP_SENTINEL)):
        return "keep marker (.janitor-keep) on disk"
    return _keep_veto(ctx, co, path)


def _live_processes(path: str, ctx: LaneContext) -> str:
    cwds, err = ctx.cwd_paths()
    if cwds is None:
        return f"process check failed: {err}"
    folded = path.casefold()
    for cwd in cwds:
        low = cwd.casefold()
        if low == folded or low.startswith(folded + os.sep):
            return "a process has it as its working directory"
    busy, reason = path_process_state(ctx.runner, path)
    return reason if busy else ""


def _git_lines(ctx: LaneContext, path: str, args: list, what: str):
    res, err = _git(ctx.runner, path, args)
    if res is None:
        return None, f"{what}: {err}"
    if res.returncode != 0:
        return None, f"{what}: git exited {res.returncode}"
    return (res.stdout or "").splitlines(), ""


def _resolve_git_dir(path: str, value: str) -> str:
    return os.path.realpath(value if os.path.isabs(value) else os.path.join(path, value))


def _linked_facts(path: str, co: dict, ctx: LaneContext):
    """HEAD, branch and repository checks shared by both selectors.  Returns (repo_root or '', refusal)."""
    lines, why = _git_lines(ctx, path, ["rev-parse", "--git-dir", "--git-common-dir"], "rev-parse")
    if lines is None:
        return "", why
    if len(lines) != 2:
        return "", "rev-parse gave an unexpected answer"
    git_dir = _resolve_git_dir(path, lines[0])
    common = _resolve_git_dir(path, lines[1])
    if git_dir == common:
        return "", "not a linked worktree (git dir equals the common dir)"
    repo_root = os.path.dirname(common)
    if not os.path.isdir(os.path.join(repo_root, ".git")) or os.path.realpath(os.path.join(repo_root, ".git")) != common:
        return "", "cannot find the main repository to run the removal from"
    return repo_root, ""


def _head_matches_report(path: str, co: dict, ctx: LaneContext) -> str:
    lines, why = _git_lines(ctx, path, ["rev-parse", "HEAD"], "rev-parse HEAD")
    if lines is None or len(lines) != 1:
        return why or "rev-parse HEAD gave an unexpected answer"
    if lines[0].strip() != co.get("head_sha"):
        return "HEAD moved since the doctor report, so its PR evidence no longer applies"
    sym, err = _git(ctx.runner, path, ["symbolic-ref", "-q", "HEAD"])
    if sym is None:
        return f"symbolic-ref: {err}"
    reported = co.get("branch")
    if sym.returncode == 0:
        current = (sym.stdout or "").strip()
        if not reported or current != f"refs/heads/{reported}":
            return "branch changed since the doctor report"
    elif sym.returncode == 1:
        if reported:
            return "branch changed since the doctor report"
    else:
        return f"symbolic-ref exited {sym.returncode}"
    return ""


def _other_worktrees(path: str, ctx: LaneContext) -> str:
    """The lane must be registered, not locked, and its branch must not be checked out anywhere else."""
    res, err = _git(ctx.runner, path, ["worktree", "list", "--porcelain"])
    if res is None:
        return f"worktree list: {err}"
    if res.returncode != 0:
        return f"worktree list: git exited {res.returncode}"
    entries = parse_worktrees(res.stdout or "")
    mine = [e for e in entries if _same_path(e["path"], path)]
    if len(mine) != 1:
        return "not found in the repository's worktree list"
    if mine[0]["locked"]:
        return "worktree is locked"
    branch = mine[0]["branch"]
    if branch:
        for entry in entries:
            if entry is not mine[0] and entry["branch"] == branch:
                return f"branch {branch} is also checked out at {entry['path']}"
    return ""


def _hidden_index_flags(path: str, ctx: LaneContext) -> str:
    """A tracked file marked --skip-worktree or --assume-unchanged can hold local edits that git status never
    shows, and `git worktree remove` would delete them.  `git ls-files -v` tags those entries S or with a
    lowercase letter.  Any tag other than H (a plain cached file) refuses; a sparse checkout is refused too,
    which is the safe direction."""
    res, err = _git(ctx.runner, path, ["ls-files", "-v", "-z"])
    if res is None:
        return f"ls-files: {err}"
    if res.returncode != 0:
        return f"ls-files: git exited {res.returncode}"
    flagged = []
    for token in (res.stdout or "").split("\0"):
        if not token:
            continue
        tag, _sep, name = token.partition(" ")
        if tag != "H":
            flagged.append(f"{tag} {name}"[:80])
    if flagged:
        return f"index flags (skip-worktree, assume-unchanged, or similar) can hide local edits: {_sample(flagged)}"
    return ""


def _ignored_contents(path: str, scan: StatusScan) -> str:
    """The ignored entries that removal would take must be what their names say.  A no-slash entry named like a
    regenerable folder must be a symlink (git removes the link, never its target), and every ignored folder
    left in the lane must hold no nested git repository."""
    verified = [rel for rel in scan.link_candidates if os.path.islink(os.path.join(path, rel))]
    blocker = scan.removal_blocker(verified)
    if blocker:
        return blocker
    for rel in scan.removal_walk_dirs():
        why = nested_repo_blocker(os.path.join(path, rel))
        if why:
            return why
    return ""


def _unpushed(path: str, co: dict, ctx: LaneContext, notes: Optional[list]) -> str:
    """Commits missing from every remote ref.  On a detached HEAD they could be the only copy, so any count
    refuses.  On the reported branch they are kept twice over: the doctor matched a MERGED or CLOSED PR to this
    HEAD (a merged PR whose head contains HEAD, or a closed PR whose head equals it), so GitHub holds them
    under the PR head, and `git worktree remove` keeps the branch ref.
    _head_matches_report has already proven HEAD and the branch are what the report says."""
    lines, why = _git_lines(ctx, path, ["rev-list", "--count", "HEAD", "--not", "--remotes"], "rev-list")
    if lines is None:
        return why
    text = lines[0].strip() if len(lines) == 1 else ""
    if not text.isdigit():
        return f"unpushed commits: {text or '?'}"
    count = int(text)
    branch = co.get("branch")
    if count and not branch:
        return f"unpushed commits: {count} on a detached HEAD, so this lane may hold the only copy"
    if count and co.get("pr_state") not in MERGED_EVIDENCE_STATES:
        return f"unpushed commits: {count}"
    if notes is not None:
        if count:
            pr = f"PR #{co.get('pr_number')}" if co.get("pr_number") else "the PR"
            notes.append(f"{count} unpushed, kept by branch {branch} and {pr} head")
        else:
            notes.append("0 unpushed")
    return ""


def recheck_for_removal(path: str, co: dict, ctx: LaneContext, notes: Optional[list] = None) -> tuple:
    """The Vacuum's own look at a lane, run again at removal time.  Returns (repo_root, refusal).  When notes is
    a list, facts worth logging (the unpushed count) are appended to it."""
    why = _live_basics(path, co, ctx)
    if why:
        return "", why
    repo_root, why = _linked_facts(path, co, ctx)
    if why:
        return "", why
    why = _head_matches_report(path, co, ctx)
    if why:
        return "", why
    res, err = _git(
        ctx.runner, path, ["status", "--porcelain", "-z", "--ignored", "--untracked-files=normal"]
    )
    if res is None:
        return "", f"status: {err}"
    if res.returncode != 0:
        return "", f"status: git exited {res.returncode}"
    why = _ignored_contents(path, parse_status(res.stdout or ""))
    if why:
        return "", why
    why = _hidden_index_flags(path, ctx)
    if why:
        return "", why
    why = _unpushed(path, co, ctx, notes)
    if why:
        return "", why
    why = _other_worktrees(path, ctx)
    if why:
        return "", why
    why = _live_processes(path, ctx)
    if why:
        return "", why
    return repo_root, ""


def removal_argv(repo_root: str, path: str) -> list:
    """The one command that removes a lane.  There is no force variant of it anywhere in this module."""
    argv = ["git", "-C", repo_root, "worktree", "remove", path]
    assert_no_force(argv)
    return argv


def assert_no_force(argv: list) -> None:
    for part in argv:
        if part in ("-f", "--force") or (part.startswith("-") and not part.startswith("--") and "f" in part[1:]):
            raise ValueError(f"refusing a force flag in {argv!r}")


# --------------------------------------------------------------------------- selectors


def _evidence(co: dict, notes: list) -> list:
    pr = f"PR {co.get('pr_state')}" + (f" #{co.get('pr_number')}" if co.get("pr_number") else "")
    return [
        pr,
        f"safety {co.get('safety')}",
        f"age {co.get('lane_age_days')}d",
        f"idle {co.get('idle_days')}d",
        *notes,
        "gh ok",
    ]


def _nested_checkout(lane: str, report: LaneReport) -> str:
    """Another checkout from the report that sits inside this lane, or an empty string.  git worktree remove
    would take it with the lane if it is ignored there."""
    prefix = lane.casefold() + os.sep
    for other in report.by_real:
        if other.casefold().startswith(prefix):
            return other
    return ""


def removable_lanes(report: LaneReport, ctx: LaneContext) -> LaneScan:
    """Lanes the doctor lists AND that pass the Vacuum's re-check.  Fails closed with an empty choices list."""
    if not report.ok:
        return LaneScan(False, report.reason, doctor_seconds=report.seconds)
    scan = LaneScan(True, generated_at=report.generated_at_text, doctor_seconds=report.seconds)
    if not report.gh_ok:
        scan.ok = False
        scan.reason = report.gh_reason
        return scan
    listed = report.data.get("cleaner_candidates")
    if not isinstance(listed, list):
        scan.ok = False
        scan.reason = "doctor report has no cleaner_candidates list"
        return scan
    seen = set()
    for item in listed:
        if not isinstance(item, str) or not item:
            scan.refused.append({"path": repr(item)[:120], "reason": "candidate is not a path string"})
            continue
        if item in seen:
            continue
        seen.add(item)
        co = report.by_real.get(item)
        if co is None:
            scan.refused.append({"path": item, "reason": "listed as a candidate but not found in checkouts"})
            continue
        why = report_gate_retire(co, report, ctx)
        if why:
            scan.refused.append({"path": item, "reason": why})
            continue
        nested = _nested_checkout(item, report)
        if nested:
            scan.refused.append({"path": item, "reason": f"another checkout lives inside it: {nested}"})
            continue
        notes: list = []
        repo_root, why = recheck_for_removal(item, co, ctx, notes)
        if why:
            scan.refused.append({"path": item, "reason": why})
            continue
        scan.choices.append(
            LaneChoice(
                path=item,
                branch=str(co.get("branch") or ""),
                head_sha=str(co.get("head_sha") or ""),
                owner_repo=str(co.get("owner_repo") or ""),
                location_class=str(co.get("location_class") or ""),
                size_bytes=dir_size_bytes(item, ctx.runner),
                reasons=_evidence(co, notes),
                command=removal_argv(repo_root, item),
                checkout=co,
            )
        )
    return scan


def dependency_candidates(report: LaneReport, ctx: LaneContext) -> tuple:
    """Report-level pass for dependency folders: (list of (path, checkout), list of refusals).  The live
    check runs lane by lane, right before that lane is touched, in evaluate_dependency_lane."""
    passing: list = []
    refused: list = []
    for path in sorted(report.by_real):
        co = report.by_real[path]
        why = report_gate_deps(co, ctx)
        if why:
            # Only fleet lane rows are worth a line in the plan; harness worktrees and the rest are noise.
            if co.get("location_class") in DEPENDENCY_LANE_CLASSES:
                refused.append({"path": path, "reason": why})
            continue
        passing.append((path, co))
    return passing, refused


def evaluate_dependency_lane(path: str, co: dict, ctx: LaneContext) -> tuple:
    """Live check for one lane.  Returns (LaneChoice or None, refusal).  A lane need not be merged."""
    why = _live_basics(path, co, ctx)
    if why:
        return None, why
    repo_root, why = _linked_facts(path, co, ctx)
    if why:
        return None, why
    res, err = _git(ctx.runner, path, ["status", "--porcelain", "-z", "--ignored", "--untracked-files=normal"])
    if res is None:
        return None, f"status: {err}"
    if res.returncode != 0:
        return None, f"status: git exited {res.returncode}"
    scan = parse_status(res.stdout or "")
    if scan.tracked_dirty:
        return None, f"tracked changes: {_sample(scan.tracked_dirty)}"
    targets = sorted(set(scan.regen_ignored) | set(scan.regen_untracked))
    if not targets:
        return None, ""  # nothing to clean here; the caller does not list this as a refusal
    why = _live_processes(path, ctx)
    if why:
        return None, why
    if recently_modified(path, ctx.settings.deps_min_hours * 3600.0, ctx.clock):
        return None, f"files changed within {ctx.settings.deps_min_hours:g} hours"
    return (
        LaneChoice(
            path=path,
            branch=str(co.get("branch") or ""),
            head_sha=str(co.get("head_sha") or ""),
            owner_repo=str(co.get("owner_repo") or ""),
            location_class=str(co.get("location_class") or ""),
            size_bytes=None,
            reasons=[
                f"idle {co.get('idle_days')}d",
                f"age {co.get('lane_age_days')}d",
                "tracked tree clean",
                "no process cwd",
            ],
            targets=[{"path": t} for t in targets],
            checkout=co,
        ),
        "",
    )


def safe_target_path(lane: str, rel: str) -> str:
    """The absolute folder for a target, or an empty string when it is a symlink, missing, or outside the lane."""
    full = os.path.join(lane, rel)
    if os.path.islink(full) or not os.path.isdir(full):
        return ""
    real = os.path.realpath(full)
    if real != os.path.normpath(full) or not real.startswith(lane + os.sep):
        return ""
    return real


def deletable_target(lane: str, rel: str) -> tuple:
    """(absolute folder, '') when a dependency target may be deleted right now, else ('', refusal).  Called
    immediately before the delete (and at the same point in a dry run), because the folder can change between
    planning and deleting: it must still be a plain folder inside the lane, and must hold no nested git
    repository (a clone under .venv/src from pip install -e, or one under build/)."""
    full = safe_target_path(lane, rel)
    if not full:
        return "", "not a plain folder inside the lane"
    why = nested_repo_blocker(full)
    if why:
        return "", why
    return full, ""


# --------------------------------------------------------------------------- the action log


def append_action_log(data_dir: Path, entry: Mapping[str, Any]) -> None:
    """One JSON line per real action: when, what, how big, and the exact command.  Never raises."""
    try:
        data_dir.mkdir(parents=True, exist_ok=True)
        log = data_dir / ACTION_LOG_NAME
        try:
            if log.stat().st_size > ACTION_LOG_MAX_BYTES:
                log.replace(data_dir / (ACTION_LOG_NAME + ".1"))
        except OSError:
            pass
        row = dict(entry)
        row.setdefault("at", _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"))
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    except (OSError, TypeError, ValueError):
        pass

# HH-142: Maintain surface — rename, script-folder registry, timeout policy (2026-10-15)

Linear HH-142.  Board `63c5458b`.  Python, docs, and a small Swift pass; launchd label unchanged on purpose.

## What changed

| Area | Change |
|---|---|
| `scripts/maintain.py` | Canonical Maintain CLI (what the Mac app already called).  `scripts/robotic-vacuum.py` is now a one-line alias for installed launchd jobs and shims. |
| `scripts/vacuum/script_registry.py` | Writes `~/.hoghunter/maintenance/registry.json` on first run.  Each script is **owned** (Maintain may invoke) or **observed** (inventory only; launchd or another owner keeps control).  Scope is **local** or **remote**. |
| `scripts/vacuum/config.py` | Default data dir `…/Maintain` with one-shot migration from `…/RoboticVacuum`.  `coolify_remote` is off by default and stays off until `coolify_ssh_host` is set. |
| `scripts/vacuum/lanes.py` | Doctor base wait 420 s (was 300).  Adaptive wait scales from the last successful doctor duration, capped at 900 s. |
| `scripts/vacuum/engine.py` | Coolify skip copy matches the phone: "No remote servers are set up". |
| `Sources/Storage/MaintainStore.swift` | Hides the Coolify step until a host is configured; repo root resolves `maintain.py` or legacy `robotic-vacuum.py`. |
| Shims / docs | `_resolve-repo.sh` and `docs/mac-local-processes-shims.md` name Maintain and the registry path. |

## Already on main (not repeated here)

- Storage tabs **Clean** / **Maintain**, single scan spinner in `DiskCleanerView`, and Maintain header without a duplicate title (#121, #123).
- Reclaim **budget** + grace for `hoghunter-clean` (#114) instead of a blind 900 s kill.

## Owner / secrets

- **Coolify remote maintenance** needs `coolify_ssh_host` in Application Support `config.json` (or policy merge).  No Infisical key exists for it in this repo; Jay must set the host on the Mac before turning the step on.

## Verify

- `python3 scripts/test-hoghunter-clean.py` -> ok
- `python3 scripts/test-robotic-vacuum.py` -> ok (includes lane doctor suite)

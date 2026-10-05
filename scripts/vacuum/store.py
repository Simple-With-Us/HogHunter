from __future__ import annotations

import json
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Optional

from .config import expand_path, load_config
from .models import RunRecord, TriggerKind

try:
    import fcntl
except ImportError:  # pragma: no cover — non-Unix test hosts
    fcntl = None  # type: ignore[assignment]


class VacuumStore:
    def __init__(self, cfg: dict[str, Any], home: Path | None = None) -> None:
        self.home = home or Path.home()
        self.cfg = cfg
        self.data_dir = expand_path(str(cfg.get("data_dir", "")), self.home)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.history_path = self.data_dir / "history.json"
        self.state_path = self.data_dir / "scheduler-state.json"
        self.status_path = self.data_dir / "status.json"
        self.alert_state_path = self.data_dir / "alert-state.json"
        self._lock_path = self.data_dir / ".store.lock"

    @classmethod
    def open(cls, home: Path | None = None) -> "VacuumStore":
        return cls(load_config(home=home), home=home)

    def new_run(self, trigger: TriggerKind, band: str = "cheap", pressure: bool = False) -> RunRecord:
        return RunRecord(
            run_id=uuid.uuid4().hex[:12],
            trigger=trigger,
            started_at=time.time(),
            band=band,
            pressure=pressure,
        )

    def append_run(self, record: RunRecord) -> None:
        def updater(history: list[dict[str, Any]]) -> list[dict[str, Any]]:
            history.append(record.as_dict())
            max_runs = int(self.cfg.get("history_max_runs", 200))
            if len(history) > max_runs:
                history = history[-max_runs:]
            return history

        self._locked_json_update(self.history_path, [], updater)

    def load_history(self) -> list[dict[str, Any]]:
        if not self.history_path.is_file():
            return []
        try:
            return json.loads(self.history_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []

    def last_run_for(self, trigger: str) -> Optional[dict[str, Any]]:
        for raw in reversed(self.load_history()):
            if raw.get("trigger") == trigger:
                return raw
        return None

    def scheduler_state(self) -> dict[str, Any]:
        if not self.state_path.is_file():
            return {}
        try:
            return json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    def touch_scheduler(self, key: str, when: float | None = None) -> None:
        def updater(state: dict[str, Any]) -> dict[str, Any]:
            state[key] = when or time.time()
            return state

        self._locked_json_update(self.state_path, {}, updater)

    def merge_scheduler_state(self, updates: dict[str, Any]) -> None:
        if not updates:
            return

        def updater(state: dict[str, Any]) -> dict[str, Any]:
            state.update(updates)
            return state

        self._locked_json_update(self.state_path, {}, updater)

    def publish_status(self, payload: dict[str, Any]) -> None:
        payload["updated_at"] = time.time()
        self._atomic_write(self.status_path, payload)

    def load_status(self) -> dict[str, Any]:
        if not self.status_path.is_file():
            return {}
        try:
            return json.loads(self.status_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    def load_alert_state(self) -> dict[str, Any]:
        if not self.alert_state_path.is_file():
            return {}
        try:
            return json.loads(self.alert_state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    def save_alert_state(self, state: dict[str, Any]) -> None:
        self._atomic_write(self.alert_state_path, state)

    def save_step_toggles(self, steps: dict[str, bool]) -> None:
        cfg_path = self.data_dir / "config.json"

        def updater(user_cfg: dict[str, Any]) -> dict[str, Any]:
            step_cfg = user_cfg.setdefault("steps", {})
            for step_id, enabled in steps.items():
                step_cfg.setdefault(step_id, {})["enabled"] = bool(enabled)
            return user_cfg

        self._locked_json_update(cfg_path, {}, updater)
        self.cfg = load_config(cfg_path, self.home)

    def _locked_json_update(
        self,
        path: Path,
        default: Any,
        updater: Callable[[Any], Any],
    ) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self._lock_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self._lock_path, "a+", encoding="utf-8") as lockf:
            if fcntl is not None:
                fcntl.flock(lockf.fileno(), fcntl.LOCK_EX)
            try:
                current = default
                if path.is_file():
                    try:
                        current = json.loads(path.read_text(encoding="utf-8"))
                    except (OSError, json.JSONDecodeError):
                        current = default
                new_data = updater(current)
                self._atomic_write(path, new_data)
            finally:
                if fcntl is not None:
                    fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)

    @staticmethod
    def _atomic_write(path: Path, data: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f"{path.name}.{uuid.uuid4().hex}.tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        tmp.replace(path)

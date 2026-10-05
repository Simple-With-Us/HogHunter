from __future__ import annotations

import json
import time
import uuid
from pathlib import Path
from typing import Any, Optional

from .config import expand_path, load_config
from .models import RunRecord, TriggerKind


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
        history = self.load_history()
        history.append(record.as_dict())
        max_runs = int(self.cfg.get("history_max_runs", 200))
        if len(history) > max_runs:
            history = history[-max_runs:]
        self._atomic_write(self.history_path, history)

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
        state = self.scheduler_state()
        state[key] = when or time.time()
        self._atomic_write(self.state_path, state)

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
        user_cfg: dict[str, Any] = {}
        if cfg_path.is_file():
            try:
                user_cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                user_cfg = {}
        step_cfg = user_cfg.setdefault("steps", {})
        for step_id, enabled in steps.items():
            step_cfg.setdefault(step_id, {})["enabled"] = bool(enabled)
        self._atomic_write(cfg_path, user_cfg)
        self.cfg = load_config(cfg_path, self.home)

    @staticmethod
    def _atomic_write(path: Path, data: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        tmp.replace(path)

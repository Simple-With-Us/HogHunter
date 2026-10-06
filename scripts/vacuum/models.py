from __future__ import annotations

import enum
import time
from dataclasses import dataclass, field, asdict
from typing import Any, Optional


class StepStatus(str, enum.Enum):
    RAN = "ran"
    SKIPPED = "skipped"
    FAILED = "failed"


class TriggerKind(str, enum.Enum):
    WATCH = "watch"
    JANITOR = "janitor"
    FULL = "full"
    MANUAL = "manual"
    PRESSURE = "pressure"


@dataclass
class StepResult:
    step_id: str
    title: str
    status: StepStatus
    reason: str = ""
    bytes_freed: int = 0
    duration_ms: int = 0

    def as_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["status"] = self.status.value
        return d

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> "StepResult":
        return StepResult(
            step_id=str(raw.get("step_id", "")),
            title=str(raw.get("title", "")),
            status=StepStatus(str(raw.get("status", StepStatus.SKIPPED.value))),
            reason=str(raw.get("reason", "")),
            bytes_freed=int(raw.get("bytes_freed", 0) or 0),
            duration_ms=int(raw.get("duration_ms", 0) or 0),
        )


@dataclass
class RunRecord:
    run_id: str
    trigger: TriggerKind
    started_at: float
    ended_at: float = 0.0
    band: str = "cheap"
    pressure: bool = False
    exit_code: int = 0
    bytes_freed: int = 0
    steps: list[StepResult] = field(default_factory=list)
    summary: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {
            "run_id": self.run_id,
            "trigger": self.trigger.value,
            "started_at": self.started_at,
            "ended_at": self.ended_at,
            "band": self.band,
            "pressure": self.pressure,
            "exit_code": self.exit_code,
            "bytes_freed": self.bytes_freed,
            "summary": self.summary,
            "steps": [s.as_dict() for s in self.steps],
        }

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> "RunRecord":
        steps = [StepResult.from_dict(s) for s in (raw.get("steps") or [])]
        return RunRecord(
            run_id=str(raw.get("run_id", "")),
            trigger=TriggerKind(str(raw.get("trigger", TriggerKind.WATCH.value))),
            started_at=float(raw.get("started_at", 0)),
            ended_at=float(raw.get("ended_at", 0)),
            band=str(raw.get("band", "cheap")),
            pressure=bool(raw.get("pressure")),
            exit_code=int(raw.get("exit_code", 0)),
            bytes_freed=int(raw.get("bytes_freed", 0)),
            steps=steps,
            summary=str(raw.get("summary", "")),
        )

    def finish(self, exit_code: int = 0, summary: str = "") -> None:
        self.ended_at = time.time()
        self.exit_code = exit_code
        self.bytes_freed = sum(s.bytes_freed for s in self.steps)
        self.summary = summary or self.summary

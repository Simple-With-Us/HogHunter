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


class RunOutcome(str, enum.Enum):
    """How a run ended, apart from its exit code.  A run is `partial` when some step failed and another one
    still did its work: the failure is real and stays on that step, but the run is not a failed run."""

    OK = "ok"
    PARTIAL = "partial"
    FAILED = "failed"


# A step that only reads the host never counts as the work that rescued a run.
_PROBE_ONLY_STEPS = frozenset({"resource_sample"})


def run_outcome(steps: list["StepResult"]) -> RunOutcome:
    """ok: no step failed.  partial: a step failed, and another step ran.  failed: a step failed and nothing
    else did any work (skips and the sampler do not count)."""
    if not any(s.status == StepStatus.FAILED for s in steps):
        return RunOutcome.OK
    worked = any(s.status == StepStatus.RAN and s.step_id not in _PROBE_ONLY_STEPS for s in steps)
    return RunOutcome.PARTIAL if worked else RunOutcome.FAILED


def outcome_summary(steps: list["StepResult"], outcome: RunOutcome) -> str:
    """One line for the CLI and the log: which steps failed, out of how many."""
    if outcome == RunOutcome.OK:
        return ""
    failed = [s.step_id for s in steps if s.status == StepStatus.FAILED]
    return f"{outcome.value}: {len(failed)} of {len(steps)} step(s) failed ({', '.join(failed)})"


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
    # ok, partial or failed (RunOutcome).  `partial` exits 0: the failed step stays visible on the step.
    outcome: str = RunOutcome.OK.value

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
            "outcome": self.outcome,
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
            # A record written before the field existed was failed exactly when it exited non-zero.
            outcome=str(raw.get("outcome") or (RunOutcome.FAILED.value if int(raw.get("exit_code", 0)) else RunOutcome.OK.value)),
        )

    def finish(self, exit_code: Optional[int] = None, summary: str = "") -> None:
        """Close the record.  With no exit code the steps decide: failed (exit 1) only when a step failed and
        nothing else worked, partial (exit 0) when some steps failed and others ran, ok otherwise.  An explicit
        exit code still wins: non-zero is always a failed run, and zero is never worse than partial."""
        self.ended_at = time.time()
        outcome = run_outcome(self.steps)
        if exit_code is None:
            exit_code = 1 if outcome == RunOutcome.FAILED else 0
        elif exit_code != 0:
            outcome = RunOutcome.FAILED
        elif outcome == RunOutcome.FAILED:
            outcome = RunOutcome.PARTIAL  # the caller says it exited cleanly, so it is not a failed run
        self.exit_code = exit_code
        self.outcome = outcome.value
        self.bytes_freed = sum(s.bytes_freed for s in self.steps)
        detail = outcome_summary(self.steps, outcome)
        parts = [part for part in (summary or self.summary, detail) if part]
        self.summary = "; ".join(parts)

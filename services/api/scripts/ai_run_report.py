"""Summarize recent ai_generation_runs outcomes and failure causes.

Run from services/api or repository root:
    python services/api/scripts/ai_run_report.py --days 14 --limit 500
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Sequence

from sqlalchemy import select

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.db.session import get_sessionmaker  # noqa: E402
from app.features.ai.models import AIGenerationRun  # noqa: E402


def classify_failure_cause(
    *,
    error_message: str | None,
    output_summary: dict[str, Any] | None = None,
    validation_status: str | None = None,
) -> str:
    """Return a normalized cause bucket from output_summary or legacy error text."""
    if isinstance(output_summary, dict):
        explicit = output_summary.get("failure_cause")
        if isinstance(explicit, str) and explicit.strip():
            return explicit.strip()

    msg = (error_message or "").lower()
    if "rate limit" in msg or "busy" in msg:
        return "rate_limit"
    if "not valid json" in msg or "options list" in msg:
        return "invalid_json"
    if (
        validation_status == "invalid"
        or "validation" in msg
        or "options" in msg
        or "draft was not valid json" in msg
    ):
        return "validation_failed"
    if "unavailable" in msg or "rejected" in msg:
        return "model_unavailable"
    if "server error" in msg:
        return "provider_server_error"
    return "other"


def _field(run: Any, name: str, default: Any = None) -> Any:
    if isinstance(run, dict):
        return run.get(name, default)
    return getattr(run, name, default)


def summarize_runs(runs: Sequence[Any]) -> dict[str, Any]:
    """Aggregate status counts, failure causes, and per-model metrics."""
    status_counts: Counter[str] = Counter()
    failure_causes: Counter[str] = Counter()
    by_purpose: dict[str, Counter[str]] = defaultdict(Counter)
    by_model: dict[str, Counter[str]] = defaultdict(Counter)
    total_tokens_succeeded = 0
    succeeded_with_tokens = 0
    total_latency_ms = 0
    runs_with_latency = 0

    for run in runs:
        run_status = str(_field(run, "status", "unknown"))
        purpose = str(_field(run, "request_purpose", "unknown"))
        model_id = str(_field(run, "model_id", "unknown"))
        output_summary = _field(run, "output_summary")
        status_counts[run_status] += 1
        by_purpose[purpose][run_status] += 1
        by_model[model_id][run_status] += 1

        if isinstance(output_summary, dict) and output_summary.get("json_retry_used"):
            by_model[model_id]["json_retry_used"] += 1

        if run_status == "failed":
            cause = classify_failure_cause(
                error_message=_field(run, "error_message"),
                output_summary=output_summary if isinstance(output_summary, dict) else None,
                validation_status=_field(run, "validation_status"),
            )
            failure_causes[cause] += 1
            by_purpose[purpose][f"cause:{cause}"] += 1

        latency = _field(run, "response_time_ms")
        if isinstance(latency, int) and latency >= 0:
            total_latency_ms += latency
            runs_with_latency += 1

        if run_status == "succeeded":
            tokens = _field(run, "total_tokens")
            if isinstance(tokens, int) and tokens >= 0:
                total_tokens_succeeded += tokens
                succeeded_with_tokens += 1

    return {
        "total_runs": len(runs),
        "status_counts": dict(status_counts),
        "failure_causes": dict(failure_causes.most_common()),
        "by_purpose": {k: dict(v) for k, v in sorted(by_purpose.items())},
        "by_model": {k: dict(v) for k, v in sorted(by_model.items())},
        "avg_tokens_succeeded": (
            round(total_tokens_succeeded / succeeded_with_tokens, 1)
            if succeeded_with_tokens
            else None
        ),
        "avg_response_time_ms": (
            round(total_latency_ms / runs_with_latency, 1)
            if runs_with_latency
            else None
        ),
    }


def format_report(summary: dict[str, Any]) -> str:
    """Format a concise human-readable report."""
    lines = [
        f"AI generation runs analyzed: {summary['total_runs']}",
        "Statuses: "
        + (
            ", ".join(f"{k}={v}" for k, v in sorted(summary["status_counts"].items()))
            or "none"
        ),
    ]
    if summary["failure_causes"]:
        lines.append("Failure causes:")
        for cause, count in summary["failure_causes"].items():
            lines.append(f"  - {cause}: {count}")
    else:
        lines.append("Failure causes: none")
    if summary["by_purpose"]:
        lines.append("By request_purpose:")
        for purpose, stats in summary["by_purpose"].items():
            ok = stats.get("succeeded", 0)
            fail = stats.get("failed", 0)
            lines.append(f"  - {purpose}: succeeded={ok}, failed={fail}")
    if summary["by_model"]:
        lines.append("By model_id:")
        for model_id, stats in summary["by_model"].items():
            ok = stats.get("succeeded", 0)
            fail = stats.get("failed", 0)
            retried = stats.get("json_retry_used", 0)
            retry_note = f", json_retry_used={retried}" if retried else ""
            lines.append(f"  - {model_id}: succeeded={ok}, failed={fail}{retry_note}")
    lines.append(
        f"Avg tokens (succeeded): {summary['avg_tokens_succeeded']} | "
        f"Avg latency ms: {summary['avg_response_time_ms']}"
    )
    return "\n".join(lines)


async def fetch_and_summarize(
    *,
    days: int = 30,
    purpose: str | None = None,
    limit: int = 500,
) -> dict[str, Any]:
    sessionmaker = get_sessionmaker()
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    async with sessionmaker() as session:
        stmt = (
            select(AIGenerationRun)
            .where(AIGenerationRun.created_at >= cutoff)
            .order_by(AIGenerationRun.created_at.desc())
            .limit(limit)
        )
        if purpose:
            stmt = stmt.where(AIGenerationRun.request_purpose == purpose)
        rows = (await session.execute(stmt)).scalars().all()
    return summarize_runs(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30, help="Lookback window in days.")
    parser.add_argument("--purpose", type=str, default=None, help="Filter request_purpose.")
    parser.add_argument("--limit", type=int, default=500, help="Max rows to summarize.")
    parser.add_argument("--json", action="store_true", help="Emit JSON output.")
    args = parser.parse_args()

    summary = asyncio.run(
        fetch_and_summarize(days=args.days, purpose=args.purpose, limit=args.limit)
    )
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(format_report(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from datetime import date, datetime, time
from typing import Optional

from sqlalchemy import or_
from sqlalchemy.orm import Session

from app import models

SCORE_BASE = 1000.0

# Deduction per error type: flat penalty on event start + per-minute rate
SCORE_RULES: dict[str, dict] = {
    "vps_offline":  {"event_penalty": 5.0, "per_minute": 0.65},
    "aro_offline":  {"event_penalty": 3.0, "per_minute": 0.50},
    "no_internet":  {"event_penalty": 3.0, "per_minute": 0.50},
    "unbound":      {"event_penalty": 3.0, "per_minute": 0.40},
    "proxy_fail":   {"event_penalty": 2.0, "per_minute": 0.20},
}

ERROR_LABELS = {
    "vps_offline": "VPS Offline",
    "aro_offline":  "ARO Offline",
    "no_internet":  "ARO No Internet",
    "unbound":      "Unbound",
    "proxy_fail":   "Proxy Fail",
}


def calculate_score_for_day(
    node_id: str,
    target_date: date,
    db: Session,
    now: Optional[datetime] = None,
) -> dict:
    """
    Calculate quality score (0–1000) for a node on a given UTC calendar day.
    For incomplete days (today), pass `now` to cap ongoing errors at current time.
    Returns: {score, error_count, breakdown: {type: minutes}}
    """
    day_start = datetime.combine(target_date, time.min)
    day_end = datetime.combine(target_date, time.max)
    cap = min(now or datetime.utcnow(), day_end)

    events = db.query(models.NodeErrorLog).filter(
        models.NodeErrorLog.node_id == node_id,
        models.NodeErrorLog.started_at < day_end,
        or_(
            models.NodeErrorLog.ended_at > day_start,
            models.NodeErrorLog.ended_at.is_(None),
        ),
    ).all()

    deductions = 0.0
    breakdown: dict[str, float] = {k: 0.0 for k in SCORE_RULES}
    error_count = len(events)

    for event in events:
        rule = SCORE_RULES.get(event.error_type, {"event_penalty": 1.0, "per_minute": 0.1})
        start = max(event.started_at, day_start)
        end = min(event.ended_at or cap, cap)
        duration_min = max(0.0, (end - start).total_seconds() / 60)
        deductions += rule["event_penalty"] + duration_min * rule["per_minute"]
        if event.error_type in breakdown:
            breakdown[event.error_type] += duration_min

    return {
        "score": max(0.0, round(SCORE_BASE - deductions, 1)),
        "error_count": error_count,
        "breakdown": {k: round(v) for k, v in breakdown.items()},
    }

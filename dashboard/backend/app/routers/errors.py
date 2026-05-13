from datetime import date, datetime, time, timedelta

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app import models
from app.auth import get_current_user
from app.database import get_db
from app.scoring import SCORE_BASE, calculate_score_for_day

router = APIRouter(prefix="/errors", tags=["errors"])


@router.get("/stats")
def get_error_stats(
    days: int = Query(30, ge=1, le=90),
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    """
    Return quality score summary for every node.
    Includes today's live score, historical daily scores, and error breakdown.
    """
    today = date.today()
    cutoff_date = today - timedelta(days=days)
    now = datetime.utcnow()

    nodes = db.query(models.Node).all()
    result = []

    for node in nodes:
        # Today's score calculated live (ongoing errors capped at now)
        today_result = calculate_score_for_day(node.node_id, today, db, now)

        # Historical daily scores from precomputed table
        daily_rows = (
            db.query(models.NodeDailyScore)
            .filter(
                models.NodeDailyScore.node_id == node.node_id,
                models.NodeDailyScore.date >= cutoff_date,
                models.NodeDailyScore.date < today,
            )
            .order_by(models.NodeDailyScore.date)
            .all()
        )

        scores_history = [{"date": str(r.date), "score": r.score} for r in daily_rows]

        recent_7 = [r.score for r in daily_rows if r.date >= today - timedelta(days=7)]
        avg_7d = round(sum(recent_7) / len(recent_7), 1) if recent_7 else None
        avg_30d = (
            round(sum(r.score for r in daily_rows) / len(daily_rows), 1)
            if daily_rows else None
        )

        # Error event counts in last N days
        err_cutoff_dt = datetime.combine(cutoff_date, time.min)
        events = (
            db.query(models.NodeErrorLog)
            .filter(
                models.NodeErrorLog.node_id == node.node_id,
                models.NodeErrorLog.started_at >= err_cutoff_dt,
            )
            .all()
        )

        errors_by_type: dict[str, int] = {}
        for e in events:
            errors_by_type[e.error_type] = errors_by_type.get(e.error_type, 0) + 1

        result.append({
            "node_id": node.node_id,
            "account": node.account,
            "today_score": today_result["score"],
            "today_error_count": today_result["error_count"],
            "avg_7d": avg_7d,
            "avg_30d": avg_30d,
            "errors_by_type": errors_by_type,
            "total_errors": len(events),
            "daily_scores": scores_history,
        })

    # Sort: worst today_score first
    result.sort(key=lambda n: n["today_score"])
    return {"nodes": result, "score_base": SCORE_BASE}


@router.get("/{node_id}/events")
def get_node_error_events(
    node_id: str,
    days: int = Query(30, ge=1, le=90),
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    """Return all error events for a specific node in the last N days."""
    cutoff = datetime.utcnow() - timedelta(days=days)
    events = (
        db.query(models.NodeErrorLog)
        .filter(
            models.NodeErrorLog.node_id == node_id,
            models.NodeErrorLog.started_at >= cutoff,
        )
        .order_by(models.NodeErrorLog.started_at.desc())
        .all()
    )

    now = datetime.utcnow()
    return {
        "events": [
            {
                "id": e.id,
                "error_type": e.error_type,
                "started_at": e.started_at.isoformat(),
                "ended_at": e.ended_at.isoformat() if e.ended_at else None,
                "duration_minutes": (
                    e.duration_minutes
                    if e.ended_at
                    else max(0, int((now - e.started_at).total_seconds() / 60))
                ),
                "ongoing": e.ended_at is None,
            }
            for e in events
        ]
    }


@router.get("/{node_id}/scores")
def get_node_daily_scores(
    node_id: str,
    days: int = Query(30, ge=1, le=90),
    db: Session = Depends(get_db),
    _=Depends(get_current_user),
):
    """Return daily quality scores for a specific node."""
    today = date.today()
    cutoff = today - timedelta(days=days)
    now = datetime.utcnow()

    rows = (
        db.query(models.NodeDailyScore)
        .filter(
            models.NodeDailyScore.node_id == node_id,
            models.NodeDailyScore.date >= cutoff,
        )
        .order_by(models.NodeDailyScore.date)
        .all()
    )

    # Add today's live score
    today_result = calculate_score_for_day(node_id, today, db, now)

    scores = [
        {
            "date": str(r.date),
            "score": r.score,
            "error_count": r.error_count,
            "vps_offline_minutes": r.vps_offline_minutes,
            "aro_offline_minutes": r.aro_offline_minutes,
            "no_internet_minutes": r.no_internet_minutes,
            "unbound_minutes": r.unbound_minutes,
            "proxy_fail_minutes": r.proxy_fail_minutes,
        }
        for r in rows
        if r.date < today
    ]
    scores.append({
        "date": str(today),
        "score": today_result["score"],
        "error_count": today_result["error_count"],
        "vps_offline_minutes": today_result["breakdown"].get("vps_offline", 0),
        "aro_offline_minutes": today_result["breakdown"].get("aro_offline", 0),
        "no_internet_minutes": today_result["breakdown"].get("no_internet", 0),
        "unbound_minutes": today_result["breakdown"].get("unbound", 0),
        "proxy_fail_minutes": today_result["breakdown"].get("proxy_fail", 0),
    })

    return {"scores": scores, "score_base": SCORE_BASE}

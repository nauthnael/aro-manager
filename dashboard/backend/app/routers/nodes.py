from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app import models, schemas
from app.config import settings
from app.database import get_db

router = APIRouter()

# Maps aro_status values that represent an error condition → error_type name
_ARO_ERROR_MAP = {
    "Offline":     "aro_offline",
    "NoInternet":  "no_internet",
    "Unbound":     "unbound",
}


def _maybe_save_history(db: Session, status: models.NodeStatus, report: schemas.NodeReportRequest):
    now = datetime.utcnow()
    if status.last_snapshot_at is None or (now - status.last_snapshot_at) >= timedelta(hours=1):
        db.add(models.NodeHistory(
            node_id=report.node_id,
            timestamp=now,
            aro_status=report.aro_status,
            reward_today=report.reward_yesterday,
            uptime_ratio=report.uptime_ratio,
        ))
        status.last_snapshot_at = now


def _open_error(db: Session, node_id: str, error_type: str, now: datetime):
    existing = db.query(models.NodeErrorLog).filter(
        models.NodeErrorLog.node_id == node_id,
        models.NodeErrorLog.error_type == error_type,
        models.NodeErrorLog.ended_at.is_(None),
    ).first()
    if not existing:
        db.add(models.NodeErrorLog(
            node_id=node_id,
            error_type=error_type,
            started_at=now,
        ))


def _close_error(db: Session, node_id: str, error_type: str, now: datetime):
    log = db.query(models.NodeErrorLog).filter(
        models.NodeErrorLog.node_id == node_id,
        models.NodeErrorLog.error_type == error_type,
        models.NodeErrorLog.ended_at.is_(None),
    ).first()
    if log:
        log.ended_at = now
        log.duration_minutes = max(0, int((now - log.started_at).total_seconds() / 60))


def _track_status_errors(
    db: Session,
    node_id: str,
    old_aro: Optional[str],
    old_proxy_ok: Optional[bool],
    new_aro: str,
    new_proxy_ok: bool,
    now: datetime,
):
    """Detect aro_status / proxy_ok changes and open or close error log entries."""
    old_err = _ARO_ERROR_MAP.get(old_aro or "")
    new_err = _ARO_ERROR_MAP.get(new_aro or "")

    if old_err != new_err:
        if old_err:
            _close_error(db, node_id, old_err, now)
        if new_err:
            _open_error(db, node_id, new_err, now)

    # proxy_fail tracking
    if old_proxy_ok is None:
        if new_proxy_ok is False:
            _open_error(db, node_id, "proxy_fail", now)
    else:
        if old_proxy_ok and not new_proxy_ok:
            _open_error(db, node_id, "proxy_fail", now)
        elif not old_proxy_ok and new_proxy_ok:
            _close_error(db, node_id, "proxy_fail", now)


@router.post("/nodes/report", response_model=schemas.NodeReportResponse)
def node_report(body: schemas.NodeReportRequest, db: Session = Depends(get_db)):
    if body.api_key != settings.dashboard_api_key:
        raise HTTPException(status_code=403, detail="Invalid API key")

    node_id = body.node_id.strip()
    now = datetime.utcnow()

    node = db.query(models.Node).filter(models.Node.node_id == node_id).first()
    if not node:
        node = models.Node(node_id=node_id)
        db.add(node)
    if body.account:
        node.account = body.account
    old_serial = node.serial
    if body.serial:
        node.serial = body.serial
    if body.proxy_host:
        node.proxy_host = body.proxy_host
    if body.proxy_port:
        node.proxy_port = body.proxy_port
    if body.proxy_user:
        node.proxy_user = body.proxy_user

    status = db.query(models.NodeStatus).filter(models.NodeStatus.node_id == node_id).first()
    if not status:
        status = models.NodeStatus(node_id=node_id)
        db.add(status)

    # Capture old state before overwriting
    old_aro = status.aro_status
    old_proxy_ok = status.proxy_ok

    status.aro_status = body.aro_status
    status.proxy_ok = body.proxy_ok
    status.reward_today = body.reward_today
    status.reward_yesterday = body.reward_yesterday
    status.uptime_ratio = body.uptime_ratio
    status.public_ip = body.public_ip
    status.script_version = body.script_version
    status.last_seen = now

    _maybe_save_history(db, status, body)
    _track_status_errors(db, node_id, old_aro, old_proxy_ok, body.aro_status, body.proxy_ok, now)

    # If serial changed, update serial_after on the most recent renew log that hasn't tracked it yet
    if body.serial and old_serial and body.serial != old_serial:
        recent_renew = (
            db.query(models.NodeRenewLog)
            .filter(
                models.NodeRenewLog.node_id == node_id,
                models.NodeRenewLog.serial_after.is_(None),
            )
            .order_by(models.NodeRenewLog.renewed_at.desc())
            .first()
        )
        if recent_renew:
            recent_renew.serial_after = body.serial

    db.commit()

    pending = (
        db.query(models.Command)
        .filter(models.Command.node_id == node_id, models.Command.status == "pending")
        .all()
    )

    try:
        app_settings = db.query(models.AppSettings).filter(models.AppSettings.id == 1).first()
        pmin = app_settings.periodic_restart_min if app_settings and app_settings.periodic_restart_min else 54
        pmax = app_settings.periodic_restart_max if app_settings and app_settings.periodic_restart_max else 120
        daily_report_enabled = app_settings.daily_report_enabled if app_settings and app_settings.daily_report_enabled is not None else True
        global_stale = (app_settings.log_stale_restart_minutes or 5) if app_settings else 5
        # Per-node override takes precedence over global
        effective_stale = node.log_stale_restart_minutes if node.log_stale_restart_minutes is not None else global_stale
    except Exception:
        pmin, pmax = 54, 120
        daily_report_enabled = True
        effective_stale = 5

    return schemas.NodeReportResponse(
        ok=True,
        commands=[schemas.PendingCommand(id=c.id, action=c.action, payload=c.payload) for c in pending],
        periodic_restart_min=pmin,
        periodic_restart_max=pmax,
        daily_report_enabled=daily_report_enabled,
        log_stale_restart_minutes=effective_stale,
    )


@router.post("/nodes/restart-event")
def node_restart_event(body: schemas.NodeRestartEventRequest, db: Session = Depends(get_db)):
    if body.api_key != settings.dashboard_api_key:
        raise HTTPException(status_code=403, detail="Invalid API key")

    node_id = body.node_id.strip()
    node = db.query(models.Node).filter(models.Node.node_id == node_id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")

    event = models.NodeRestartLog(
        node_id=node_id,
        timestamp=datetime.utcnow(),
        success=body.success,
        duration_secs=body.duration_secs,
    )
    db.add(event)
    db.commit()
    return {"ok": True}


@router.post("/nodes/{node_id}/commands/{cmd_id}/ack")
def ack_command(node_id: str, cmd_id: int, db: Session = Depends(get_db)):
    cmd = db.query(models.Command).filter(
        models.Command.id == cmd_id,
        models.Command.node_id == node_id,
    ).first()
    if not cmd:
        raise HTTPException(status_code=404)
    cmd.status = "acked"
    cmd.acked_at = datetime.utcnow()
    db.commit()
    return {"ok": True}


@router.post("/nodes/{node_id}/commands/{cmd_id}/complete")
def complete_command(
    node_id: str,
    cmd_id: int,
    body: schemas.CommandCompleteRequest,
    db: Session = Depends(get_db),
):
    cmd = db.query(models.Command).filter(
        models.Command.id == cmd_id,
        models.Command.node_id == node_id,
    ).first()
    if not cmd:
        raise HTTPException(status_code=404)
    cmd.status = "completed" if body.success else "failed"
    cmd.result = body.result
    cmd.completed_at = datetime.utcnow()

    if cmd.action == "renew_node":
        renew_log = db.query(models.NodeRenewLog).filter(
            models.NodeRenewLog.command_id == cmd_id
        ).first()
        if renew_log:
            renew_log.status = "completed" if body.success else "failed"

    db.commit()
    return {"ok": True}

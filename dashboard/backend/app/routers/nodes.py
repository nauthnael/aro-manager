from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app import models, schemas
from app.config import settings
from app.database import get_db

router = APIRouter()


def _maybe_save_history(db: Session, status: models.NodeStatus, report: schemas.NodeReportRequest):
    now = datetime.utcnow()
    if status.last_snapshot_at is None or (now - status.last_snapshot_at) >= timedelta(hours=1):
        db.add(models.NodeHistory(
            node_id=report.node_id,
            timestamp=now,
            aro_status=report.aro_status,
            reward_today=report.reward_yesterday,  # app không trả today, dùng yesterday
            uptime_ratio=report.uptime_ratio,
        ))
        status.last_snapshot_at = now


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
    if body.serial:
        node.serial = body.serial
    if body.proxy_host:
        node.proxy_host = body.proxy_host
    if body.proxy_port:
        node.proxy_port = body.proxy_port

    status = db.query(models.NodeStatus).filter(models.NodeStatus.node_id == node_id).first()
    if not status:
        status = models.NodeStatus(node_id=node_id)
        db.add(status)

    status.aro_status = body.aro_status
    status.proxy_ok = body.proxy_ok
    status.reward_today = body.reward_today
    status.reward_yesterday = body.reward_yesterday
    status.uptime_ratio = body.uptime_ratio
    status.public_ip = body.public_ip
    status.script_version = body.script_version
    status.last_seen = now

    _maybe_save_history(db, status, body)
    db.commit()

    pending = (
        db.query(models.Command)
        .filter(models.Command.node_id == node_id, models.Command.status == "pending")
        .all()
    )

    app_settings = db.query(models.AppSettings).filter(models.AppSettings.id == 1).first()
    pmin = app_settings.periodic_restart_min if app_settings and app_settings.periodic_restart_min else 54
    pmax = app_settings.periodic_restart_max if app_settings and app_settings.periodic_restart_max else 120

    return schemas.NodeReportResponse(
        ok=True,
        commands=[schemas.PendingCommand(id=c.id, action=c.action) for c in pending],
        periodic_restart_min=pmin,
        periodic_restart_max=pmax,
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
    db.commit()
    return {"ok": True}

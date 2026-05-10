from datetime import datetime, timedelta
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from app import models, schemas
from app.auth import create_token, get_current_user, verify_password
from app.config import settings
from app.database import get_db

router = APIRouter()

STALE_SECS = settings.stale_threshold_secs


def _node_out(node: models.Node, status: Optional[models.NodeStatus], now: datetime) -> schemas.NodeStatusOut:
    if status and status.last_seen:
        is_stale = (now - status.last_seen).total_seconds() > STALE_SECS
    else:
        is_stale = True

    return schemas.NodeStatusOut(
        node_id=node.node_id,
        aro_status=status.aro_status if status else None,
        proxy_ok=status.proxy_ok if status else None,
        reward_today=status.reward_today if status else None,
        reward_yesterday=status.reward_yesterday if status else None,
        uptime_ratio=status.uptime_ratio if status else None,
        public_ip=status.public_ip if status else None,
        script_version=status.script_version if status else None,
        last_seen=status.last_seen if status else None,
        is_stale=is_stale,
        account=node.account,
        serial=node.serial,
        proxy_host=node.proxy_host,
        proxy_port=node.proxy_port,
        notes=node.notes,
    )


@router.post("/auth/login", response_model=schemas.TokenResponse)
def login(body: schemas.LoginRequest, db: Session = Depends(get_db)):
    user = db.query(models.User).filter(models.User.username == body.username).first()
    if not user or not verify_password(body.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    return schemas.TokenResponse(access_token=create_token(body.username))


@router.get("/auth/me")
def me(current_user: models.User = Depends(get_current_user)):
    return {"username": current_user.username}


@router.get("/dashboard/nodes", response_model=schemas.NodeListResponse)
def list_nodes(
    status_filter: Optional[str] = Query(None),
    search: Optional[str] = Query(None),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    now = datetime.utcnow()
    nodes = db.query(models.Node).all()
    statuses = {s.node_id: s for s in db.query(models.NodeStatus).all()}

    all_out = [_node_out(n, statuses.get(n.node_id), now) for n in nodes]

    online = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Online")
    offline = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Offline")
    no_internet = sum(1 for n in all_out if not n.is_stale and n.aro_status == "NoInternet")
    unbound = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Unbound")
    stale = sum(1 for n in all_out if n.is_stale)

    filtered = all_out
    if search:
        q = search.lower()
        filtered = [n for n in filtered if q in (n.node_id or "").lower() or q in (n.account or "").lower()]
    if status_filter == "stale":
        filtered = [n for n in filtered if n.is_stale]
    elif status_filter:
        filtered = [n for n in filtered if not n.is_stale and n.aro_status == status_filter]

    return schemas.NodeListResponse(
        nodes=filtered,
        total=len(nodes),
        online=online,
        offline=offline,
        no_internet=no_internet,
        unbound=unbound,
        stale=stale,
    )


@router.get("/dashboard/nodes/{node_id}", response_model=schemas.NodeDetailResponse)
def get_node(
    node_id: str,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    now = datetime.utcnow()
    node = db.query(models.Node).filter(models.Node.node_id == node_id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")

    status = db.query(models.NodeStatus).filter(models.NodeStatus.node_id == node_id).first()
    cutoff = now - timedelta(days=30)
    history = (
        db.query(models.NodeHistory)
        .filter(models.NodeHistory.node_id == node_id, models.NodeHistory.timestamp >= cutoff)
        .order_by(models.NodeHistory.timestamp)
        .all()
    )

    return schemas.NodeDetailResponse(
        node=_node_out(node, status, now),
        history=[
            schemas.HistoryPoint(
                timestamp=h.timestamp,
                aro_status=h.aro_status,
                reward_today=h.reward_today,
                uptime_ratio=h.uptime_ratio,
            )
            for h in history
        ],
    )


@router.get("/dashboard/nodes/{node_id}/screenshot")
def get_node_screenshot(
    node_id: str,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    cmd = (
        db.query(models.Command)
        .filter(
            models.Command.node_id == node_id,
            models.Command.action == "capture_screenshot",
            models.Command.status == "completed",
        )
        .order_by(models.Command.completed_at.desc())
        .first()
    )
    if not cmd or not cmd.result:
        raise HTTPException(status_code=404, detail="Chưa có screenshot")
    return {"data": cmd.result, "captured_at": cmd.completed_at}


@router.put("/dashboard/nodes/{node_id}/notes")
def update_notes(
    node_id: str,
    body: schemas.UpdateNotesRequest,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    node = db.query(models.Node).filter(models.Node.node_id == node_id).first()
    if not node:
        raise HTTPException(status_code=404)
    node.notes = body.notes
    db.commit()
    return {"ok": True}


@router.get("/dashboard/accounts", response_model=List[schemas.AccountStatsOut])
def account_stats(
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    now = datetime.utcnow()
    nodes = db.query(models.Node).all()
    statuses = {s.node_id: s for s in db.query(models.NodeStatus).all()}

    buckets: dict = {}
    for node in nodes:
        key = node.account or "(không rõ)"
        if key not in buckets:
            buckets[key] = dict(
                account=key, total=0, online=0, offline=0,
                no_internet=0, unbound=0, vps_offline=0,
                total_points=0.0, uptime_sum=0.0, uptime_count=0,
            )
        b = buckets[key]
        b["total"] += 1

        status = statuses.get(node.node_id)
        if status and status.last_seen and (now - status.last_seen).total_seconds() <= STALE_SECS:
            aro = status.aro_status
            if aro == "Online":        b["online"] += 1
            elif aro == "Offline":     b["offline"] += 1
            elif aro == "NoInternet":  b["no_internet"] += 1
            elif aro == "Unbound":     b["unbound"] += 1
            else:                      b["vps_offline"] += 1

            if status.reward_yesterday:
                b["total_points"] += status.reward_yesterday
            if status.uptime_ratio is not None:
                b["uptime_sum"] += status.uptime_ratio
                b["uptime_count"] += 1
        else:
            b["vps_offline"] += 1

    result = []
    for b in buckets.values():
        avg = b["uptime_sum"] / b["uptime_count"] if b["uptime_count"] > 0 else None
        result.append(schemas.AccountStatsOut(
            account=b["account"], total=b["total"],
            online=b["online"], offline=b["offline"],
            no_internet=b["no_internet"], unbound=b["unbound"],
            vps_offline=b["vps_offline"],
            total_points=round(b["total_points"], 2),
            avg_uptime=round(avg, 1) if avg is not None else None,
        ))

    result.sort(key=lambda x: x.total_points, reverse=True)
    return result

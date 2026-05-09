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

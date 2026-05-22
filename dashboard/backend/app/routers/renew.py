from datetime import datetime, timedelta
from math import ceil
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func
from sqlalchemy.orm import Session

from app import models, schemas
from app.auth import get_current_user
from app.config import settings
from app.database import get_db

router = APIRouter()

COOLDOWN_HOURS = 4


def _get_renew_count(db: Session, node_id: str) -> int:
    return db.query(func.count(models.NodeRenewLog.id)).filter(
        models.NodeRenewLog.node_id == node_id
    ).scalar() or 0


def _get_last_renew(db: Session, node_id: str) -> Optional[models.NodeRenewLog]:
    return (
        db.query(models.NodeRenewLog)
        .filter(models.NodeRenewLog.node_id == node_id)
        .order_by(models.NodeRenewLog.renewed_at.desc())
        .first()
    )


def _cooldown_until(last_renew: Optional[models.NodeRenewLog]) -> Optional[datetime]:
    if not last_renew:
        return None
    cutoff = last_renew.renewed_at + timedelta(hours=COOLDOWN_HOURS)
    return cutoff if datetime.utcnow() < cutoff else None


def _pending_renew_count(db: Session) -> int:
    return db.query(func.count(models.Command.id)).filter(
        models.Command.action == "renew_node",
        models.Command.status.in_(["pending", "acked"]),
    ).scalar() or 0


@router.get("/renew/candidates", response_model=schemas.RenewCandidatesResponse)
def get_renew_candidates(
    min_history_days: int = Query(0, ge=0, le=7),
    filter_avg_score: bool = Query(True),
    filter_uptime: bool = Query(False),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    """Return renew candidates based on selected filters, excluding Unbound nodes."""
    threshold_secs = settings.stale_threshold_secs
    now = datetime.utcnow()

    query = (
        db.query(models.Node, models.NodeStatus)
        .join(models.NodeStatus, models.Node.node_id == models.NodeStatus.node_id, isouter=True)
        .filter(models.NodeStatus.aro_status != "Unbound")
    )
    if filter_uptime:
        query = query.filter(models.NodeStatus.uptime_ratio == 0)

    rows = query.order_by(models.Node.node_id).all()
    node_ids = [node.node_id for node, _ in rows]

    # Precompute avg reward per node from node_history.reward_today snapshots
    avg_scores: dict = {}
    if node_ids:
        for row in (
            db.query(
                models.NodeHistory.node_id,
                func.avg(models.NodeHistory.reward_today).label("avg"),
            )
            .filter(models.NodeHistory.node_id.in_(node_ids))
            .group_by(models.NodeHistory.node_id)
            .all()
        ):
            avg_scores[row.node_id] = float(row.avg) if row.avg is not None else 0.0

    # Precompute distinct history day count per node
    history_days: dict = {}
    if node_ids:
        for row in (
            db.query(
                models.NodeHistory.node_id,
                func.count(func.distinct(func.date(models.NodeHistory.timestamp))).label("days"),
            )
            .filter(models.NodeHistory.node_id.in_(node_ids))
            .group_by(models.NodeHistory.node_id)
            .all()
        ):
            history_days[row.node_id] = row.days

    result: List[schemas.RenewCandidateOut] = []
    for node, status in rows:
        node_avg = avg_scores.get(node.node_id, 0.0)

        # Apply avg_score filter: skip nodes that have avg_score > 0
        if filter_avg_score and node_avg > 0:
            continue

        # Apply history filter
        if min_history_days > 0 and history_days.get(node.node_id, 0) < min_history_days:
            continue

        is_stale = (
            status is None
            or status.last_seen is None
            or (now - status.last_seen).total_seconds() > threshold_secs
        )

        renew_count = _get_renew_count(db, node.node_id)
        last_renew = _get_last_renew(db, node.node_id)
        cooldown = _cooldown_until(last_renew)

        result.append(schemas.RenewCandidateOut(
            node_id=node.node_id,
            account=node.account,
            serial=node.serial,
            aro_status=status.aro_status if status else None,
            avg_score=node_avg,
            uptime_ratio=status.uptime_ratio if status else None,
            last_seen=status.last_seen if status else None,
            is_stale=is_stale,
            renew_count=renew_count,
            last_renewed_at=last_renew.renewed_at if last_renew else None,
            last_renew_status=last_renew.status if last_renew else None,
            cooldown_until=cooldown,
        ))

    return schemas.RenewCandidatesResponse(nodes=result, total=len(result))


@router.post("/renew/trigger", response_model=schemas.RenewTriggerResponse)
def trigger_renew(
    body: schemas.RenewTriggerRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    node = db.query(models.Node).filter(models.Node.node_id == body.node_id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")

    last_renew = _get_last_renew(db, body.node_id)
    cooldown = _cooldown_until(last_renew)
    if cooldown:
        remaining = int((cooldown - datetime.utcnow()).total_seconds() / 60)
        raise HTTPException(
            status_code=429,
            detail=f"Cooldown: còn {remaining} phút nữa mới có thể renew lại node này.",
        )

    pending = _pending_renew_count(db)
    if pending >= settings.max_concurrent_renews:
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit: đang có {pending} renew đang chờ. Tối đa {settings.max_concurrent_renews} node cùng lúc.",
        )

    # Cancel duplicate pending renew commands
    db.query(models.Command).filter(
        models.Command.node_id == body.node_id,
        models.Command.action == "renew_node",
        models.Command.status == "pending",
    ).delete()

    cmd = models.Command(
        node_id=body.node_id,
        action="renew_node",
        created_by=current_user.username,
    )
    db.add(cmd)
    db.flush()

    renew_count = _get_renew_count(db, body.node_id) + 1
    log = models.NodeRenewLog(
        node_id=body.node_id,
        serial_before=node.serial,
        account_before=node.account,
        command_id=cmd.id,
        status="pending",
        renew_count=renew_count,
    )
    db.add(log)
    db.commit()

    return schemas.RenewTriggerResponse(
        ok=True,
        message=f"Đã gửi lệnh renew đến node {body.node_id}.",
        command_id=cmd.id,
    )


@router.post("/renew/bulk", response_model=schemas.BulkRenewResponse)
def bulk_renew(
    body: schemas.BulkRenewRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if not body.node_ids:
        raise HTTPException(status_code=400, detail="node_ids is empty")

    existing_nodes = {
        n.node_id: n
        for n in db.query(models.Node).filter(models.Node.node_id.in_(body.node_ids)).all()
    }

    triggered = 0
    skipped = 0
    details = []
    now = datetime.utcnow()

    # Track how many slots are available (global rate limit)
    current_pending = _pending_renew_count(db)
    slots_available = settings.max_concurrent_renews - current_pending

    for node_id in body.node_ids:
        node = existing_nodes.get(node_id)
        if not node:
            skipped += 1
            details.append({"node_id": node_id, "ok": False, "reason": "Node không tồn tại"})
            continue

        if slots_available <= 0:
            skipped += 1
            details.append({"node_id": node_id, "ok": False, "reason": f"Rate limit: tối đa {settings.max_concurrent_renews} node cùng lúc"})
            continue

        last_renew = _get_last_renew(db, node_id)
        cooldown = _cooldown_until(last_renew)
        if cooldown:
            remaining = int((cooldown - now).total_seconds() / 60)
            skipped += 1
            details.append({"node_id": node_id, "ok": False, "reason": f"Cooldown: còn {remaining} phút"})
            continue

        db.query(models.Command).filter(
            models.Command.node_id == node_id,
            models.Command.action == "renew_node",
            models.Command.status == "pending",
        ).delete()

        cmd = models.Command(
            node_id=node_id,
            action="renew_node",
            created_by=current_user.username,
        )
        db.add(cmd)
        db.flush()

        renew_count = _get_renew_count(db, node_id) + 1
        db.add(models.NodeRenewLog(
            node_id=node_id,
            serial_before=node.serial,
            account_before=node.account,
            command_id=cmd.id,
            status="pending",
            renew_count=renew_count,
        ))
        triggered += 1
        slots_available -= 1
        details.append({"node_id": node_id, "ok": True, "command_id": cmd.id})

    db.commit()
    return schemas.BulkRenewResponse(triggered=triggered, skipped=skipped, details=details)


@router.post("/renew/bulk-combo")
def bulk_combo_renew(
    body: schemas.BulkComboRenewRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Bulk queue combo_purge_proxy_renew: apt purge aro-desktop → đổi proxy → apt install aro-desktop.
    Validates proxy format, batch duplicates, DB uniqueness, cooldown and rate limit."""
    import base64

    if not body.assignments:
        raise HTTPException(status_code=400, detail="Danh sách assignments trống")

    # Step 1: Validate proxy format
    fmt_errors = []
    parsed = []
    for a in body.assignments:
        parts = a.proxy.strip().split(":")
        if len(parts) != 4:
            fmt_errors.append(f"Node {a.node_id}: sai định dạng (cần host:port:user:pass)")
            continue
        try:
            port = int(parts[1])
        except ValueError:
            fmt_errors.append(f"Node {a.node_id}: port không phải số nguyên")
            continue
        parsed.append({
            "node_id": a.node_id,
            "proxy": a.proxy.strip(),
            "host": parts[0],
            "port": port,
            "user": parts[2],
        })

    if fmt_errors:
        raise HTTPException(status_code=400, detail="\n".join(fmt_errors))

    # Step 2: Check duplicates within batch (same host:port:user)
    batch_node_ids = {p["node_id"] for p in parsed}
    seen_keys: dict = {}
    dup_errors = []
    for p in parsed:
        key = f"{p['host']}:{p['port']}:{p['user']}"
        if key in seen_keys:
            dup_errors.append(f"Proxy {key} bị trùng giữa node {seen_keys[key]} và {p['node_id']}")
        else:
            seen_keys[key] = p["node_id"]

    if dup_errors:
        raise HTTPException(status_code=409, detail="\n".join(dup_errors))

    # Step 3: Check DB uniqueness (exclude nodes in this batch — they're getting new proxies)
    conflict_errors = []
    for p in parsed:
        conflict = (
            db.query(models.Node)
            .filter(
                models.Node.node_id.notin_(batch_node_ids),
                models.Node.proxy_host == p["host"],
                models.Node.proxy_port == p["port"],
                models.Node.proxy_user == p["user"],
            )
            .first()
        )
        if conflict:
            conflict_errors.append(
                f"Proxy {p['host']}:{p['port']}:{p['user']} đang dùng bởi node {conflict.node_id}"
            )

    if conflict_errors:
        raise HTTPException(status_code=409, detail="\n".join(conflict_errors))

    # Step 4: Cooldown + rate limit + create commands
    existing_nodes = {
        n.node_id: n
        for n in db.query(models.Node).filter(models.Node.node_id.in_(batch_node_ids)).all()
    }

    current_pending = _pending_renew_count(db)
    slots_available = settings.max_concurrent_renews - current_pending
    now = datetime.utcnow()

    triggered = 0
    skipped = 0
    details = []

    for p in parsed:
        node = existing_nodes.get(p["node_id"])
        if not node:
            skipped += 1
            details.append({"node_id": p["node_id"], "ok": False, "reason": "Node không tồn tại"})
            continue

        if slots_available <= 0:
            skipped += 1
            details.append({
                "node_id": p["node_id"], "ok": False,
                "reason": f"Rate limit: tối đa {settings.max_concurrent_renews} node cùng lúc",
            })
            continue

        last_renew = _get_last_renew(db, p["node_id"])
        cooldown = _cooldown_until(last_renew)
        if cooldown:
            remaining = int((cooldown - now).total_seconds() / 60)
            skipped += 1
            details.append({"node_id": p["node_id"], "ok": False, "reason": f"Cooldown: còn {remaining} phút"})
            continue

        # Cancel pending combo/renew commands to avoid conflicts
        for action in ("combo_purge_proxy_renew", "renew_node", "set_proxy"):
            db.query(models.Command).filter(
                models.Command.node_id == p["node_id"],
                models.Command.action == action,
                models.Command.status == "pending",
            ).delete()

        payload_b64 = base64.b64encode(p["proxy"].encode()).decode()
        cmd = models.Command(
            node_id=p["node_id"],
            action="combo_purge_proxy_renew",
            payload=payload_b64,
            created_by=current_user.username,
        )
        db.add(cmd)
        db.flush()

        renew_count = _get_renew_count(db, p["node_id"]) + 1
        db.add(models.NodeRenewLog(
            node_id=p["node_id"],
            serial_before=node.serial,
            account_before=node.account,
            command_id=cmd.id,
            status="pending",
            renew_count=renew_count,
        ))

        triggered += 1
        slots_available -= 1
        details.append({"node_id": p["node_id"], "ok": True, "command_id": cmd.id})

    db.commit()
    return {"ok": True, "triggered": triggered, "skipped": skipped, "details": details}


@router.get("/renew/history", response_model=schemas.RenewHistoryResponse)
def get_renew_history(
    node_id: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, le=200),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    q = db.query(models.NodeRenewLog).order_by(models.NodeRenewLog.renewed_at.desc())
    if node_id:
        q = q.filter(models.NodeRenewLog.node_id == node_id)

    total = q.count()
    logs = q.offset((page - 1) * page_size).limit(page_size).all()

    node_accounts = {}
    node_last_account_seen = {}
    node_reward_yesterday = {}
    node_ids = list({log.node_id for log in logs})
    if node_ids:
        for n in db.query(models.Node).filter(models.Node.node_id.in_(node_ids)).all():
            node_accounts[n.node_id] = n.account
        for s in db.query(models.NodeStatus).filter(models.NodeStatus.node_id.in_(node_ids)).all():
            node_reward_yesterday[s.node_id] = s.reward_yesterday
        # Use NodeAccountHistory.last_seen (only updated when node reports a valid account)
        # instead of NodeStatus.last_seen (updated on every heartbeat regardless of account)
        for row in (
            db.query(
                models.NodeAccountHistory.node_id,
                func.max(models.NodeAccountHistory.last_seen).label("last_account_seen"),
            )
            .filter(models.NodeAccountHistory.node_id.in_(node_ids))
            .group_by(models.NodeAccountHistory.node_id)
            .all()
        ):
            node_last_account_seen[row.node_id] = row.last_account_seen

    result = []
    for log in logs:
        last_account_seen = node_last_account_seen.get(log.node_id)
        reconnected = last_account_seen is not None and log.renewed_at is not None and last_account_seen > log.renewed_at
        account = node_accounts.get(log.node_id) if reconnected else None
        result.append(schemas.RenewLogOut(
            id=log.id,
            node_id=log.node_id,
            account=account,
            renewed_at=log.renewed_at,
            serial_before=log.serial_before,
            serial_after=log.serial_after,
            account_before=log.account_before,
            command_id=log.command_id,
            status=log.status,
            renew_count=log.renew_count,
            monitored_at=log.monitored_at,
            reward_yesterday=node_reward_yesterday.get(log.node_id),
        ))

    return schemas.RenewHistoryResponse(
        logs=result,
        total=total,
        page=page,
        page_size=page_size,
        total_pages=ceil(total / page_size) if total > 0 else 1,
    )

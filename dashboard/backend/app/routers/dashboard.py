import math
from datetime import datetime, timedelta
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, text
from sqlalchemy.orm import Session

from app import models, schemas
from app.auth import create_token, get_current_user, verify_password
from app.config import settings
from app.database import get_db
from app.ip_country import get_node_country

router = APIRouter()

STALE_SECS = settings.stale_threshold_secs


def _node_out(node: models.Node, status: Optional[models.NodeStatus], now: datetime, total_score: Optional[float] = None, avg_score: Optional[float] = None, renew_count: int = 0, tags: Optional[list] = None) -> schemas.NodeStatusOut:
    if status and status.last_seen:
        is_stale = (now - status.last_seen).total_seconds() > STALE_SECS
    else:
        is_stale = True

    needs_renew = (
        status is not None
        and not is_stale
        and (status.reward_yesterday or 0) == 0
        and (status.uptime_ratio or 0) == 0
    )

    return schemas.NodeStatusOut(
        node_id=node.node_id,
        aro_status=status.aro_status if status else None,
        proxy_ok=status.proxy_ok if status else None,
        reward_today=status.reward_today if status else None,
        reward_yesterday=status.reward_yesterday if status else None,
        total_score=total_score,
        avg_score=avg_score,
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
        first_seen=node.created_at,
        renew_count=renew_count,
        needs_renew=needs_renew,
        country_code=get_node_country(
            node.proxy_host,
            status.public_ip if status else None,
        ),
        tags=tags or [],
    )


def _compute_scores(db: Session, node_ids: list) -> dict:
    """Compute total and avg reward score for given node IDs from NodeHistory."""
    if not node_ids:
        return {}
    daily_max_sq = (
        db.query(
            models.NodeHistory.node_id.label('node_id'),
            func.date(models.NodeHistory.timestamp).label('day'),
            func.max(models.NodeHistory.reward_today).label('daily_max'),
        )
        .filter(models.NodeHistory.node_id.in_(node_ids))
        .group_by(models.NodeHistory.node_id, func.date(models.NodeHistory.timestamp))
        .subquery()
    )
    rows = (
        db.query(
            daily_max_sq.c.node_id,
            func.sum(daily_max_sq.c.daily_max).label('total'),
            func.count(daily_max_sq.c.day).label('days'),
        )
        .group_by(daily_max_sq.c.node_id)
        .all()
    )
    result = {}
    for row in rows:
        total = round(row.total, 2) if row.total is not None else None
        avg = round(row.total / row.days, 2) if row.total is not None and row.days else None
        result[row.node_id] = (total, avg)
    return result


@router.post("/auth/login", response_model=schemas.TokenResponse)
def login(body: schemas.LoginRequest, db: Session = Depends(get_db)):
    user = db.query(models.User).filter(models.User.username == body.username).first()
    if not user or not verify_password(body.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    return schemas.TokenResponse(access_token=create_token(body.username))


@router.get("/auth/me")
def me(current_user: models.User = Depends(get_current_user)):
    return {"username": current_user.username}


_STATUS_SORT = {'Online': 0, 'NoInternet': 1, 'Unbound': 2, 'proxy_expired': 3, 'Offline': 4}


def _sort_key(sort_by: str):
    """Return a key function for sorting NodeStatusOut objects."""
    if sort_by == 'node_id':
        return lambda n: (n.node_id or '').lower()
    if sort_by == 'account':
        return lambda n: (n.account or '').lower()
    if sort_by == 'status':
        return lambda n: _STATUS_SORT.get(n.aro_status, 4)
    if sort_by == 'last_seen':
        return lambda n: n.last_seen.isoformat() if n.last_seen else ''
    if sort_by == 'reward_yesterday':
        return lambda n: n.reward_yesterday or 0
    if sort_by == 'uptime_ratio':
        return lambda n: n.uptime_ratio or 0
    if sort_by == 'proxy_ok':
        return lambda n: 0 if n.proxy_ok is True else (1 if n.proxy_ok is False else 2)
    if sort_by == 'total_score':
        return lambda n: n.total_score or 0
    if sort_by == 'avg_score':
        return lambda n: n.avg_score or 0
    if sort_by == 'script_version':
        def _semver(n):
            parts = (n.script_version or '').split('.')
            return [int(x) if x.isdigit() else 0 for x in parts] or [0]
        return _semver
    if sort_by == 'renew_count':
        return lambda n: n.renew_count or 0
    if sort_by == 'public_ip':
        def _ip_key(n):
            ip = n.public_ip
            if not ip:
                return (999, 0, 0, 0)
            try:
                return tuple(int(p) for p in ip.split('.'))
            except Exception:
                return (998, 0, 0, 0)
        return _ip_key
    return None


@router.get("/dashboard/nodes", response_model=schemas.NodeListResponse)
def list_nodes(
    status_filter: Optional[str] = Query(None),
    search: Optional[str] = Query(None),
    no_points_yesterday: bool = Query(False),
    no_points_avg: bool = Query(False),
    exclude_new_nodes: bool = Query(False),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=500),
    sort_by: Optional[str] = Query(None),
    sort_dir: str = Query("asc"),
    tag_ids: Optional[str] = Query(None),
    tag_mode: Optional[str] = Query("or"),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    now = datetime.utcnow()
    nodes = db.query(models.Node).all()
    statuses = {s.node_id: s for s in db.query(models.NodeStatus).all()}

    # Renew counts per node (single aggregate query)
    renew_counts: dict = {}
    for row in db.query(models.NodeRenewLog.node_id, func.count(models.NodeRenewLog.id)).group_by(models.NodeRenewLog.node_id).all():
        renew_counts[row[0]] = row[1]

    # Fetch all node-tag mappings in one query
    node_tag_rows = (
        db.query(models.NodeTag, models.Tag)
        .join(models.Tag, models.NodeTag.tag_id == models.Tag.id)
        .all()
    )
    tags_by_node: dict = {}
    for nt, tag in node_tag_rows:
        tags_by_node.setdefault(nt.node_id, []).append(
            schemas.TagRef(id=tag.id, name=tag.name, color=tag.color)
        )

    all_out = [_node_out(n, statuses.get(n.node_id), now, None, None, renew_counts.get(n.node_id, 0), tags_by_node.get(n.node_id, [])) for n in nodes]

    online = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Online")
    offline = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Offline")
    no_internet = sum(1 for n in all_out if not n.is_stale and n.aro_status == "NoInternet")
    unbound = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Unbound")
    proxy_expired = sum(1 for n in all_out if not n.is_stale and n.aro_status == "proxy_expired")
    stale = sum(1 for n in all_out if n.is_stale)
    no_exit_ip_count = sum(1 for n in all_out if not n.public_ip or n.public_ip.upper() == 'N/A')
    needs_renew_count = sum(1 for n in all_out if n.needs_renew)

    # --- Filtering (applied to ALL nodes) ---
    filtered = all_out
    if search:
        q = search.lower()
        filtered = [n for n in filtered if q in (n.node_id or "").lower() or q in (n.account or "").lower() or q in (n.serial or "").lower()]
    if status_filter == "stale":
        filtered = [n for n in filtered if n.is_stale]
    elif status_filter == "no_exit_ip":
        filtered = [n for n in filtered if not n.public_ip or n.public_ip.upper() == 'N/A']
    elif status_filter:
        filtered = [n for n in filtered if not n.is_stale and n.aro_status == status_filter]
    if exclude_new_nodes:
        filtered = [
            n for n in filtered
            if n.first_seen is None or (now - n.first_seen).total_seconds() >= 86400
        ]
    if no_points_yesterday:
        filtered = [
            n for n in filtered
            if n.reward_yesterday is not None and n.reward_yesterday == 0
        ]

    # Filter by tags (AND/OR)
    if tag_ids:
        filter_ids = [int(i) for i in tag_ids.split(',') if i.strip().isdigit()]
        if filter_ids:
            node_tag_ids = lambda n: {t.id for t in n.tags}  # noqa: E731
            if tag_mode == "and":
                filtered = [n for n in filtered if all(fid in node_tag_ids(n) for fid in filter_ids)]
            else:
                filtered = [n for n in filtered if any(fid in node_tag_ids(n) for fid in filter_ids)]

    # --- Score computation (when needed for filtering or sorting) ---
    scores_computed = False
    needs_scores = no_points_avg or sort_by in ('total_score', 'avg_score')
    if needs_scores:
        scores = _compute_scores(db, [n.node_id for n in filtered])
        for n in filtered:
            pair = scores.get(n.node_id, (None, None))
            n.total_score = pair[0]
            n.avg_score = pair[1]
        scores_computed = True
        if no_points_avg:
            filtered = [n for n in filtered if n.avg_score is not None and n.avg_score == 0]

    # --- Sorting (applied to ALL filtered nodes before pagination) ---
    if sort_by:
        key_fn = _sort_key(sort_by)
        if key_fn:
            filtered.sort(key=key_fn, reverse=(sort_dir == 'desc'))

    # --- Pagination ---
    total_filtered = len(filtered)
    total_pages = math.ceil(total_filtered / page_size) if total_filtered > 0 else 1
    start = (page - 1) * page_size
    paged = filtered[start:start + page_size]

    # Compute scores for current page if not already done
    if not scores_computed:
        scores = _compute_scores(db, [n.node_id for n in paged])
        for n in paged:
            pair = scores.get(n.node_id, (None, None))
            n.total_score = pair[0]
            n.avg_score = pair[1]

    return schemas.NodeListResponse(
        nodes=paged,
        total=len(nodes),
        total_filtered=total_filtered,
        page=page,
        page_size=page_size,
        total_pages=total_pages,
        online=online,
        offline=offline,
        no_internet=no_internet,
        unbound=unbound,
        proxy_expired=proxy_expired,
        stale=stale,
        no_exit_ip_count=no_exit_ip_count,
        needs_renew_count=needs_renew_count,
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

    daily_maxes: dict = {}
    for h in history:
        if h.reward_today is not None:
            day = h.timestamp.date()
            daily_maxes[day] = max(daily_maxes.get(day, 0.0), h.reward_today)
    total_score = round(sum(daily_maxes.values()), 2) if daily_maxes else None
    avg_score = round(sum(daily_maxes.values()) / len(daily_maxes), 2) if daily_maxes else None

    node_tags = (
        db.query(models.Tag)
        .join(models.NodeTag, models.NodeTag.tag_id == models.Tag.id)
        .filter(models.NodeTag.node_id == node_id)
        .order_by(models.Tag.name)
        .all()
    )
    tags = [schemas.TagRef(id=t.id, name=t.name, color=t.color) for t in node_tags]

    restart_events = (
        db.query(models.NodeRestartLog)
        .filter(models.NodeRestartLog.node_id == node_id, models.NodeRestartLog.timestamp >= cutoff)
        .order_by(models.NodeRestartLog.timestamp.desc())
        .limit(100)
        .all()
    )

    app_settings = db.query(models.AppSettings).filter(models.AppSettings.id == 1).first()
    global_stale = (app_settings.log_stale_restart_minutes or 5) if app_settings else 5

    return schemas.NodeDetailResponse(
        node=_node_out(node, status, now, total_score, avg_score, tags=tags),
        history=[
            schemas.HistoryPoint(
                timestamp=h.timestamp,
                aro_status=h.aro_status,
                reward_today=h.reward_today,
                uptime_ratio=h.uptime_ratio,
            )
            for h in history
        ],
        restart_events=[
            schemas.RestartEventOut(
                id=r.id,
                node_id=r.node_id,
                timestamp=r.timestamp,
                success=r.success,
                duration_secs=r.duration_secs,
            )
            for r in restart_events
        ],
        node_log_stale_restart_minutes=node.log_stale_restart_minutes,
        global_log_stale_restart_minutes=global_stale,
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


@router.post("/dashboard/nodes/{node_id}/set-proxy")
def set_node_proxy(
    node_id: str,
    body: schemas.SetProxyRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Queue a set_proxy command for a node. Validates format and proxy uniqueness (host:port:user)."""
    node = db.query(models.Node).filter(models.Node.node_id == node_id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")

    parts = body.proxy.strip().split(":")
    if len(parts) != 4:
        raise HTTPException(status_code=400, detail="Định dạng proxy phải là host:port:user:pass")

    proxy_host, proxy_port_str, proxy_user, _ = parts
    try:
        proxy_port = int(proxy_port_str)
    except ValueError:
        raise HTTPException(status_code=400, detail="Port phải là số nguyên")

    # Uniqueness check: same host:port:user → reject (regardless of pass)
    conflict = (
        db.query(models.Node)
        .filter(
            models.Node.node_id != node_id,
            models.Node.proxy_host == proxy_host,
            models.Node.proxy_port == proxy_port,
            models.Node.proxy_user == proxy_user,
        )
        .first()
    )
    if conflict:
        raise HTTPException(
            status_code=409,
            detail=f"Proxy {proxy_host}:{proxy_port}:{proxy_user} đang được dùng bởi node {conflict.node_id}",
        )

    import base64
    payload_b64 = base64.b64encode(body.proxy.strip().encode()).decode()

    # Cancel existing pending set_proxy commands for this node
    db.query(models.Command).filter(
        models.Command.node_id == node_id,
        models.Command.action == "set_proxy",
        models.Command.status == "pending",
    ).delete()

    cmd = models.Command(
        node_id=node_id,
        action="set_proxy",
        payload=payload_b64,
        created_by=current_user.username,
    )
    db.add(cmd)
    db.commit()
    db.refresh(cmd)
    return {"ok": True, "command_id": cmd.id}


@router.put("/dashboard/nodes/{node_id}/settings")
def update_node_settings(
    node_id: str,
    body: schemas.NodeSettingsIn,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    node = db.query(models.Node).filter(models.Node.node_id == node_id).first()
    if not node:
        raise HTTPException(status_code=404)
    if body.log_stale_restart_minutes is None:
        node.log_stale_restart_minutes = None
    else:
        node.log_stale_restart_minutes = max(1, min(body.log_stale_restart_minutes, 60))
    db.commit()
    return {"ok": True}


@router.post("/dashboard/nodes/{node_id}/rename", response_model=schemas.RenameNodeResponse)
def rename_node(
    node_id: str,
    body: schemas.RenameNodeRequest,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    new_id = body.new_node_id.strip()
    if not new_id:
        raise HTTPException(status_code=422, detail="Hostname mới không được để trống.")
    if new_id == node_id:
        raise HTTPException(status_code=422, detail="Hostname mới phải khác hostname hiện tại.")

    node = db.query(models.Node).filter(models.Node.node_id == node_id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node không tồn tại.")

    conflict = db.query(models.Node).filter(models.Node.node_id == new_id).first()
    if conflict:
        raise HTTPException(status_code=409, detail=f"Hostname '{new_id}' đã tồn tại.")

    # ON UPDATE CASCADE on all FK constraints handles child tables automatically
    try:
        db.execute(
            text("UPDATE nodes SET node_id = :new WHERE node_id = :old"),
            {"new": new_id, "old": node_id},
        )
        db.commit()
    except Exception as exc:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Lỗi khi đổi hostname: {exc}")

    return schemas.RenameNodeResponse(ok=True, old_node_id=node_id, new_node_id=new_id)


@router.delete("/dashboard/nodes/{node_id}")
def delete_node(
    node_id: str,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    node = db.query(models.Node).filter(models.Node.node_id == node_id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node không tồn tại.")
    db.delete(node)
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
                no_internet=0, unbound=0, proxy_expired=0, vps_offline=0,
                total_points=0.0, uptime_sum=0.0, uptime_count=0,
            )
        b = buckets[key]
        b["total"] += 1

        status = statuses.get(node.node_id)
        if status and status.last_seen and (now - status.last_seen).total_seconds() <= STALE_SECS:
            aro = status.aro_status
            if aro == "Online":             b["online"] += 1
            elif aro == "Offline":          b["offline"] += 1
            elif aro == "NoInternet":       b["no_internet"] += 1
            elif aro == "Unbound":          b["unbound"] += 1
            elif aro == "proxy_expired":    b["proxy_expired"] += 1
            else:                           b["vps_offline"] += 1

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
            proxy_expired=b["proxy_expired"], vps_offline=b["vps_offline"],
            total_points=round(b["total_points"], 2),
            avg_uptime=round(avg, 1) if avg is not None else None,
        ))

    result.sort(key=lambda x: x.total_points, reverse=True)
    return result

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
MASTER_ACCOUNT = "nauthnael@gmail.com"


def _load_hier(db: Session) -> dict:
    """Return {account: parent_account} map from DB."""
    return {h.account: h.parent_account for h in db.query(models.AccountHierarchy).all()}


def _compute_tier(account: Optional[str], hier: dict) -> Optional[int]:
    if not account:
        return None
    parent = hier.get(account)
    if parent == MASTER_ACCOUNT:
        return 1
    if parent and hier.get(parent) == MASTER_ACCOUNT:
        return 2
    return None


def _get_t1_group(account: Optional[str], hier: dict) -> Optional[str]:
    """Return the parent (referrer) of this account in hierarchy, or None."""
    if not account:
        return None
    return hier.get(account) or None


def _node_out(node: models.Node, status: Optional[models.NodeStatus], now: datetime, total_score: Optional[float] = None, avg_score: Optional[float] = None, renew_count: int = 0, tags: Optional[list] = None, t1_group: Optional[str] = None) -> schemas.NodeStatusOut:
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
        ip_leak=status.ip_leak if status else None,
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
        proxy_user=node.proxy_user,
        notes=node.notes,
        first_seen=node.created_at,
        renew_count=renew_count,
        needs_renew=needs_renew,
        country_code=get_node_country(
            node.proxy_host,
            status.public_ip if status else None,
        ),
        tags=tags or [],
        t1_group=t1_group,
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
    no_points_2days: bool = Query(False),
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

    hier = _load_hier(db)
    all_out = [_node_out(n, statuses.get(n.node_id), now, None, None, renew_counts.get(n.node_id, 0), tags_by_node.get(n.node_id, []), _get_t1_group(n.account, hier)) for n in nodes]

    # Previous account: 2nd most recent record per node in NodeAccountHistory
    _ah_subq = (
        db.query(
            models.NodeAccountHistory.node_id,
            models.NodeAccountHistory.account,
            func.row_number().over(
                partition_by=models.NodeAccountHistory.node_id,
                order_by=models.NodeAccountHistory.first_seen.desc(),
            ).label('rn'),
        ).subquery()
    )
    _prev_account_map = {
        r.node_id: r.account
        for r in db.query(_ah_subq.c.node_id, _ah_subq.c.account)
        .filter(_ah_subq.c.rn == 2)
        .all()
    }
    for n in all_out:
        n.prev_account = _prev_account_map.get(n.node_id)

    online = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Online")
    offline = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Offline")
    no_internet = sum(1 for n in all_out if not n.is_stale and n.aro_status == "NoInternet")
    unbound = sum(1 for n in all_out if not n.is_stale and n.aro_status == "Unbound")
    proxy_expired = sum(1 for n in all_out if not n.is_stale and n.aro_status == "proxy_expired")
    stale = sum(1 for n in all_out if n.is_stale)
    no_exit_ip_count = sum(1 for n in all_out if not n.public_ip or n.public_ip.upper() == 'N/A')
    needs_renew_count = sum(1 for n in all_out if n.needs_renew)
    ip_leak_count = sum(1 for n in all_out if n.ip_leak is True)

    # Compute yesterday's reward from NodeHistory.
    # After the storage fix, records are stored under yesterday's date with the correct reward value.
    yesterday_utc = now.date() - timedelta(days=1)
    yesterday_start = datetime(yesterday_utc.year, yesterday_utc.month, yesterday_utc.day)
    yesterday_end = yesterday_start + timedelta(days=1)
    _hist_yesterday = (
        db.query(models.NodeHistory.node_id, func.max(models.NodeHistory.reward_today).label('max_rwd'))
        .filter(
            models.NodeHistory.timestamp >= yesterday_start,
            models.NodeHistory.timestamp < yesterday_end,
            models.NodeHistory.reward_today.isnot(None),
        )
        .group_by(models.NodeHistory.node_id)
        .all()
    )
    # NodeHistory D-1 is the source of truth: not affected by post-restart zeroing.
    # Falls back to NodeStatus.reward_yesterday (already in all_out) if no record exists.
    _hist_yesterday_map = {r.node_id: r.max_rwd for r in _hist_yesterday if r.max_rwd and r.max_rwd > 0}
    _nodes_with_yesterday_points = set(_hist_yesterday_map.keys())

    for n in all_out:
        if n.node_id in _hist_yesterday_map:
            n.reward_yesterday = _hist_yesterday_map[n.node_id]

    def _no_points_yesterday(n: schemas.NodeStatusOut) -> bool:
        if n.node_id in _nodes_with_yesterday_points:
            return False
        if n.reward_yesterday is not None and n.reward_yesterday > 0:
            return False
        return True

    no_points_yesterday_count = sum(1 for n in all_out if _no_points_yesterday(n))

    # Nodes with no points for both yesterday AND day before yesterday (2 consecutive days)
    day_before_yesterday_utc = now.date() - timedelta(days=2)
    dby_start = datetime(day_before_yesterday_utc.year, day_before_yesterday_utc.month, day_before_yesterday_utc.day)
    dby_end = dby_start + timedelta(days=1)
    _hist_dby = (
        db.query(models.NodeHistory.node_id, func.max(models.NodeHistory.reward_today).label('max_rwd'))
        .filter(
            models.NodeHistory.timestamp >= dby_start,
            models.NodeHistory.timestamp < dby_end,
            models.NodeHistory.reward_today.isnot(None),
        )
        .group_by(models.NodeHistory.node_id)
        .all()
    )
    _nodes_with_dby_points = {r.node_id for r in _hist_dby if r.max_rwd and r.max_rwd > 0}

    # Nodes that have ever earned positive points (to filter out nodes that never had points)
    _nodes_with_any_points = {
        r.node_id for r in db.query(models.NodeHistory.node_id)
        .filter(models.NodeHistory.reward_today > 0)
        .distinct()
        .all()
    }

    def _no_points_2days(n: schemas.NodeStatusOut) -> bool:
        return (
            n.node_id in _nodes_with_any_points
            and _no_points_yesterday(n)
            and n.node_id not in _nodes_with_dby_points
        )

    no_points_2days_count = sum(1 for n in all_out if _no_points_2days(n))

    # Count nodes: most recent renewal <= yesterday, no positive NodeHistory since renewal date
    _rl_rows = (
        db.query(models.NodeRenewLog.node_id, func.max(models.NodeRenewLog.renewed_at).label('max_renewed'))
        .group_by(models.NodeRenewLog.node_id)
        .all()
    )
    _renewed_map_c = {
        r.node_id: r.max_renewed.date()
        for r in _rl_rows
        if r.max_renewed and r.max_renewed.date() <= yesterday_utc
    }
    if _renewed_map_c:
        _earliest_c = min(_renewed_map_c.values())
        _hist_after_renew = (
            db.query(models.NodeHistory.node_id, func.date(models.NodeHistory.timestamp).label('day'))
            .filter(
                models.NodeHistory.node_id.in_(list(_renewed_map_c.keys())),
                func.date(models.NodeHistory.timestamp) >= _earliest_c,
                func.date(models.NodeHistory.timestamp) <= yesterday_utc,
                models.NodeHistory.reward_today > 0,
            )
            .distinct()
            .all()
        )
        _with_reward_c = {
            r.node_id for r in _hist_after_renew
            if r.day >= _renewed_map_c.get(r.node_id, yesterday_utc)
        }
        renew_0points_count = len(_renewed_map_c) - len(_with_reward_c)
    else:
        renew_0points_count = 0

    # Count nodes with avg daily score == 0 via a single aggregated query
    _avg_sq = (
        db.query(
            models.NodeHistory.node_id.label('node_id'),
            func.date(models.NodeHistory.timestamp).label('day'),
            func.max(models.NodeHistory.reward_today).label('daily_max'),
        )
        .group_by(models.NodeHistory.node_id, func.date(models.NodeHistory.timestamp))
        .subquery()
    )
    _avg_rows = (
        db.query(_avg_sq.c.node_id)
        .group_by(_avg_sq.c.node_id)
        .having(func.sum(_avg_sq.c.daily_max) == 0)
        .all()
    )
    _nodes_with_history = set(
        row[0] for row in db.query(models.NodeHistory.node_id).distinct().all()
    )
    _no_history_count = sum(1 for n in all_out if n.node_id not in _nodes_with_history)
    no_points_avg_count = len(_avg_rows) + _no_history_count

    # --- Filtering (applied to ALL nodes) ---
    filtered = all_out
    if search:
        q = search.lower()
        filtered = [n for n in filtered if q in (n.node_id or "").lower() or q in (n.account or "").lower() or q in (n.serial or "").lower()]
    if status_filter == "stale":
        filtered = [n for n in filtered if n.is_stale]
    elif status_filter == "no_exit_ip":
        filtered = [n for n in filtered if not n.public_ip or n.public_ip.upper() == 'N/A']
    elif status_filter == "ip_leak":
        filtered = [n for n in filtered if n.ip_leak is True]
    elif status_filter:
        filtered = [n for n in filtered if not n.is_stale and n.aro_status == status_filter]
    if exclude_new_nodes:
        filtered = [
            n for n in filtered
            if n.first_seen is None or (now - n.first_seen).total_seconds() >= 86400
        ]
    if no_points_yesterday:
        filtered = [n for n in filtered if _no_points_yesterday(n)]
    if no_points_2days:
        filtered = [n for n in filtered if _no_points_2days(n)]

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
            filtered = [n for n in filtered if n.avg_score is None or n.avg_score == 0]

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
        no_points_yesterday_count=no_points_yesterday_count,
        no_points_avg_count=no_points_avg_count,
        no_points_2days_count=no_points_2days_count,
        renew_0points_count=renew_0points_count,
        ip_leak_count=ip_leak_count,
    )


@router.get("/dashboard/stats-trend", response_model=schemas.StatsTrendResponse)
def get_stats_trend(
    days: int = Query(30, ge=7, le=30),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    from collections import defaultdict
    now = datetime.utcnow()
    today = now.date()

    # Luôn load full 30 ngày để tránh sai số khi days=7 hoặc 14
    full_cutoff = datetime(*(today - timedelta(days=32)).timetuple()[:3])
    history_rows = (
        db.query(models.NodeHistory.node_id, models.NodeHistory.timestamp, models.NodeHistory.reward_today)
        .filter(models.NodeHistory.timestamp >= full_cutoff)
        .all()
    )

    # rewards[node_id][date] = max_reward_today
    rewards: dict = defaultdict(dict)
    for row in history_rows:
        d = row.timestamp.date()
        val = row.reward_today or 0.0
        prev = rewards[row.node_id].get(d)
        rewards[row.node_id][d] = max(prev, val) if prev is not None else val

    nodes_in_history: set = set(rewards.keys())

    # Tất cả node_id từ NodeStatus — để biết nodes không có history
    all_node_ids: set = {
        row[0] for row in db.query(models.NodeStatus.node_id).all()
    }
    # Nodes không bao giờ lưu vào NodeHistory (reward_yesterday luôn == 0 hoặc None)
    no_history_count: int = len(all_node_ids - nodes_in_history)

    # Nodes đã từng có điểm (full 30d)
    ever_had_points: set = {nid for nid, dm in rewards.items() if any(v > 0 for v in dm.values())}

    # TB 0 điểm là constant: nodes trong history mà toàn bộ rewards == 0 + nodes không có history
    # NodeHistory chỉ lưu khi reward_yesterday > 0, nên nodes_in_history hầu hết có reward > 0
    nodes_all_zero_in_history = sum(
        1 for nid in nodes_in_history
        if all(v == 0.0 for v in rewards[nid].values())
    )
    static_no_points_avg = nodes_all_zero_in_history + no_history_count

    # Load NodeRenewLog
    renew_rows = (
        db.query(models.NodeRenewLog.node_id, func.max(models.NodeRenewLog.renewed_at).label("last_renewed"))
        .group_by(models.NodeRenewLog.node_id)
        .all()
    )
    renewed_map: dict = {r.node_id: r.last_renewed.date() for r in renew_rows if r.last_renewed}

    result = []
    for offset in range(days, 0, -1):
        D = today - timedelta(days=offset)
        D1 = D - timedelta(days=1)
        D2 = D - timedelta(days=2)

        # Không điểm hôm qua: nodes trong history không có reward D-1 + nodes không có history
        no_points_yesterday = (
            sum(1 for nid in nodes_in_history if rewards[nid].get(D1, 0.0) == 0.0)
            + no_history_count
        )

        # TB 0 điểm: constant — không đổi theo ngày D
        no_points_avg = static_no_points_avg

        # Mất điểm 2 ngày: đã từng có điểm (full 30d) nhưng 0 cả D-1 lẫn D-2
        no_points_2days = sum(
            1 for nid in ever_had_points
            if rewards[nid].get(D1, 0.0) == 0.0 and rewards[nid].get(D2, 0.0) == 0.0
        )

        # Renew 0 điểm: renewed trước ngày D, không có reward nào từ renew_date đến D
        renew_0points = 0
        for nid, renew_date in renewed_map.items():
            if renew_date > D:
                continue
            has_points_since_renew = any(
                v > 0 for d, v in rewards.get(nid, {}).items()
                if renew_date <= d <= D
            )
            if not has_points_since_renew:
                renew_0points += 1

        result.append(schemas.StatsTrendPoint(
            date=D.isoformat(),
            no_points_yesterday=no_points_yesterday,
            no_points_avg=no_points_avg,
            no_points_2days=no_points_2days,
            renew_0points=renew_0points,
        ))

    return schemas.StatsTrendResponse(data=result, days=days)


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

    hier = _load_hier(db)
    node_out = _node_out(node, status, now, total_score, avg_score, tags=tags, t1_group=_get_t1_group(node.account, hier))
    hist_yesterday = daily_maxes.get(now.date() - timedelta(days=1))
    if hist_yesterday:
        node_out.reward_yesterday = hist_yesterday

    return schemas.NodeDetailResponse(
        node=node_out,
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


@router.get("/dashboard/nodes/{node_id}/diagnostics", response_model=List[schemas.DiagnosticLogOut])
def get_diagnostics(
    node_id: str,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    return (
        db.query(models.NodeDiagnosticLog)
        .filter(models.NodeDiagnosticLog.node_id == node_id)
        .order_by(models.NodeDiagnosticLog.collected_at.desc())
        .limit(10)
        .all()
    )


@router.get("/dashboard/renew-stats", response_model=schemas.RenewStatsResponse)
def get_renew_stats(
    date: Optional[str] = Query(None),
    sort_by: str = Query('days_0pts'),
    sort_dir: str = Query('desc'),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=500),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    now = datetime.utcnow()
    yesterday = now.date() - timedelta(days=1)

    _rl_rows = (
        db.query(models.NodeRenewLog.node_id, func.max(models.NodeRenewLog.renewed_at).label('max_renewed'))
        .group_by(models.NodeRenewLog.node_id)
        .all()
    )
    _renewed_map = {
        r.node_id: r.max_renewed
        for r in _rl_rows
        if r.max_renewed and r.max_renewed.date() <= yesterday
    }

    if date:
        try:
            filter_date = datetime.strptime(date, '%Y-%m-%d').date()
            _renewed_map = {k: v for k, v in _renewed_map.items() if v.date() == filter_date}
        except ValueError:
            pass

    if not _renewed_map:
        return schemas.RenewStatsResponse(nodes=[], total=0, page=page, page_size=page_size, total_pages=1)

    node_ids = list(_renewed_map.keys())
    earliest = min(v.date() for v in _renewed_map.values())

    _hist_rows = (
        db.query(models.NodeHistory.node_id, func.date(models.NodeHistory.timestamp).label('day'))
        .filter(
            models.NodeHistory.node_id.in_(node_ids),
            func.date(models.NodeHistory.timestamp) >= earliest,
            func.date(models.NodeHistory.timestamp) <= yesterday,
            models.NodeHistory.reward_today > 0,
        )
        .distinct()
        .all()
    )
    _with_reward = {
        r.node_id for r in _hist_rows
        if r.day >= _renewed_map[r.node_id].date()
    }

    qualifying_ids = [nid for nid in node_ids if nid not in _with_reward]
    if not qualifying_ids:
        return schemas.RenewStatsResponse(nodes=[], total=0, page=page, page_size=page_size, total_pages=1)

    nodes_map = {n.node_id: n for n in db.query(models.Node).filter(models.Node.node_id.in_(qualifying_ids)).all()}
    statuses_map = {s.node_id: s for s in db.query(models.NodeStatus).filter(models.NodeStatus.node_id.in_(qualifying_ids)).all()}
    renew_counts_map = {
        r.node_id: r.cnt
        for r in db.query(models.NodeRenewLog.node_id, func.count(models.NodeRenewLog.id).label('cnt'))
        .filter(models.NodeRenewLog.node_id.in_(qualifying_ids))
        .group_by(models.NodeRenewLog.node_id)
        .all()
    }

    result = []
    for nid in qualifying_ids:
        node = nodes_map.get(nid)
        status = statuses_map.get(nid)
        renewed_at = _renewed_map[nid]
        days_0pts = max(0, (yesterday - renewed_at.date()).days + 1)
        is_stale = True
        if status and status.last_seen:
            is_stale = (now - status.last_seen).total_seconds() > STALE_SECS
        result.append(schemas.RenewStatsNodeOut(
            node_id=nid,
            account=node.account if node else None,
            serial=node.serial if node else None,
            renewed_at=renewed_at,
            days_0pts=days_0pts,
            renew_count=renew_counts_map.get(nid, 0),
            aro_status=status.aro_status if status else None,
            last_seen=status.last_seen if status else None,
            is_stale=is_stale,
            proxy_ok=status.proxy_ok if status else None,
        ))

    if sort_by == 'days_0pts':
        result.sort(key=lambda x: x.days_0pts, reverse=(sort_dir == 'desc'))
    elif sort_by == 'renewed_at':
        result.sort(key=lambda x: x.renewed_at, reverse=(sort_dir == 'desc'))
    elif sort_by == 'node_id':
        result.sort(key=lambda x: x.node_id.lower(), reverse=(sort_dir == 'desc'))
    elif sort_by == 'account':
        result.sort(key=lambda x: (x.account or '').lower(), reverse=(sort_dir == 'desc'))
    elif sort_by == 'renew_count':
        result.sort(key=lambda x: x.renew_count, reverse=(sort_dir == 'desc'))
    elif sort_by == 'aro_status':
        result.sort(key=lambda x: (x.aro_status or '').lower(), reverse=(sort_dir == 'desc'))

    total = len(result)
    total_pages = math.ceil(total / page_size) if total > 0 else 1
    start = (page - 1) * page_size

    return schemas.RenewStatsResponse(
        nodes=result[start:start + page_size],
        total=total,
        page=page,
        page_size=page_size,
        total_pages=total_pages,
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


@router.post("/dashboard/nodes/bulk-set-proxy")
def bulk_set_node_proxy(
    body: schemas.BulkSetProxyRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Bulk queue set_proxy commands. Validates format, internal batch duplicates, and DB uniqueness."""
    import base64

    if not body.assignments:
        raise HTTPException(status_code=400, detail="Danh sách assignments trống")

    # Step 1: Validate all proxy formats
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

    # Step 3: Check DB uniqueness (exclude nodes in this batch)
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

    # Step 4: Cancel existing pending set_proxy and create new commands
    created = 0
    for p in parsed:
        db.query(models.Command).filter(
            models.Command.node_id == p["node_id"],
            models.Command.action == "set_proxy",
            models.Command.status == "pending",
        ).delete()

        payload_b64 = base64.b64encode(p["proxy"].encode()).decode()
        cmd = models.Command(
            node_id=p["node_id"],
            action="set_proxy",
            payload=payload_b64,
            created_by=current_user.username,
        )
        db.add(cmd)
        created += 1

    db.commit()
    return {"ok": True, "created": created}


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
    hier = _load_hier(db)

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

    # Build flat result with tier / parent info
    result = []
    for b in buckets.values():
        avg = b["uptime_sum"] / b["uptime_count"] if b["uptime_count"] > 0 else None
        acct = b["account"]
        tier = _compute_tier(acct, hier)
        parent = hier.get(acct) if tier else None
        result.append(schemas.AccountStatsOut(
            account=acct, total=b["total"],
            online=b["online"], offline=b["offline"],
            no_internet=b["no_internet"], unbound=b["unbound"],
            proxy_expired=b["proxy_expired"], vps_offline=b["vps_offline"],
            total_points=round(b["total_points"], 2),
            avg_uptime=round(avg, 1) if avg is not None else None,
            tier=tier,
            parent_account=parent,
        ))

    # Compute ref points and counts for master account row
    pts_by_account = {r.account: r.total_points for r in result}
    t1_accounts = {a for a, p in hier.items() if p == MASTER_ACCOUNT}
    t2_accounts = {a for a, p in hier.items() if p in t1_accounts}
    ref_t1 = round(sum(pts_by_account.get(a, 0) for a in t1_accounts) * 0.15, 2)
    ref_t2 = round(sum(pts_by_account.get(a, 0) for a in t2_accounts) * 0.02, 2)

    for r in result:
        if r.account == MASTER_ACCOUNT:
            r.ref_points_yesterday = ref_t1 + ref_t2
            r.t1_count = len(t1_accounts)
            r.t2_count = len(t2_accounts)

    result.sort(key=lambda x: x.total_points, reverse=True)
    return result


@router.get("/accounts/hierarchy", response_model=List[schemas.AccountHierarchyItem])
def get_hierarchy(
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    hier = _load_hier(db)
    # Collect all known accounts from nodes + hierarchy table
    node_accounts = {n.account for n in db.query(models.Node.account).distinct().all() if n.account}
    hier_accounts = set(hier.keys())
    all_accounts = node_accounts | hier_accounts | {MASTER_ACCOUNT}

    items = []
    for acct in sorted(all_accounts):
        parent = hier.get(acct)
        tier = _compute_tier(acct, hier)
        if acct == MASTER_ACCOUNT:
            tier = 0
        items.append(schemas.AccountHierarchyItem(account=acct, parent_account=parent, tier=tier))
    return items


@router.put("/accounts/hierarchy", response_model=List[schemas.AccountHierarchyItem])
def set_hierarchy(
    body: schemas.AccountHierarchySetIn,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    for item in body.assignments:
        existing = db.query(models.AccountHierarchy).filter(models.AccountHierarchy.account == item.account).first()
        if existing:
            existing.parent_account = item.parent_account
            existing.updated_at = datetime.utcnow()
        else:
            db.add(models.AccountHierarchy(account=item.account, parent_account=item.parent_account))
    db.commit()

    hier = _load_hier(db)
    node_accounts = {n.account for n in db.query(models.Node.account).distinct().all() if n.account}
    hier_accounts = set(hier.keys())
    all_accounts = node_accounts | hier_accounts | {MASTER_ACCOUNT}

    items = []
    for acct in sorted(all_accounts):
        parent = hier.get(acct)
        tier = _compute_tier(acct, hier)
        if acct == MASTER_ACCOUNT:
            tier = 0
        items.append(schemas.AccountHierarchyItem(account=acct, parent_account=parent, tier=tier))
    return items


@router.delete("/accounts/hierarchy/{account}")
def delete_hierarchy(
    account: str,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    db.query(models.AccountHierarchy).filter(models.AccountHierarchy.account == account).delete()
    db.commit()
    return {"ok": True}

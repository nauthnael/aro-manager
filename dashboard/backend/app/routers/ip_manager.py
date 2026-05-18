from collections import Counter
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app import models
from app.config import settings
from app.database import get_db
from app.auth import get_current_user
from app.schemas import IpManagerResponse, NodeIpInfo

router = APIRouter(prefix="/ip-manager", tags=["ip-manager"])

# IPs that nodes report when they cannot determine their real exit IP
_SENTINEL_IPS = {"n/a", "na", "unknown", "0.0.0.0", "none", ""}


def _build_node_ip_info(node: models.Node, status: Optional[models.NodeStatus], duplicate_ips: set, now: datetime) -> NodeIpInfo:
    is_stale = False
    aro_status = None
    last_seen = None
    public_ip = None

    if status:
        last_seen = status.last_seen
        aro_status = status.aro_status
        public_ip = status.public_ip
        if status.last_seen:
            is_stale = (now - status.last_seen).total_seconds() > settings.stale_threshold_secs

    is_ip_duplicate = bool(public_ip and public_ip in duplicate_ips)

    return NodeIpInfo(
        node_id=node.node_id,
        account=node.account,
        public_ip=public_ip,
        proxy_host=node.proxy_host,
        proxy_port=node.proxy_port,
        proxy_user=node.proxy_user,
        aro_status=aro_status,
        last_seen=last_seen,
        is_stale=is_stale,
        is_ip_duplicate=is_ip_duplicate,
    )


@router.get("/nodes", response_model=IpManagerResponse)
def get_ip_manager_nodes(
    only_duplicates: bool = Query(False),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    now = datetime.utcnow()

    nodes = db.query(models.Node).all()
    statuses = {s.node_id: s for s in db.query(models.NodeStatus).all()}

    # Find duplicate public IPs (ignore empty/None and sentinel placeholder values)
    ip_counts = Counter(
        statuses[n.node_id].public_ip
        for n in nodes
        if n.node_id in statuses
        and statuses[n.node_id].public_ip
        and statuses[n.node_id].public_ip.strip().lower() not in _SENTINEL_IPS
    )
    duplicate_ips = {ip for ip, cnt in ip_counts.items() if cnt > 1}

    result = []
    for node in nodes:
        status = statuses.get(node.node_id)
        info = _build_node_ip_info(node, status, duplicate_ips, now)
        if only_duplicates and not info.is_ip_duplicate:
            continue
        result.append(info)

    # Sort: duplicates first, then by node_id
    result.sort(key=lambda x: (not x.is_ip_duplicate, x.node_id))

    affected_node_count = sum(1 for n in result if n.is_ip_duplicate)

    return IpManagerResponse(
        nodes=result,
        total=len(result),
        duplicate_ip_count=len(duplicate_ips),
        affected_node_count=affected_node_count,
    )

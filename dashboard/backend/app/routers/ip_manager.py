from collections import defaultdict
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


def _proxy_key(node: models.Node) -> str:
    """Canonical proxy identity string for comparison."""
    return f"{node.proxy_host or ''}:{node.proxy_port or ''}:{node.proxy_user or ''}"


def _is_valid_ip(ip: Optional[str]) -> bool:
    return bool(ip and ip.strip().lower() not in _SENTINEL_IPS)


def _build_ip_type_map(nodes: list, statuses: dict) -> dict[str, str]:
    """
    For each IP that appears on more than one node, determine:
      "proxy_shared"     — all nodes share the same proxy (same host:port:user)
      "routing_conflict" — nodes use different proxies (real IP collision)
    """
    ip_to_nodes: dict[str, list] = defaultdict(list)
    for node in nodes:
        s = statuses.get(node.node_id)
        if s and _is_valid_ip(s.public_ip):
            ip_to_nodes[s.public_ip.strip()].append(node)

    ip_type: dict[str, str] = {}
    for ip, group in ip_to_nodes.items():
        if len(group) <= 1:
            continue
        proxy_keys = {_proxy_key(n) for n in group}
        ip_type[ip] = "proxy_shared" if len(proxy_keys) == 1 else "routing_conflict"
    return ip_type


def _build_node_ip_info(
    node: models.Node,
    status: Optional[models.NodeStatus],
    ip_type: dict[str, str],
    now: datetime,
) -> NodeIpInfo:
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

    valid_ip = _is_valid_ip(public_ip)
    dup_type = ip_type.get(public_ip.strip(), None) if (public_ip and valid_ip) else None

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
        is_ip_duplicate=dup_type is not None,
        duplicate_type=dup_type,
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

    ip_type = _build_ip_type_map(nodes, statuses)

    result = []
    for node in nodes:
        status = statuses.get(node.node_id)
        info = _build_node_ip_info(node, status, ip_type, now)
        if only_duplicates and not info.is_ip_duplicate:
            continue
        result.append(info)

    # Sort: routing_conflict groups first, then proxy_shared groups, then normal nodes.
    # Within each group, sort by public_ip then node_id so same-IP rows are adjacent.
    _TYPE_ORDER = {"routing_conflict": 0, "proxy_shared": 1}
    result.sort(key=lambda x: (
        _TYPE_ORDER.get(x.duplicate_type, 2),
        x.public_ip or "",
        x.node_id,
    ))

    affected_node_count = sum(1 for n in result if n.is_ip_duplicate)
    proxy_shared_count = sum(1 for ip, t in ip_type.items() if t == "proxy_shared")
    routing_conflict_count = sum(1 for ip, t in ip_type.items() if t == "routing_conflict")

    return IpManagerResponse(
        nodes=result,
        total=len(result),
        duplicate_ip_count=len(ip_type),
        affected_node_count=affected_node_count,
        proxy_shared_count=proxy_shared_count,
        routing_conflict_count=routing_conflict_count,
    )

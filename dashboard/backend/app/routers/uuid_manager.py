from collections import defaultdict
from datetime import datetime

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app import models
from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.schemas import NodeUuidInfo, UuidManagerResponse

router = APIRouter(prefix="/uuid-manager", tags=["uuid-manager"])

_SENTINEL_UUIDS = {"n/a", "na", "unknown", "", "none"}


def _is_valid_uuid(uuid: str | None) -> bool:
    return bool(uuid and uuid.strip().lower() not in _SENTINEL_UUIDS)


def _build_duplicate_set(nodes: list, statuses: dict) -> set[str]:
    uuid_counts: dict[str, int] = defaultdict(int)
    for node in nodes:
        s = statuses.get(node.node_id)
        if s and _is_valid_uuid(s.uuid):
            uuid_counts[s.uuid.strip()] += 1
    return {u for u, c in uuid_counts.items() if c > 1}


@router.get("/nodes", response_model=UuidManagerResponse)
def get_uuid_manager_nodes(
    only_duplicates: bool = Query(False),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    now = datetime.utcnow()

    nodes = db.query(models.Node).all()
    statuses = {s.node_id: s for s in db.query(models.NodeStatus).all()}

    duplicate_uuids = _build_duplicate_set(nodes, statuses)

    result = []
    for node in nodes:
        s = statuses.get(node.node_id)
        uuid = (s.uuid.strip() if s and s.uuid else None)
        is_dup = bool(uuid and uuid in duplicate_uuids)

        if only_duplicates and not is_dup:
            continue

        is_stale = False
        if s and s.last_seen:
            is_stale = (now - s.last_seen).total_seconds() > settings.stale_threshold_secs

        result.append(NodeUuidInfo(
            node_id=node.node_id,
            account=node.account,
            uuid=uuid,
            aro_status=s.aro_status if s else None,
            last_seen=s.last_seen if s else None,
            is_stale=is_stale,
            is_uuid_duplicate=is_dup,
        ))

    result.sort(key=lambda x: (
        0 if x.is_uuid_duplicate else 1,
        x.uuid or "",
        x.node_id,
    ))

    affected_node_count = sum(1 for n in result if n.is_uuid_duplicate)

    return UuidManagerResponse(
        nodes=result,
        total=len(result),
        duplicate_uuid_count=len(duplicate_uuids),
        affected_node_count=affected_node_count,
    )

from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel


# --- Auth ---

class LoginRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


# --- Node report (node → backend) ---

class NodeReportRequest(BaseModel):
    node_id: str
    api_key: str
    aro_status: str
    proxy_ok: bool
    reward_today: float = 0
    reward_yesterday: float = 0
    uptime_ratio: float = 0
    public_ip: str = ""
    proxy_host: str = ""
    proxy_port: int = 0
    serial: str = ""
    account: str = ""
    script_version: str = ""


class PendingCommand(BaseModel):
    id: int
    action: str


class NodeReportResponse(BaseModel):
    ok: bool
    commands: List[PendingCommand] = []
    periodic_restart_min: int = 54
    periodic_restart_max: int = 120


# --- Command complete (node → backend) ---

class CommandCompleteRequest(BaseModel):
    result: str = ""
    success: bool = True


# --- Tags ---

class TagRef(BaseModel):
    id: int
    name: str
    color: str


class TagOut(BaseModel):
    id: int
    name: str
    color: str
    node_count: int = 0


class CreateTagRequest(BaseModel):
    name: str
    color: Optional[str] = None


class UpdateTagRequest(BaseModel):
    name: Optional[str] = None
    color: Optional[str] = None


class SetNodeTagsRequest(BaseModel):
    tag_ids: List[int] = []


class BulkTagRequest(BaseModel):
    node_ids: List[str]
    add_tag_ids: List[int] = []
    remove_tag_ids: List[int] = []


# --- Dashboard ---

class NodeStatusOut(BaseModel):
    node_id: str
    aro_status: Optional[str] = None
    proxy_ok: Optional[bool] = None
    reward_today: Optional[float] = None
    reward_yesterday: Optional[float] = None
    total_score: Optional[float] = None
    avg_score: Optional[float] = None
    uptime_ratio: Optional[float] = None
    public_ip: Optional[str] = None
    script_version: Optional[str] = None
    last_seen: Optional[datetime] = None
    is_stale: bool
    account: Optional[str] = None
    serial: Optional[str] = None
    proxy_host: Optional[str] = None
    proxy_port: Optional[int] = None
    notes: Optional[str] = None
    tags: List[TagRef] = []

    class Config:
        from_attributes = True


class NodeListResponse(BaseModel):
    nodes: List[NodeStatusOut]
    total: int
    online: int
    offline: int
    no_internet: int
    unbound: int
    stale: int


class HistoryPoint(BaseModel):
    timestamp: datetime
    aro_status: Optional[str] = None
    reward_today: Optional[float] = None
    uptime_ratio: Optional[float] = None


class RestartEventOut(BaseModel):
    id: int
    node_id: str
    timestamp: datetime
    success: bool
    duration_secs: Optional[int] = None

    class Config:
        from_attributes = True


class NodeDetailResponse(BaseModel):
    node: NodeStatusOut
    history: List[HistoryPoint]
    restart_events: List[RestartEventOut] = []


class CommandOut(BaseModel):
    id: int
    node_id: str
    action: str
    status: str
    result: Optional[str] = None
    created_at: datetime
    acked_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    created_by: Optional[str] = None

    class Config:
        from_attributes = True


class CreateCommandRequest(BaseModel):
    node_id: str
    action: str


class UpdateNotesRequest(BaseModel):
    notes: str


class AccountStatsOut(BaseModel):
    account: str
    total: int
    online: int
    offline: int
    no_internet: int
    unbound: int
    vps_offline: int
    total_points: float
    avg_uptime: Optional[float] = None


class SettingsOut(BaseModel):
    tg_critical: str
    tg_warning: str
    tg_info: str
    tg_stats: str
    alert_offline_minutes: int
    periodic_restart_min: int
    periodic_restart_max: int

    class Config:
        from_attributes = True


class SettingsIn(BaseModel):
    tg_critical: str = ""
    tg_warning: str = ""
    tg_info: str = ""
    tg_stats: str = ""
    alert_offline_minutes: int = 10
    periodic_restart_min: int = 54
    periodic_restart_max: int = 120


class TestTelegramRequest(BaseModel):
    topic: str  # critical | warning | info | stats


class NodeRestartEventRequest(BaseModel):
    node_id: str
    api_key: str
    success: bool = True
    duration_secs: int = 0


class BulkCommandRequest(BaseModel):
    action: str
    node_ids: List[str]


class BulkCommandResponse(BaseModel):
    created: int
    skipped: int

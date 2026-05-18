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
    ip_leak: bool = False
    reward_today: float = 0
    reward_yesterday: float = 0
    uptime_ratio: float = 0
    public_ip: str = ""
    proxy_host: str = ""
    proxy_port: int = 0
    proxy_user: str = ""
    serial: str = ""
    account: str = ""
    script_version: str = ""
    bind_status: str = "unknown"


class PendingCommand(BaseModel):
    id: int
    action: str
    payload: Optional[str] = None


class NodeReportResponse(BaseModel):
    ok: bool
    commands: List[PendingCommand] = []
    periodic_restart_min: int = 54
    periodic_restart_max: int = 120
    daily_report_enabled: bool = True
    log_stale_restart_minutes: int = 5


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
    ip_leak: Optional[bool] = None
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
    proxy_user: Optional[str] = None
    notes: Optional[str] = None
    first_seen: Optional[datetime] = None
    renew_count: int = 0
    needs_renew: bool = False
    country_code: Optional[str] = None
    tags: List[TagRef] = []
    prev_account: Optional[str] = None

    class Config:
        from_attributes = True


class NodeListResponse(BaseModel):
    nodes: List[NodeStatusOut]
    total: int
    total_filtered: int
    page: int
    page_size: int
    total_pages: int
    online: int
    offline: int
    no_internet: int
    unbound: int
    proxy_expired: int = 0
    stale: int
    no_exit_ip_count: int = 0
    needs_renew_count: int = 0
    no_points_yesterday_count: int = 0
    no_points_avg_count: int = 0
    no_points_2days_count: int = 0
    renew_0points_count: int = 0
    ip_leak_count: int = 0


class RenewStatsNodeOut(BaseModel):
    node_id: str
    account: Optional[str] = None
    serial: Optional[str] = None
    renewed_at: datetime
    days_0pts: int
    renew_count: int = 0
    aro_status: Optional[str] = None
    last_seen: Optional[datetime] = None
    is_stale: bool
    proxy_ok: Optional[bool] = None

    class Config:
        from_attributes = True


class RenewStatsResponse(BaseModel):
    nodes: List[RenewStatsNodeOut]
    total: int
    page: int
    page_size: int
    total_pages: int


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
    node_log_stale_restart_minutes: Optional[int] = None
    global_log_stale_restart_minutes: int = 5


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


class RenameNodeRequest(BaseModel):
    new_node_id: str


class RenameNodeResponse(BaseModel):
    ok: bool
    old_node_id: str
    new_node_id: str


class AccountStatsOut(BaseModel):
    account: str
    total: int
    online: int
    offline: int
    no_internet: int
    unbound: int
    proxy_expired: int = 0
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
    daily_report_enabled: bool = True
    log_stale_restart_minutes: int = 5
    node_tg_bot_token: str = ""
    nodes_tg_enabled: bool = True
    backup_enabled: bool = False
    backup_interval_hours: int = 24
    backup_retention_count: int = 7

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
    daily_report_enabled: bool = True
    log_stale_restart_minutes: int = 5
    node_tg_bot_token: str = ""
    backup_enabled: bool = False
    backup_interval_hours: int = 24
    backup_retention_count: int = 7


class BackupFileInfo(BaseModel):
    filename: str
    size: int
    created_at: datetime


class DatabaseStatusOut(BaseModel):
    db_size: str
    db_size_bytes: int
    pg_version: str
    host: str
    dbname: str
    counts: dict
    table_sizes: List[dict]
    error: Optional[str] = None


class NodeSettingsIn(BaseModel):
    log_stale_restart_minutes: Optional[int] = None


class TeleBroadcastRequest(BaseModel):
    action: str  # "tele_off" | "tele_on"


class TeleBroadcastResponse(BaseModel):
    sent: int
    action: str
    nodes_tg_enabled: bool


class BroadcastTgChatIdRequest(BaseModel):
    tg_chat_id: str  # new chat_id:thread_id value


class BroadcastTgTokenRequest(BaseModel):
    tg_bot_token: str  # new bot token


class BroadcastResponse(BaseModel):
    sent: int


class SetProxyRequest(BaseModel):
    proxy: str  # host:port:user:pass


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


# --- Renew ---

class RenewCandidateOut(BaseModel):
    node_id: str
    account: Optional[str] = None
    serial: Optional[str] = None
    aro_status: Optional[str] = None
    avg_score: Optional[float] = None
    uptime_ratio: Optional[float] = None
    last_seen: Optional[datetime] = None
    is_stale: bool
    renew_count: int = 0
    last_renewed_at: Optional[datetime] = None
    last_renew_status: Optional[str] = None
    cooldown_until: Optional[datetime] = None

    class Config:
        from_attributes = True


class RenewCandidatesResponse(BaseModel):
    nodes: List[RenewCandidateOut]
    total: int


class RenewTriggerRequest(BaseModel):
    node_id: str


class BulkRenewRequest(BaseModel):
    node_ids: List[str]


class RenewTriggerResponse(BaseModel):
    ok: bool
    message: str
    command_id: Optional[int] = None


class BulkRenewResponse(BaseModel):
    triggered: int
    skipped: int
    details: List[dict]


class RenewLogOut(BaseModel):
    id: int
    node_id: str
    account: Optional[str] = None
    renewed_at: datetime
    serial_before: Optional[str] = None
    serial_after: Optional[str] = None
    account_before: Optional[str] = None
    command_id: Optional[int] = None
    status: str
    renew_count: int
    monitored_at: Optional[datetime] = None
    reward_yesterday: Optional[float] = None

    class Config:
        from_attributes = True


class RenewHistoryResponse(BaseModel):
    logs: List[RenewLogOut]
    total: int
    page: int
    page_size: int
    total_pages: int


class NodeAccountHistoryOut(BaseModel):
    id: int
    node_id: str
    account: str
    first_seen: datetime
    last_seen: datetime

    class Config:
        from_attributes = True


# --- IP Manager ---

class NodeIpInfo(BaseModel):
    node_id: str
    account: Optional[str] = None
    public_ip: Optional[str] = None
    proxy_host: Optional[str] = None
    aro_status: Optional[str] = None
    last_seen: Optional[datetime] = None
    is_stale: bool = False
    is_ip_duplicate: bool = False

    class Config:
        from_attributes = True


class IpManagerResponse(BaseModel):
    nodes: List[NodeIpInfo]
    total: int
    duplicate_ip_count: int
    affected_node_count: int

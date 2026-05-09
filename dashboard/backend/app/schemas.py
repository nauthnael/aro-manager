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


# --- Command complete (node → backend) ---

class CommandCompleteRequest(BaseModel):
    result: str = ""
    success: bool = True


# --- Dashboard ---

class NodeStatusOut(BaseModel):
    node_id: str
    aro_status: Optional[str] = None
    proxy_ok: Optional[bool] = None
    reward_today: Optional[float] = None
    reward_yesterday: Optional[float] = None
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


class NodeDetailResponse(BaseModel):
    node: NodeStatusOut
    history: List[HistoryPoint]


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

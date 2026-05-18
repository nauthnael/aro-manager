from datetime import datetime

from sqlalchemy import Boolean, Column, Date, DateTime, Float, ForeignKey, Index, Integer, String, Text

from app.database import Base


class AppSettings(Base):
    __tablename__ = "app_settings"

    id = Column(Integer, primary_key=True, default=1)
    tg_critical = Column(String(100), default="")   # "chat_id:thread_id"
    tg_warning = Column(String(100), default="")
    tg_info = Column(String(100), default="")
    tg_stats = Column(String(100), default="")
    alert_offline_minutes = Column(Integer, default=10)
    periodic_restart_min = Column(Integer, default=54)
    periodic_restart_max = Column(Integer, default=120)
    daily_report_enabled = Column(Boolean, default=True)
    log_stale_restart_minutes = Column(Integer, default=5)
    node_tg_bot_token = Column(String(200), default="")   # bot token dùng trên các node (khác với dashboard bot)
    nodes_tg_enabled = Column(Boolean, default=True)       # trạng thái Telegram trên các node (để track ý định)
    backup_enabled = Column(Boolean, default=False)
    backup_interval_hours = Column(Integer, default=24)
    backup_retention_count = Column(Integer, default=7)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True)
    username = Column(String(50), unique=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class Node(Base):
    __tablename__ = "nodes"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), unique=True, nullable=False, index=True)
    account = Column(String(255))
    serial = Column(String(255))
    proxy_host = Column(String(255))
    proxy_port = Column(Integer)
    proxy_user = Column(String(255))
    notes = Column(Text)
    log_stale_restart_minutes = Column(Integer, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class NodeStatus(Base):
    __tablename__ = "node_status"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), unique=True, index=True)
    aro_status = Column(String(50))
    proxy_ok = Column(Boolean)
    ip_leak = Column(Boolean, nullable=True)
    reward_today = Column(Float)
    reward_yesterday = Column(Float)
    uptime_ratio = Column(Float)
    public_ip = Column(String(50))
    script_version = Column(String(20))
    last_seen = Column(DateTime)
    last_snapshot_at = Column(DateTime)


class NodeHistory(Base):
    __tablename__ = "node_history"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    timestamp = Column(DateTime, default=datetime.utcnow, index=True)
    aro_status = Column(String(50))
    reward_today = Column(Float)
    uptime_ratio = Column(Float)

    __table_args__ = (Index("ix_node_history_node_ts", "node_id", "timestamp"),)


class NodeOfflineLog(Base):
    __tablename__ = "node_offline_log"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    offline_at = Column(DateTime, nullable=False, index=True)
    online_at = Column(DateTime)
    duration_minutes = Column(Integer)
    alerted = Column(Boolean, default=False)


class NodeRestartLog(Base):
    __tablename__ = "node_restart_log"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    timestamp = Column(DateTime, default=datetime.utcnow, index=True)
    success = Column(Boolean, default=True)
    duration_secs = Column(Integer)

    __table_args__ = (Index("ix_node_restart_log_node_ts", "node_id", "timestamp"),)


class NodeErrorLog(Base):
    __tablename__ = "node_error_log"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    # vps_offline | aro_offline | no_internet | unbound | proxy_fail
    error_type = Column(String(30), nullable=False)
    started_at = Column(DateTime, nullable=False, index=True)
    ended_at = Column(DateTime, nullable=True)
    duration_minutes = Column(Integer, nullable=True)

    __table_args__ = (Index("ix_node_error_log_node_start", "node_id", "started_at"),)


class NodeDailyScore(Base):
    __tablename__ = "node_daily_score"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    date = Column(Date, nullable=False, index=True)
    score = Column(Float, nullable=False)
    error_count = Column(Integer, default=0)
    vps_offline_minutes = Column(Integer, default=0)
    aro_offline_minutes = Column(Integer, default=0)
    no_internet_minutes = Column(Integer, default=0)
    unbound_minutes = Column(Integer, default=0)
    proxy_fail_minutes = Column(Integer, default=0)

    __table_args__ = (Index("ix_node_daily_score_node_date", "node_id", "date", unique=True),)


class NodeRenewLog(Base):
    __tablename__ = "node_renew_log"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    renewed_at = Column(DateTime, default=datetime.utcnow, index=True)
    serial_before = Column(String(255), nullable=True)
    serial_after = Column(String(255), nullable=True)
    account_before = Column(String(255), nullable=True)
    command_id = Column(Integer, nullable=True)
    status = Column(String(20), default="pending")  # pending | completed | failed
    renew_count = Column(Integer, default=1)
    monitored_at = Column(DateTime, nullable=True)

    __table_args__ = (Index("ix_node_renew_log_node_ts", "node_id", "renewed_at"),)


class NodeAccountHistory(Base):
    __tablename__ = "node_account_history"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    account = Column(String(255), nullable=False)
    first_seen = Column(DateTime, nullable=False, index=True)
    last_seen = Column(DateTime, nullable=False)

    __table_args__ = (Index("ix_node_account_history_node_ts", "node_id", "first_seen"),)


class IPCountryCache(Base):
    __tablename__ = "ip_country_cache"

    ip = Column(String(50), primary_key=True)
    country_code = Column(String(5), nullable=False)
    cached_at = Column(DateTime, default=datetime.utcnow)


class Command(Base):
    __tablename__ = "commands"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    action = Column(String(50))
    payload = Column(Text, nullable=True)
    status = Column(String(20), default="pending")  # pending | acked | completed | failed
    result = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow, index=True)
    acked_at = Column(DateTime)
    completed_at = Column(DateTime)
    created_by = Column(String(50))


class Tag(Base):
    __tablename__ = "tags"

    id = Column(Integer, primary_key=True)
    name = Column(String(50), unique=True, nullable=False, index=True)
    color = Column(String(7), default="#3b82f6")  # hex color
    created_at = Column(DateTime, default=datetime.utcnow)


class NodeTag(Base):
    __tablename__ = "node_tags"

    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE"), primary_key=True)
    tag_id = Column(Integer, ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True)


class NodeDiagnosticLog(Base):
    __tablename__ = "node_diagnostic_log"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE", onupdate="CASCADE"), index=True)
    collected_at = Column(DateTime, default=datetime.utcnow, index=True)
    trigger = Column(String(50), nullable=False)
    content = Column(Text, nullable=False)

    __table_args__ = (Index("ix_node_diagnostic_log_node_ts", "node_id", "collected_at"),)

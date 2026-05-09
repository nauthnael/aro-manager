from datetime import datetime

from sqlalchemy import Boolean, Column, DateTime, Float, ForeignKey, Index, Integer, String, Text

from app.database import Base


class AppSettings(Base):
    __tablename__ = "app_settings"

    id = Column(Integer, primary_key=True, default=1)
    tg_critical = Column(String(100), default="")   # "chat_id:thread_id"
    tg_warning = Column(String(100), default="")
    tg_info = Column(String(100), default="")
    tg_stats = Column(String(100), default="")
    alert_offline_minutes = Column(Integer, default=10)
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
    notes = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow)


class NodeStatus(Base):
    __tablename__ = "node_status"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE"), unique=True, index=True)
    aro_status = Column(String(50))
    proxy_ok = Column(Boolean)
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
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE"), index=True)
    timestamp = Column(DateTime, default=datetime.utcnow, index=True)
    aro_status = Column(String(50))
    reward_today = Column(Float)
    uptime_ratio = Column(Float)

    __table_args__ = (Index("ix_node_history_node_ts", "node_id", "timestamp"),)


class NodeOfflineLog(Base):
    __tablename__ = "node_offline_log"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE"), index=True)
    offline_at = Column(DateTime, nullable=False, index=True)
    online_at = Column(DateTime)
    duration_minutes = Column(Integer)
    alerted = Column(Boolean, default=False)


class Command(Base):
    __tablename__ = "commands"

    id = Column(Integer, primary_key=True)
    node_id = Column(String(255), ForeignKey("nodes.node_id", ondelete="CASCADE"), index=True)
    action = Column(String(50))
    status = Column(String(20), default="pending")  # pending | acked | completed | failed
    result = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow, index=True)
    acked_at = Column(DateTime)
    completed_at = Column(DateTime)
    created_by = Column(String(50))

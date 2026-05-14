import logging
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta

from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from sqlalchemy import text

from app import models
from app.auth import hash_password
from app.config import settings
from app.database import Base, SessionLocal, engine
from app.routers import commands, dashboard, nodes
from app.routers import settings as settings_router
from app.routers import errors as errors_router
from app.routers import renew as renew_router
from app.scoring import calculate_score_for_day
from app.telegram import send_telegram_message

logger = logging.getLogger(__name__)


def migrate_db():
    """Add new columns/data to existing tables without Alembic."""
    ddl_migrations = [
        "ALTER TABLE app_settings ADD COLUMN periodic_restart_min INTEGER DEFAULT 54",
        "ALTER TABLE app_settings ADD COLUMN periodic_restart_max INTEGER DEFAULT 120",
        "ALTER TABLE app_settings ADD COLUMN daily_report_enabled BOOLEAN DEFAULT TRUE",
        "ALTER TABLE node ADD COLUMN notes TEXT",
        """CREATE TABLE IF NOT EXISTS node_renew_log (
            id SERIAL PRIMARY KEY,
            node_id VARCHAR(255) REFERENCES nodes(node_id) ON DELETE CASCADE,
            renewed_at TIMESTAMP DEFAULT NOW(),
            serial_before VARCHAR(255),
            serial_after VARCHAR(255),
            command_id INTEGER,
            status VARCHAR(20) DEFAULT 'pending',
            renew_count INTEGER DEFAULT 1,
            monitored_at TIMESTAMP
        )""",
        "CREATE INDEX IF NOT EXISTS ix_node_renew_log_node_ts ON node_renew_log (node_id, renewed_at)",
        "ALTER TABLE node_renew_log ADD COLUMN serial_after VARCHAR(255)",
        "ALTER TABLE node_renew_log ADD COLUMN monitored_at TIMESTAMP",
        "ALTER TABLE nodes ADD COLUMN proxy_user VARCHAR(255)",
        "ALTER TABLE app_settings ADD COLUMN log_stale_restart_minutes INTEGER DEFAULT 5",
        "ALTER TABLE nodes ADD COLUMN log_stale_restart_minutes INTEGER",
        "ALTER TABLE app_settings ADD COLUMN node_tg_bot_token VARCHAR(200) DEFAULT ''",
        "ALTER TABLE app_settings ADD COLUMN nodes_tg_enabled BOOLEAN DEFAULT TRUE",
    ]
    for sql in ddl_migrations:
        try:
            with engine.begin() as conn:
                conn.execute(text(sql))
        except Exception:
            pass  # column already exists → ignore

    # Migrate existing NodeOfflineLog rows into NodeErrorLog
    migrate_sql = """
        INSERT INTO node_error_log (node_id, error_type, started_at, ended_at, duration_minutes)
        SELECT nol.node_id, 'vps_offline', nol.offline_at, nol.online_at, nol.duration_minutes
        FROM node_offline_log nol
        WHERE NOT EXISTS (
            SELECT 1 FROM node_error_log nel
            WHERE nel.node_id = nol.node_id
              AND nel.error_type = 'vps_offline'
              AND nel.started_at = nol.offline_at
        )
    """
    with engine.connect() as conn:
        try:
            conn.execute(text(migrate_sql))
            conn.commit()
        except Exception:
            pass


def init_db():
    Base.metadata.create_all(bind=engine)
    migrate_db()
    db = SessionLocal()
    try:
        admin = db.query(models.User).filter(models.User.username == settings.admin_username).first()
        if not admin:
            db.add(models.User(
                username=settings.admin_username,
                password_hash=hash_password(settings.admin_password),
            ))
            db.commit()

        if not db.query(models.AppSettings).filter(models.AppSettings.id == 1).first():
            db.add(models.AppSettings(id=1))
            db.commit()
    finally:
        db.close()


def _open_error_log(db, node_id: str, error_type: str, started_at: datetime):
    existing = db.query(models.NodeErrorLog).filter(
        models.NodeErrorLog.node_id == node_id,
        models.NodeErrorLog.error_type == error_type,
        models.NodeErrorLog.ended_at.is_(None),
    ).first()
    if not existing:
        db.add(models.NodeErrorLog(
            node_id=node_id,
            error_type=error_type,
            started_at=started_at,
        ))


def _close_error_log(db, node_id: str, error_type: str, ended_at: datetime):
    log = db.query(models.NodeErrorLog).filter(
        models.NodeErrorLog.node_id == node_id,
        models.NodeErrorLog.error_type == error_type,
        models.NodeErrorLog.ended_at.is_(None),
    ).first()
    if log:
        log.ended_at = ended_at
        log.duration_minutes = max(0, int((ended_at - log.started_at).total_seconds() / 60))


def check_offline_alerts():
    db = SessionLocal()
    try:
        cfg = db.query(models.AppSettings).filter(models.AppSettings.id == 1).first()
        if not cfg or not cfg.tg_critical:
            return

        threshold_secs = settings.stale_threshold_secs
        alert_threshold = timedelta(minutes=cfg.alert_offline_minutes)
        now = datetime.utcnow()

        all_status = db.query(models.NodeStatus).all()
        for ns in all_status:
            if not ns.last_seen:
                continue
            offline_duration = now - ns.last_seen
            is_offline = offline_duration.total_seconds() > threshold_secs

            open_log = (
                db.query(models.NodeOfflineLog)
                .filter(
                    models.NodeOfflineLog.node_id == ns.node_id,
                    models.NodeOfflineLog.online_at == None,  # noqa: E711
                )
                .first()
            )

            if is_offline:
                if not open_log:
                    log = models.NodeOfflineLog(node_id=ns.node_id, offline_at=ns.last_seen)
                    db.add(log)
                    db.flush()
                    open_log = log
                    _open_error_log(db, ns.node_id, "vps_offline", ns.last_seen)

                if not open_log.alerted and (now - open_log.offline_at) >= alert_threshold:
                    node = db.query(models.Node).filter(models.Node.node_id == ns.node_id).first()
                    account = node.account if node else ns.node_id
                    minutes = int((now - open_log.offline_at).total_seconds() / 60)
                    send_telegram_message(
                        cfg.tg_critical,
                        f"🔴 <b>Node Offline</b>\n"
                        f"Host: <code>{ns.node_id}</code>\n"
                        f"Account: {account}\n"
                        f"Offline: {minutes} phút",
                    )
                    open_log.alerted = True
            else:
                if open_log:
                    open_log.online_at = now
                    open_log.duration_minutes = int((now - open_log.offline_at).total_seconds() / 60)
                    _close_error_log(db, ns.node_id, "vps_offline", now)

        db.commit()
    except Exception as exc:
        db.rollback()
        logger.error("check_offline_alerts error: %s", exc)
    finally:
        db.close()


def calculate_daily_scores():
    """Runs daily at 00:05 UTC — scores yesterday for every node."""
    yesterday = date.today() - timedelta(days=1)
    db = SessionLocal()
    try:
        nodes = db.query(models.Node).all()
        for node in nodes:
            result = calculate_score_for_day(node.node_id, yesterday, db)
            bd = result["breakdown"]

            existing = db.query(models.NodeDailyScore).filter(
                models.NodeDailyScore.node_id == node.node_id,
                models.NodeDailyScore.date == yesterday,
            ).first()

            if existing:
                existing.score = result["score"]
                existing.error_count = result["error_count"]
                existing.vps_offline_minutes = bd.get("vps_offline", 0)
                existing.aro_offline_minutes = bd.get("aro_offline", 0)
                existing.no_internet_minutes = bd.get("no_internet", 0)
                existing.unbound_minutes = bd.get("unbound", 0)
                existing.proxy_fail_minutes = bd.get("proxy_fail", 0)
            else:
                db.add(models.NodeDailyScore(
                    node_id=node.node_id,
                    date=yesterday,
                    score=result["score"],
                    error_count=result["error_count"],
                    vps_offline_minutes=bd.get("vps_offline", 0),
                    aro_offline_minutes=bd.get("aro_offline", 0),
                    no_internet_minutes=bd.get("no_internet", 0),
                    unbound_minutes=bd.get("unbound", 0),
                    proxy_fail_minutes=bd.get("proxy_fail", 0),
                ))
        db.commit()
        logger.info("calculate_daily_scores: scored %d nodes for %s", len(nodes), yesterday)
    except Exception as exc:
        db.rollback()
        logger.error("calculate_daily_scores error: %s", exc)
    finally:
        db.close()


def check_renew_monitoring():
    """Runs every 5 min — after 30 min post-renew, check if node recovered and notify via Telegram."""
    db = SessionLocal()
    try:
        now = datetime.utcnow()
        window_start = now - timedelta(minutes=35)
        window_end = now - timedelta(minutes=25)

        pending_logs = (
            db.query(models.NodeRenewLog)
            .filter(
                models.NodeRenewLog.renewed_at >= window_start,
                models.NodeRenewLog.renewed_at <= window_end,
                models.NodeRenewLog.monitored_at.is_(None),
            )
            .all()
        )

        if not pending_logs:
            return

        cfg = db.query(models.AppSettings).filter(models.AppSettings.id == 1).first()

        for log in pending_logs:
            status = db.query(models.NodeStatus).filter(models.NodeStatus.node_id == log.node_id).first()
            node = db.query(models.Node).filter(models.Node.node_id == log.node_id).first()

            is_online = (
                status is not None
                and status.aro_status == "Online"
                and status.last_seen is not None
                and (now - status.last_seen).total_seconds() < settings.stale_threshold_secs
            )

            serial_line = ""
            if log.serial_after and log.serial_after != log.serial_before:
                serial_line = f"\nSerial: <code>{log.serial_before}</code> → <code>{log.serial_after}</code>"
            elif log.serial_before:
                serial_line = f"\nSerial: <code>{log.serial_before}</code> (chưa đổi)"

            icon = "✅" if is_online else "⚠️"
            status_text = status.aro_status if status else "Unknown"
            account_text = node.account if node else "—"

            msg = (
                f"{icon} <b>Kiểm tra sau Renew</b>\n"
                f"Host: <code>{log.node_id}</code>\n"
                f"Account: {account_text}\n"
                f"Trạng thái: <b>{status_text}</b>\n"
                f"Renew lần #{log.renew_count}"
                + serial_line
            )

            if cfg and cfg.tg_info:
                try:
                    send_telegram_message(cfg.tg_info, msg)
                except Exception as exc:
                    logger.error("check_renew_monitoring telegram error: %s", exc)

            log.monitored_at = now

        db.commit()
    except Exception as exc:
        db.rollback()
        logger.error("check_renew_monitoring error: %s", exc)
    finally:
        db.close()


def cleanup_old_data():
    db = SessionLocal()
    try:
        cutoff = datetime.utcnow() - timedelta(days=settings.history_retention_days)
        db.query(models.NodeHistory).filter(models.NodeHistory.timestamp < cutoff).delete()

        cmd_cutoff = datetime.utcnow() - timedelta(days=7)
        db.query(models.Command).filter(
            models.Command.status.in_(["completed", "failed"]),
            models.Command.created_at < cmd_cutoff,
        ).delete()

        # Keep error logs and daily scores for 90 days
        err_cutoff = datetime.utcnow() - timedelta(days=90)
        db.query(models.NodeErrorLog).filter(
            models.NodeErrorLog.started_at < err_cutoff,
        ).delete()
        score_cutoff = date.today() - timedelta(days=90)
        db.query(models.NodeDailyScore).filter(
            models.NodeDailyScore.date < score_cutoff,
        ).delete()

        db.commit()
    finally:
        db.close()


scheduler = BackgroundScheduler()


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    scheduler.add_job(cleanup_old_data, "interval", hours=6)
    scheduler.add_job(check_offline_alerts, "interval", minutes=2)
    scheduler.add_job(check_renew_monitoring, "interval", minutes=5)
    scheduler.add_job(calculate_daily_scores, "cron", hour=0, minute=5)
    scheduler.start()
    yield
    scheduler.shutdown()


app = FastAPI(title="ARO Dashboard API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(nodes.router, prefix="/api/v1")
app.include_router(dashboard.router, prefix="/api/v1")
app.include_router(commands.router, prefix="/api/v1")
app.include_router(settings_router.router, prefix="/api/v1")
app.include_router(errors_router.router, prefix="/api/v1")
app.include_router(renew_router.router, prefix="/api/v1")

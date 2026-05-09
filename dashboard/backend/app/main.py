from contextlib import asynccontextmanager
from datetime import datetime, timedelta

from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import models
from app.auth import hash_password
from app.config import settings
from app.database import Base, SessionLocal, engine
from app.routers import commands, dashboard, nodes
from app.routers import settings as settings_router
from app.telegram import send_telegram_message


def init_db():
    Base.metadata.create_all(bind=engine)
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

        db.commit()
    except Exception as exc:
        db.rollback()
        import logging
        logging.getLogger(__name__).error("check_offline_alerts error: %s", exc)
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

        db.commit()
    finally:
        db.close()


scheduler = BackgroundScheduler()


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    scheduler.add_job(cleanup_old_data, "interval", hours=6)
    scheduler.add_job(check_offline_alerts, "interval", minutes=2)
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

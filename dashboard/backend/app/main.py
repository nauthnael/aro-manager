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

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app import models, schemas
from app.auth import get_current_user
from app.database import get_db
from app.telegram import check_telegram_api, get_telegram_health, send_telegram_message

router = APIRouter(tags=["settings"])


def _get_or_create_settings(db: Session) -> models.AppSettings:
    row = db.query(models.AppSettings).filter(models.AppSettings.id == 1).first()
    if not row:
        row = models.AppSettings(id=1)
        db.add(row)
        db.commit()
        db.refresh(row)
    return row


@router.get("/settings", response_model=schemas.SettingsOut)
def get_settings(db: Session = Depends(get_db), _=Depends(get_current_user)):
    return _get_or_create_settings(db)


@router.put("/settings", response_model=schemas.SettingsOut)
def update_settings(body: schemas.SettingsIn, db: Session = Depends(get_db), _=Depends(get_current_user)):
    row = _get_or_create_settings(db)
    row.tg_critical = body.tg_critical
    row.tg_warning = body.tg_warning
    row.tg_info = body.tg_info
    row.tg_stats = body.tg_stats
    row.alert_offline_minutes = body.alert_offline_minutes
    pmin = max(1, min(body.periodic_restart_min, 1440))
    pmax = max(1, min(body.periodic_restart_max, 1440))
    row.periodic_restart_min = min(pmin, pmax)
    row.periodic_restart_max = max(pmin, pmax)
    row.daily_report_enabled = body.daily_report_enabled
    row.log_stale_restart_minutes = max(1, min(body.log_stale_restart_minutes, 60))
    db.commit()
    db.refresh(row)
    return row


@router.get("/settings/telegram-health")
def telegram_health(_=Depends(get_current_user)):
    """Return cached Telegram API health state (no live API call)."""
    return get_telegram_health()


@router.post("/settings/telegram-health/check")
def telegram_health_check(_=Depends(get_current_user)):
    """Live-check Telegram API via getMe and return fresh state."""
    return check_telegram_api()


@router.post("/settings/test")
def test_telegram(body: schemas.TestTelegramRequest, db: Session = Depends(get_db), _=Depends(get_current_user)):
    row = _get_or_create_settings(db)
    topic_map = {
        "critical": row.tg_critical,
        "warning": row.tg_warning,
        "info": row.tg_info,
        "stats": row.tg_stats,
    }
    chat_config = topic_map.get(body.topic, "")
    if not chat_config:
        return {"ok": False, "error": f"Topic '{body.topic}' chưa được cấu hình"}

    ok, err = send_telegram_message(chat_config, f"✅ Test từ ARO Dashboard — topic: <b>{body.topic}</b>")
    return {"ok": ok, "error": None if ok else err}

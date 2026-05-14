from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app import models, schemas
from app.auth import get_current_user
from app.database import get_db
from app.telegram import (
    get_node_telegram_health,
    get_telegram_health,
    send_node_health_check,
    send_primary_health_check,
    send_telegram_message,
)

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
    row.node_tg_bot_token = body.node_tg_bot_token.strip()
    db.commit()
    db.refresh(row)
    return row


# --- Dashboard bot health (primary) ---

@router.get("/settings/telegram-health")
def telegram_health(_=Depends(get_current_user)):
    """Return cached health state for the dashboard bot (no live API call)."""
    return get_telegram_health()


@router.post("/settings/telegram-health/check")
def telegram_health_check(db: Session = Depends(get_db), _=Depends(get_current_user)):
    """Send 1 test message to tg_critical using dashboard bot. Returns real rate-limit state."""
    row = _get_or_create_settings(db)
    return send_primary_health_check(row.tg_critical or "")


# --- Node bot health (secondary) ---

@router.get("/settings/telegram-health/node")
def telegram_health_node(db: Session = Depends(get_db), _=Depends(get_current_user)):
    """Return cached health state for the node bot (no API call)."""
    row = _get_or_create_settings(db)
    return get_node_telegram_health(row.node_tg_bot_token or "")


@router.post("/settings/telegram-health/check/node")
def telegram_health_check_node(db: Session = Depends(get_db), _=Depends(get_current_user)):
    """Send 1 test message to tg_critical using node bot. Returns real rate-limit state."""
    row = _get_or_create_settings(db)
    return send_node_health_check(row.node_tg_bot_token or "", row.tg_critical or "")


# --- Tele broadcast (tắt/bật Telegram trên tất cả nodes) ---

@router.post("/settings/tele-broadcast", response_model=schemas.TeleBroadcastResponse)
def tele_broadcast(
    body: schemas.TeleBroadcastRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if body.action not in ("tele_off", "tele_on"):
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail="action must be 'tele_off' or 'tele_on'")

    all_node_ids = [r.node_id for r in db.query(models.Node.node_id).all()]

    # Cancel existing pending tele_off/tele_on for all nodes
    db.query(models.Command).filter(
        models.Command.action.in_(["tele_off", "tele_on"]),
        models.Command.status == "pending",
    ).delete(synchronize_session=False)

    for node_id in all_node_ids:
        db.add(models.Command(
            node_id=node_id,
            action=body.action,
            created_by=current_user.username,
        ))

    # Track intended state
    row = _get_or_create_settings(db)
    row.nodes_tg_enabled = (body.action == "tele_on")
    db.commit()

    return schemas.TeleBroadcastResponse(
        sent=len(all_node_ids),
        action=body.action,
        nodes_tg_enabled=row.nodes_tg_enabled,
    )


# --- Test Telegram topic ---

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

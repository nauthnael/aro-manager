import logging

import requests

from app.config import settings

logger = logging.getLogger(__name__)


def send_telegram_message(chat_config: str, text: str) -> tuple[bool, str]:
    """Send message to a Telegram topic. chat_config format: 'chat_id:thread_id'.
    Returns (ok, error_message)."""
    if not settings.telegram_bot_token:
        return False, "TELEGRAM_BOT_TOKEN chưa được cấu hình trong .env"
    if not chat_config:
        return False, "Chat config trống"

    parts = chat_config.strip().split(":", 1)
    if len(parts) != 2:
        return False, f"Định dạng sai (phải là chat_id:thread_id): {chat_config}"

    chat_id, thread_id = parts[0], parts[1]
    url = f"https://api.telegram.org/bot{settings.telegram_bot_token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "message_thread_id": int(thread_id),
        "text": text,
        "parse_mode": "HTML",
    }
    try:
        r = requests.post(url, json=payload, timeout=10)
        if not r.ok:
            err = r.json().get("description", r.text[:200]) if r.headers.get("content-type", "").startswith("application/json") else r.text[:200]
            logger.warning("Telegram error %s: %s", r.status_code, err)
            return False, f"Telegram API lỗi {r.status_code}: {err}"
        return True, ""
    except Exception as exc:
        logger.error("Telegram send failed: %s", exc)
        return False, str(exc)

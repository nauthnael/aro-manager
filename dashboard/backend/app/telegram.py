import logging

import requests

from app.config import settings

logger = logging.getLogger(__name__)


def send_telegram_message(chat_config: str, text: str) -> bool:
    """Send message to a Telegram topic. chat_config format: 'chat_id:thread_id'"""
    if not settings.telegram_bot_token or not chat_config:
        return False

    parts = chat_config.strip().split(":", 1)
    if len(parts) != 2:
        logger.warning("Invalid tg config: %s", chat_config)
        return False

    chat_id, thread_id = parts[0], parts[1]
    url = f"https://api.telegram.org/bot{settings.telegram_bot_token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "message_thread_id": thread_id,
        "text": text,
        "parse_mode": "HTML",
    }
    try:
        r = requests.post(url, json=payload, timeout=10)
        if not r.ok:
            logger.warning("Telegram error %s: %s", r.status_code, r.text[:200])
        return r.ok
    except Exception as exc:
        logger.error("Telegram send failed: %s", exc)
        return False

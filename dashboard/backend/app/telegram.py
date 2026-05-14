import time
import logging

import requests

from app.config import settings

logger = logging.getLogger(__name__)

# --- Module-level health state ---
_rate_limit_until: float = 0.0   # epoch seconds when rate limit expires
_last_error: str = ""             # last non-429 error message
_bot_username: str = ""           # cached from getMe


def _set_rate_limit(retry_after: int) -> None:
    global _rate_limit_until
    _rate_limit_until = time.time() + max(retry_after, 1)


def _clear_error() -> None:
    global _last_error
    _last_error = ""


def get_rate_limit_remaining() -> int:
    remaining = int(_rate_limit_until - time.time())
    return max(0, remaining)


def get_telegram_health() -> dict:
    """Return current health state without making any API call."""
    if not settings.telegram_bot_token:
        return {"status": "not_configured", "bot_username": None, "retry_after": 0, "error": None}
    remaining = get_rate_limit_remaining()
    if remaining > 0:
        return {"status": "rate_limited", "bot_username": _bot_username or None, "retry_after": remaining, "error": None}
    if _last_error:
        return {"status": "error", "bot_username": _bot_username or None, "retry_after": 0, "error": _last_error}
    return {"status": "ok", "bot_username": _bot_username or None, "retry_after": 0, "error": None}


def check_telegram_api() -> dict:
    """Live check via getMe. Updates module-level state."""
    global _bot_username, _last_error

    if not settings.telegram_bot_token:
        return {"status": "not_configured", "bot_username": None, "retry_after": 0, "error": "Bot token chưa cấu hình"}

    remaining = get_rate_limit_remaining()
    if remaining > 0:
        return {"status": "rate_limited", "bot_username": _bot_username or None, "retry_after": remaining, "error": None}

    url = f"https://api.telegram.org/bot{settings.telegram_bot_token}/getMe"
    try:
        r = requests.get(url, timeout=10)
        if r.status_code == 200:
            bot = r.json().get("result", {})
            _bot_username = f"@{bot.get('username', '')}" if bot.get("username") else ""
            _last_error = ""
            return {"status": "ok", "bot_username": _bot_username or None, "retry_after": 0, "error": None}
        elif r.status_code == 429:
            retry_after = 60
            try:
                retry_after = r.json().get("parameters", {}).get("retry_after", 60)
            except Exception:
                pass
            _set_rate_limit(retry_after)
            _last_error = ""
            return {"status": "rate_limited", "bot_username": _bot_username or None, "retry_after": retry_after, "error": None}
        elif r.status_code == 401:
            _last_error = "Bot token không hợp lệ (401 Unauthorized)"
            return {"status": "error", "bot_username": None, "retry_after": 0, "error": _last_error}
        else:
            err = r.text[:200]
            _last_error = f"HTTP {r.status_code}: {err}"
            return {"status": "error", "bot_username": None, "retry_after": 0, "error": _last_error}
    except Exception as exc:
        _last_error = str(exc)
        return {"status": "error", "bot_username": None, "retry_after": 0, "error": _last_error}


def send_telegram_message(chat_config: str, text: str) -> tuple[bool, str]:
    """Send message to a Telegram topic. chat_config format: 'chat_id:thread_id'.
    Returns (ok, error_message)."""
    global _last_error

    if not settings.telegram_bot_token:
        return False, "TELEGRAM_BOT_TOKEN chưa được cấu hình trong .env"
    if not chat_config:
        return False, "Chat config trống"

    # Bail early if still rate limited
    remaining = get_rate_limit_remaining()
    if remaining > 0:
        return False, f"Telegram rate limited, còn {remaining}s"

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
        if r.status_code == 200:
            _last_error = ""
            return True, ""
        elif r.status_code == 429:
            retry_after = 60
            try:
                retry_after = r.json().get("parameters", {}).get("retry_after", 60)
            except Exception:
                pass
            _set_rate_limit(retry_after)
            logger.warning("Telegram rate limited (429) — backing off %ss", retry_after)
            return False, f"Telegram rate limited, retry after {retry_after}s"
        else:
            err = r.json().get("description", r.text[:200]) if r.headers.get("content-type", "").startswith("application/json") else r.text[:200]
            _last_error = f"Telegram API lỗi {r.status_code}: {err}"
            logger.warning("Telegram error %s: %s", r.status_code, err)
            return False, _last_error
    except Exception as exc:
        _last_error = str(exc)
        logger.error("Telegram send failed: %s", exc)
        return False, _last_error

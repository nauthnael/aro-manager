import time
import logging

import requests

from app.config import settings

logger = logging.getLogger(__name__)


# --- Generic state tracking ---

def _new_state() -> dict:
    return {"rate_limit_until": 0.0, "last_error": "", "bot_username": ""}


_primary = _new_state()    # dashboard bot (from .env TELEGRAM_BOT_TOKEN)
_secondary = _new_state()  # node bot (from AppSettings.node_tg_bot_token)


def _remaining(state: dict) -> int:
    return max(0, int(state["rate_limit_until"] - time.time()))


def _set_rate_limit(state: dict, retry_after: int) -> None:
    state["rate_limit_until"] = time.time() + max(retry_after, 1)


# --- Health functions ---

def _get_health(bot_token: str, state: dict) -> dict:
    """Return current health state without making any API call."""
    if not bot_token:
        return {"status": "not_configured", "bot_username": None, "retry_after": 0, "error": None}
    remaining = _remaining(state)
    if remaining > 0:
        return {"status": "rate_limited", "bot_username": state["bot_username"] or None, "retry_after": remaining, "error": None}
    if state["last_error"]:
        return {"status": "error", "bot_username": state["bot_username"] or None, "retry_after": 0, "error": state["last_error"]}
    return {"status": "ok", "bot_username": state["bot_username"] or None, "retry_after": 0, "error": None}


def _check_api(bot_token: str, state: dict) -> dict:
    """Live check via getMe. Updates state in-place."""
    if not bot_token:
        return {"status": "not_configured", "bot_username": None, "retry_after": 0, "error": "Bot token chưa cấu hình"}
    remaining = _remaining(state)
    if remaining > 0:
        return {"status": "rate_limited", "bot_username": state["bot_username"] or None, "retry_after": remaining, "error": None}

    url = f"https://api.telegram.org/bot{bot_token}/getMe"
    try:
        r = requests.get(url, timeout=10)
        if r.status_code == 200:
            bot = r.json().get("result", {})
            state["bot_username"] = f"@{bot.get('username', '')}" if bot.get("username") else ""
            state["last_error"] = ""
            return {"status": "ok", "bot_username": state["bot_username"] or None, "retry_after": 0, "error": None}
        elif r.status_code == 429:
            retry_after = 60
            try:
                retry_after = r.json().get("parameters", {}).get("retry_after", 60)
            except Exception:
                pass
            _set_rate_limit(state, retry_after)
            state["last_error"] = ""
            return {"status": "rate_limited", "bot_username": state["bot_username"] or None, "retry_after": retry_after, "error": None}
        elif r.status_code == 401:
            state["last_error"] = "Bot token không hợp lệ (401 Unauthorized)"
            return {"status": "error", "bot_username": None, "retry_after": 0, "error": state["last_error"]}
        else:
            state["last_error"] = f"HTTP {r.status_code}: {r.text[:200]}"
            return {"status": "error", "bot_username": None, "retry_after": 0, "error": state["last_error"]}
    except Exception as exc:
        state["last_error"] = str(exc)
        return {"status": "error", "bot_username": None, "retry_after": 0, "error": state["last_error"]}


# --- Public API (primary = dashboard bot) ---

def get_telegram_health() -> dict:
    return _get_health(settings.telegram_bot_token, _primary)


def check_telegram_api() -> dict:
    return _check_api(settings.telegram_bot_token, _primary)


# --- Public API (secondary = node bot, token from DB) ---

def get_node_telegram_health(bot_token: str) -> dict:
    return _get_health(bot_token, _secondary)


def check_node_telegram_api(bot_token: str) -> dict:
    return _check_api(bot_token, _secondary)


# --- Send message (uses primary bot) ---

def send_telegram_message(chat_config: str, text: str) -> tuple[bool, str]:
    """Send message to a Telegram topic. chat_config format: 'chat_id:thread_id'.
    Returns (ok, error_message)."""
    if not settings.telegram_bot_token:
        return False, "TELEGRAM_BOT_TOKEN chưa được cấu hình trong .env"
    if not chat_config:
        return False, "Chat config trống"

    # Bail early if still rate limited
    remaining = _remaining(_primary)
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
            _primary["last_error"] = ""
            return True, ""
        elif r.status_code == 429:
            retry_after = 60
            try:
                retry_after = r.json().get("parameters", {}).get("retry_after", 60)
            except Exception:
                pass
            _set_rate_limit(_primary, retry_after)
            logger.warning("Telegram rate limited (429) — backing off %ss", retry_after)
            return False, f"Telegram rate limited, retry after {retry_after}s"
        else:
            err = r.json().get("description", r.text[:200]) if r.headers.get("content-type", "").startswith("application/json") else r.text[:200]
            _primary["last_error"] = f"Telegram API lỗi {r.status_code}: {err}"
            logger.warning("Telegram error %s: %s", r.status_code, err)
            return False, _primary["last_error"]
    except Exception as exc:
        _primary["last_error"] = str(exc)
        logger.error("Telegram send failed: %s", exc)
        return False, _primary["last_error"]

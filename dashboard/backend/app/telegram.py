import threading
import time
import logging
from collections import defaultdict

import requests

from app.config import settings

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Module-level health state
# ---------------------------------------------------------------------------

def _new_state() -> dict:
    return {
        "status": "unknown",
        "rate_limit_until": 0.0,
        "last_error": "",
        "bot_username": "",
    }


_primary = _new_state()    # dashboard bot (from .env TELEGRAM_BOT_TOKEN)
_secondary = _new_state()  # node bot (from AppSettings.node_tg_bot_token)


def _remaining(state: dict) -> int:
    return max(0, int(state["rate_limit_until"] - time.time()))


def _set_rate_limit(state: dict, retry_after: int) -> None:
    state["rate_limit_until"] = time.time() + max(retry_after, 1)
    state["status"] = "rate_limited"


# ---------------------------------------------------------------------------
# Message queue (flush every 2 minutes via APScheduler)
# ---------------------------------------------------------------------------

_queue_lock = threading.Lock()
# key = chat_config ("chat_id:thread_id"), value = list of message strings
_queue: dict[str, list[str]] = defaultdict(list)

TG_MAX_MSG_LEN = 4096
_QUEUE_SEP = "\n\n"


def enqueue_telegram_message(chat_config: str, text: str) -> None:
    """Add message to the queue. Actual send happens in flush_telegram_queue()."""
    if not settings.telegram_bot_token or not chat_config:
        return
    with _queue_lock:
        _queue[chat_config].append(text)


def flush_telegram_queue() -> None:
    """Called by APScheduler every 2 minutes. Consolidates and sends queued messages."""
    with _queue_lock:
        if not _queue:
            return
        snapshot = {k: list(v) for k, v in _queue.items()}
        _queue.clear()

    for chat_config, messages in snapshot.items():
        if not messages:
            continue
        # Combine messages, split if exceeds Telegram limit
        chunks: list[str] = []
        current = ""
        for msg in messages:
            candidate = (current + _QUEUE_SEP + msg).lstrip(_QUEUE_SEP) if current else msg
            if len(candidate) <= TG_MAX_MSG_LEN:
                current = candidate
            else:
                if current:
                    chunks.append(current)
                # If single message itself is too long, truncate
                current = msg[:TG_MAX_MSG_LEN]
        if current:
            chunks.append(current)

        for chunk in chunks:
            ok, err = _send_now(settings.telegram_bot_token, chat_config, _primary, chunk)
            if not ok:
                logger.warning("flush_telegram_queue: send failed for %s: %s", chat_config, err)


# ---------------------------------------------------------------------------
# Health check — cached state (GET) + sendMessage-based live check (POST)
# ---------------------------------------------------------------------------

def _get_health(bot_token: str, state: dict) -> dict:
    if not bot_token:
        return {"status": "not_configured", "bot_username": None, "retry_after": 0, "error": None}
    remaining = _remaining(state)
    if remaining > 0:
        return {"status": "rate_limited", "bot_username": state["bot_username"] or None, "retry_after": remaining, "error": None}
    if state["status"] == "rate_limited":
        state["status"] = "unknown"
    return {
        "status": state["status"],
        "bot_username": state["bot_username"] or None,
        "retry_after": 0,
        "error": state["last_error"] or None,
    }


def _send_health_check(bot_token: str, chat_config: str, state: dict) -> dict:
    """Send a real message to chat_config to test rate limits. Updates state in-place."""
    if not bot_token:
        return {"status": "not_configured", "bot_username": None, "retry_after": 0, "error": None}
    remaining = _remaining(state)
    if remaining > 0:
        return {"status": "rate_limited", "bot_username": state["bot_username"] or None, "retry_after": remaining, "error": None}
    if not chat_config or ":" not in chat_config:
        state["status"] = "error"
        state["last_error"] = "Chưa cấu hình Telegram Topics 'Nghiêm trọng' trong Cài đặt"
        return {"status": "error", "bot_username": None, "retry_after": 0, "error": state["last_error"]}

    ok, err = _send_now(bot_token, chat_config, state, "🔧 <b>ARO Dashboard</b> — Telegram API health check")
    return _get_health(bot_token, state) if ok else {
        "status": state["status"],
        "bot_username": state["bot_username"] or None,
        "retry_after": _remaining(state),
        "error": state["last_error"] or err,
    }


# Public health API
def get_telegram_health() -> dict:
    return _get_health(settings.telegram_bot_token, _primary)

def send_primary_health_check(tg_critical: str) -> dict:
    return _send_health_check(settings.telegram_bot_token, tg_critical, _primary)

def get_node_telegram_health(bot_token: str) -> dict:
    return _get_health(bot_token, _secondary)

def send_node_health_check(bot_token: str, tg_critical: str) -> dict:
    return _send_health_check(bot_token, tg_critical, _secondary)


# ---------------------------------------------------------------------------
# Core send function (shared by queue flush and health check)
# ---------------------------------------------------------------------------

def _send_now(bot_token: str, chat_config: str, state: dict, text: str) -> tuple[bool, str]:
    """Actually send a message. Updates state on 429/error."""
    parts = chat_config.strip().split(":", 1)
    if len(parts) != 2:
        return False, f"Định dạng sai (phải là chat_id:thread_id): {chat_config}"

    chat_id, thread_id = parts[0], parts[1]
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "message_thread_id": int(thread_id),
        "text": text,
        "parse_mode": "HTML",
    }
    try:
        r = requests.post(url, json=payload, timeout=10)
        if r.status_code == 200:
            state["last_error"] = ""
            if state["status"] != "rate_limited":
                state["status"] = "ok"
            return True, ""
        elif r.status_code == 429:
            retry_after = 60
            try:
                retry_after = r.json().get("parameters", {}).get("retry_after", 60)
            except Exception:
                pass
            _set_rate_limit(state, retry_after)
            state["last_error"] = ""
            logger.warning("Telegram 429 — backing off %ss", retry_after)
            return False, f"rate_limited retry_after={retry_after}"
        elif r.status_code == 401:
            state["status"] = "error"
            state["last_error"] = "Bot token không hợp lệ (401 Unauthorized)"
            return False, state["last_error"]
        else:
            try:
                err = r.json().get("description", r.text[:200])
            except Exception:
                err = r.text[:200]
            state["status"] = "error"
            state["last_error"] = f"HTTP {r.status_code}: {err}"
            logger.warning("Telegram error %s: %s", r.status_code, err)
            return False, state["last_error"]
    except Exception as exc:
        state["status"] = "error"
        state["last_error"] = str(exc)
        logger.error("Telegram send failed: %s", exc)
        return False, state["last_error"]


# ---------------------------------------------------------------------------
# Legacy direct-send (kept for backward compat; now wraps enqueue)
# Use enqueue_telegram_message for new call sites.
# ---------------------------------------------------------------------------

def send_telegram_message(chat_config: str, text: str) -> tuple[bool, str]:
    """Enqueue a message. Actual delivery happens on next flush cycle (~2 min)."""
    if not settings.telegram_bot_token:
        return False, "TELEGRAM_BOT_TOKEN chưa được cấu hình trong .env"
    if not chat_config:
        return False, "Chat config trống"
    enqueue_telegram_message(chat_config, text)
    return True, ""

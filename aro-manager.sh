#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ARO Manager - Unified Proxy + Watchdog Management Script v3.7.1
# ═══════════════════════════════════════════════════════════════
# Purpose: Complete management solution for ARO nodes with transparent
#          SOCKS5 proxy, kill-switch protection, and automated watchdog
# Author: Built for Adam's ARO DePIN infrastructure
# Based on: aro-proxy.sh v1.0.0 + aro-watchdog.sh v1.4.3
# Requirements: Ubuntu 24.04 / Debian 12, root access
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ───────────────────────────────────────────────────────────────
# CONSTANTS & GLOBAL VARIABLES
# ───────────────────────────────────────────────────────────────
SCRIPT_VERSION="3.10.1"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHOW_FOOTER_ON_EXIT=0

# Paths - Unified config directory
CONFIG_DIR="/etc/aro-manager"
PROXY_CONF_FILE="$CONFIG_DIR/proxy.conf"
WATCHDOG_CONF_FILE="$CONFIG_DIR/watchdog.conf"
REDSOCKS_CONF_FILE="$CONFIG_DIR/redsocks.conf"

# Binary paths
ARO_BINARY="/usr/bin/ARO"
WRAPPER_SCRIPT="/usr/local/bin/aro-launch"

# Service files
SYSTEMD_REDSOCKS_SERVICE="/etc/systemd/system/redsocks-aro.service"
SYSTEMD_WATCHDOG_SERVICE="/etc/systemd/system/aro-watchdog.service"

# Log files
MAIN_LOG="$SCRIPT_DIR/aro-manager.log"
WATCHDOG_LOG="$SCRIPT_DIR/aro-watchdog.log"
WRAPPER_LOG="/tmp/aro-wrapper.log"
DEBUG_LOG_DIR="$SCRIPT_DIR"   # Save debug log cùng folder với script

# iptables
IPTABLES_RULES_FILE="/etc/iptables/rules.v4"

# Runtime files
PID_FILE="/tmp/aro_watchdog_manager.pid"
STATE_FILE="/tmp/aro_watchdog_state_manager"
UPDATE_RESTART_FLAG="aro_update_restart"
MAINTENANCE_FLAG="/tmp/aro_maintenance"
MAINTENANCE_EXPIRE_MINS=60    # Tự hết hạn sau 60 phút

# Proxy settings
REDSOCKS_PORT=12345
PROXY_HOST=""
PROXY_PORT=""
PROXY_USER=""
PROXY_PASS=""
USE_PROXY=1    # 1 = dùng proxy (default), 0 = no-proxy mode

# Telegram fallback endpoint (Cloudflare Worker — dùng khi api.telegram.org bị chặn)
TG_API_FALLBACK_URL="https://tele-api.nauthnael.workers.dev"

# ── Watchdog timing ──────────────────────────────────────────────
CHECK_INTERVAL=60           # Chu kỳ watchdog: 60s - giảm 50% IO, vẫn đủ responsive

# ── Periodic restart ─────────────────────────────────────────────
PERIODIC_RESTART_MIN_MINS=54   # Minimum minutes between periodic restarts
PERIODIC_RESTART_MAX_MINS=120  # Maximum minutes between periodic restarts
PERIODIC_RESTART_WAIT_MINS=2   # Minutes to wait (ARO killed) before restarting

# ── Periodic VPS reboot ──────────────────────────────────────────
PERIODIC_VPS_REBOOT_COUNT=6        # Số lần reboot VPS mỗi ngày
PERIODIC_VPS_REBOOT_ENABLED=true   # Bật/tắt reboot VPS định kỳ
LOG_STALE_MINUTES=10        # Log không update >10m = ARO frozen hoặc crash
STALE_RESTART_MINUTES=5       # Nếu log stale kéo dài >5m → force restart dù không có disconnect
DISCONNECT_ALERT_MINUTES=15 # Disconnected >15m mới trigger restart (tránh false positive)
STARTUP_TIMEOUT=120         # Chờ app init (VNC/X11) trước khi check log
GIVE_UP_RETRY_MINS=30       # Sau give-up, tự retry sau N phút
RESET_STABLE_HOURS=2        # Sau 2h stable liên tục, reset retry counter về 0
MAX_RETRIES=5               # 5 lần retry với backoff trước khi give up
BACKOFF_TIMES="0 0 30 60 120"  # retry 1&2: ngay lập tức; 3: 30s; 4: 60s; 5: 120s
DAILY_REPORT_HOUR=7         # Giờ gửi daily report (0–23, không dùng leading zero)
DAILY_REPORT_ENABLED=true   # true/false — tắt/bật báo cáo hằng ngày qua Telegram

# Proxy connectivity check
PROXY_CHECK_INTERVAL=600          # real proxy test every 10 minutes - giảm 50% outbound curl
PROXY_DOWN_NOTIFY_MAX=15          # max Telegram alerts per hour khi proxy server lỗi
PROXY_DOWN_NOTIFY_INTERVAL=$(( 3600 / PROXY_DOWN_NOTIFY_MAX ))

# IP leak detection
IP_LEAK_CHECK_INTERVAL=300        # compare real IP vs exit IP every 5 minutes
IP_LEAK_MAX_RECOVERY=2            # auto-recovery attempts before giving up

# ── Stuck-connecting watchdog ───────────────────────────────────
STUCK_THRESHOLD_MINUTES=10  # tray=NoInternet >10m = stuck thực sự (không phải fluctuation)
TRAY_UNKNOWN_THRESHOLD_MINUTES=15  # tray=unknown >15m khi log fresh → restart ARO
CONNECTING_GRACE_SECS=600   # Sau launch, cho ARO 10 phút để connect trước khi coi là stuck
CONNECTING_WAIT_SECS=600    # Chờ tối đa 10 phút cho ARO reconnect sau restart
CONNECTING_POLL_INTERVAL=30 # Poll tray state mỗi 30s
PROXY_RESTART_TIMEOUT_SECS=60 # Chờ tối đa 60s cho redsocks restart functional
REDSOCKS_QUEUE_THRESHOLD=500  # recv-Q >500 bytes = redsocks backpressure, coi là hung
                             # (empirically: healthy redsocks thường <100)

# Telegram
TRAY_STATUS="unknown"              # Trạng thái thực của ARO app (từ tray state log)
TRAY_STATUS_TS=0                   # Epoch khi TRAY_STATUS được set
TG_ENABLED=1                       # 1 = bật Telegram notify, 0 = tắt hoàn toàn
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_RETRY_AFTER_FILE="/tmp/aro_tg_retry_after"  # Lưu timestamp hết hạn rate limit
TG_NOTIFY_COOLDOWN_MINS=0          # Min phút giữa 2 tin nhắn bất kỳ (0 = không giới hạn)

# Throttle states
_last_proxy_down_notify=0
_last_pre_restart_notify=0
_last_known_exit_ip=""
_grace_period_last_log=0
_nointernet_last_log=0
_tray_unknown_last_log=0
_unbound_last_log=0
PRE_RESTART_NOTIFY_COOLDOWN=300   # Tối thiểu 5 phút giữa 2 lần gửi pre-restart notification
_next_periodic_restart=0          # Epoch time for next scheduled periodic ARO restart
_next_periodic_vps_reboot=0       # Epoch time for next scheduled periodic VPS reboot

# Guard flags
_WAIT_FOR_ARO_ONLINE_RUNNING=false

# Runtime
CURRENT_USER=$(whoami)
CRD_USER=""
EFFECTIVE_USER=""
EFFECTIVE_HOME=""
ARO_LOG_DIR=""
ARO_DATA_DIR=""
HOSTNAME=$(hostname)

# Environment detection
ENV_TYPE=""           # "crd" | "lxc_vnc" | "unknown" — set by detect_environment()
DISPLAY_NUM=":20"     # overridden by detect_desktop_user()
XAUTHORITY_PATH=""    # overridden by detect_desktop_user()
export LIBGL_ALWAYS_SOFTWARE="1"

# Deploy config
REMOTE_MODE=""          # "vnc" | "crd" — chọn lúc deploy
VNC_PASS=""             # VNC password (bắt buộc khi remote_mode=vnc)
UBUNTU_SSH_KEY=""       # SSH public key (bắt buộc)
VNC_DISPLAY=":1"
VNC_PORT="5901"
VNC_RESOLUTION="1280x800"
VNC_DEPTH="24"


# ───────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ───────────────────────────────────────────────────────────────

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$MAIN_LOG"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }

watchdog_log() {
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg" >> "$WATCHDOG_LOG"
}

show_banner() {
    cat << EOF
╔═══════════════════════════════════════════════════════════════╗
║         ARO Manager - Complete Node Management v${SCRIPT_VERSION}         ║
║      Transparent Proxy + Watchdog + Kill-Switch Protection    ║
╠═══════════════════════════════════════════════════════════════╣
║  GitHub: https://github.com/nauthnael/aro-node-manager        ║
║  X/Twitter: https://x.com/nauthnael                           ║
╚═══════════════════════════════════════════════════════════════╝
EOF
}

show_footer() {
    cat << 'EOF'
─────────────────────────────────────────────────────────────
 Thanks for using ARO Manager! Follow @nauthnael on X/Twitter
 for updates, tips and new scripts: https://x.com/nauthnael
─────────────────────────────────────────────────────────────
EOF
}

trap '[ "$SHOW_FOOTER_ON_EXIT" = "1" ] && show_footer' EXIT

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo ""
        echo "Please run: sudo bash $SCRIPT_NAME $*"
        echo ""
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu)
                if [[ "$VERSION_ID" != "24.04" ]]; then
                    log_warn "Tested on Ubuntu 24.04, you have $VERSION_ID"
                fi
                ;;
            debian)
                if [[ "$VERSION_ID" != "12" ]]; then
                    log_warn "Tested on Debian 12, you have $VERSION_ID"
                fi
                ;;
            *)
                log_warn "Unsupported OS: $ID. Script may not work correctly."
                ;;
        esac
    else
        log_warn "Cannot detect OS version"
    fi
}

detect_environment() {
    # Detect LXC container
    local virt; virt=$(systemd-detect-virt --container 2>/dev/null || true)
    local is_lxc=0
    [[ "$virt" == "lxc" ]] && is_lxc=1
    # Secondary check: /proc/1/environ (works even without systemd-detect-virt)
    if [[ $is_lxc -eq 0 ]]; then
        { strings /proc/1/environ 2>/dev/null | grep -q '^container=lxc$' && is_lxc=1; } || true
    fi

    # Detect TigerVNC (Xtigervnc or Xvnc process)
    local is_vnc=0
    { pgrep -x Xtigervnc >/dev/null 2>&1 && is_vnc=1; } || true
    { pgrep -x Xvnc      >/dev/null 2>&1 && is_vnc=1; } || true

    if [[ $is_lxc -eq 1 ]] && [[ $is_vnc -eq 1 ]]; then
        ENV_TYPE="lxc_vnc"
    else
        ENV_TYPE="crd"   # Chrome Remote Desktop (or bare-metal fallback)
    fi

    log_info "Environment: $ENV_TYPE (LXC=${is_lxc}, VNC=${is_vnc})"
}

detect_vnc_user() {
    # Find owner of the TigerVNC/Xvnc process
    local user=""
    user=$({ ps aux | grep -E '[X](tigervnc|vnc)' 2>/dev/null || true; } \
        | awk '{print $1}' | head -n1)

    if [[ -z "$user" ]]; then
        # Fallback: check common non-root users
        for u in ubuntu adam; do
            if id "$u" &>/dev/null; then user="$u"; break; fi
        done
    fi

    if [[ -z "$user" ]]; then
        log_error "Cannot detect VNC user. TigerVNC/Xvnc not running?"
        echo ""
        echo "Please start TigerVNC or check that the VNC server is running."
        exit 1
    fi

    # Lấy full command line của VNC process (ps -eo args = chỉ cột COMMAND, không có TIME)
    local vnc_cmd=""
    local retries=0
    while [[ -z "$vnc_cmd" ]] && [[ $retries -lt 6 ]]; do
        vnc_cmd=$(ps -eo args 2>/dev/null \
            | { grep -E '^/usr/(bin/)?X(tigervnc|vnc|org)' 2>/dev/null || true; } \
            | head -n1 || true)
        if [[ -z "$vnc_cmd" ]]; then
            [[ $retries -eq 0 ]] && log_info "VNC process not found yet, waiting..."
            sleep 5
            retries=$(( retries + 1 ))
        fi
    done

    if [[ -z "$vnc_cmd" ]]; then
        log_error "VNC process not found after $((retries * 5))s — using fallback DISPLAY=:1"
    fi

    local vnc_display=""
    vnc_display=$(echo "$vnc_cmd" | grep -oP '(?<=\s):\d+(?=\s|$)' | head -n1 || true)
    DISPLAY_NUM="${vnc_display:-:1}"

    CRD_USER="$user"
    EFFECTIVE_USER="$user"
    EFFECTIVE_HOME=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    if [[ -z "$EFFECTIVE_HOME" ]]; then
        # Fallback cho trường hợp getent không có (container minimal)
        EFFECTIVE_HOME="/home/$user"
        [[ "$user" == "root" ]] && EFFECTIVE_HOME="/root"
    fi
    ARO_LOG_DIR="$EFFECTIVE_HOME/.local/share/com.aro.ARONetwork/logs"
    ARO_DATA_DIR="$EFFECTIVE_HOME/.local/share/com.aro.ARONetwork"

    # Extract XAUTHORITY từ flag -auth của process Xtigervnc
    XAUTHORITY_PATH=$(echo "$vnc_cmd" | grep -oP '(?<=-auth )\S+' | head -n1 || true)
    # Fallback: ~/.Xauthority (TigerVNC default, cũng là path phổ biến nhất)
    if [[ -z "$XAUTHORITY_PATH" ]] || [[ ! -f "$XAUTHORITY_PATH" ]]; then
        XAUTHORITY_PATH="$EFFECTIVE_HOME/.Xauthority"
    fi

    export DISPLAY="$DISPLAY_NUM"
    export XAUTHORITY="$XAUTHORITY_PATH"

    log_info "Detected VNC user: $CRD_USER (home: $EFFECTIVE_HOME)"
    log_info "VNC display: $DISPLAY_NUM | XAUTHORITY: $XAUTHORITY_PATH"
}

detect_crd_user() {
    # Detect Chrome Remote Desktop user
    local user
    user=$({ ps aux | grep '[c]hrome-remote-desktop' 2>/dev/null || true; } \
        | awk '{print $1}' | head -n1)

    if [[ -z "$user" ]]; then
        # Fallback: check common users
        for u in ubuntu adam; do
            if id "$u" &>/dev/null; then
                user="$u"
                break
            fi
        done
    fi

    if [[ -z "$user" ]]; then
        log_error "Cannot detect CRD user. Chrome Remote Desktop not running?"
        echo ""
        echo "Please start Chrome Remote Desktop or specify user manually."
        exit 1
    fi

    DISPLAY_NUM=":20"  # CRD default display

    CRD_USER="$user"
    EFFECTIVE_USER="$user"
    EFFECTIVE_HOME=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    if [[ -z "$EFFECTIVE_HOME" ]]; then
        # Fallback cho trường hợp getent không có (container minimal)
        EFFECTIVE_HOME="/home/$user"
        [[ "$user" == "root" ]] && EFFECTIVE_HOME="/root"
    fi
    ARO_LOG_DIR="$EFFECTIVE_HOME/.local/share/com.aro.ARONetwork/logs"
    ARO_DATA_DIR="$EFFECTIVE_HOME/.local/share/com.aro.ARONetwork"
    XAUTHORITY_PATH="$EFFECTIVE_HOME/.Xauthority"

    export DISPLAY="$DISPLAY_NUM"
    export XAUTHORITY="$XAUTHORITY_PATH"

    log_info "Detected CRD user: $CRD_USER (home: $EFFECTIVE_HOME)"
}

# detect_desktop_user: auto-dispatches based on ENV_TYPE.
# Always call detect_environment() first (done inside this function).
detect_desktop_user() {
    # Nếu ENV_TYPE đã được load từ config → dùng luôn, không detect lại
    # Chỉ gọi detect_environment() khi ENV_TYPE rỗng (lần đầu cài đặt)
    if [[ -z "$ENV_TYPE" ]]; then
        detect_environment
    fi
    case "$ENV_TYPE" in
        lxc_vnc) detect_vnc_user ;;
        *)       detect_crd_user ;;
    esac
}

parse_proxy_string() {
    local proxy_str="$1"
    
    # No-proxy mode: không cần parse
    if [[ "$USE_PROXY" -eq 0 ]]; then
        PROXY_HOST=""
        PROXY_PORT=""
        PROXY_USER=""
        PROXY_PASS=""
        log_info "No-proxy mode: skipping proxy string parse"
        return 0
    fi
    
    # Format: host:port:user:pass
    if [[ ! "$proxy_str" =~ ^[^:]+:[0-9]+:[^:]+:.+$ ]]; then
        log_error "Invalid proxy format. Expected: host:port:username:password"
        echo ""
        echo "Example: snvn8.tunproxy.com:44228:3K0i:66aMKG"
        echo ""
        exit 1
    fi
    
    IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$proxy_str"
    
    log_info "Proxy parsed: $PROXY_HOST:$PROXY_PORT (user: $PROXY_USER)"
}

# ───────────────────────────────────────────────────────────────
# TELEGRAM FUNCTIONS (from watchdog)
# ───────────────────────────────────────────────────────────────

send_telegram() {
    local message="$1"

    # Check kill switch — đọc từ state file để có hiệu lực ngay (không cần restart watchdog)
    if [[ "$(state_get 'tg_enabled' "${TG_ENABLED:-1}")" == "0" ]]; then
        return 0
    fi

    if [[ -z "$TG_BOT_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
        return 0
    fi

    # Per-node cooldown (nếu TG_NOTIFY_COOLDOWN_MINS > 0)
    local _cooldown_mins; _cooldown_mins=$(state_get "tg_notify_cooldown_mins" "${TG_NOTIFY_COOLDOWN_MINS:-0}")
    if [[ "$_cooldown_mins" =~ ^[0-9]+$ ]] && [[ "$_cooldown_mins" -gt 0 ]]; then
        local _last_sent; _last_sent=$(state_get "tg_last_sent" "0")
        local _now_cd; _now_cd=$(date +%s)
        local _cooldown_secs=$(( _cooldown_mins * 60 ))
        if (( _now_cd - _last_sent < _cooldown_secs )); then
            local _remaining=$(( _cooldown_secs - (_now_cd - _last_sent) ))
            watchdog_log "TG cooldown (${_cooldown_mins}m) — skipping (retry in ${_remaining}s)"
            return 0
        fi
        state_set "tg_last_sent" "$_now_cd"
    fi

    # Check global rate limit backoff
    if [[ -f "$TG_RETRY_AFTER_FILE" ]]; then
        local retry_until
        retry_until=$(cat "$TG_RETRY_AFTER_FILE" 2>/dev/null || echo 0)
        local now_ts; now_ts=$(date +%s)
        if ! [[ "$retry_until" =~ ^[0-9]+$ ]]; then
            rm -f "$TG_RETRY_AFTER_FILE"
        elif [[ $now_ts -lt $retry_until ]]; then
            local remaining=$(( retry_until - now_ts ))
            watchdog_log "Telegram rate-limited - skipping (retry_after: ${remaining}s remaining)"
            return 0
        else
            rm -f "$TG_RETRY_AFTER_FILE"
        fi
    fi

    local escaped_msg
    escaped_msg=$(echo "$message" | sed 's/"/\\"/g')
    local payload="{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":\"${escaped_msg}\",\"parse_mode\":\"HTML\"}"

    # Hướng 1: Direct - api.telegram.org (đọc response body để lấy retry_after)
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 10 2>/dev/null || echo -e "\n000")

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    if [[ "$http_code" == "200" ]]; then
        return 0
    fi

    # Xử lý 429: đọc retry_after và lưu vào file
    if [[ "$http_code" == "429" ]]; then
        local retry_after
        retry_after=$(echo "$body" | grep -o '"retry_after":[0-9]*' | grep -o '[0-9]*' || echo 60)
        [[ -z "$retry_after" || "$retry_after" -lt 1 ]] && retry_after=60
        local retry_until=$(( $(date +%s) + retry_after ))
        echo "$retry_until" > "$TG_RETRY_AFTER_FILE"
        watchdog_log "Telegram rate limited (429) - backing off for ${retry_after}s (until $(date -d @$retry_until '+%H:%M:%S' 2>/dev/null || date -r $retry_until '+%H:%M:%S' 2>/dev/null || echo $retry_until))"
        return 0  # KHÔNG gọi fallback khi bị rate limit
    fi

    watchdog_log "WARNING: Telegram direct failed (HTTP $http_code) - trying fallback..."

    # Hướng 2: Fallback - chỉ khi lỗi thật (không phải 429)
    local fallback_url="${TG_API_FALLBACK_URL:-https://tele-api.nauthnael.workers.dev}"
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${fallback_url}/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 10 2>/dev/null || echo -e "\n000")

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    if [[ "$http_code" == "200" ]]; then
        watchdog_log "Telegram sent via fallback"
        return 0
    fi

    # Fallback cũng 429
    if [[ "$http_code" == "429" ]]; then
        local retry_after
        retry_after=$(echo "$body" | grep -o '"retry_after":[0-9]*' | grep -o '[0-9]*' || echo 60)
        [[ -z "$retry_after" || "$retry_after" -lt 1 ]] && retry_after=60
        local retry_until=$(( $(date +%s) + retry_after ))
        echo "$retry_until" > "$TG_RETRY_AFTER_FILE"
        watchdog_log "Telegram fallback also rate limited (429) - backing off for ${retry_after}s"
        return 0
    fi

    watchdog_log "WARNING: Telegram fallback also failed (HTTP $http_code)"
    return 1
}

validate_telegram_credentials() {
    local token_invalid=0
    local chatid_invalid=0
    local token_reason=""
    local chatid_reason=""
    
    local placeholders=("TOKEN_CUA_BAN" "YOUR_TOKEN" "BOT_TOKEN" "YOUR_BOT_TOKEN" "ID_CUA_BAN" "YOUR_CHAT_ID" "CHATID" "YOUR_ID" "TOKEN" "CHAT_ID")
    
    if [ -n "$TG_BOT_TOKEN" ]; then
        local t_upper=$(echo "$TG_BOT_TOKEN" | tr '[:lower:]' '[:upper:]')
        for p in "${placeholders[@]}"; do
            if [ "$t_upper" = "$p" ]; then
                token_invalid=1
                token_reason="looks like a placeholder"
                break
            fi
        done
        if [ "$token_invalid" -eq 0 ] && [[ ! "$TG_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            token_invalid=1
            token_reason="invalid format (expected format: 123456789:ABCdef...)"
        fi
    fi
    
    if [ -n "$TG_CHAT_ID" ]; then
        local c_upper=$(echo "$TG_CHAT_ID" | tr '[:lower:]' '[:upper:]')
        for p in "${placeholders[@]}"; do
            if [ "$c_upper" = "$p" ]; then
                chatid_invalid=1
                chatid_reason="looks like a placeholder"
                break
            fi
        done
        if [ "$chatid_invalid" -eq 0 ] && [[ ! "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
            chatid_invalid=1
            chatid_reason="invalid format (expected: numeric ID like 123456789 or -100123456789)"
        fi
    fi
    
    if [ "$token_invalid" -eq 1 ] || [ "$chatid_invalid" -eq 1 ]; then
        if [ "$token_invalid" -eq 1 ]; then
            echo ""
            echo "  ⚠️  WARNING: Telegram Bot Token appears invalid"
            echo "      Value:  \"$TG_BOT_TOKEN\""
            echo "      Reason: $token_reason"
        fi
        if [ "$chatid_invalid" -eq 1 ]; then
            echo ""
            echo "  ⚠️  WARNING: Telegram Chat ID appears invalid"
            echo "      Value:  \"$TG_CHAT_ID\""
            echo "      Reason: $chatid_reason"
        fi
        
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        echo "  → Telegram notifications disabled."
    fi
}

# ───────────────────────────────────────────────────────────────
# PROXY INSTALLATION FUNCTIONS
# ───────────────────────────────────────────────────────────────

install_packages() {
    log_info "Installing required packages..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -qq
    
    if [[ "$USE_PROXY" -eq 1 ]]; then
        apt-get install -y -qq \
            redsocks \
            iptables \
            iptables-persistent \
            netfilter-persistent \
            netcat-openbsd \
            curl \
            psmisc \
            > /dev/null 2>&1
    else
        # No-proxy mode: không cần redsocks và iptables-persistent
        apt-get install -y -qq \
            iptables \
            netcat-openbsd \
            curl \
            psmisc \
            > /dev/null 2>&1
    fi
    
    log_success "Packages installed"
}

create_config_directory() {
    log_info "Creating configuration directory..."
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
}

save_proxy_config() {
    log_info "Saving proxy configuration..."
    
    cat > "$PROXY_CONF_FILE" << EOF
# ARO Manager - Proxy Configuration
# Generated: $(date)

PROXY_HOST="$PROXY_HOST"
PROXY_PORT="$PROXY_PORT"
PROXY_USER="$PROXY_USER"
PROXY_PASS="$PROXY_PASS"
CRD_USER="$CRD_USER"
REDSOCKS_PORT="$REDSOCKS_PORT"
ENV_TYPE="$ENV_TYPE"
USE_PROXY=$USE_PROXY
EOF
    
    chmod 600 "$PROXY_CONF_FILE"
    log_success "Proxy config saved to $PROXY_CONF_FILE"
}

save_watchdog_config() {
    log_info "Saving watchdog configuration..."
    
    cat > "$WATCHDOG_CONF_FILE" << EOF
# ARO Manager - Watchdog Configuration
# Generated: $(date)

# === Telegram ===
TG_ENABLED=$TG_ENABLED
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
TG_API_FALLBACK_URL="$TG_API_FALLBACK_URL"
TG_NOTIFY_COOLDOWN_MINS=${TG_NOTIFY_COOLDOWN_MINS:-0}

# === Timing ===
CHECK_INTERVAL=$CHECK_INTERVAL
LOG_STALE_MINUTES=$LOG_STALE_MINUTES
STALE_RESTART_MINUTES=$STALE_RESTART_MINUTES
DISCONNECT_ALERT_MINUTES=$DISCONNECT_ALERT_MINUTES
STARTUP_TIMEOUT=$STARTUP_TIMEOUT
RESET_STABLE_HOURS=$RESET_STABLE_HOURS
CONNECTING_GRACE_SECS=$CONNECTING_GRACE_SECS
CONNECTING_WAIT_SECS=$CONNECTING_WAIT_SECS
STUCK_THRESHOLD_MINUTES=$STUCK_THRESHOLD_MINUTES
TRAY_UNKNOWN_THRESHOLD_MINUTES=$TRAY_UNKNOWN_THRESHOLD_MINUTES
REDSOCKS_QUEUE_THRESHOLD=$REDSOCKS_QUEUE_THRESHOLD
PROXY_RESTART_TIMEOUT_SECS=$PROXY_RESTART_TIMEOUT_SECS

# === Restart Policy ===
MAX_RETRIES=$MAX_RETRIES
BACKOFF_TIMES="$BACKOFF_TIMES"

# === Daily Report ===
DAILY_REPORT_HOUR=$DAILY_REPORT_HOUR
DAILY_REPORT_ENABLED=$DAILY_REPORT_ENABLED

# === ARO Binary ===
ARO_BINARY="$WRAPPER_SCRIPT"

# === ARO Run User ===
ARO_RUN_USER="$CRD_USER"

# === Dashboard ===
DASHBOARD_ENABLED=${DASHBOARD_ENABLED:-false}
DASHBOARD_URL="${DASHBOARD_URL:-}"
DASHBOARD_API_KEY="${DASHBOARD_API_KEY:-}"
EOF
    
    chmod 600 "$WATCHDOG_CONF_FILE"
    log_success "Watchdog config saved to $WATCHDOG_CONF_FILE"
}

load_configs() {
    if [[ -f "$PROXY_CONF_FILE" ]]; then
        source "$PROXY_CONF_FILE"
    fi

    if [[ -f "$WATCHDOG_CONF_FILE" ]]; then
        source "$WATCHDOG_CONF_FILE"
    fi

    # Dashboard defaults (có thể bị override bởi watchdog.conf)
    DASHBOARD_ENABLED="${DASHBOARD_ENABLED:-false}"
    DASHBOARD_URL="${DASHBOARD_URL:-}"
    DASHBOARD_API_KEY="${DASHBOARD_API_KEY:-}"
}

create_redsocks_config() {
    log_info "Creating redsocks configuration..."

    # daemon=off → systemd manages the process lifecycle (Type=simple)
    cat > "$REDSOCKS_CONF_FILE" << EOF
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = off;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = $REDSOCKS_PORT;

    ip = $PROXY_HOST;
    port = $PROXY_PORT;
    type = socks5;

    login = "$PROXY_USER";
    password = "$PROXY_PASS";
}
EOF

    chmod 600 "$REDSOCKS_CONF_FILE"
    log_success "Redsocks config created"
}

create_redsocks_service() {
    log_info "Creating redsocks systemd service..."

    # Detect redsocks binary (path differs across distros/versions)
    local redsocks_bin=""
    if command -v redsocks >/dev/null 2>&1; then
        redsocks_bin=$(command -v redsocks)
    elif [[ -x /usr/sbin/redsocks ]]; then
        redsocks_bin="/usr/sbin/redsocks"
    elif [[ -x /usr/bin/redsocks ]]; then
        redsocks_bin="/usr/bin/redsocks"
    else
        log_error "redsocks binary not found after installation!"
        exit 1
    fi

    log_info "Redsocks binary: $redsocks_bin"

    # Type=simple + daemon=off → systemd tracks PID directly, no forking issues
    cat > "$SYSTEMD_REDSOCKS_SERVICE" << EOF
[Unit]
Description=Redsocks SOCKS5 Transparent Proxy for ARO
Documentation=https://github.com/darkk/redsocks
After=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'ss -tlnp | grep -q ":${REDSOCKS_PORT} " && fuser -k ${REDSOCKS_PORT}/tcp 2>/dev/null || true'
ExecStart=$redsocks_bin -c $REDSOCKS_CONF_FILE
ExecStartPost=/usr/local/sbin/aro-restore-iptables
Restart=on-failure
RestartSec=10s

# Security hardening
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/run /var/log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "Redsocks service created (binary: $redsocks_bin)"
}

setup_iptables_rules() {
    log_info "Setting up iptables rules with kill-switch..."
    
    # Get proxy server IP
    local proxy_ip
    proxy_ip=$(getent hosts "$PROXY_HOST" | awk '{ print $1 }' | head -n1)
    
    if [[ -z "$proxy_ip" ]]; then
        # Fallback: dùng dig
        proxy_ip=$(dig +short "$PROXY_HOST" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
    fi
    
    if [[ -z "$proxy_ip" ]] || [[ ! "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Cannot resolve proxy hostname '$PROXY_HOST' to IP. Setup aborted."
        log_error "Check DNS or provide IP directly in config."
        return 1
    fi
    
    log_info "Proxy IP: $proxy_ip"
    
    # Create custom chain for ARO traffic
    iptables -t nat -N ARO_PROXY 2>/dev/null || iptables -t nat -F ARO_PROXY
    
    # Bypass rules
    iptables -t nat -A ARO_PROXY -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A ARO_PROXY -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A ARO_PROXY -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A ARO_PROXY -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A ARO_PROXY -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A ARO_PROXY -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A ARO_PROXY -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A ARO_PROXY -d 240.0.0.0/4 -j RETURN
    
    # Bypass proxy server itself
    if [[ "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        iptables -t nat -A ARO_PROXY -d "$proxy_ip" -j RETURN
    fi
    
    # Redirect all TCP traffic to redsocks
    iptables -t nat -A ARO_PROXY -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"
    
    # Apply chain to CRD user
    iptables -t nat -D OUTPUT -m owner --uid-owner "$CRD_USER" -j ARO_PROXY 2>/dev/null || true
    iptables -t nat -A OUTPUT -m owner --uid-owner "$CRD_USER" -j ARO_PROXY
    
    # KILL-SWITCH: Block IPv6
    ip6tables -D OUTPUT -m owner --uid-owner "$CRD_USER" -j REJECT 2>/dev/null || true
    ip6tables -A OUTPUT -m owner --uid-owner "$CRD_USER" -j REJECT
    
    log_success "iptables rules applied"
}

persist_iptables_rules() {
    log_info "Persisting iptables rules..."

    mkdir -p /etc/iptables

    iptables-save > "$IPTABLES_RULES_FILE"
    ip6tables-save > /etc/iptables/rules.v6

    systemctl enable netfilter-persistent >/dev/null 2>&1 || true

    log_success "iptables rules persisted"
}

# Creates /usr/local/sbin/aro-restore-iptables — a standalone script that
# redsocks-aro.service calls via ExecStartPost. Must live outside /root/
# because ProtectHome=yes in the service makes /root inaccessible.
create_iptables_restore_script() {
    local restore_script="/usr/local/sbin/aro-restore-iptables"

    cat > "$restore_script" << 'RESTORE_EOF'
#!/bin/bash
# Auto-generated by aro-manager. Do not edit manually.
# Re-applies iptables ARO_PROXY kill-switch rules.
# Called by redsocks-aro.service ExecStartPost on every redsocks start.
set -euo pipefail

PROXY_CONF="/etc/aro-manager/proxy.conf"
[ -f "$PROXY_CONF" ] || exit 0

# shellcheck source=/dev/null
. "$PROXY_CONF"

[ -n "${PROXY_HOST:-}" ] || exit 0
[ -n "${REDSOCKS_PORT:-}" ] || exit 0
[ -n "${CRD_USER:-}" ] || exit 0

proxy_ip=$(getent hosts "$PROXY_HOST" | awk '{ print $1 }' | head -n1)
if [[ -z "$proxy_ip" ]] || [[ ! "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "aro-restore-iptables: cannot resolve $PROXY_HOST, skipping" >&2
    exit 0
fi

iptables -t nat -N ARO_PROXY 2>/dev/null || iptables -t nat -F ARO_PROXY
iptables -t nat -A ARO_PROXY -d 0.0.0.0/8   -j RETURN
iptables -t nat -A ARO_PROXY -d 10.0.0.0/8  -j RETURN
iptables -t nat -A ARO_PROXY -d 127.0.0.0/8 -j RETURN
iptables -t nat -A ARO_PROXY -d 169.254.0.0/16 -j RETURN
iptables -t nat -A ARO_PROXY -d 172.16.0.0/12  -j RETURN
iptables -t nat -A ARO_PROXY -d 192.168.0.0/16 -j RETURN
iptables -t nat -A ARO_PROXY -d 224.0.0.0/4 -j RETURN
iptables -t nat -A ARO_PROXY -d 240.0.0.0/4 -j RETURN
iptables -t nat -A ARO_PROXY -d "$proxy_ip" -j RETURN
iptables -t nat -A ARO_PROXY -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"
iptables -t nat -D OUTPUT -m owner --uid-owner "$CRD_USER" -j ARO_PROXY 2>/dev/null || true
iptables -t nat -A OUTPUT -m owner --uid-owner "$CRD_USER" -j ARO_PROXY
ip6tables -D OUTPUT -m owner --uid-owner "$CRD_USER" -j REJECT 2>/dev/null || true
ip6tables -A OUTPUT -m owner --uid-owner "$CRD_USER" -j REJECT

echo "aro-restore-iptables: ARO_PROXY chain applied (user=$CRD_USER proxy=$proxy_ip:$REDSOCKS_PORT)"
RESTORE_EOF

    chmod +x "$restore_script"
    log_success "iptables restore script created: $restore_script"
}

verify_wrapper_script() {
    local wrapper="$WRAPPER_SCRIPT"
    [[ -f "$wrapper.new" ]] && wrapper="$wrapper.new"
    
    # 1. File tồn tại và executable
    if [[ ! -x "$wrapper" ]]; then
        log_error "Wrapper not found or not executable: $wrapper"
        return 1
    fi
    
    # 2. Shebang hợp lệ
    if ! head -1 "$wrapper" | grep -q "^#!/"; then
        log_error "Wrapper missing shebang"
        return 1
    fi
    
    # 3. Bash syntax check
    if ! bash -n "$wrapper" 2>/dev/null; then
        log_error "Wrapper has syntax errors"
        return 1
    fi

    # 4. Các thành phần bắt buộc — phân biệt no-proxy vs proxy wrapper
    if ! grep -q "redsocks-aro" "$wrapper" 2>/dev/null; then
        # No-proxy wrapper: chỉ kiểm tra pattern tối thiểu
        local noproxy_checks=("REAL_ARO" 'exec "$REAL_ARO"')
        for check in "${noproxy_checks[@]}"; do
            if ! grep -q "$check" "$wrapper" 2>/dev/null; then
                log_error "No-proxy wrapper missing required component: $check"
                return 1
            fi
        done
    else
        # Proxy wrapper: kiểm tra đầy đủ
        local checks=("redsocks-aro" "ss -tlnp" "REDSOCKS_PORT" "REAL_ARO" 'exec "$REAL_ARO"')
        for check in "${checks[@]}"; do
            if ! grep -q "$check" "$wrapper" 2>/dev/null; then
                log_error "Wrapper missing required component: $check"
                return 1
            fi
        done
    fi

    return 0
}

create_wrapper_script_no_proxy() {
    log_info "Creating ARO launch wrapper (no-proxy mode)..."
    
    # Backup existing wrapper nếu có
    if [[ -f "$WRAPPER_SCRIPT" ]]; then
        cp "$WRAPPER_SCRIPT" "${WRAPPER_SCRIPT}.bak"
        log_info "Backed up existing wrapper to ${WRAPPER_SCRIPT}.bak"
    fi
    
    local tmp_wrapper="${WRAPPER_SCRIPT}.new"
    
    cat > "$tmp_wrapper" << 'EOF'
#!/bin/bash
# ARO Manager - Launch Wrapper (No-Proxy Mode)
# Direct launch without proxy protection

REAL_ARO="/usr/bin/ARO"
LOG="/tmp/aro-wrapper.log"

log_msg() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# Check ARO binary exists
if [[ ! -x "$REAL_ARO" ]]; then
    log_msg "ERROR: ARO binary not found at $REAL_ARO"
    exit 1
fi

log_msg "No-proxy mode: launching ARO directly..."
exec "$REAL_ARO" "$@"
EOF
    
    chmod +x "$tmp_wrapper"
    
    if bash -n "$tmp_wrapper" 2>/dev/null && grep -q 'exec "$REAL_ARO"' "$tmp_wrapper"; then
        mv "$tmp_wrapper" "$WRAPPER_SCRIPT"
        log_success "No-proxy wrapper created at $WRAPPER_SCRIPT"
    else
        rm -f "$tmp_wrapper"
        log_error "No-proxy wrapper failed verification"
        return 1
    fi
}

create_wrapper_script() {
    log_info "Creating ARO launch wrapper with proxy checks..."
    
    # Backup existing wrapper nếu có
    if [[ -f "$WRAPPER_SCRIPT" ]]; then
        local backup="${WRAPPER_SCRIPT}.bak"
        cp "$WRAPPER_SCRIPT" "$backup"
        log_info "Backed up existing wrapper to $backup"
    fi
    
    # Ghi ra file tạm trước
    local tmp_wrapper="${WRAPPER_SCRIPT}.new"
    cat > "$tmp_wrapper" << 'EOF'
#!/bin/bash
# ARO Manager - Launch Wrapper with Proxy Protection
# This wrapper ensures ARO only runs when proxy is healthy

REAL_ARO="/usr/bin/ARO"
LOG="/tmp/aro-wrapper.log"
REDSOCKS_PORT=$(grep '^REDSOCKS_PORT=' /etc/aro-manager/proxy.conf 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"   # fallback nếu config không có

log_msg() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# Check 1: Is redsocks service running?
if ! systemctl is-active --quiet redsocks-aro; then
    log_msg "CRITICAL: redsocks-aro.service is NOT running!"
    log_msg "ARO launch BLOCKED to prevent IP leak (kill-switch active)"
    log_msg "Fix: sudo systemctl start redsocks-aro"
    exit 1
fi

# Check 2: Is redsocks port listening? (ss check is more reliable for transparent proxy)
if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
    log_msg "CRITICAL: Redsocks port $REDSOCKS_PORT not in LISTEN state!"
    log_msg "ARO launch BLOCKED (kill-switch active)"
    exit 1
fi

# Check 3: Does ARO binary exist?
if [[ ! -x "$REAL_ARO" ]]; then
    log_msg "ERROR: ARO binary not found at $REAL_ARO"
    exit 1
fi

log_msg "✓ Proxy checks passed. Launching ARO..."

# Launch ARO with all arguments
exec "$REAL_ARO" "$@"
EOF
    
    chmod +x "$tmp_wrapper"
    
    # Verify file tạm trước khi replace
    if verify_wrapper_script; then
        mv "$tmp_wrapper" "$WRAPPER_SCRIPT"
        log_success "Wrapper created and verified at $WRAPPER_SCRIPT"
    else
        rm -f "$tmp_wrapper"
        log_error "New wrapper failed verification — keeping existing wrapper"
        return 1
    fi
}

start_redsocks_service() {
    log_info "Starting redsocks service..."
    
    systemctl enable redsocks-aro >/dev/null 2>&1
    systemctl start redsocks-aro
    
    sleep 2
    
    if systemctl is-active --quiet redsocks-aro; then
        log_success "Redsocks service is running"
    else
        log_error "Failed to start redsocks service"
        echo ""
        echo "Check logs: journalctl -u redsocks-aro -n 50"
        echo ""
        exit 1
    fi
}

# ───────────────────────────────────────────────────────────────
# WATCHDOG FUNCTIONS (ported from aro-watchdog.sh v1.4.3)
# NOTE: All functions are hardened against set -euo pipefail
# ───────────────────────────────────────────────────────────────

# Global node info variables (populated by parse_node_info)
SERIAL="N/A"
EMAIL="N/A"
BIND_STATUS="unknown"
CONNECT_STATUS="N/A"
REWARD_TODAY="0"
REWARD_YESTERDAY="0"
UPTIME_RATIO="0"
PUBLIC_IP="N/A"
LATEST_LOG_FILE=""
LAST_ONLINE_LABEL="❓ No connection history"
LAST_ONLINE_AGO=""

# Cache reward values — giữ lại giá trị cuối cùng lấy được khi API lỗi
_CACHED_REWARD_TODAY="0"
_CACHED_REWARD_YESTERDAY="0"
_CACHED_UPTIME="0"

# Run a command as EFFECTIVE_USER if needed
run_as_aro_user() {
    if [[ "$EFFECTIVE_USER" == "$(whoami)" ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n -u "$EFFECTIVE_USER" true 2>/dev/null; then
        sudo -u "$EFFECTIVE_USER" "$@"
    else
        "$@"
    fi
}

get_latest_aro_log() {
    # Guard: directory may not exist yet
    if [[ ! -d "$ARO_LOG_DIR" ]] && ! run_as_aro_user test -d "$ARO_LOG_DIR" 2>/dev/null; then
        echo ""
        return 0
    fi
    # IMPORTANT: ls exits non-zero when no *.log files match the glob.
    # With pipefail enabled, we must isolate the ls failure with "|| true"
    # so head -1 still runs and the pipeline returns 0.
    { run_as_aro_user ls -t "$ARO_LOG_DIR"/*.log 2>/dev/null || true; } | head -1
}

# ── Format helpers ──────────────────────────────────────────────

format_number() {
    local raw="$1"
    if [[ -z "$raw" ]] || [[ "$raw" == "N/A" ]]; then echo "0"; return 0; fi
    # awk || true: prevent set -e abort if awk fails on unexpected input
    echo "$raw" | awk '{
        split($1, a, ".")
        int_part = a[1]
        frac_part = (length(a) > 1) ? ("." a[2]) : ""
        res = ""
        len = length(int_part)
        for (i = 1; i <= len; i++) {
            res = res substr(int_part, i, 1)
            if ((len - i) % 3 == 0 && i != len) res = res ","
        }
        print res frac_part
    }' || echo "$raw"
}

format_uptime() {
    local ratio="$1"
    if [[ -z "$ratio" ]] || [[ "$ratio" == "N/A" ]]; then echo "N/A"; return 0; fi
    local result
    result=$(echo "$ratio" | awk '{printf "%.1f", $1 * 100}' 2>/dev/null)
    if [[ -z "$result" ]]; then
        echo "N/A"
    else
        echo "$result"
    fi
}

get_tray_status_age() {
    local now; now=$(date +%s)
    echo $(( now - TRAY_STATUS_TS ))
}

is_tray_status_stale() {
    local max_age="${1:-120}"  # default: stale nếu > 2 phút
    [[ $(get_tray_status_age) -gt $max_age ]]
}

format_time_ago() {
    local seconds="$1"
    if [[ -z "$seconds" ]] || ! [[ "$seconds" =~ ^[0-9]+$ ]]; then echo "unknown"; return 0; fi
    local days=$(( seconds / 86400 ))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$(( seconds % 60 ))
    if [[ $days -gt 0 ]]; then
        [[ $hours -gt 0 ]] && echo "${days}d ${hours}h ${minutes}m ago" || echo "${days}d ago"
    elif [[ $hours -gt 0 ]]; then
        [[ $minutes -gt 0 ]] && echo "${hours}h ${minutes}m ago" || echo "${hours}h ago"
    elif [[ $minutes -gt 0 ]]; then
        echo "${minutes}m ${secs}s ago"
    else
        echo "${secs}s ago"
    fi
}

# ── Parse node info from ARO log ────────────────────────────────
# Mirrors watchdog v1.4.3 field names exactly.
# All grep calls use "|| true" inside $() so set -e never aborts
# when grep finds no match (exit 1).

parse_node_info() {
    SERIAL="N/A"; EMAIL="N/A"; BIND_STATUS="unknown"; CONNECT_STATUS="N/A"
    REWARD_TODAY="0"; REWARD_YESTERDAY="0"; UPTIME_RATIO="0"; PUBLIC_IP="N/A"

    LATEST_LOG_FILE=$(get_latest_aro_log)
    if [[ -z "$LATEST_LOG_FILE" ]] || ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null; then
        return 0
    fi

    local lines
    lines=$(run_as_aro_user tail -n 200 "$LATEST_LOG_FILE" 2>/dev/null || true)
    [[ -z "$lines" ]] && return 0

    local val
    # "|| true" inside $() prevents set -e abort when grep returns 1 (no match)
    val=$(echo "$lines" | grep -oP '(?<="serialNumber":")[^"]+' 2>/dev/null | tail -1 || true)
    [[ -n "$val" ]] && SERIAL="$val"

    val=$(echo "$lines" | grep -oP '(?<="email":")[^"]+' 2>/dev/null | tail -1 || true)
    [[ -n "$val" ]] && EMAIL="$val"

    val=$(echo "$lines" | grep -oP '(?<="bind":)(true|false)' 2>/dev/null | tail -1 || true)
    if [[ -n "$val" ]]; then
        BIND_STATUS="$val"
        # If ARO explicitly reports unbound, discard any email found in the same log window
        [[ "$BIND_STATUS" == "false" ]] && EMAIL="N/A"
    fi

    val=$(echo "$lines" | grep -oP '(?<="connect":")(connected|disconnected)' 2>/dev/null | tail -1 || true)
    [[ -n "$val" ]] && CONNECT_STATUS="$val"

    val=$(echo "$lines" | grep -oP '(?<="today":)[0-9.]+' 2>/dev/null | tail -1 || true)
    if [[ -n "$val" ]]; then
        REWARD_TODAY="$val"
        _CACHED_REWARD_TODAY="$val"
    else
        REWARD_TODAY="$_CACHED_REWARD_TODAY"
    fi

    val=$(echo "$lines" | grep -oP '(?<="yesterday":)[0-9.]+' 2>/dev/null | tail -1 || true)
    if [[ -n "$val" ]]; then
        REWARD_YESTERDAY="$val"
        _CACHED_REWARD_YESTERDAY="$val"
    else
        REWARD_YESTERDAY="$_CACHED_REWARD_YESTERDAY"
    fi

    val=$(echo "$lines" | grep -oP '(?<="uptime":)[0-9.]+' 2>/dev/null | tail -1 || true)
    if [[ -n "$val" ]]; then
        UPTIME_RATIO="$val"
        _CACHED_UPTIME="$val"
    else
        UPTIME_RATIO="$_CACHED_UPTIME"
    fi

    val=$(echo "$lines" | grep -oP '(?<="publicIp":")[^"]+' 2>/dev/null | tail -1 || true)
    [[ -n "$val" ]] && PUBLIC_IP="$val"

    # Lấy tray state thực — đây là trạng thái thực của app, không phải API cache
    local ts
    ts=$(get_aro_tray_state 2>/dev/null || true)
    if [[ -n "$ts" ]]; then
        TRAY_STATUS="$ts"
    else
        TRAY_STATUS="unknown"
    fi
    TRAY_STATUS_TS=$(date +%s)

    return 0
}

get_last_online_info() {
    LAST_ONLINE_LABEL="❓ No connection history"
    LAST_ONLINE_AGO=""

    LATEST_LOG_FILE=$(get_latest_aro_log)
    if [[ -z "$LATEST_LOG_FILE" ]] || ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null; then
        return 0
    fi

    local now; now=$(date +%s)
    local tray_state; tray_state=$(get_aro_tray_state)

    # Tìm timestamp Net init gần nhất (startup hiện tại)
    local net_init_ts
    net_init_ts=$(run_as_aro_user tail -n 1000 "$LATEST_LOG_FILE" 2>/dev/null \
        | grep "Net init" \
        | tail -1 \
        | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || true)

    if [[ "$tray_state" == "Online" ]]; then
        local online_ts=""

        if [[ -n "$net_init_ts" ]]; then
            # Convert net_init_ts sang epoch để so sánh chính xác
            local net_init_ep; net_init_ep=$(date -d "$net_init_ts" +%s 2>/dev/null || echo 0)

            if [[ "$net_init_ep" -gt 0 ]]; then
                # Tìm dòng tray=Online ĐẦU TIÊN có timestamp > net_init_ep
                online_ts=$(run_as_aro_user tail -n 2000 "$LATEST_LOG_FILE" 2>/dev/null \
                    | grep "linux tray icon synced to state=Online" \
                    | while IFS= read -r line; do
                        ts=$(echo "$line" | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null || true)
                        [[ -z "$ts" ]] && continue
                        ep=$(date -d "$ts" +%s 2>/dev/null || echo 0)
                        if [[ "$ep" -gt "$net_init_ep" ]]; then
                            echo "$ts"
                            break
                        fi
                    done || true)
            fi
        fi

        # Fallback: nếu không tìm được qua Net init, dùng last_restart từ state file
        if [[ -z "$online_ts" ]]; then
            local last_restart; last_restart=$(state_get "last_restart" "0")
            if [[ "$last_restart" -gt 0 ]]; then
                # Tìm dòng tray=Online đầu tiên sau last_restart
                online_ts=$(run_as_aro_user tail -n 2000 "$LATEST_LOG_FILE" 2>/dev/null \
                    | grep "linux tray icon synced to state=Online" \
                    | while IFS= read -r line; do
                        ts=$(echo "$line" | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null || true)
                        [[ -z "$ts" ]] && continue
                        ep=$(date -d "$ts" +%s 2>/dev/null || echo 0)
                        if [[ "$ep" -gt "$last_restart" ]]; then
                            echo "$ts"
                            break
                        fi
                    done || true)
            fi
        fi

        if [[ -n "$online_ts" ]]; then
            local ep; ep=$(date -d "$online_ts" +%s 2>/dev/null || echo 0)
            if [[ "$ep" -gt 0 ]]; then
                LAST_ONLINE_LABEL="🟢 Online since"
                LAST_ONLINE_AGO=$(format_time_ago $(( now - ep )))
            fi
        else
            # Đang online nhưng không tìm được timestamp → hiện "Currently online"
            LAST_ONLINE_LABEL="🟢 Currently online"
            LAST_ONLINE_AGO=""
        fi
    elif [[ "$tray_state" == "NoInternet" ]] || [[ "$tray_state" == "Offline" ]]; then
        # Tìm lần Online cuối cùng trong log
        local last_online_ts
        last_online_ts=$(run_as_aro_user tail -n 2000 "$LATEST_LOG_FILE" 2>/dev/null \
            | grep "linux tray icon synced to state=Online" \
            | tail -1 \
            | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || true)
        
        if [[ -n "$last_online_ts" ]]; then
            local ep; ep=$(date -d "$last_online_ts" +%s 2>/dev/null || echo 0)
            if [[ "$ep" -gt 0 ]]; then
                LAST_ONLINE_LABEL="🔴 Last online"
                LAST_ONLINE_AGO=$(format_time_ago $(( now - ep )))
            fi
        else
            LAST_ONLINE_LABEL="❓ Never connected in recent log"
            LAST_ONLINE_AGO=""
        fi
    else
        # Fallback về cách cũ nhưng chỉ 200 dòng cuối
        local last_conn
        last_conn=$(run_as_aro_user tail -n 200 "$LATEST_LOG_FILE" 2>/dev/null \
            | grep '"connect":"connected"' \
            | tail -1 \
            | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || true)
        
        if [[ -n "$last_conn" ]]; then
            local ep; ep=$(date -d "$last_conn" +%s 2>/dev/null || echo 0)
            if [[ "$ep" -gt 0 ]]; then
                LAST_ONLINE_LABEL="📡 Connected (api)"
                LAST_ONLINE_AGO=$(format_time_ago $(( now - ep )))
            fi
        fi
    fi
}

# ── Process helpers ─────────────────────────────────────────────

is_aro_running() {
    pgrep -u "$EFFECTIVE_USER" -x "ARO" >/dev/null 2>&1 || return 1
}

get_aro_pid() {
    pgrep -u "$EFFECTIVE_USER" -x "ARO" 2>/dev/null | head -n1 || true
}

is_log_fresh() {
    LATEST_LOG_FILE=$(get_latest_aro_log)
    [[ -z "$LATEST_LOG_FILE" ]] && return 1
    ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null && return 1
    local mtime
    mtime=$(run_as_aro_user stat -c %Y "$LATEST_LOG_FILE" 2>/dev/null || echo 0)
    local log_age=$(( $(date +%s) - mtime ))
    [[ $log_age -lt $((LOG_STALE_MINUTES * 60)) ]]
}

get_aro_tray_state() {
    LATEST_LOG_FILE=$(get_latest_aro_log)
    if [[ -z "$LATEST_LOG_FILE" ]] || ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null; then
        echo ""
        return 0
    fi

    # Tầng 1: Parse "linux tray icon synced to state=X"
    # ARO emit dòng này khi có state transition (Online↔Offline↔NoInternet)
    local state
    state=$(run_as_aro_user tail -n 500 "$LATEST_LOG_FILE" 2>/dev/null \
        | grep "linux tray icon synced to state=" \
        | tail -1 \
        | grep -oP "state=\K[A-Za-z]+" 2>/dev/null || true)

    if [[ -n "$state" ]]; then
        echo "$state"
        return 0
    fi

    # Tầng 2 (fallback): Parse "connect" field từ get_node_stat polling
    # ARO poll mỗi 20s — khi node stable không có state transition,
    # dòng tray synced không xuất hiện nhưng "connect" vẫn có liên tục.
    # Chỉ đọc 60 dòng cuối (~20 phút polling) để tránh data từ session cũ.
    # An toàn: hàm này chỉ được gọi khi log đã fresh (< LOG_STALE_MINUTES=10m).
    local connect_line
    connect_line=$(run_as_aro_user tail -n 60 "$LATEST_LOG_FILE" 2>/dev/null \
        | { grep -F '"connect"' 2>/dev/null || true; } \
        | tail -1)

    if [[ -n "$connect_line" ]]; then
        if echo "$connect_line" | grep -qF '"connect":"connected"'; then
            echo "Online"
            return 0
        elif echo "$connect_line" | grep -qF '"connect":"disconnected"'; then
            # Phân biệt: chưa bind vs đã bind nhưng mất kết nối
            # bind=null hoặc bind=false → node chưa bind tài khoản → không restart
            # bind=true → node đã bind nhưng disconnected → xử lý như Offline
            if echo "$connect_line" | grep -qF '"bind":true'; then
                echo "Offline"
            else
                # bind=null hoặc bind=false
                echo "Unbound"
            fi
            return 0
        fi
    fi

    # Tầng 3: Không tìm thấy gì → thực sự unknown (ARO chạy nhưng chưa poll)
    echo ""
    return 0
}

# Returns 0 (true) nếu ARO đang connected theo log mới nhất
# Returns 1 (false) nếu disconnected, hoặc không có entry nào
is_aro_connected() {
    local tray_state
    tray_state=$(get_aro_tray_state)
    [[ "$tray_state" == "Online" ]]
}

get_disconnect_duration() {
    if [[ -z "$LATEST_LOG_FILE" ]] || ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null; then
        echo "0"; return 0
    fi
    local last_line
    last_line=$(run_as_aro_user tail -n 100 "$LATEST_LOG_FILE" 2>/dev/null \
        | { grep -E '"connect":"(connected|disconnected)"' 2>/dev/null || true; } | tail -1)
    if echo "$last_line" | grep -q '"connect":"disconnected"' 2>/dev/null; then
        local ts_str
        ts_str=$(echo "$last_line" \
            | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null || true)
        if [[ -n "$ts_str" ]]; then
            local ep; ep=$(date -d "$ts_str" +%s 2>/dev/null || echo 0)
            if [[ "$ep" -gt 0 ]]; then
                echo $(( ($(date +%s) - ep) / 60 ))
                return 0
            fi
        fi
    fi
    echo "0"
}

# Returns số phút kể từ lần cuối ARO log thấy tray=Online
# Nếu chưa bao giờ online trong log → dùng (now - last_restart) thay thế
get_disconnected_since_minutes() {
    LATEST_LOG_FILE=$(get_latest_aro_log)
    [[ -z "$LATEST_LOG_FILE" ]] && echo "0" && return 0
    ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null && echo "0" && return 0

    local last_online_line
    last_online_line=$(run_as_aro_user tail -n 500 "$LATEST_LOG_FILE" 2>/dev/null \
        | grep "linux tray icon synced to state=Online" \
        | tail -1 || true)

    local now; now=$(date +%s)

    if [[ -n "$last_online_line" ]]; then
        local ts_str
        ts_str=$(echo "$last_online_line" \
            | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null || true)
        if [[ -n "$ts_str" ]]; then
            local ep; ep=$(date -d "$ts_str" +%s 2>/dev/null || echo 0)
            if [[ "$ep" -gt 0 ]]; then
                echo $(( (now - ep) / 60 ))
                return 0
            fi
        fi
    fi

    local last_restart
    last_restart=$(state_get "last_restart" "0")
    if [[ "$last_restart" -gt 0 ]]; then
        echo $(( (now - last_restart) / 60 ))
    else
        echo "0"
    fi
}

kill_aro() {
    watchdog_log "Killing ARO process..."
    pkill -u "$EFFECTIVE_USER" -x ARO 2>/dev/null || true
    sleep 2
    pkill -9 -u "$EFFECTIVE_USER" -x ARO 2>/dev/null || true
    sleep 1
    cleanup_aro_tmp
}

cleanup_aro_tmp() {
    # Xóa các file lock/socket của ARO trong /tmp/ có thể thuộc root sau unclean kill
    # ARO (Tauri) để lại các file này, khi launch lại với user ubuntu sẽ gây Permission denied
    local cleaned=0

    for f in \
        /tmp/com.aro.ARONetwork.lock \
        /tmp/.com.aro.ARONetwork.lock \
        /tmp/com.aro.ARONetwork-*.sock \
        /tmp/.com.aro.ARONetwork-* \
        /tmp/com.aro.* \
        /tmp/.com.aro.*
    do
        # Glob expansion — bỏ qua nếu không có file nào match
        [[ -e "$f" ]] || continue
        rm -f "$f" 2>/dev/null && {
            watchdog_log "Cleaned ARO tmp file: $f"
            (( cleaned++ )) || true
        } || watchdog_log "WARN: Could not remove ARO tmp file: $f (owner: $(stat -c '%U' "$f" 2>/dev/null || echo unknown))"
    done

    if [[ $cleaned -gt 0 ]]; then
        watchdog_log "cleanup_aro_tmp: removed $cleaned file(s)"
    fi
}

launch_aro() {
    cleanup_aro_tmp

    # Tauri 2.0 tray icon requires D-Bus session bus. When launched from systemd (clean env),
    # DBUS_SESSION_BUS_ADDRESS is not inherited — read it from the user's running processes.
    local _dbus_addr=""
    while IFS= read -r _pid; do
        local _addr
        _addr=$(tr '\0' '\n' < "/proc/$_pid/environ" 2>/dev/null \
            | grep '^DBUS_SESSION_BUS_ADDRESS=' | head -1 | cut -d= -f2- || true)
        if [[ -n "$_addr" ]]; then
            _dbus_addr="$_addr"
            break
        fi
    done < <(pgrep -u "$EFFECTIVE_USER" 2>/dev/null)

    watchdog_log "Launching ARO via wrapper: $WRAPPER_SCRIPT"
    watchdog_log "  Display: $DISPLAY_NUM | XAUTH: $XAUTHORITY_PATH"
    watchdog_log "  DBUS: ${_dbus_addr:-not found (tray icon may fail)}"

    if command -v sudo >/dev/null 2>&1 && sudo -n -u "$EFFECTIVE_USER" true 2>/dev/null; then
        local _env_args=(
            DISPLAY="$DISPLAY_NUM"
            XAUTHORITY="$XAUTHORITY_PATH"
            LIBGL_ALWAYS_SOFTWARE="1"
        )
        [[ -n "$_dbus_addr" ]] && _env_args+=(DBUS_SESSION_BUS_ADDRESS="$_dbus_addr")
        sudo -u "$EFFECTIVE_USER" env "${_env_args[@]}" "$WRAPPER_SCRIPT" >/dev/null 2>&1 &
    else
        local _dbus_part=""
        [[ -n "$_dbus_addr" ]] && _dbus_part="DBUS_SESSION_BUS_ADDRESS=\"$_dbus_addr\""
        local launch_cmd="DISPLAY=\"${DISPLAY_NUM}\" XAUTHORITY=\"${XAUTHORITY_PATH}\" LIBGL_ALWAYS_SOFTWARE=1 ${_dbus_part} \"${WRAPPER_SCRIPT}\""
        su - "$EFFECTIVE_USER" -c "$launch_cmd" >/dev/null 2>&1 &
    fi
    watchdog_log "ARO launch initiated (PID: $!)"
}

# ── Telegram notification templates ────────────────────────────

send_notify_restart_success() {
    _last_pre_restart_notify=0   # Reset throttle — ARO đã healthy
    local retry_count=$1
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info
    get_last_online_info

    local f_today; f_today=$(format_number "$REWARD_TODAY")
    local f_yest;  f_yest=$(format_number "$REWARD_YESTERDAY")
    local f_up;    f_up=$(format_uptime "$UPTIME_RATIO")

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="✅ <b>[ARO RESTARTED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 User: ${EFFECTIVE_USER}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
🔄 Retry: ${retry_count}/${MAX_RETRIES}
──────────────────────
💰 Reward today:     ${f_today} pts
💰 Reward yesterday: ${f_yest} pts
📶 Uptime: ${f_up}%
${LAST_ONLINE_LABEL}: ${LAST_ONLINE_AGO}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

get_aro_start_error() {
    local log_file
    log_file=$(get_latest_aro_log)
    [[ -z "$log_file" ]] || [[ ! -f "$log_file" ]] && echo "No ARO log found" && return

    # Lấy ERROR/panic từ 30 dòng cuối (đủ để cover lần start mới nhất)
    local err
    err=$(tail -30 "$log_file" 2>/dev/null \
        | grep -E '\[ERROR\]|\[panic\]|FATAL|Permission denied|error encountered' \
        | tail -3 \
        | sed 's/\[20[0-9-]* [0-9:\.]*\] //g')   # strip timestamp để ngắn hơn

    if [[ -n "$err" ]]; then
        echo "$err"
    else
        # Fallback: lấy 3 dòng cuối bất kể level
        tail -3 "$log_file" 2>/dev/null | sed 's/\[20[0-9-]* [0-9:\.]*\] //g' \
            || echo "Cannot read ARO log"
    fi
}

send_notify_aro_start_failed() {
    local retry_count="${1:-?}"
    local error_msg="${2:-unknown error}"
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info

    local msg="❌ <b>[ARO START FAILED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 User: ${EFFECTIVE_USER}
🖥️ Display: ${DISPLAY_NUM}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🔄 Retry: ${retry_count}/${MAX_RETRIES}
──────────────────────
❌ Error:
<code>${error_msg}</code>
──────────────────────
💡 Possible causes:
• Wrong DISPLAY (currently: ${DISPLAY_NUM})
• X server not accessible
• Permission issue on tray icon socket
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

check_display_accessible() {
    # Verify DISPLAY thực sự accessible bởi EFFECTIVE_USER
    # Dùng xdpyinfo nếu có, fallback sang check socket file
    local display="${DISPLAY_NUM:-:1}"
    local socket="/tmp/.X11-unix/X${display#:}"

    # Quick check: socket file tồn tại không
    if [[ ! -S "$socket" ]]; then
        watchdog_log "ERROR: X socket $socket not found — display $display not running"
        return 1
    fi

    # Permission check: user có đọc được socket không
    if ! sudo -u "$EFFECTIVE_USER" test -r "$socket" 2>/dev/null; then
        watchdog_log "ERROR: User $EFFECTIVE_USER cannot access X socket $socket (Permission denied)"
        return 1
    fi

    return 0
}

send_notify_max_retries() {
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="🚨 <b>[ARO MAX RETRIES] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
⚠️ Failed after ${MAX_RETRIES} attempts
🛑 Watchdog stopped retrying
👉 Manual intervention required!
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}



send_notify_pre_restart() {
    local reason="$1"          # Mô tả lý do kỹ thuật
    local tray_state="$2"      # tray state lúc phát hiện
    local stuck_mins="${3:-0}" # Số phút đã stuck (nếu có)
    local retry_count="${4:-?}"

    # Throttle: không spam — chỉ gửi nếu đã qua cooldown
    local now; now=$(date +%s)
    local since=$(( now - _last_pre_restart_notify ))
    if [[ $_last_pre_restart_notify -gt 0 ]] && [[ $since -lt $PRE_RESTART_NOTIFY_COOLDOWN ]]; then
        watchdog_log "Pre-restart notification throttled (${since}s since last, cooldown ${PRE_RESTART_NOTIFY_COOLDOWN}s)"
        return 0
    fi
    _last_pre_restart_notify=$now

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="⚠️ <b>[ARO RESTARTING] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 User: ${EFFECTIVE_USER}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
🔄 Retry: ${retry_count}/${MAX_RETRIES}
──────────────────────
📊 Tray state: ${tray_state:-unknown}
⏱️ Stuck duration: ${stuck_mins}m
❌ Reason: ${reason}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')

<i>Attempting restart...</i>"

    send_telegram "$msg"
}

send_notify_proxy_down() {
    local reason="${1:-redsocks service not running}"

    # Throttle: max PROXY_DOWN_NOTIFY_MAX alerts per hour
    local now; now=$(date +%s)
    local since=$(( now - _last_proxy_down_notify ))
    if [[ $_last_proxy_down_notify -gt 0 ]] && [[ $since -lt $PROXY_DOWN_NOTIFY_INTERVAL ]]; then
        watchdog_log "Proxy-down notification throttled (${since}s since last, limit ${PROXY_DOWN_NOTIFY_INTERVAL}s)"
        return 0
    fi
    _last_proxy_down_notify=$now

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="🚨 <b>[PROXY DOWN] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
⚠️ Reason: ${reason}
🛡️ ARO launch blocked (kill-switch active)
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')

<i>Attempting auto-recovery...</i>"

    send_telegram "$msg"
}

send_notify_proxy_recovered() {
    local context="${1:-routine}"   # "routine" | "stuck_connecting"
    local context_label="Auto-recovery (routine check)"
    [[ "$context" == "stuck_connecting" ]] && context_label="Recovery triggered by ARO stuck-connecting"

    local msg="✅ <b>[PROXY RECOVERED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
✓ Redsocks service restarted OK
🔧 Context: ${context_label}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

send_notify_redsocks_restarted() {
    local msg="🔄 <b>[REDSOCKS RESTARTED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
⚠️ Phát hiện: redsocks queue overflow
✓ Đã tự động restart thành công
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')

<i>Watchdog đang chờ ARO reconnect...</i>"

    send_telegram "$msg"
}

send_notify_aro_reconnected() {
    _last_pre_restart_notify=0   # Reset throttle — ARO đã online
    local context="${1:-unknown}"
    local elapsed_secs="${2:-0}"
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info
    get_last_online_info

    local f_today; f_today=$(format_number "$REWARD_TODAY")
    local f_yest;  f_yest=$(format_number "$REWARD_YESTERDAY")
    local f_up;    f_up=$(format_uptime "$UPTIME_RATIO")
    local elapsed_min=$(( elapsed_secs / 60 ))

    local cause_label="Proxy OK, ARO restarted"
    [[ "$context" == "proxy_recovered" ]]    && cause_label="Proxy recovered + ARO restarted"
    [[ "$context" == "redsocks_recovered" ]] && cause_label="Redsocks hung → restarted → ARO reconnected"
    [[ "$context" == "proxy_ok_aro_restarted" ]] && cause_label="Network OK, ARO app restarted"

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="✅ <b>[ARO RECONNECTED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 User: ${EFFECTIVE_USER}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 Exit IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
──────────────────────
🔧 Cause: ${cause_label}
⏱️ Recovery time: ${elapsed_min}m ${elapsed_secs}s
💰 Reward today:     ${f_today} pts
💰 Reward yesterday: ${f_yest} pts
📶 Uptime: ${f_up}%
${LAST_ONLINE_LABEL}: ${LAST_ONLINE_AGO}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

send_notify_aro_stuck_manual() {
    local retry_count="${1:-?}"
    local context="${2:-unknown}"
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info

    local cause_label="Proxy OK nhưng ARO không reconnect"
    [[ "$context" == "proxy_recovered" ]] && cause_label="Proxy đã recover nhưng ARO vẫn không connect"

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="⚠️ <b>[ARO STUCK] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
──────────────────────
❌ ARO không kết nối được sau ${CONNECTING_WAIT_SECS}s
🔧 Context: ${cause_label}
🔄 Retry: ${retry_count}/${MAX_RETRIES}
👉 <b>Cần kiểm tra thủ công!</b>
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

send_notify_proxy_dead() {
    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="🚨 <b>[PROXY DEAD] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
⏱️ Timeout: ${PROXY_RESTART_TIMEOUT_SECS}s
❌ Redsocks restart FAILED — ARO đang tắt
🛑 Kill-switch đang hoạt động
👉 <b>Cần can thiệp thủ công!</b>
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

send_notify_ip_leak() {
    local exit_ip="${1:-unknown}"
    local real_ip="${2:-unknown}"
    local attempt="${3:-0}"
    local attempt_label=""
    [[ "$attempt" -gt 0 ]] && attempt_label=$'\n'"🔄 Auto-recovery attempt: ${attempt}/${IP_LEAK_MAX_RECOVERY}"
    local msg="🚨🚨🚨 <b>[IP LEAK DETECTED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS:    ${HOSTNAME}
🌐 Exit IP: <code>${exit_ip}</code> ← TRÙNG IP THẬT!
🔍 Real IP: <code>${real_ip}</code>
🔌 Proxy:  ${PROXY_HOST}:${PROXY_PORT}
⛔ ARO đã bị kill để ngăn lộ IP thêm${attempt_label}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')

<i>Fix thủ công: sudo ./aro-manager.sh proxy enable &amp;&amp; sudo ./aro-manager.sh start</i>"
    send_telegram "$msg" || true
}

send_notify_ip_leak_recovered() {
    local exit_ip="${1:-unknown}"
    local attempt="${2:-1}"
    local msg="✅ <b>[IP LEAK FIXED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS:    ${HOSTNAME}
🌐 Exit IP: <code>${exit_ip}</code> ← Đã qua proxy
🔄 Tự sửa sau attempt ${attempt}/${IP_LEAK_MAX_RECOVERY}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"
    send_telegram "$msg" || true
}

collect_ip_leak_diagnostics() {
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local logfile="/var/log/aro-ip-leak-debug-${ts}.log"

    # Gather key metrics for the Telegram summary
    local conntrack_count conntrack_max redsocks_listen root_ip user_ip
    conntrack_count=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo "?")
    conntrack_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "?")
    if ss -lntp 2>/dev/null | grep -q ':12345'; then
        redsocks_listen="YES"
    else
        redsocks_listen="NO ⚠️"
    fi
    root_ip=$(curl --max-time 8 -sf https://ifconfig.me 2>/dev/null | tr -d '[:space:]' || echo "?")
    user_ip=$(sudo -u "$EFFECTIVE_USER" curl --max-time 8 -sf https://ifconfig.me 2>/dev/null | tr -d '[:space:]' || echo "?")

    # Write full diagnostic log to disk (survives reboot)
    {
        echo "=== ARO IP LEAK DIAGNOSTIC REPORT ==="
        echo "Timestamp  : $(date '+%Y-%m-%d %H:%M:%S') UTC"
        echo "Hostname   : ${HOSTNAME}"
        echo "Script     : v${SCRIPT_VERSION}"
        echo "Trigger    : ip_leak_reboot"
        echo "Real IP    : $(state_get 'ip_leak_real_ip' 'unknown')"
        echo "Exit IP    : $(state_get 'ip_leak_exit_ip' 'unknown')"
        echo ""
        echo "=== CONNTRACK ==="
        sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max 2>/dev/null || echo "N/A"
        echo ""
        echo "=== REDSOCKS SOCKET STATES ==="
        ss -tnp 2>/dev/null | grep -i redsocks || echo "(no redsocks sockets found)"
        echo ""
        echo "=== LISTENING ON :12345 ==="
        ss -lntp 2>/dev/null | grep -E ':12345|redsocks' || echo "(not listening)"
        echo ""
        echo "=== ROUTING TABLE ==="
        ip route show 2>/dev/null || echo "N/A"
        echo ""
        echo "=== IPTABLES nat ARO_PROXY ==="
        iptables -t nat -L ARO_PROXY -n -v 2>/dev/null || echo "N/A (chain may not exist)"
        echo ""
        echo "=== REDSOCKS SERVICE STATUS ==="
        systemctl status redsocks-aro --no-pager -l 2>/dev/null || echo "N/A"
        echo ""
        echo "=== REDSOCKS JOURNAL (50 lines) ==="
        journalctl -u redsocks-aro -n 50 --no-pager 2>/dev/null || echo "N/A"
        echo ""
        echo "=== EXIT IP (root — bypasses proxy) ==="
        echo "${root_ip}"
        echo ""
        echo "=== EXIT IP (${EFFECTIVE_USER} — via proxy) ==="
        echo "${user_ip}"
    } > "$logfile" 2>&1

    # Upload full log to dashboard in background
    if [[ -n "${DASHBOARD_URL:-}" && -n "${DASHBOARD_API_KEY:-}" ]]; then
        (
            DIAG_URL="${DASHBOARD_URL%/}" \
            DIAG_KEY="${DASHBOARD_API_KEY}" \
            DIAG_NODE="${HOSTNAME}" \
            DIAG_FILE="$logfile" \
            python3 - <<'PYEOF'
import json, os, urllib.request, sys
try:
    with open(os.environ['DIAG_FILE'], 'r', errors='replace') as f:
        content = f.read(65535)
    payload = json.dumps({
        'node_id':  os.environ['DIAG_NODE'],
        'api_key':  os.environ['DIAG_KEY'],
        'trigger':  'ip_leak_reboot',
        'content':  content,
    }).encode()
    req = urllib.request.Request(
        os.environ['DIAG_URL'] + '/api/v1/nodes/diagnostic',
        data=payload,
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    urllib.request.urlopen(req, timeout=15)
except Exception as e:
    sys.stderr.write(f'diagnostic upload failed: {e}\n')
PYEOF
        ) &>/dev/null &
    fi

    # Return one-line summary for embedding in Telegram message
    printf "conntrack: %s/%s | redsocks: %s | root: %s | user: %s" \
        "$conntrack_count" "$conntrack_max" "$redsocks_listen" "$root_ip" "$user_ip"
}

send_notify_ip_leak_give_up() {
    local real_ip="${1:-unknown}"
    local diag_summary="${2:-}"
    local diag_section=""
    [[ -n "$diag_summary" ]] && diag_section=$'\n'"📊 Diagnostics: <code>${diag_summary}</code>"
    local msg="🚨 <b>[IP LEAK - AUTO-FIX THẤT BẠI] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS:    ${HOSTNAME}
🔍 Real IP: <code>${real_ip}</code>
❌ ${IP_LEAK_MAX_RECOVERY}/${IP_LEAK_MAX_RECOVERY} recovery attempts FAILED
🔁 Đang reboot VPS để khắc phục...${diag_section}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"
    send_telegram "$msg" || true
}

# Auto-recovery khi phát hiện IP leak.
# Chạy proxy enable, chờ 15s, kiểm tra lại.
# Returns 0 nếu fix thành công, 1 nếu vẫn còn leak hoặc đã give up.
handle_ip_leak_recovery() {
    local leak_real; leak_real=$(state_get "ip_leak_real_ip" "unknown")
    local recovery_count; recovery_count=$(state_get "ip_leak_recovery_count" "0")

    if [[ "$recovery_count" -ge "$IP_LEAK_MAX_RECOVERY" ]]; then
        watchdog_log "IP LEAK: give-up state (${recovery_count}/${IP_LEAK_MAX_RECOVERY} attempts used), ARO stays killed"
        return 1
    fi

    recovery_count=$(( recovery_count + 1 ))
    state_set "ip_leak_recovery_count" "$recovery_count"
    watchdog_log "IP LEAK auto-recovery attempt ${recovery_count}/${IP_LEAK_MAX_RECOVERY} — running proxy enable"

    bash "$SCRIPT_DIR/$SCRIPT_NAME" proxy enable > /tmp/aro_leak_recovery.log 2>&1 || true
    sleep 15

    local _check_result=0
    check_ip_leak 2>/dev/null || _check_result=$?

    if [[ "$_check_result" -eq 0 ]]; then
        local fixed_ip; fixed_ip=$(sudo -u "$EFFECTIVE_USER" curl -s --max-time 8 "https://ifconfig.me" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
        watchdog_log "IP LEAK fixed after attempt ${recovery_count} — exit IP now: $fixed_ip"
        state_set "ip_leak_detected" "0"
        state_set "ip_leak_recovery_count" "0"
        send_notify_ip_leak_recovered "$fixed_ip" "$recovery_count" || true
        return 0
    else
        watchdog_log "IP LEAK still present after attempt ${recovery_count}"
        local leak_exit; leak_exit=$(state_get "ip_leak_exit_ip" "unknown")
        send_notify_ip_leak "$leak_exit" "$leak_real" "$recovery_count" || true
        if [[ "$recovery_count" -ge "$IP_LEAK_MAX_RECOVERY" ]]; then
            watchdog_log "IP LEAK: ${IP_LEAK_MAX_RECOVERY} recovery attempts failed — collecting diagnostics"
            local diag_summary; diag_summary=$(collect_ip_leak_diagnostics 2>/dev/null || echo "")
            watchdog_log "IP LEAK: diagnostics collected — scheduling VPS reboot in 1 minute"
            send_notify_ip_leak_give_up "$leak_real" "$diag_summary" || true
            shutdown -r +1 "aro-manager: IP leak auto-recovery failed, rebooting" &
        fi
        return 1
    fi
}

_execute_dashboard_command() {
    local cmd_id="$1"
    local action="$2"
    local payload_b64="${3:-}"
    local node_id="$HOSTNAME"
    local base_url="${DASHBOARD_URL%/}"
    local api_key="$DASHBOARD_API_KEY"

    # Ack ngay để dashboard biết node đã nhận lệnh
    curl -sf --max-time 5 \
        -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/ack" \
        -H "Content-Type: application/json" \
        -d '{}' > /dev/null 2>&1 || true

    watchdog_log "Dashboard command received: action=${action} id=${cmd_id}"

    local result="" success="true"

    case "$action" in
        restart_aro)
            watchdog_log "Dashboard: killing ARO for restart"
            kill_aro
            result="ARO killed — watchdog sẽ restart trong chu kỳ tiếp theo"
            ;;
        restart_watchdog)
            watchdog_log "Dashboard: restarting watchdog service"
            result="Watchdog restarting..."
            # Gửi complete trước khi restart (service sẽ kill process này)
            curl -sf --max-time 5 \
                -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/complete" \
                -H "Content-Type: application/json" \
                -d "{\"result\":\"${result}\",\"success\":true}" > /dev/null 2>&1 || true
            systemctl restart aro-watchdog.service
            return  # không tiếp tục (process bị kill)
            ;;
        debug_aro)
            watchdog_log "Dashboard: running debug"
            result=$(do_debug 2>&1 | head -200 | tr '"' "'" | tr '\n' '|')
            ;;
        reboot_vps)
            watchdog_log "Dashboard: scheduling VPS reboot in 1 minute"
            result="VPS sẽ reboot trong 1 phút"
            curl -sf --max-time 5 \
                -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/complete" \
                -H "Content-Type: application/json" \
                -d "{\"result\":\"${result}\",\"success\":true}" > /dev/null 2>&1 || true
            shutdown -r +1 "Dashboard reboot command" &
            return
            ;;
        update_script)
            watchdog_log "Dashboard: downloading latest script from GitHub"
            local script_url="https://raw.githubusercontent.com/nauthnael/aro-manager/main/aro-manager.sh"
            local tmp_script="/tmp/aro-manager-new-${cmd_id}.sh"
            # Xác định path thực của script đang chạy trong service
            local target_script
            target_script=$(grep '^ExecStart=' /etc/systemd/system/aro-watchdog.service 2>/dev/null \
                | cut -d'=' -f2- | awk '{print $1}')
            [[ -z "$target_script" ]] && target_script="$SCRIPT_DIR/$SCRIPT_NAME"

            if curl -sf --max-time 60 -o "$tmp_script" "$script_url"; then
                if bash -n "$tmp_script" 2>/dev/null; then
                    local new_ver
                    new_ver=$(grep '^SCRIPT_VERSION=' "$tmp_script" | cut -d'"' -f2)
                    cp "$tmp_script" "$target_script"
                    chmod +x "$target_script"
                    rm -f "$tmp_script"
                    result="Script updated to v${new_ver}. Restarting watchdog (ARO tiếp tục chạy)..."
                    # Gửi complete trước khi restart watchdog (sẽ kill process này)
                    curl -sf --max-time 5 \
                        -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/complete" \
                        -H "Content-Type: application/json" \
                        -d "{\"result\":\"${result}\",\"success\":true}" > /dev/null 2>&1 || true
                    nohup bash "$target_script" update > /tmp/aro_update.log 2>&1 &
                    disown
                    return
                else
                    result="ERROR: Script download thành công nhưng failed syntax check"
                    success="false"
                fi
            else
                result="ERROR: Không thể tải script từ GitHub (${script_url})"
                success="false"
            fi
            rm -f "$tmp_script"
            ;;
        install_scrot)
            watchdog_log "Dashboard: installing scrot via apt-get"
            local install_out
            if install_out=$(DEBIAN_FRONTEND=noninteractive apt-get install -y scrot 2>&1); then
                result="scrot installed successfully. Bạn có thể chụp màn hình ngay bây giờ."
            else
                result="ERROR: $(echo "$install_out" | tail -5 | tr '"' "'" | tr '\n' '|')"
                success="false"
            fi
            ;;
        capture_screenshot)
            watchdog_log "Dashboard: capturing screenshot of display ${DISPLAY_NUM:-:1}"
            local ss_file="/tmp/aro_ss_${cmd_id}.png"
            rm -f "$ss_file"
            local captured=false
            if command -v scrot >/dev/null 2>&1; then
                DISPLAY="${DISPLAY_NUM:-:1}" XAUTHORITY="${XAUTHORITY_PATH}" scrot -z "$ss_file" 2>/dev/null && captured=true
            fi
            if [[ "$captured" != "true" ]] && command -v import >/dev/null 2>&1; then
                DISPLAY="${DISPLAY_NUM:-:1}" XAUTHORITY="${XAUTHORITY_PATH}" import -window root "$ss_file" 2>/dev/null && captured=true
            fi
            if [[ "$captured" == "true" ]] && [[ -f "$ss_file" ]]; then
                local b64
                b64=$(base64 -w0 "$ss_file")
                rm -f "$ss_file"
                local json_file="/tmp/aro_ss_payload_${cmd_id}.json"
                echo "$b64" | python3 -c "
import json, sys
d = sys.stdin.read().strip()
print(json.dumps({'result': d, 'success': True}))
" > "$json_file" 2>/dev/null
                curl -sf --max-time 30 \
                    -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/complete" \
                    -H "Content-Type: application/json" \
                    -d "@$json_file" > /dev/null 2>&1 || true
                rm -f "$json_file"
                return
            else
                result="ERROR: Không thể chụp màn hình. Cần cài scrot hoặc imagemagick (display: ${DISPLAY_NUM:-:1})"
                success="false"
            fi
            ;;
        fetch_log)
            watchdog_log "Dashboard: fetching ARO Desktop log"
            local log_file="/home/ubuntu/.local/share/com.aro.ARONetwork/logs/ARO Desktop.log"
            if [[ -f "$log_file" ]]; then
                local encoded
                encoded=$(tail -c 5242880 "$log_file" | gzip -9 | base64 -w 0)
                local json_file="/tmp/aro_log_payload_${cmd_id}.json"
                echo "$encoded" | python3 -c "
import json, sys
d = sys.stdin.read().strip()
print(json.dumps({'result': d, 'success': True}))
" > "$json_file" 2>/dev/null
                curl -sf --max-time 60 \
                    -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/complete" \
                    -H "Content-Type: application/json" \
                    -d "@$json_file" > /dev/null 2>&1 || true
                rm -f "$json_file"
                return
            else
                result="ERROR: Log file không tồn tại: $log_file"
                success="false"
            fi
            ;;
        renew_node)
            watchdog_log "Dashboard: renewing ARO (purge + reinstall) — sending early ack"
            # Gửi complete ngay vì lệnh này chạy lâu (~2-3 phút), tránh timeout
            curl -sf --max-time 5 \
                -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/complete" \
                -H "Content-Type: application/json" \
                -d '{"result":"Renew đang thực thi: purge + reinstall ARO...","success":true}' > /dev/null 2>&1 || true

            # Purge ARO
            watchdog_log "Renew: purging aro-desktop..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y aro-desktop 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true

            # Tải và cài lại ARO
            local deb_path="/tmp/ARO_Desktop_latest_debian.deb"
            rm -f "$deb_path"
            watchdog_log "Renew: downloading ARO package..."
            if wget -q --timeout=120 -O "$deb_path" \
                "https://download.aro.network/files/packages/linux/ARO_Desktop_latest_debian.deb"; then
                watchdog_log "Renew: installing ARO package..."
                if DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_path" 2>/dev/null; then
                    watchdog_log "Renew: ARO reinstalled successfully — watchdog sẽ khởi động lại ARO trong chu kỳ tiếp theo"
                else
                    watchdog_log "Renew: ERROR — apt install thất bại"
                fi
            else
                watchdog_log "Renew: ERROR — không tải được package từ ARO network"
            fi
            rm -f "$deb_path"
            return  # Đã gửi complete phía trên, không gửi lại
            ;;
        tele_off)
            watchdog_log "Dashboard: disabling Telegram notifications"
            TG_ENABLED=0
            save_watchdog_config
            state_set "tg_enabled" "0"   # Có hiệu lực ngay trong watchdog loop
            result="Telegram notifications DISABLED on ${HOSTNAME}"
            ;;
        tele_on)
            watchdog_log "Dashboard: enabling Telegram notifications"
            TG_ENABLED=1
            save_watchdog_config
            state_set "tg_enabled" "1"   # Có hiệu lực ngay trong watchdog loop
            result="Telegram notifications ENABLED on ${HOSTNAME}"
            ;;
        set_tg_chatid)
            if [[ -z "$payload_b64" ]]; then
                result="ERROR: payload trống"
                success="false"
            else
                local new_chatid
                new_chatid=$(echo "$payload_b64" | base64 -d 2>/dev/null)
                if [[ -z "$new_chatid" ]]; then
                    result="ERROR: base64 decode thất bại"
                    success="false"
                else
                    watchdog_log "Dashboard: setting TG_CHAT_ID to ${new_chatid}"
                    TG_CHAT_ID="$new_chatid"
                    save_watchdog_config
                    result="TG_CHAT_ID updated to ${new_chatid} on ${HOSTNAME}"
                fi
            fi
            ;;
        set_tg_token)
            if [[ -z "$payload_b64" ]]; then
                result="ERROR: payload trống"
                success="false"
            else
                local new_token
                new_token=$(echo "$payload_b64" | base64 -d 2>/dev/null)
                if [[ -z "$new_token" ]]; then
                    result="ERROR: base64 decode thất bại"
                    success="false"
                else
                    watchdog_log "Dashboard: updating TG_BOT_TOKEN"
                    TG_BOT_TOKEN="$new_token"
                    save_watchdog_config
                    result="TG_BOT_TOKEN updated on ${HOSTNAME}"
                fi
            fi
            ;;
        set_proxy)
            if [[ -z "$payload_b64" ]]; then
                result="ERROR: payload trống"
                success="false"
            else
                local new_proxy
                new_proxy=$(echo "$payload_b64" | base64 -d 2>/dev/null)
                if [[ -z "$new_proxy" ]]; then
                    result="ERROR: base64 decode thất bại"
                    success="false"
                else
                    watchdog_log "Dashboard: changing proxy to ${new_proxy%%:*}:..."
                    # Parse new proxy string host:port:user:pass
                    IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$new_proxy"
                    if [[ -z "$PROXY_HOST" ]] || [[ -z "$PROXY_PORT" ]]; then
                        result="ERROR: định dạng proxy không hợp lệ (cần host:port:user:pass)"
                        success="false"
                    else
                        # Kill ARO first so wrapper doesn't block redsocks restart
                        kill_aro
                        save_proxy_config
                        create_redsocks_config
                        systemctl restart redsocks-aro 2>/dev/null || true
                        watchdog_log "Dashboard: proxy changed — watchdog sẽ khởi động lại ARO"
                        result="Proxy changed to ${PROXY_HOST}:${PROXY_PORT} on ${HOSTNAME} — ARO will restart"
                    fi
                fi
            fi
            ;;
        combo_purge_proxy_renew)
            if [[ -z "$payload_b64" ]]; then
                result="ERROR: payload trống"
                success="false"
            else
                local new_proxy
                new_proxy=$(echo "$payload_b64" | base64 -d 2>/dev/null)
                if [[ -z "$new_proxy" ]]; then
                    result="ERROR: base64 decode thất bại"
                    success="false"
                else
                    watchdog_log "Dashboard: combo_purge_proxy_renew — proxy=${new_proxy%%:*}:... — sending early ack"
                    # Gửi complete ngay vì lệnh này chạy lâu (~3-5 phút)
                    curl -sf --max-time 5 \
                        -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/complete" \
                        -H "Content-Type: application/json" \
                        -d '{"result":"Combo Renew đang thực thi: purge → đổi proxy → cài lại ARO...","success":true}' > /dev/null 2>&1 || true

                    # Bước 1: Kill ARO + Purge aro-desktop
                    kill_aro
                    watchdog_log "Combo Renew: purging aro-desktop..."
                    DEBIAN_FRONTEND=noninteractive apt-get purge -y aro-desktop 2>/dev/null || true
                    apt-get autoremove -y 2>/dev/null || true

                    # Bước 2: Đổi proxy (giống handler set_proxy)
                    IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$new_proxy"
                    if [[ -n "$PROXY_HOST" ]] && [[ -n "$PROXY_PORT" ]]; then
                        watchdog_log "Combo Renew: updating proxy to ${PROXY_HOST}:${PROXY_PORT}..."
                        save_proxy_config
                        create_redsocks_config
                        systemctl restart redsocks-aro 2>/dev/null || true
                        # Chờ redsocks khởi động xong trước khi cài ARO
                        local rs_waited=0
                        while [[ $rs_waited -lt ${PROXY_RESTART_TIMEOUT_SECS:-60} ]]; do
                            if systemctl is-active --quiet redsocks-aro 2>/dev/null; then
                                watchdog_log "Combo Renew: redsocks ready (${rs_waited}s)"
                                break
                            fi
                            sleep 2
                            rs_waited=$(( rs_waited + 2 ))
                        done
                    else
                        watchdog_log "Combo Renew: WARNING — không parse được proxy, bỏ qua bước đổi proxy"
                    fi

                    # Bước 3: Tải + cài lại ARO (giống handler renew_node)
                    local deb_path="/tmp/ARO_Desktop_latest_debian.deb"
                    rm -f "$deb_path"
                    watchdog_log "Combo Renew: downloading ARO package..."
                    if wget -q --timeout=120 -O "$deb_path" \
                        "https://download.aro.network/files/packages/linux/ARO_Desktop_latest_debian.deb"; then
                        watchdog_log "Combo Renew: installing ARO package..."
                        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_path" 2>/dev/null; then
                            watchdog_log "Combo Renew: hoàn thành — watchdog sẽ khởi động lại ARO trong chu kỳ tiếp theo"
                        else
                            watchdog_log "Combo Renew: ERROR — apt install thất bại"
                        fi
                    else
                        watchdog_log "Combo Renew: ERROR — không tải được package từ ARO network"
                    fi
                    rm -f "$deb_path"
                    return  # Đã gửi complete phía trên, không gửi lại
                fi
            fi
            ;;
        proxy_test)
            watchdog_log "Dashboard: running proxy test"
            result=$(do_proxy_test 2>&1 | head -100 | tr '"' "'" | tr '\n' '|')
            ;;
        *)
            result="Unknown action: ${action}"
            success="false"
            ;;
    esac

    # Gửi kết quả về dashboard
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({'result': sys.argv[1], 'success': sys.argv[2] == 'true'}))
" "$result" "$success" 2>/dev/null) || payload="{\"result\":\"done\",\"success\":true}"

    curl -sf --max-time 10 \
        -X POST "${base_url}/api/v1/nodes/${node_id}/commands/${cmd_id}/complete" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

report_to_dashboard() {
    local override_status="${1:-}"   # Optional: pass e.g. "proxy_expired" to bypass tray_state
    [[ "${DASHBOARD_ENABLED:-false}" != "true" ]] && return 0
    [[ -z "$DASHBOARD_URL" ]] || [[ -z "$DASHBOARD_API_KEY" ]] && return 0

    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info

    local tray_state
    if [[ -n "$override_status" ]]; then
        tray_state="$override_status"
    else
        tray_state=$(get_aro_tray_state)
    fi
    local proxy_status="false"
    if [[ "${USE_PROXY:-1}" -eq 0 ]]; then
        proxy_status="true"   # no-proxy mode: không cần redsocks
    elif check_proxy_health > /dev/null 2>&1; then
        # Also require real proxy check (SOCKS5+credentials) to have passed recently
        local real_ok; real_ok=$(state_get "real_proxy_ok" "true")
        [[ "$real_ok" == "true" ]] && proxy_status="true"
    fi

    local base_url="${DASHBOARD_URL%/}"
    local node_id="$HOSTNAME"

    local ip_leak_flag; ip_leak_flag=$(state_get "ip_leak_detected" "0")
    local ip_leak_bool="false"
    [[ "$ip_leak_flag" == "1" ]] && ip_leak_bool="true"

    local payload
    payload=$(python3 -c "
import json, sys
d = {
    'node_id':          sys.argv[1],
    'api_key':          sys.argv[2],
    'aro_status':       sys.argv[3],
    'proxy_ok':         sys.argv[4] == 'true',
    'reward_today':     float(sys.argv[5]) if sys.argv[5] else 0,
    'reward_yesterday': float(sys.argv[6]) if sys.argv[6] else 0,
    'uptime_ratio':     float(sys.argv[7]) if sys.argv[7] else 0,
    'public_ip':        sys.argv[8],
    'proxy_host':       sys.argv[9],
    'proxy_port':       int(sys.argv[10]) if sys.argv[10].isdigit() else 0,
    'proxy_user':       sys.argv[11],
    'serial':           sys.argv[12],
    'account':          sys.argv[13],
    'script_version':   sys.argv[14],
    'bind_status':      sys.argv[15],
    'ip_leak':          sys.argv[16] == 'true',
}
print(json.dumps(d))
" "$node_id" "$DASHBOARD_API_KEY" \
  "${tray_state:-unknown}" "$proxy_status" \
  "${REWARD_TODAY:-0}" "${REWARD_YESTERDAY:-0}" "${UPTIME_RATIO:-0}" \
  "${PUBLIC_IP:-}" "${PROXY_HOST:-}" "${PROXY_PORT:-0}" \
  "${PROXY_USER:-}" "${SERIAL:-}" "${EMAIL:-}" "$SCRIPT_VERSION" \
  "${BIND_STATUS:-unknown}" "$ip_leak_bool" 2>/dev/null) || {
        watchdog_log "Dashboard: failed to build payload"
        return 0
    }

    local response
    response=$(curl -sf --max-time 8 \
        -X POST "${base_url}/api/v1/nodes/report" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || {
        watchdog_log "Dashboard: report failed (server unreachable)"
        return 0
    }

    # Parse và execute commands trả về
    local cmds_json
    cmds_json=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    cmds = data.get('commands', [])
    for c in cmds:
        print(c['id'], c['action'], c.get('payload') or '')
except:
    pass
" "$response" 2>/dev/null)

    if [[ -n "$cmds_json" ]]; then
        while IFS=' ' read -r cmd_id cmd_action cmd_payload; do
            [[ -z "$cmd_id" ]] && continue
            _execute_dashboard_command "$cmd_id" "$cmd_action" "$cmd_payload"
        done <<< "$cmds_json"
    fi

    # Đọc cấu hình periodic restart từ dashboard và lưu vào state
    local cfg_out
    cfg_out=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    pmin = data.get('periodic_restart_min')
    pmax = data.get('periodic_restart_max')
    if isinstance(pmin, int) and isinstance(pmax, int):
        print(pmin, pmax)
except:
    pass
" "$response" 2>/dev/null)

    if [[ -n "$cfg_out" ]]; then
        local _pmin _pmax
        read -r _pmin _pmax <<< "$cfg_out"
        if [[ "$_pmin" =~ ^[0-9]+$ ]] && [[ "$_pmax" =~ ^[0-9]+$ ]] && [[ $_pmin -lt $_pmax ]]; then
            local _cur_pmin; _cur_pmin=$(state_get "dashboard_periodic_min" "")
            [[ "$_cur_pmin" != "$_pmin" ]] && state_set "dashboard_periodic_min" "$_pmin"
            local _cur_pmax; _cur_pmax=$(state_get "dashboard_periodic_max" "")
            [[ "$_cur_pmax" != "$_pmax" ]] && state_set "dashboard_periodic_max" "$_pmax"
        fi
    fi

    # Đọc cấu hình daily report enabled từ dashboard
    local dr_enabled
    dr_enabled=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    v = data.get('daily_report_enabled')
    if v is not None:
        print('true' if v else 'false')
except:
    pass
" "$response" 2>/dev/null)
    if [[ -n "$dr_enabled" ]]; then
        local _cur_dr; _cur_dr=$(state_get "dashboard_daily_report_enabled" "")
        [[ "$_cur_dr" != "$dr_enabled" ]] && state_set "dashboard_daily_report_enabled" "$dr_enabled"
    fi

    # Đọc log stale restart threshold từ dashboard
    local _stale_mins
    _stale_mins=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    v = data.get('log_stale_restart_minutes')
    if isinstance(v, int) and 1 <= v <= 60:
        print(v)
except:
    pass
" "$response" 2>/dev/null)
    if [[ -n "$_stale_mins" ]]; then
        local _cur_stale; _cur_stale=$(state_get "dashboard_log_stale_restart_minutes" "")
        [[ "$_cur_stale" != "$_stale_mins" ]] && state_set "dashboard_log_stale_restart_minutes" "$_stale_mins"
    fi

    # Đọc thời gian chờ trước khi restart từ dashboard
    local _pwait
    _pwait=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    v = data.get('periodic_restart_wait_minutes')
    if isinstance(v, int) and 1 <= v <= 20:
        print(v)
except:
    pass
" "$response" 2>/dev/null)
    if [[ -n "$_pwait" ]]; then
        local _cur_pwait; _cur_pwait=$(state_get "dashboard_periodic_wait" "")
        [[ "$_cur_pwait" != "$_pwait" ]] && state_set "dashboard_periodic_wait" "$_pwait"
    fi

    # Đọc cấu hình periodic VPS reboot từ dashboard
    local _vps_count _vps_enabled
    _vps_count=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    v = data.get('periodic_vps_reboot_count')
    if isinstance(v, int) and 1 <= v <= 24:
        print(v)
except:
    pass
" "$response" 2>/dev/null)
    if [[ -n "$_vps_count" ]]; then
        local _cur_vps_count; _cur_vps_count=$(state_get "dashboard_vps_reboot_count" "")
        [[ "$_cur_vps_count" != "$_vps_count" ]] && state_set "dashboard_vps_reboot_count" "$_vps_count"
    fi

    _vps_enabled=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    v = data.get('periodic_vps_reboot_enabled')
    if v is not None:
        print('true' if v else 'false')
except:
    pass
" "$response" 2>/dev/null)
    if [[ -n "$_vps_enabled" ]]; then
        local _cur_vps_enabled; _cur_vps_enabled=$(state_get "dashboard_vps_reboot_enabled" "")
        [[ "$_cur_vps_enabled" != "$_vps_enabled" ]] && state_set "dashboard_vps_reboot_enabled" "$_vps_enabled"
    fi
}

send_daily_report() {
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info
    get_last_online_info

    local delta; delta=$(awk "BEGIN {print $REWARD_TODAY - $REWARD_YESTERDAY}" 2>/dev/null || echo "0")
    local cmp;   cmp=$(awk "BEGIN {if ($delta>0) print 1; else if ($delta<0) print -1; else print 0}" 2>/dev/null || echo "0")
    local trend="➡️ No change"
    [[ "$cmp" -eq 1 ]]  && trend="📈 +$(format_number "$delta")"
    [[ "$cmp" -eq -1 ]] && trend="📉 $(format_number "$delta")"

    local f_today; f_today=$(format_number "$REWARD_TODAY")
    local f_yest;  f_yest=$(format_number "$REWARD_YESTERDAY")
    local f_up;    f_up=$(format_uptime "$UPTIME_RATIO")

    local tray_display
    case "$TRAY_STATUS" in
        Online)     tray_display="🟢 Online (connected)" ;;
        NoInternet) tray_display="🔴 NoInternet (connecting...)" ;;
        Offline)    tray_display="🟡 Offline" ;;
        *)          tray_display="❓ ${CONNECT_STATUS:-unknown}" ;;
    esac

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="📊 <b>[ARO DAILY REPORT] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
─────── Reward ───────
💰 Today:     ${f_today} pts
💰 Yesterday: ${f_yest} pts
${trend}
📶 Uptime: ${f_up}%
📡 Status: ${tray_display}
${LAST_ONLINE_LABEL}: ${LAST_ONLINE_AGO}
📅 Date: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

send_notify_setup_success() {
    local mode="$1"
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info
    get_last_online_info

    local f_today; f_today=$(format_number "$REWARD_TODAY")
    local f_yest;  f_yest=$(format_number "$REWARD_YESTERDAY")
    local f_up;    f_up=$(format_uptime "$UPTIME_RATIO")

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="🚀 <b>[ARO MANAGER INSTALLED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 ARO User: ${EFFECTIVE_USER}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   ${vnc_ip}:${VNC_PORT}
🤖 Watchdog: ${mode} mode
──────────────────────
💰 Reward today:     ${f_today} pts
💰 Reward yesterday: ${f_yest} pts
📶 Uptime: ${f_up}%
🔗 Status: ${CONNECT_STATUS}
${LAST_ONLINE_LABEL}: ${LAST_ONLINE_AGO}
──────────────────────
✅ Watchdog is active and monitoring your node.
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

check_proxy_health() {
    if ! systemctl is-active --quiet redsocks-aro; then
        watchdog_log "WARNING: Proxy service (redsocks-aro) is down!"
        send_notify_proxy_down "redsocks service not running" || true

        # Attempt auto-recovery
        watchdog_log "Attempting to restart proxy service..."
        systemctl restart redsocks-aro 2>/dev/null || true
        sleep 3

        if systemctl is-active --quiet redsocks-aro; then
            watchdog_log "SUCCESS: Proxy service recovered"
            send_notify_proxy_recovered || true
            return 0
        else
            watchdog_log "ERROR: Proxy service restart failed!"
            return 1
        fi
    fi

    # Check redsocks port via ss (nc không reliable với transparent proxy)
    if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
        watchdog_log "WARNING: Redsocks port $REDSOCKS_PORT not in LISTEN state"
        return 1
    fi

    # Check recv-Q (detect hung service)
    local recv_q
    recv_q=$(ss -tlnp 2>/dev/null | grep "127.0.0.1:${REDSOCKS_PORT} " | awk '{print $2}' || echo "0")
    if [[ "$recv_q" =~ ^[0-9]+$ ]] && [[ "$recv_q" -gt "$REDSOCKS_QUEUE_THRESHOLD" ]]; then
        watchdog_log "WARNING: Redsocks recv-Q=${recv_q} > threshold=${REDSOCKS_QUEUE_THRESHOLD} — service hung!"
        
        # Attempt restart
        watchdog_log "Restarting hung redsocks..."
        systemctl restart redsocks-aro 2>/dev/null || true
        sleep 5
        
        if systemctl is-active --quiet redsocks-aro; then
            watchdog_log "SUCCESS: Redsocks restarted (queue cleared)"
            send_notify_redsocks_restarted || true
            return 0
        else
            watchdog_log "ERROR: Redsocks restart failed!"
            return 1
        fi
    fi

    return 0
}

# ── Real proxy connectivity check ───────────────────────────────
# Tests actual SOCKS5 tunnel to proxy server, independent of
# redsocks/iptables. Detects: proxy server offline, wrong creds,
# upstream routing failure. Runs every PROXY_CHECK_INTERVAL (10m).

check_real_proxy() {
    watchdog_log "Real proxy connectivity check: ${PROXY_HOST}:${PROXY_PORT}"

    local exit_ip=""
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        exit_ip=$(curl -s --max-time 10 \
            --socks5-hostname "${PROXY_HOST}:${PROXY_PORT}" --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
            "https://${endpoint}" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$exit_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        exit_ip=""
    done

    if [[ -z "$exit_ip" ]]; then
        watchdog_log "ERROR: Real proxy check FAILED — cannot reach ${PROXY_HOST}:${PROXY_PORT}"
        state_set "real_proxy_ok" "false"
        send_notify_proxy_down "proxy server unreachable or credentials rejected" || true
        return 1
    fi

    if [[ "$exit_ip" != "$_last_known_exit_ip" ]]; then
        watchdog_log "Real proxy check OK — exit IP: ${exit_ip}${_last_known_exit_ip:+ (was: $_last_known_exit_ip)}"
        _last_known_exit_ip="$exit_ip"
    fi
    state_set "real_proxy_ok" "true"
    return 0
}

# ── Real functional path check ──────────────────────────────────
# Tests if traffic from ubuntu user actually passes through transparent proxy.
# Returns 0 if working, 1 if broken.
check_redsocks_functional() {
    local test_ip=""
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        test_ip=$(sudo -u "$EFFECTIVE_USER" curl -s --max-time 5 "https://${endpoint}" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$test_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            return 0
        fi
    done
    return 1
}

# ── IP leak detection ────────────────────────────────────────────
# Compares exit IP (as ubuntu user, goes through transparent proxy)
# against real IP (as root, bypasses iptables).
# Returns: 0 = no leak, 1 = LEAK detected, 2 = inconclusive (no internet)
check_ip_leak() {
    local user_exit_ip=""
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        user_exit_ip=$(sudo -u "$EFFECTIVE_USER" curl -s --max-time 8 "https://${endpoint}" 2>/dev/null | tr -d '[:space:]' || true)
        [[ "$user_exit_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        user_exit_ip=""
    done

    if [[ -z "$user_exit_ip" ]]; then
        return 2
    fi

    local real_ip=""
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        real_ip=$(curl -s --max-time 8 "https://${endpoint}" 2>/dev/null | tr -d '[:space:]' || true)
        [[ "$real_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        real_ip=""
    done

    if [[ -z "$real_ip" ]]; then
        return 2
    fi

    if [[ "$user_exit_ip" == "$real_ip" ]]; then
        watchdog_log "🚨 IP LEAK: ubuntu exits as $user_exit_ip (= real IP $real_ip)"
        state_set "ip_leak_detected" "1"
        state_set "ip_leak_since" "$(date +%s)"
        state_set "ip_leak_exit_ip" "$user_exit_ip"
        state_set "ip_leak_real_ip" "$real_ip"
        return 1
    fi

    state_set "ip_leak_detected" "0"
    return 0
}

# Returns 0 = no IPv6 leak, 1 = IPv6 leak detected
check_ipv6_leak() {
    local ipv6_result
    ipv6_result=$(sudo -u "$EFFECTIVE_USER" curl -6 -s --max-time 5 "https://ifconfig.me" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -n "$ipv6_result" ]] && [[ "$ipv6_result" == *:* ]]; then
        watchdog_log "🚨 IPv6 LEAK: $ipv6_result"
        state_set "ipv6_leak_detected" "1"
        state_set "ipv6_leak_ip" "$ipv6_result"
        return 1
    fi
    state_set "ipv6_leak_detected" "0"
    return 0
}

check_disconnect_alert() {
    # Returns 0 (true) if ARO has been disconnected for >= DISCONNECT_ALERT_MINUTES
    local duration
    duration=$(get_disconnect_duration)
    [[ "$duration" -ge "$DISCONNECT_ALERT_MINUTES" ]]
}

# Trả về 0 (true) nếu đang trong grace period sau launch
is_in_grace_period() {
    local last_restart; last_restart=$(state_get "last_restart" "0")
    local now; now=$(date +%s)
    local since_launch=$(( now - last_restart ))
    
    [[ "$last_restart" -gt 0 ]] && [[ "$since_launch" -lt "$CONNECTING_GRACE_SECS" ]]
}

# Trả về số giây còn lại trong grace period
grace_period_remaining() {
    local last_restart; last_restart=$(state_get "last_restart" "0")
    local now; now=$(date +%s)
    local since_launch=$(( now - last_restart ))
    local remaining=$(( CONNECTING_GRACE_SECS - since_launch ))
    echo $(( remaining > 0 ? remaining : 0 ))
}

# Xử lý khi ARO process đang chạy nhưng không connect được (tray state != Online)
# Param $1: số phút đã disconnected
handle_stuck_connecting() {
    local stuck_mins="${1:-0}"

    # ── Grace period check ─────────────────────────────────────
    if is_in_grace_period; then
        local remaining; remaining=$(grace_period_remaining)
        watchdog_log "ARO disconnected ${stuck_mins}m but within grace period (${remaining}s remaining)"
        return 0
    fi

    watchdog_log "ARO stuck NoInternet for ${stuck_mins}m — starting recovery"

    # ── Bước 1: Test path thực sự của ARO (ubuntu traffic) ──────
    local tray_state; tray_state=$(get_aro_tray_state)
    if ! check_redsocks_functional; then
        # Redsocks transparent proxy bị broken (hung hoặc lỗi iptables)
        watchdog_log "Transparent proxy BROKEN — redsocks issue"
        send_notify_pre_restart "Transparent proxy broken (redsocks hung/iptables error)" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)" || true
        kill_aro
        
        # Restart redsocks và poll đến khi functional hoặc timeout
        systemctl restart redsocks-aro 2>/dev/null || true
        local proxy_wait_start; proxy_wait_start=$(date +%s)
        local redsocks_ok=false
        
        while true; do
            local elapsed=$(( $(date +%s) - proxy_wait_start ))
            if [[ "$elapsed" -ge "$PROXY_RESTART_TIMEOUT_SECS" ]]; then
                break
            fi
            sleep 5
            if check_redsocks_functional; then
                redsocks_ok=true
                break
            fi
        done
        
        if $redsocks_ok; then
            watchdog_log "Redsocks recovered — launching ARO"
            send_notify_proxy_recovered "stuck_connecting" || true
            launch_aro
            state_set "last_restart" "$(date +%s)"
            _wait_for_aro_online "redsocks_recovered"
        else
            watchdog_log "Redsocks recovery FAILED after ${PROXY_RESTART_TIMEOUT_SECS}s — ARO stays down"
            send_notify_proxy_dead || true
            # ARO tắt, chờ can thiệp thủ công
        fi
        return 0
    fi

    # ── Bước 2: Redsocks functional nhưng ARO vẫn NoInternet ───
    # Kiểm tra upstream proxy server (SOCKS5 target)
    watchdog_log "Transparent proxy OK — checking upstream proxy server"
    
    if ! check_real_proxy 2>/dev/null; then
        # Proxy server thực sự offline
        watchdog_log "Upstream proxy server DOWN — killing ARO to protect IP"
        send_notify_pre_restart "Upstream SOCKS5 proxy server unreachable" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)" || true
        kill_aro
        send_notify_proxy_down "proxy server unreachable" || true
        return 0
    fi

    # ── Bước 3: Mạng OK hết nhưng ARO vẫn stuck ────────────────
    # Có thể app gặp vấn đề nội bộ
    watchdog_log "Network path OK but ARO still stuck — restarting ARO app"
    send_notify_pre_restart "Network OK but ARO app stuck internally" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)" || true
    kill_aro
    sleep 3
    launch_aro
    state_set "last_restart" "$(date +%s)"
    
    _wait_for_aro_online "proxy_ok_aro_restarted"
}

# Helper: chờ ARO Online (tray state), poll mỗi CONNECTING_POLL_INTERVAL
# Param $1: context label dùng cho log & notification
_wait_for_aro_online() {
    local context="${1:-unknown}"
    
    # Guard: không cho chạy lồng nhau
    if [[ "$_WAIT_FOR_ARO_ONLINE_RUNNING" == "true" ]]; then
        watchdog_log "WARNING: _wait_for_aro_online already running (context: $context) — skipping"
        return 0
    fi
    _WAIT_FOR_ARO_ONLINE_RUNNING=true
    local wait_start; wait_start=$(date +%s)
    local retry_count; retry_count=$(state_get "retry_count" "0")

    watchdog_log "Waiting up to ${CONNECTING_WAIT_SECS}s for ARO tray=Online (context: $context)..."

    while true; do
        local elapsed=$(( $(date +%s) - wait_start ))
        if [[ "$elapsed" -ge "$CONNECTING_WAIT_SECS" ]]; then
            break
        fi
        sleep "$CONNECTING_POLL_INTERVAL"

        local tray_state
        tray_state=$(get_aro_tray_state)
        if [[ $(( elapsed % 60 )) -lt "$CONNECTING_POLL_INTERVAL" ]]; then
            watchdog_log "Waiting... tray=${tray_state:-unknown} ${elapsed}s / ${CONNECTING_WAIT_SECS}s"
        fi

        if [[ "$tray_state" == "Online" ]]; then
            watchdog_log "ARO online successfully after ${elapsed}s (context: $context)"
            send_notify_aro_reconnected "$context" "$elapsed" || true
            state_set "retry_count" "0"
            state_set "stable_since" "$(date +%s)"
            _WAIT_FOR_ARO_ONLINE_RUNNING=false
            return 0
        fi
    done

    # Hết thời gian, vẫn không online
    if [[ "$retry_count" -lt "$MAX_RETRIES" ]]; then
        retry_count=$(( retry_count + 1 ))
        state_set "retry_count" "$retry_count"
        watchdog_log "ARO still not online after ${CONNECTING_WAIT_SECS}s (retry $retry_count/$MAX_RETRIES)"
        send_notify_aro_stuck_manual "$retry_count" "$context" || true
    else
        watchdog_log "MAX RETRIES reached ($MAX_RETRIES) — giving up"
        send_notify_max_retries || true
        state_set "retry_count" "0"
    fi
    
    _WAIT_FOR_ARO_ONLINE_RUNNING=false
    return 0
}

# ── Maintenance mode helpers ────────────────────────────────────

# Set maintenance mode (tạo flag file)
maintenance_set() {
    touch "$MAINTENANCE_FLAG"
    watchdog_log "Maintenance mode ENABLED by user"
}

# Clear maintenance mode (xóa flag file)
maintenance_clear() {
    rm -f "$MAINTENANCE_FLAG"
    watchdog_log "Maintenance mode CLEARED"
}

# Check có đang trong maintenance mode không (kể cả check expire)
is_maintenance_mode() {
    [[ ! -f "$MAINTENANCE_FLAG" ]] && return 1   # không có flag → không maintenance
    
    # Kiểm tra expiry: nếu file cũ hơn MAINTENANCE_EXPIRE_MINS → tự expire
    if find "$MAINTENANCE_FLAG" -mmin +"$MAINTENANCE_EXPIRE_MINS" 2>/dev/null | grep -q .; then
        rm -f "$MAINTENANCE_FLAG"
        watchdog_log "Maintenance mode expired (>${MAINTENANCE_EXPIRE_MINS}m) — auto-cleared"
        return 1
    fi
    
    return 0
}

# Trả về số phút maintenance đã active
maintenance_age_mins() {
    if [[ -f "$MAINTENANCE_FLAG" ]]; then
        echo $(( ( $(date +%s) - $(stat -c %Y "$MAINTENANCE_FLAG" 2>/dev/null || echo 0) ) / 60 ))
    else
        echo "0"
    fi
}

state_get() {
    local key="$1"
    local default="${2:-}"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "$default"
        return
    fi
    
    local val
    val=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2- || echo "$default")
    echo "$val"
}

state_set() {
    local key="$1"
    local value="$2"
    
    local lock="${STATE_FILE}.lock"
    local temp="${STATE_FILE}.tmp"
    
    (
        flock -w 5 200 || exit 1
        
        if [[ -f "$STATE_FILE" ]]; then
            grep -v "^${key}=" "$STATE_FILE" > "$temp" 2>/dev/null
        else
            : > "$temp"
        fi
        
        echo "${key}=${value}" >> "$temp"
        [[ -f "$temp" ]] && mv "$temp" "$STATE_FILE" || return 1
        
    ) 200>"$lock" || watchdog_log "WARNING: state_set '$key' failed (flock timeout or write error)"
}

aro_set_give_up() {
    state_set "aro_give_up" "1"
    watchdog_log "Give-up flag SET — watchdog will not restart ARO until cleared"
}

aro_clear_give_up() {
    state_set "aro_give_up" "0"
    watchdog_log "Give-up flag CLEARED — watchdog will resume ARO monitoring"
}

aro_is_give_up() {
    [[ "$(state_get 'aro_give_up' '0')" == "1" ]]
}

apply_dashboard_periodic_config() {
    local new_min; new_min=$(state_get "dashboard_periodic_min" "")
    local new_max; new_max=$(state_get "dashboard_periodic_max" "")
    [[ -z "$new_min" ]] || [[ -z "$new_max" ]] && return 0
    [[ "$new_min" =~ ^[0-9]+$ ]] && [[ "$new_max" =~ ^[0-9]+$ ]] || return 0
    [[ $new_min -lt $new_max ]] || return 0

    if [[ "$new_min" != "$PERIODIC_RESTART_MIN_MINS" ]] || [[ "$new_max" != "$PERIODIC_RESTART_MAX_MINS" ]]; then
        watchdog_log "Dashboard config: cập nhật periodic restart ${PERIODIC_RESTART_MIN_MINS}–${PERIODIC_RESTART_MAX_MINS}m → ${new_min}–${new_max}m"
        PERIODIC_RESTART_MIN_MINS=$new_min
        PERIODIC_RESTART_MAX_MINS=$new_max
        schedule_next_periodic_restart
    fi

    local new_wait; new_wait=$(state_get "dashboard_periodic_wait" "")
    if [[ -n "$new_wait" ]] && [[ "$new_wait" =~ ^[0-9]+$ ]] && [[ $new_wait -ge 1 ]] && [[ $new_wait -le 20 ]]; then
        if [[ "$new_wait" != "$PERIODIC_RESTART_WAIT_MINS" ]]; then
            watchdog_log "Dashboard config: periodic restart wait ${PERIODIC_RESTART_WAIT_MINS}m → ${new_wait}m"
            PERIODIC_RESTART_WAIT_MINS=$new_wait
        fi
    fi
}

apply_dashboard_daily_report_config() {
    local new_val; new_val=$(state_get "dashboard_daily_report_enabled" "")
    [[ -z "$new_val" ]] && return 0
    if [[ "$new_val" != "$DAILY_REPORT_ENABLED" ]]; then
        watchdog_log "Dashboard config: daily report ${DAILY_REPORT_ENABLED} → ${new_val}"
        DAILY_REPORT_ENABLED=$new_val
    fi
}

apply_dashboard_log_stale_config() {
    local new_val; new_val=$(state_get "dashboard_log_stale_restart_minutes" "")
    [[ -z "$new_val" ]] && return 0
    [[ "$new_val" =~ ^[0-9]+$ ]] || return 0
    [[ $new_val -ge 1 ]] || return 0
    if [[ "$new_val" != "$STALE_RESTART_MINUTES" ]]; then
        watchdog_log "Dashboard config: log stale restart ${STALE_RESTART_MINUTES}m → ${new_val}m"
        STALE_RESTART_MINUTES=$new_val
    fi
}

apply_dashboard_vps_reboot_config() {
    local new_count; new_count=$(state_get "dashboard_vps_reboot_count" "")
    local new_enabled; new_enabled=$(state_get "dashboard_vps_reboot_enabled" "")

    if [[ -n "$new_count" ]] && [[ "$new_count" =~ ^[0-9]+$ ]] && \
       [[ $new_count -ge 1 ]] && [[ $new_count -le 24 ]]; then
        if [[ "$new_count" != "$PERIODIC_VPS_REBOOT_COUNT" ]]; then
            watchdog_log "Dashboard config: VPS reboot ${PERIODIC_VPS_REBOOT_COUNT}x/day → ${new_count}x/day"
            PERIODIC_VPS_REBOOT_COUNT=$new_count
            schedule_next_periodic_vps_reboot
        fi
    fi

    if [[ -n "$new_enabled" ]] && [[ "$new_enabled" != "$PERIODIC_VPS_REBOOT_ENABLED" ]]; then
        watchdog_log "Dashboard config: VPS reboot enabled ${PERIODIC_VPS_REBOOT_ENABLED} → ${new_enabled}"
        PERIODIC_VPS_REBOOT_ENABLED=$new_enabled
        if [[ "$new_enabled" == "true" ]] && [[ $_next_periodic_vps_reboot -eq 0 ]]; then
            schedule_next_periodic_vps_reboot
        fi
    fi
}

schedule_next_periodic_restart() {
    local range=$(( PERIODIC_RESTART_MAX_MINS - PERIODIC_RESTART_MIN_MINS ))
    local rand_mins=$(( RANDOM % (range + 1) + PERIODIC_RESTART_MIN_MINS ))
    _next_periodic_restart=$(( $(date +%s) + rand_mins * 60 ))
    local next_time
    next_time=$(date -d "@$_next_periodic_restart" '+%H:%M:%S' 2>/dev/null \
        || date -r "$_next_periodic_restart" '+%H:%M:%S' 2>/dev/null \
        || echo "$_next_periodic_restart")
    watchdog_log "Next periodic ARO restart scheduled in ${rand_mins}m (at ${next_time})"
}

schedule_next_periodic_vps_reboot() {
    local base=$(( 24 * 60 / PERIODIC_VPS_REBOOT_COUNT ))
    local jitter=$(( RANDOM % 61 - 30 ))   # ±30 phút ngẫu nhiên để giãn cách các node
    local next_mins=$(( base + jitter ))
    [[ $next_mins -lt 30 ]] && next_mins=30
    _next_periodic_vps_reboot=$(( $(date +%s) + next_mins * 60 ))
    local next_time
    next_time=$(date -d "@$_next_periodic_vps_reboot" '+%H:%M' 2>/dev/null \
        || date -r "$_next_periodic_vps_reboot" '+%H:%M' 2>/dev/null \
        || echo "${next_mins}m")
    watchdog_log "Next periodic VPS reboot in ${next_mins}m (at ${next_time}) [${PERIODIC_VPS_REBOOT_COUNT}x/day]"
}

report_periodic_restart_to_dashboard() {
    local success="${1:-true}"
    local duration_secs="${2:-0}"

    [[ "${DASHBOARD_ENABLED:-false}" != "true" ]] && return 0
    [[ -z "$DASHBOARD_URL" ]] || [[ -z "$DASHBOARD_API_KEY" ]] && return 0

    local base_url="${DASHBOARD_URL%/}"
    local node_id="$HOSTNAME"

    local payload
    payload=$(python3 -c "
import json, sys
d = {
    'node_id':       sys.argv[1],
    'api_key':       sys.argv[2],
    'success':       sys.argv[3] == 'true',
    'duration_secs': int(sys.argv[4]) if sys.argv[4].isdigit() else 0,
}
print(json.dumps(d))
" "$node_id" "$DASHBOARD_API_KEY" "$success" "$duration_secs" 2>/dev/null) || return 0

    curl -sf --max-time 8 \
        -X POST "${base_url}/api/v1/nodes/restart-event" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

watchdog_loop() {
    watchdog_log "=== ARO Manager Watchdog Started ==="
    watchdog_log "Version: $SCRIPT_VERSION"
    watchdog_log "Host: $HOSTNAME"
    watchdog_log "Env: $ENV_TYPE"
    watchdog_log "User: $EFFECTIVE_USER"
    watchdog_log "Display: $DISPLAY_NUM | XAUTH: $XAUTHORITY_PATH"
    watchdog_log "Proxy: $PROXY_HOST:$PROXY_PORT"
    watchdog_log "Check interval: ${CHECK_INTERVAL}s"
    
    # Initialize state - distinguish fresh start vs update restart
    local _is_update_restart=0
    if [[ "$(state_get "$UPDATE_RESTART_FLAG" "0")" == "1" ]]; then
        _is_update_restart=1
        watchdog_log "Update restart detected - preserving ARO state (uptime protected)"
    fi

    # Clear flag immediately after reading it.
    state_set "$UPDATE_RESTART_FLAG" "0"

    if [[ $_is_update_restart -eq 0 ]]; then
        # Fresh start: reset state as before.
        state_set "retry_count" "0"
        aro_clear_give_up
        state_set "last_restart" "0"
        state_set "last_report" "0"
        state_set "stable_since" "$(date +%s)"
        state_set "tray_unknown_since" "0"
        state_set "give_up_since" "0"
        state_set "log_stale_since" "0"
    else
        # Update restart: preserve state; set last_restart only if missing so grace applies.
        local preserved_last_restart
        preserved_last_restart=$(state_get "last_restart" "0")
        if ! [[ "$preserved_last_restart" =~ ^[0-9]+$ ]] || [[ "$preserved_last_restart" -eq 0 ]]; then
            state_set "last_restart" "$(date +%s)"
        fi
        watchdog_log "State preserved: last_restart=$preserved_last_restart retry_count=$(state_get retry_count 0)"
    fi
    rm -f "$TG_RETRY_AFTER_FILE"   # Clear rate limit state on watchdog start
    state_set "tg_enabled" "${TG_ENABLED:-1}"   # Sync state file từ config khi khởi động
    _unbound_last_log=0

    local last_daily_hour=-1
    local last_proxy_check_epoch=0   # tracks real proxy check timer
    local last_ip_leak_check_epoch=0 # tracks IP leak check timer
    # Update restart: skip immediate checks until intervals elapse.
    if [[ $_is_update_restart -eq 1 ]]; then
        last_proxy_check_epoch=$(date +%s)
        last_ip_leak_check_epoch=$(date +%s)
    fi

    # Schedule first periodic restart (54–120 minutes from now)
    schedule_next_periodic_restart

    # Schedule first periodic VPS reboot
    if [[ "$PERIODIC_VPS_REBOOT_ENABLED" == "true" ]]; then
        schedule_next_periodic_vps_reboot
    fi

    while true; do
        local now; now=$(date +%s)

        # ── Áp dụng cấu hình periodic restart từ dashboard (nếu có cập nhật) ──
        apply_dashboard_periodic_config
        apply_dashboard_daily_report_config
        apply_dashboard_log_stale_config
        apply_dashboard_vps_reboot_config

        # ── Maintenance mode check ──────────────────────────────────
        if is_maintenance_mode; then
            local maint_age; maint_age=$(maintenance_age_mins)
            watchdog_log "Maintenance mode active (${maint_age}m) — skipping ARO checks"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # ── Give-up check ────────────────────────────────────────────
        if aro_is_give_up; then
            local give_up_since
            give_up_since=$(state_get "give_up_since" "0")
            local now_ts; now_ts=$(date +%s)

            if [[ "$give_up_since" -eq 0 ]]; then
                # Lần đầu vào give-up: ghi timestamp
                state_set "give_up_since" "$now_ts"
                watchdog_log "Give-up flag active — will auto-retry in ${GIVE_UP_RETRY_MINS}m (run 'start' to reset)"
            else
                local elapsed_mins=$(( (now_ts - give_up_since) / 60 ))
                if [[ $elapsed_mins -ge $GIVE_UP_RETRY_MINS ]]; then
                    watchdog_log "Give-up auto-retry triggered after ${elapsed_mins}m — clearing flag"
                    state_set "aro_give_up" "0"
                    state_set "retry_count" "0"
                    state_set "give_up_since" "0"
                    # Tiếp tục vòng lặp bình thường (không sleep, không continue)
                else
                    local remaining=$(( GIVE_UP_RETRY_MINS - elapsed_mins ))
                    watchdog_log "Give-up flag active — auto-retry in ${remaining}m (run 'start' to reset now)"
                    report_to_dashboard "proxy_expired" &
                    sleep "$CHECK_INTERVAL"
                    continue
                fi
            fi
        fi

        # ── Real proxy check + proxy-dead state machine ─────────────
        if [[ "${USE_PROXY:-1}" -eq 1 ]]; then
            local proxy_dead; proxy_dead=$(state_get "proxy_dead" "0")

            if [[ "$proxy_dead" == "1" ]]; then
                # Proxy đang chết — không restart ARO, chờ proxy hồi phục
                if [[ $(( now - last_proxy_check_epoch )) -ge $PROXY_CHECK_INTERVAL ]]; then
                    watchdog_log "Proxy dead — re-checking connectivity..."
                    if check_real_proxy 2>/dev/null; then
                        watchdog_log "Proxy RECOVERED — resuming normal operation"
                        state_set "proxy_dead" "0"
                        state_set "retry_count" "0"
                        local rec_msg="✅ <b>[PROXY RECOVERED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"
                        send_telegram "$rec_msg" || true
                        last_proxy_check_epoch=$(date +%s)
                        # Tiếp tục vòng lặp bình thường (ARO sẽ được start lại ở dưới)
                    else
                        last_proxy_check_epoch=$(date +%s)
                        report_to_dashboard "proxy_expired" &
                        sleep "$CHECK_INTERVAL"
                        continue
                    fi
                else
                    local dead_since; dead_since=$(state_get "proxy_dead_since" "0")
                    local dead_mins=$(( (now - dead_since) / 60 ))
                    watchdog_log "Proxy dead for ${dead_mins}m — waiting for recovery (next check in $(( PROXY_CHECK_INTERVAL - (now - last_proxy_check_epoch) ))s)"
                    report_to_dashboard "proxy_expired" &
                    sleep "$CHECK_INTERVAL"
                    continue
                fi
            elif [[ $(( now - last_proxy_check_epoch )) -ge $PROXY_CHECK_INTERVAL ]]; then
                if ! check_real_proxy 2>/dev/null; then
                    watchdog_log "Proxy DEAD — entering proxy_dead state, killing ARO"
                    state_set "proxy_dead" "1"
                    state_set "proxy_dead_since" "$now"
                    kill_aro
                    send_notify_proxy_down "Upstream SOCKS5 server unreachable — ARO killed, waiting for proxy recovery" || true
                    last_proxy_check_epoch=$(date +%s)
                    report_to_dashboard "proxy_expired" &
                    sleep "$CHECK_INTERVAL"
                    continue
                fi
                last_proxy_check_epoch=$(date +%s)
            fi
        fi

        # ── IP Leak check (every IP_LEAK_CHECK_INTERVAL, proxy mode only) ──
        if [[ "${USE_PROXY:-1}" -eq 1 ]] && [[ "$(state_get "proxy_dead" "0")" != "1" ]]; then
            if [[ $(( now - last_ip_leak_check_epoch )) -ge $IP_LEAK_CHECK_INTERVAL ]]; then
                local _current_leak; _current_leak=$(state_get "ip_leak_detected" "0")
                if [[ "$_current_leak" == "1" ]]; then
                    # Already in leak state — continue recovery attempts
                    if ! handle_ip_leak_recovery 2>/dev/null; then
                        last_ip_leak_check_epoch=$(date +%s)
                        report_to_dashboard &
                        sleep "$CHECK_INTERVAL"
                        continue
                    fi
                    # Recovery succeeded — fall through to normal ARO management
                else
                    local _leak_result=0
                    check_ip_leak 2>/dev/null || _leak_result=$?
                    if [[ "$_leak_result" -eq 1 ]]; then
                        local _leak_exit; _leak_exit=$(state_get "ip_leak_exit_ip" "unknown")
                        local _leak_real; _leak_real=$(state_get "ip_leak_real_ip" "unknown")
                        watchdog_log "IP LEAK detected — killing ARO, starting auto-recovery"
                        kill_aro
                        state_set "ip_leak_recovery_count" "0"
                        send_notify_ip_leak "$_leak_exit" "$_leak_real" "0" || true
                        if ! handle_ip_leak_recovery 2>/dev/null; then
                            last_ip_leak_check_epoch=$(date +%s)
                            report_to_dashboard &
                            sleep "$CHECK_INTERVAL"
                            continue
                        fi
                        # Recovery succeeded — fall through
                    fi
                    # _leak_result=2 (inconclusive) → do nothing
                fi
                last_ip_leak_check_epoch=$(date +%s)
            fi
        fi

        # ── Redsocks service / port check (every cycle) ──
        if [[ "${USE_PROXY:-1}" -eq 1 ]]; then
            if ! check_proxy_health; then
                watchdog_log "Proxy unhealthy, skipping ARO checks this cycle"
                report_to_dashboard "proxy_expired" &
                sleep "$CHECK_INTERVAL"
                continue
            fi
        fi
        
        # Check if ARO is running
        if is_aro_running; then
            LATEST_LOG_FILE=$(get_latest_aro_log)
            
            if is_log_fresh; then
                # Khi log fresh trở lại, reset stale tracker
                local log_stale_since; log_stale_since=$(state_get "log_stale_since" "0")
                if [[ "$log_stale_since" -ne 0 ]]; then
                    watchdog_log "ARO log recovered (was stale) — resetting stale tracker"
                    state_set "log_stale_since" "0"
                fi

                # Log đang được ghi đều — check tray state thực sự
                local tray_state
                tray_state=$(get_aro_tray_state)
                local now; now=$(date +%s)

                case "$tray_state" in
                    Online)
                        # ── ARO connected & healthy ──────────────────────
                        state_set "tray_unknown_since" "0"
                        local retry_count
                        retry_count=$(state_get "retry_count" "0")

                        if [[ $retry_count -gt 0 ]]; then
                            watchdog_log "ARO healthy (tray=Online) after recovery"
                        fi

                        local stable_since; stable_since=$(state_get "stable_since")
                        local stable_duration=$(( now - stable_since ))
                        local reset_threshold=$(( RESET_STABLE_HOURS * 3600 ))

                        if [[ $stable_duration -gt $reset_threshold ]] && [[ $retry_count -gt 0 ]]; then
                            watchdog_log "ARO stable for ${RESET_STABLE_HOURS}h, resetting retry counter"
                            state_set "retry_count" "0"
                        fi

                        # ── Periodic restart (mỗi 54–120 phút ngẫu nhiên) ──
                        if [[ $_next_periodic_restart -gt 0 ]] && [[ $now -ge $_next_periodic_restart ]]; then
                            watchdog_log "Periodic ARO restart triggered — tắt ARO, chờ ${PERIODIC_RESTART_WAIT_MINS}m rồi khởi động lại"
                            local _pr_start; _pr_start=$(date +%s)
                            kill_aro

                            # Chờ thời gian cấu hình; vẫn gửi report lên dashboard định kỳ
                            local _wait_end=$(( $(date +%s) + PERIODIC_RESTART_WAIT_MINS * 60 ))
                            local _wait_report_interval=30
                            local _wait_last_report=0
                            while [[ $(date +%s) -lt $_wait_end ]]; do
                                local _now_w; _now_w=$(date +%s)
                                local _remaining=$(( _wait_end - _now_w ))
                                if [[ $(( _now_w - _wait_last_report )) -ge $_wait_report_interval ]]; then
                                    watchdog_log "Periodic restart: đang chờ ${_remaining}s trước khi khởi động lại ARO"
                                    report_to_dashboard "Offline" &
                                    _wait_last_report=$_now_w
                                fi
                                sleep 5
                            done

                            launch_aro
                            state_set "last_restart" "$(date +%s)"
                            state_set "stable_since" "$(date +%s)"

                            local _pr_waited=0
                            local _pr_online=0
                            while [[ $_pr_waited -lt $CONNECTING_WAIT_SECS ]]; do
                                sleep "$CONNECTING_POLL_INTERVAL"
                                _pr_waited=$(( _pr_waited + CONNECTING_POLL_INTERVAL ))
                                local _pr_tray; _pr_tray=$(get_aro_tray_state)
                                watchdog_log "Periodic restart: chờ ARO online (${_pr_waited}s, tray=${_pr_tray:-unknown})"
                                if [[ "$_pr_tray" == "Online" ]]; then
                                    _pr_online=1
                                    break
                                fi
                            done

                            local _pr_duration=$(( $(date +%s) - _pr_start ))
                            if [[ $_pr_online -eq 1 ]]; then
                                watchdog_log "Periodic restart THÀNH CÔNG — ARO online trở lại sau ${_pr_duration}s"
                                report_periodic_restart_to_dashboard "true" "$_pr_duration" &
                            else
                                watchdog_log "Periodic restart: ARO chưa online sau ${CONNECTING_WAIT_SECS}s"
                                report_periodic_restart_to_dashboard "false" "$_pr_duration" &
                            fi
                            schedule_next_periodic_restart
                        fi

                        # ── Periodic VPS reboot (định kỳ reboot toàn bộ VPS) ──────────
                        if [[ "$PERIODIC_VPS_REBOOT_ENABLED" == "true" ]] && \
                           [[ $_next_periodic_vps_reboot -gt 0 ]] && \
                           [[ $now -ge $_next_periodic_vps_reboot ]]; then
                            watchdog_log "Periodic VPS reboot triggered (${PERIODIC_VPS_REBOOT_COUNT}x/day) — VPS sẽ reboot trong 1 phút"
                            _next_periodic_vps_reboot=0   # Tránh trigger lại trong 1 phút chờ shutdown
                            shutdown -r +1 "Periodic VPS reboot" &
                        fi
                        ;;
                    
                    Offline)
                        # Vừa khởi động hoặc đang check mạng — kiểm tra grace period
                        state_set "tray_unknown_since" "0"
                        local last_restart; last_restart=$(state_get "last_restart" "0")
                        local since_launch=$(( now - last_restart ))

                        if is_in_grace_period; then
                            local remaining=$(( CONNECTING_GRACE_SECS - since_launch ))
                            local now_ts; now_ts=$(date +%s)
                            if [[ $(( now_ts - _grace_period_last_log )) -ge 60 ]]; then
                                watchdog_log "ARO tray=Offline, in startup grace period (${remaining}s remaining)"
                                _grace_period_last_log=$now_ts
                            fi
                        else
                            watchdog_log "ARO tray=Offline beyond grace period — treating as stuck"
                            local stuck_mins=$(( since_launch / 60 ))
                            handle_stuck_connecting "$stuck_mins"
                        fi
                        ;;

                    NoInternet)
                        # Stuck — tính thời gian
                        state_set "tray_unknown_since" "0"
                        local stuck_mins
                        stuck_mins=$(get_disconnected_since_minutes)

                        if [[ "$stuck_mins" -ge "$STUCK_THRESHOLD_MINUTES" ]]; then
                            handle_stuck_connecting "$stuck_mins"
                        else
                            local now_ts; now_ts=$(date +%s)
                            if [[ $(( now_ts - _nointernet_last_log )) -ge 120 ]]; then
                                watchdog_log "ARO tray=NoInternet for ${stuck_mins}m (threshold: ${STUCK_THRESHOLD_MINUTES}m)"
                                _nointernet_last_log=$now_ts
                            fi
                        fi
                        ;;

                    Unbound)
                        # Node chưa bind tài khoản — ARO chạy bình thường, chỉ chờ bind
                        # Không restart, không đếm unknown timer
                        # Khi bind xong ARO tự chuyển sang connected — không cần can thiệp
                        state_set "tray_unknown_since" "0"
                        local now_ts; now_ts=$(date +%s)
                        if [[ $(( now_ts - _unbound_last_log )) -ge 300 ]]; then
                            watchdog_log "ARO running, waiting for account bind — monitoring"
                            _unbound_last_log=$now_ts
                        fi
                        ;;

                    *)
                        # State không xác định hoặc log chưa có entry tray
                        # Track thời gian bắt đầu unknown
                        local unknown_since; unknown_since=$(state_get "tray_unknown_since" "0")
                        if [[ "$unknown_since" -eq 0 ]]; then
                            state_set "tray_unknown_since" "$now"
                            unknown_since="$now"
                        fi

                        local unknown_mins=$(( (now - unknown_since) / 60 ))

                        if [[ "$unknown_mins" -ge "$TRAY_UNKNOWN_THRESHOLD_MINUTES" ]]; then
                            # Đã unknown đủ lâu → restart
                            watchdog_log "ARO tray state unknown for ${unknown_mins}m (threshold: ${TRAY_UNKNOWN_THRESHOLD_MINUTES}m) — restarting"
                            state_set "tray_unknown_since" "0"

                            local retry_count; retry_count=$(state_get "retry_count" "0")
                            if [[ $retry_count -lt $MAX_RETRIES ]]; then
                                retry_count=$(( retry_count + 1 ))
                                state_set "retry_count" "$retry_count"
                                send_notify_pre_restart "ARO tray state unknown for ${unknown_mins}m" "unknown" "$unknown_mins" "$retry_count" || true
                                kill_aro
                                sleep 3
                                launch_aro
                                state_set "last_restart" "$(date +%s)"
                                state_set "stable_since" "$(date +%s)"
                                watchdog_log "Waiting for ARO to start (timeout: ${STARTUP_TIMEOUT}s)..."
                                local waited=0
                                local poll_interval=10
                                local log_appeared=0

                                while [[ $waited -lt $STARTUP_TIMEOUT ]]; do
                                    sleep "$poll_interval"
                                    waited=$(( waited + poll_interval ))
                                    LATEST_LOG_FILE=$(get_latest_aro_log)
                                    if [[ -n "$LATEST_LOG_FILE" ]] && run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null; then
                                        log_appeared=1
                                        watchdog_log "ARO log appeared after ${waited}s"
                                        break
                                    fi
                                done

                                if is_aro_running && [[ $log_appeared -eq 1 ]]; then
                                    watchdog_log "ARO restarted after unknown tray state (retry $retry_count/$MAX_RETRIES)"
                                    send_notify_restart_success "$retry_count" || true
                                else
                                    watchdog_log "ARO failed to start after unknown tray restart (log appeared: $log_appeared)"
                                    local start_err; start_err=$(get_aro_start_error)
                                    send_notify_aro_start_failed "$retry_count" "$start_err" || true
                                fi
                            else
                                watchdog_log "MAX RETRIES REACHED ($MAX_RETRIES) - giving up (tray unknown)"
                                send_notify_max_retries || true
                                state_set "retry_count" "0"
                                aro_set_give_up
                            fi
                        else
                            # Chưa đủ threshold — log định kỳ mỗi 2 phút
                            local now_ts; now_ts=$(date +%s)
                            if [[ $(( now_ts - _tray_unknown_last_log )) -ge 120 ]]; then
                                watchdog_log "ARO tray state unknown ('${tray_state}') for ${unknown_mins}m (threshold: ${TRAY_UNKNOWN_THRESHOLD_MINUTES}m) — monitoring"
                                _tray_unknown_last_log=$now_ts
                            fi
                        fi
                        ;;
                esac
            else
                # ── Log stale (>LOG_STALE_MINUTES) ──
                local now_ts; now_ts=$(date +%s)
                local log_stale_since; log_stale_since=$(state_get "log_stale_since" "0")

                # Ghi timestamp lần đầu phát hiện stale
                if [[ "$log_stale_since" -eq 0 ]]; then
                    state_set "log_stale_since" "$now_ts"
                    log_stale_since=$now_ts
                fi

                local stale_mins=$(( (now_ts - log_stale_since) / 60 ))
                watchdog_log "ARO process running but log is stale (>${LOG_STALE_MINUTES}m, stale for ${stale_mins}m)"

                if check_disconnect_alert; then
                    # Case 1: Stale + disconnected ≥ 15m → restart (logic cũ giữ nguyên)
                    watchdog_log "Recent disconnect detected, attempting restart"
                    state_set "log_stale_since" "0"
                    
                    local retry_count; retry_count=$(state_get "retry_count" "0")
                    if [[ $retry_count -lt $MAX_RETRIES ]]; then
                        retry_count=$((retry_count + 1))
                        state_set "retry_count" "$retry_count"
                        
                        # Apply backoff delay
                        local backoff_array=($BACKOFF_TIMES)
                        local backoff_index=$((retry_count - 1))
                        local backoff_delay=0
                        
                        if [[ $backoff_index -lt ${#backoff_array[@]} ]]; then
                            backoff_delay=${backoff_array[$backoff_index]}
                        else
                            backoff_delay=${backoff_array[-1]}
                        fi
                        
                        if [[ $backoff_delay -gt 0 ]]; then
                            watchdog_log "Applying backoff delay: ${backoff_delay}s (retry $retry_count/$MAX_RETRIES)"
                            sleep "$backoff_delay"
                        fi
                        
                        # Notify BEFORE kill
                        local disc_mins; disc_mins=$(get_disconnect_duration)
                        send_notify_pre_restart "Log stale >$LOG_STALE_MINUTES min, disconnected ${disc_mins}min" "$(get_aro_tray_state)" "$disc_mins" "$retry_count" || true

                        # Kill and restart
                        kill_aro
                        sleep 3

                        # Check display trước khi launch
                        if ! check_display_accessible; then
                            local disp_err="Display ${DISPLAY_NUM} not accessible — check X server and XAUTHORITY"
                            watchdog_log "ERROR: $disp_err"
                            send_notify_aro_start_failed "$retry_count" "$disp_err" || true
                            sleep "$CHECK_INTERVAL"
                            continue
                        fi

                        launch_aro
                        
                        state_set "last_restart" "$(date +%s)"
                        state_set "stable_since" "$(date +%s)"
                        
                        # Wait for startup
                        watchdog_log "Waiting for ARO to start (timeout: ${STARTUP_TIMEOUT}s)..."
                        local waited=0
                        local poll_interval=10
                        local log_appeared=0

                        while [[ $waited -lt $STARTUP_TIMEOUT ]]; do
                            sleep "$poll_interval"
                            waited=$(( waited + poll_interval ))
                            LATEST_LOG_FILE=$(get_latest_aro_log)
                            if [[ -n "$LATEST_LOG_FILE" ]] && run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null; then
                                log_appeared=1
                                watchdog_log "ARO log appeared after ${waited}s"
                                break
                            fi
                        done
                        
                        if is_aro_running && is_log_fresh; then
                            watchdog_log "ARO restarted successfully (retry $retry_count/$MAX_RETRIES)"
                            send_notify_restart_success "$retry_count" || true
                        else
                            watchdog_log "ARO restart verification failed (retry $retry_count/$MAX_RETRIES, log appeared: $log_appeared)"
                            local start_err; start_err=$(get_aro_start_error)
                            watchdog_log "Start error: $start_err"
                            send_notify_aro_start_failed "$retry_count" "$start_err" || true
                        fi
                    else
                        watchdog_log "MAX RETRIES REACHED ($MAX_RETRIES) - giving up"
                        send_notify_max_retries || true
                        state_set "retry_count" "0"
                        aro_set_give_up
                    fi
                elif [[ $stale_mins -ge $STALE_RESTART_MINUTES ]]; then
                    # Case 2: Stale kéo dài ≥ 30m dù tray=Online → ARO frozen, force restart
                    watchdog_log "ARO log stale for ${stale_mins}m (threshold: ${STALE_RESTART_MINUTES}m) — force restart (frozen while Online)"
                    state_set "log_stale_since" "0"

                    local retry_count; retry_count=$(state_get "retry_count" "0")
                    if [[ $retry_count -lt $MAX_RETRIES ]]; then
                        retry_count=$((retry_count + 1))
                        state_set "retry_count" "$retry_count"

                        send_notify_pre_restart "ARO frozen ${stale_mins}m (log stale, tray=Online)" "$(get_aro_tray_state)" "0" "$retry_count" || true
                        kill_aro
                        sleep 3
                        if ! check_display_accessible; then
                            watchdog_log "ERROR: Display ${DISPLAY_NUM} not accessible"
                            sleep "$CHECK_INTERVAL"
                            continue
                        fi
                        launch_aro
                        state_set "last_restart" "$(date +%s)"
                        state_set "stable_since" "$(date +%s)"
                        
                        watchdog_log "Waiting for ARO to start (timeout: ${STARTUP_TIMEOUT}s)..."
                        local waited=0
                        local poll_interval=10
                        local log_appeared=0

                        while [[ $waited -lt $STARTUP_TIMEOUT ]]; do
                            sleep "$poll_interval"
                            waited=$(( waited + poll_interval ))
                            LATEST_LOG_FILE=$(get_latest_aro_log)
                            if [[ -n "$LATEST_LOG_FILE" ]] && run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null; then
                                log_appeared=1
                                watchdog_log "ARO log appeared after ${waited}s"
                                break
                            fi
                        done
                    else
                        watchdog_log "MAX RETRIES REACHED — giving up (frozen ARO)"
                        state_set "aro_give_up" "1"
                    fi
                else
                    # Case 3: Stale nhưng chưa đủ threshold → log định kỳ mỗi 2 phút
                    local _stale_last_log; _stale_last_log=$(state_get "_stale_last_log" "0")
                    if [[ $(( now_ts - _stale_last_log )) -ge 120 ]]; then
                        watchdog_log "ARO log stale for ${stale_mins}m — waiting (threshold: ${STALE_RESTART_MINUTES}m)"
                        state_set "_stale_last_log" "$now_ts"
                    fi
                fi
            fi
        else
            # ARO is not running - start it
            watchdog_log "ARO not running, starting..."
            
            local retry_count
            retry_count=$(state_get "retry_count" "0")
            
            if [[ $retry_count -lt $MAX_RETRIES ]]; then
                retry_count=$((retry_count + 1))
                state_set "retry_count" "$retry_count"
                watchdog_log "ARO not running, starting... (Retry $retry_count/$MAX_RETRIES)"
                
                # Check display trước khi launch
                if ! check_display_accessible; then
                    local disp_err="Display ${DISPLAY_NUM} not accessible — check X server and XAUTHORITY"
                    watchdog_log "ERROR: $disp_err"
                    send_notify_aro_start_failed "$retry_count" "$disp_err" || true
                    sleep "$CHECK_INTERVAL"
                    continue
                fi

                send_notify_pre_restart "ARO process not found (crashed or killed)" "not_running" "0" "$retry_count" || true
                launch_aro
                state_set "last_restart" "$(date +%s)"
                state_set "stable_since" "$(date +%s)"
                
                watchdog_log "Waiting for ARO to start (timeout: ${STARTUP_TIMEOUT}s)..."
                local waited=0
                local poll_interval=10
                local log_appeared=0

                while [[ $waited -lt $STARTUP_TIMEOUT ]]; do
                    sleep "$poll_interval"
                    waited=$(( waited + poll_interval ))
                    LATEST_LOG_FILE=$(get_latest_aro_log)
                    if [[ -n "$LATEST_LOG_FILE" ]] && run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null; then
                        log_appeared=1
                        watchdog_log "ARO log appeared after ${waited}s"
                        break
                    fi
                done
                
                if is_aro_running; then
                    watchdog_log "ARO started successfully"
                    send_notify_restart_success "$retry_count" || true
                else
                    watchdog_log "ARO failed to start (log appeared: $log_appeared)"
                    local start_err; start_err=$(get_aro_start_error)
                    watchdog_log "Start error: $start_err"
                    send_notify_aro_start_failed "$retry_count" "$start_err" || true
                fi
            else
                watchdog_log "MAX RETRIES REACHED ($MAX_RETRIES) - giving up"
                send_notify_max_retries || true
                state_set "retry_count" "0"
                aro_set_give_up
            fi
        fi
        
        # Daily report
        local current_hour
        current_hour=$(( 10#$(date +%H) ))   # Force base-10, an toàn với 08, 09
        
        if [[ $current_hour -eq $DAILY_REPORT_HOUR ]] && [[ $last_daily_hour -ne $current_hour ]]; then
            if [[ "$DAILY_REPORT_ENABLED" == "true" ]]; then
                watchdog_log "Sending daily report..."
                send_daily_report
            else
                watchdog_log "Daily report disabled — skipping"
            fi
            last_daily_hour=$current_hour
        elif [[ $current_hour -ne $DAILY_REPORT_HOUR ]]; then
            last_daily_hour=-1
        fi
        
        # Dashboard report (fire-and-forget, không block watchdog)
        report_to_dashboard &

        # Sleep until next check
        sleep "$CHECK_INTERVAL"
    done
}

create_watchdog_service() {
    log_info "Creating watchdog systemd service..."

    if [[ "${USE_PROXY:-1}" -eq 1 ]]; then
        cat > "$SYSTEMD_WATCHDOG_SERVICE" << EOF
[Unit]
Description=ARO Manager Watchdog with Proxy Protection
After=network.target redsocks-aro.service
Wants=redsocks-aro.service

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/$SCRIPT_NAME watchdog-loop
Restart=on-failure
RestartSec=10s
StartLimitBurst=0
User=root
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > "$SYSTEMD_WATCHDOG_SERVICE" << EOF
[Unit]
Description=ARO Manager Watchdog (No-Proxy Mode)
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/$SCRIPT_NAME watchdog-loop
Restart=on-failure
RestartSec=10s
StartLimitBurst=0
User=root
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    log_success "Watchdog service created"
}

# ───────────────────────────────────────────────────────────────
# ARO APP INSTALLATION FUNCTIONS
# ───────────────────────────────────────────────────────────────

ARO_DEB_URL="https://download.aro.network/files/packages/linux/ARO_Desktop_latest_debian.deb"
ARO_DEB_TMP="/tmp/ARO_Desktop_latest_debian.deb"

get_real_ip() {
    # Run as root → bypasses CRD-user iptables rules → returns actual server IP
    local ip=""
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        ip=$(curl -s --max-time 10 "https://$endpoint" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

get_local_ip() {
    # Lấy IP nội bộ của interface chính (non-loopback, IPv4)
    local ip=""
    # Cách 1: dùng routing table để tìm src IP của default route
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | grep -oP '(?<=src )\S+' | head -1 || true)
    # Cách 2: fallback — lấy IP đầu tiên không phải loopback
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    echo "${ip:-N/A}"
}

get_vnc_access_ip() {
    # LXC/VM → dùng IP LAN của interface chính
    # VPS/bare metal → dùng public IP
    if [[ "$ENV_TYPE" == "lxc_vnc" ]] || [[ "$ENV_TYPE" == "lxc_crd" ]]; then
        get_local_ip
    else
        # VPS: dùng public IP
        get_real_ip
    fi
}

verify_proxy_ip() {
    # Run as CRD user → goes through redsocks → must differ from real IP
    local real_ip="$1"

    log_info "Checking IP as user '$CRD_USER' (through proxy)..."
    echo ""

    local proxy_ip=""
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        proxy_ip=$(sudo -u "$CRD_USER" timeout 20 curl -s --max-time 15 \
            "https://$endpoint" 2>/dev/null | tr -d '[:space:]')
        if [[ "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        proxy_ip=""
    done

    echo "  Real IP  (root): ${real_ip:-UNKNOWN}"
    echo "  System IP (CRD): ${proxy_ip:-FAILED TO FETCH}"
    echo ""

    if [[ -z "$proxy_ip" ]]; then
        log_error "Cannot fetch IP as user '$CRD_USER'."
        log_error "Proxy/kill-switch may be misconfigured. ARO installation BLOCKED."
        echo ""
        echo "Troubleshoot:"
        echo "  sudo bash $SCRIPT_NAME proxy test"
        echo ""
        exit 1
    fi

    if [[ "$proxy_ip" == "$real_ip" ]]; then
        log_error "IP LEAK DETECTED! System IP ($proxy_ip) is the same as real IP."
        log_error "Proxy is NOT routing traffic correctly. ARO installation BLOCKED."
        echo ""
        echo "Troubleshoot:"
        echo "  sudo bash $SCRIPT_NAME proxy test"
        echo "  journalctl -u redsocks-aro -n 50"
        echo ""
        exit 1
    fi

    log_success "IP check PASSED → Real: $real_ip | Proxy: $proxy_ip (different ✓)"
}

install_aro_app() {
    log_info "Checking ARO Desktop installation..."

    if [[ -x "$ARO_BINARY" ]]; then
        log_info "ARO is already installed at $ARO_BINARY — skipping download."
        return 0
    fi

    log_info "ARO not found. Downloading from:"
    echo "  $ARO_DEB_URL"
    echo ""

    if ! curl -L --progress-bar --max-time 180 -o "$ARO_DEB_TMP" "$ARO_DEB_URL"; then
        log_error "Download failed. Check network connectivity."
        rm -f "$ARO_DEB_TMP"
        exit 1
    fi

    if [[ ! -s "$ARO_DEB_TMP" ]]; then
        log_error "Downloaded file is empty."
        rm -f "$ARO_DEB_TMP"
        exit 1
    fi

    log_info "Installing ARO Desktop (.deb)..."
    echo ""

    if ! dpkg -i "$ARO_DEB_TMP" 2>&1; then
        log_warn "dpkg reported issues — attempting to fix dependencies..."
        apt-get install -f -y -qq >/dev/null 2>&1
    fi

    rm -f "$ARO_DEB_TMP"

    if [[ ! -x "$ARO_BINARY" ]]; then
        log_error "ARO installation failed — binary not found at $ARO_BINARY"
        exit 1
    fi

    log_success "ARO Desktop installed at $ARO_BINARY"
}

# ───────────────────────────────────────────────────────────────
# COMMAND: FULL-INSTALL
# ───────────────────────────────────────────────────────────────


# ───────────────────────────────────────────────────────────────
# DEPLOYMENT HELPER FUNCTIONS (Phase 0 & 1)
# ───────────────────────────────────────────────────────────────

_append_ssh_key_if_needed() {
    if [[ -n "$UBUNTU_SSH_KEY" ]]; then
        mkdir -p /home/ubuntu/.ssh
        if ! grep -qxF "$UBUNTU_SSH_KEY" /home/ubuntu/.ssh/authorized_keys 2>/dev/null; then
            echo "$UBUNTU_SSH_KEY" >> /home/ubuntu/.ssh/authorized_keys
        fi
        chown -R ubuntu:ubuntu /home/ubuntu/.ssh
        chmod 700 /home/ubuntu/.ssh
        chmod 600 /home/ubuntu/.ssh/authorized_keys
        log_info "Đã cập nhật SSH key cho user 'ubuntu'."
    fi
}

_setup_ssh_key() {
    if [[ -n "$UBUNTU_SSH_KEY" ]]; then
        mkdir -p /home/ubuntu/.ssh
        echo "$UBUNTU_SSH_KEY" > /home/ubuntu/.ssh/authorized_keys
        chown -R ubuntu:ubuntu /home/ubuntu/.ssh
        chmod 700 /home/ubuntu/.ssh
        chmod 600 /home/ubuntu/.ssh/authorized_keys
    fi
}

_create_swap() {
    local ram_mb; ram_mb=$(free -m | awk '/^Mem:/ {print $2}' || echo 9999)
    local swap_target_mb=1024
    local swap_target="1G"

    # Máy có RAM >= 1GB → không can thiệp swap
    if [[ "${ram_mb:-9999}" -ge 1024 ]]; then
        log_info "[SKIP] RAM ${ram_mb}MB >= 1GB — bỏ qua cấu hình swap"
        return 0
    fi

    # RAM < 1GB → đảm bảo có đúng 1GB swap
    log_info "RAM ${ram_mb}MB < 1GB — kiểm tra swap..."

    local current_swap_mb; current_swap_mb=$(free -m | awk '/^Swap:/ {print $2}' || echo 0)

    if [[ "${current_swap_mb:-0}" -ge "$swap_target_mb" ]]; then
        log_info "[SKIP] Swap đã đủ: ${current_swap_mb}MB"
        return 0
    fi

    # Swap chưa đủ → tạo mới (hoặc replace nếu đã có nhỏ hơn)
    if [[ "${current_swap_mb:-0}" -gt 0 ]] && [[ -f /swapfile ]]; then
        log_info "Swap hiện tại ${current_swap_mb}MB < ${swap_target_mb}MB — thay thế..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi

    log_info "Tạo swap ${swap_target} cho máy RAM ${ram_mb}MB..."
    fallocate -l "$swap_target" /swapfile 2>/dev/null \
        || dd if=/dev/zero of=/swapfile bs=1M count="$swap_target_mb" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    log_success "Swap ${swap_target} đã được kích hoạt (RAM: ${ram_mb}MB)"
}

_apply_swap_optimization() {
    cat > /etc/sysctl.d/99-swap-optimize.conf << 'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    sysctl -p /etc/sysctl.d/99-swap-optimize.conf >/dev/null 2>&1 || true
    log_info "Đã áp dụng cấu hình swap tối ưu."
}

_setup_ssh_hardening() {
    local ubuntu_auth_keys="/home/ubuntu/.ssh/authorized_keys"
    local permit_root_login="yes"
    
    if [[ ! -s "$ubuntu_auth_keys" ]]; then
        log_warn "CẢNH BÁO: /home/ubuntu/.ssh/authorized_keys trống. PermitRootLogin KHÔNG bị disable để tránh lock out."
    else
        permit_root_login="no"
    fi
    
    cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
PasswordAuthentication no
PermitRootLogin ${permit_root_login}
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
AllowTcpForwarding no
EOF
    
    if sshd -t 2>/dev/null; then
        systemctl restart ssh
        log_success "SSH hardening hoàn tất. PermitRootLogin=${permit_root_login}"
    else
        log_warn "SSH config có lỗi, KHÔNG restart để tránh mất kết nối."
    fi
}

_configure_fail2ban() {
    cat > /etc/fail2ban/jail.d/ssh.conf << 'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
findtime = 10m
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl start fail2ban >/dev/null 2>&1 || true
}

_configure_unattended_upgrades() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
}

_configure_polkit_colord() {
    mkdir -p /etc/polkit-1/localauthority/50-local.d/
    cat > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla << 'EOF'
[Allow colord for ubuntu]
Identity=unix-user:ubuntu
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF
}

_disable_xscreensaver_autostart() {
    local home_ubuntu; home_ubuntu=$(getent passwd ubuntu | cut -d: -f6)
    mkdir -p "$home_ubuntu/.config/autostart"
    cat > "$home_ubuntu/.config/autostart/xscreensaver.desktop" << 'EOF'
[Desktop Entry]
Hidden=true
EOF
}

_configure_xfce_power_manager() {
    local home_ubuntu; home_ubuntu=$(getent passwd ubuntu | cut -d: -f6)
    mkdir -p "$home_ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml"

    cat > "$home_ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="presentation-mode" type="bool" value="true"/>
    <property name="lid-action-on-ac" type="uint" value="0"/>
  </property>
</channel>
EOF

    cat > "$home_ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="false"/>
    <property name="mode" type="int" value="0"/>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="false"/>
    <property name="saver-activation-enabled" type="bool" value="false"/>
  </property>
</channel>
EOF
}

_create_vnc_service() {
    cat > /etc/systemd/system/vncserver.service << EOF
[Unit]
Description=TigerVNC Display Server
After=network.target syslog.target

[Service]
Type=forking
User=ubuntu
Group=ubuntu

ExecStartPre=-/usr/bin/vncserver -kill $VNC_DISPLAY
ExecStartPre=-/bin/rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

ExecStart=/usr/bin/vncserver $VNC_DISPLAY \
    -geometry $VNC_RESOLUTION \
    -depth $VNC_DEPTH \
    -localhost no \
    -rfbport $VNC_PORT \
    -rfbauth /home/ubuntu/.vnc/passwd

ExecStop=/usr/bin/vncserver -kill $VNC_DISPLAY

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

_send_deploy_report() {
    local machine_ip="$1"
    parse_node_info || true

    local vnc_or_crd="VNC (port $VNC_PORT)"
    [[ "$REMOTE_MODE" == "crd" ]] && vnc_or_crd="Chrome Remote Desktop"

    local vnc_ip; vnc_ip=$(get_vnc_access_ip)
    local msg="🚀 <b>[ARO DEPLOY COMPLETE] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
🖥️ Host:     ${HOSTNAME}
🌐 IP:       ${machine_ip}
🔗 Remote:   ${vnc_or_crd}
🖥️ Env:      ${ENV_TYPE}
👤 User:     ubuntu
──────────────────────
🔌 Proxy:    ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:      ${vnc_ip}:${VNC_PORT}
🤖 Watchdog: ✅ Active
──────────────────────
🔢 Serial:   ${SERIAL:-Chờ ARO kết nối...}
📧 Account:  ${EMAIL:-N/A}
──────────────────────
📡 Kết nối:
   <code>${vnc_ip}:${VNC_PORT}</code>
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
    log_success "Deploy report đã gửi về Telegram"
}

# ───────────────────────────────────────────────────────────────
# DEPLOYMENT PHASES
# ───────────────────────────────────────────────────────────────

deploy_phase0_vps() {
    log_info "=== PHASE 0: VPS PREPARATION ==="
    
    # 4a. Tạo/verify user ubuntu
    if id "ubuntu" &>/dev/null; then
        log_info "[SKIP] User ubuntu đã tồn tại"
        _append_ssh_key_if_needed
    else
        log_info "Tạo user ubuntu..."
        useradd -m -s /bin/bash ubuntu || true
        usermod -aG sudo ubuntu || true
        _setup_ssh_key
    fi

    if [[ ! -f /etc/sudoers.d/ubuntu-nopasswd ]]; then
        echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu-nopasswd
        chmod 440 /etc/sudoers.d/ubuntu-nopasswd
    fi
    passwd -l ubuntu 2>/dev/null || true

    # 4b. apt update + upgrade
    log_info "Cập nhật hệ thống..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq

    # 4c. Swap
    local is_lxc=0
    local virt; virt=$(systemd-detect-virt --container 2>/dev/null || true)
    [[ "$virt" == "lxc" ]] && is_lxc=1

    if [[ $is_lxc -eq 1 ]]; then
        log_info "[SKIP] Môi trường LXC — bỏ qua cấu hình swap"
    else
        _create_swap
        _apply_swap_optimization
    fi

    # 4d. SSH Hardening
    if [[ -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; then
        log_info "[SKIP] SSH hardening đã được cấu hình"
    else
        _setup_ssh_hardening
    fi

    # 4e. Utilities + fail2ban + unattended
    log_info "Cài đặt utilities..."
    apt-get install -y -qq wget curl gnupg2 btop fail2ban unattended-upgrades         software-properties-common apt-transport-https ca-certificates
    _configure_fail2ban
    _configure_unattended_upgrades

    # 4f. UFW
    log_info "Cấu hình firewall UFW..."
    apt-get install -y -qq ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 5901/tcp
    ufw allow 11235/tcp
    ufw --force enable >/dev/null 2>&1 || true

    # 4g. XFCE
    if dpkg -l xfce4 2>/dev/null | grep -q '^ii'; then
        log_info "[SKIP] XFCE đã được cài đặt"
    else
        log_info "Cài đặt XFCE..."
        apt-get install -y -qq xfce4 xfce4-goodies dbus-x11 x11-xserver-utils             xserver-xorg-core xbase-clients xauth libgl1-mesa-dri             xscreensaver psmisc
        apt-get purge -y light-locker 2>/dev/null || true
    fi

    cat > /etc/X11/Xwrapper.config << 'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

    # 4h. Polkit + XFCE power
    _configure_polkit_colord
    _configure_xfce_power_manager
    _disable_xscreensaver_autostart
    
    local home_ubuntu; home_ubuntu=$(getent passwd ubuntu | cut -d: -f6)
    chown -R ubuntu:ubuntu "$home_ubuntu/.config" 2>/dev/null || true
}

deploy_phase1_vnc() {
    log_info "=== PHASE 1: TIGERVNC SETUP ==="

    if dpkg -l tigervnc-standalone-server 2>/dev/null | grep -q '^ii'; then
        log_info "[SKIP] TigerVNC đã được cài đặt"
    else
        apt-get install -y -qq tigervnc-standalone-server tigervnc-common dbus-x11
    fi

    local vnc_dir="/home/ubuntu/.vnc"
    install -d -o ubuntu -g ubuntu -m 700 "$vnc_dir"

    if [[ -f "$vnc_dir/passwd" ]]; then
        log_info "[SKIP] VNC password đã tồn tại"
    else
        echo "$VNC_PASS" | vncpasswd -f > "$vnc_dir/passwd"
        chmod 600 "$vnc_dir/passwd"
        chown ubuntu:ubuntu "$vnc_dir/passwd"
        log_success "VNC password đã được đặt"
    fi

    cat > "$vnc_dir/xstartup" << 'XSTARTUP'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
exec startxfce4
XSTARTUP
    chmod +x "$vnc_dir/xstartup"
    chown -R ubuntu:ubuntu "$vnc_dir"

    _create_vnc_service

    systemctl daemon-reload
    systemctl enable vncserver.service >/dev/null 2>&1

    if systemctl is-active --quiet vncserver.service; then
        systemctl restart vncserver.service
    else
        systemctl start vncserver.service
    fi
    sleep 3

    if systemctl is-active --quiet vncserver.service; then
        log_success "TigerVNC service đang chạy (port $VNC_PORT)"
    else
        log_error "TigerVNC không khởi động. Kiểm tra: journalctl -u vncserver -xe"
        exit 1
    fi
}

deploy_phase1_crd() {
    log_info "=== PHASE 1: CHROME REMOTE DESKTOP SETUP ==="

    if grep -q "^NAME_REGEX=" /etc/adduser.conf 2>/dev/null; then
        sed -i 's/^NAME_REGEX=.*/NAME_REGEX="^[a-z_][-a-z0-9_]*\$"/' /etc/adduser.conf
    else
        echo 'NAME_REGEX="^[a-z_][-a-z0-9_]*$"' >> /etc/adduser.conf
    fi

    if grep -q "^NAME_REGEX_SYSTEM=" /etc/adduser.conf 2>/dev/null; then
        sed -i 's/^NAME_REGEX_SYSTEM=.*/NAME_REGEX_SYSTEM="^[a-z_][-a-z0-9_]*\$"/' /etc/adduser.conf
    else
        echo 'NAME_REGEX_SYSTEM="^[a-z_][-a-z0-9_]*$"' >> /etc/adduser.conf
    fi

    adduser --system --quiet --group --force-badname _crd_network || true

    local crd_deb_url="https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb"
    local crd_success=false

    if wget -q --spider "$crd_deb_url" 2>/dev/null && wget -O /tmp/crd.deb "$crd_deb_url" 2>/dev/null; then
        if apt-get install -y /tmp/crd.deb 2>/dev/null; then
            crd_success=true
        fi
    fi

    if [[ "$crd_success" != "true" ]]; then
        log_info "Cài CRD từ Google repository..."
        wget -q -O /tmp/google-chrome-key.gpg https://dl.google.com/linux/linux_signing_key.pub
        gpg --yes --dearmor -o /usr/share/keyrings/google-chrome-archive-keyring.gpg /tmp/google-chrome-key.gpg
        rm -f /tmp/google-chrome-key.gpg
        
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-archive-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
        apt-get update -qq
        apt-get install -y -qq chrome-remote-desktop
    fi

    local home_ubuntu; home_ubuntu=$(getent passwd ubuntu | cut -d: -f6)
    echo "exec startxfce4" > "$home_ubuntu/.chrome-remote-desktop-session"
    chown ubuntu:ubuntu "$home_ubuntu/.chrome-remote-desktop-session"

    mkdir -p "$home_ubuntu/.config/chrome-remote-desktop"
    chown -R ubuntu:ubuntu "$home_ubuntu/.config"
    chmod 700 "$home_ubuntu/.config/chrome-remote-desktop"

    log_success "Chrome Remote Desktop đã được cài đặt."
}

deploy_phase2_proxy() {
    log_info "=== PHASE 2: PROXY SETUP ==="

    if [[ "$USE_PROXY" -eq 0 ]]; then
        log_info "No-proxy mode: skipping redsocks/iptables setup"
        install_packages
        create_config_directory
        # save_proxy_config vẫn chạy để lưu USE_PROXY=0 và CRD_USER vào config
        save_proxy_config
        save_watchdog_config
        # Tạo wrapper không có proxy check
        create_wrapper_script_no_proxy
        return 0
    fi

    install_packages
    create_config_directory
    save_proxy_config
    save_watchdog_config
    create_redsocks_config
    create_redsocks_service
    create_iptables_restore_script
    setup_iptables_rules
    persist_iptables_rules
    create_wrapper_script
    start_redsocks_service
}

deploy_phase3_ip_verify() {
    if [[ "$USE_PROXY" -eq 0 ]]; then
        log_info "=== PHASE 3: IP VERIFICATION — skipped (no-proxy mode) ==="
        return 0
    fi

    log_info "=== PHASE 3: IP VERIFICATION (ANTI-LEAK CHECK) ==="
    echo "Waiting 5s for iptables rules to stabilise..."
    sleep 5
    # get_real_ip defined in original code
    local real_ip; real_ip=$(get_real_ip)
    verify_proxy_ip "$real_ip"
}

deploy_phase4_aro() {
    log_info "=== PHASE 4: ARO INSTALLATION ==="
    install_aro_app
}

deploy_phase5_watchdog() {
    log_info "=== PHASE 5: WATCHDOG SETUP ==="
    create_watchdog_service
    systemctl enable aro-watchdog >/dev/null 2>&1
    systemctl start aro-watchdog
    sleep 3
    if systemctl is-active --quiet aro-watchdog; then
        log_success "Watchdog service started"
    else
        log_error "Watchdog service failed to start"
        echo "Check: journalctl -u aro-watchdog -n 50"
        exit 1
    fi
}

deploy_phase6_finish() {
    log_info "=== PHASE 6: VERIFICATION ==="

    apt-get autoremove -y -qq 2>/dev/null || true

    local machine_ip=""
    if [[ "$ENV_TYPE" == "lxc_vnc" ]]; then
        machine_ip=$(get_local_ip)
        log_info "LXC environment — dùng IP nội bộ: $machine_ip"
    else
        machine_ip=$(get_real_ip)
        log_info "IP public: $machine_ip"
    fi

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              ✓ DEPLOY HOÀN TẤT                                ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Services:"
    systemctl is-active vncserver   2>/dev/null && echo "  ✓ VNC:      Running (port $VNC_PORT)" || true
    systemctl is-active redsocks-aro 2>/dev/null && echo "  ✓ Redsocks: Running" || true
    systemctl is-active aro-watchdog 2>/dev/null && echo "  ✓ Watchdog: Running" || true
    echo ""
    if [[ "$REMOTE_MODE" == "vnc" ]]; then
        echo "  Remote: $machine_ip:$VNC_PORT (VNC)"
    else
        echo "  Remote: Chrome Remote Desktop"
    fi
    echo ""

    if [[ "${DASHBOARD_ENABLED:-false}" == "true" ]]; then
        echo "  Dashboard: ✅ ${DASHBOARD_URL}"
    fi
    echo ""

    if [[ -n "$TG_BOT_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
        _send_deploy_report "$machine_ip"
    fi
}

do_deploy() {
    local proxy_string="$1"
    shift

    show_banner
    require_root
    check_os

    if [[ -z "$REMOTE_MODE" ]]; then
        echo ""
        echo "Chọn phương thức remote desktop:"
        echo "  1) VNC (TigerVNC) — khuyến nghị cho LXC"
        echo "  2) CRD (Chrome Remote Desktop) — cho bare-metal / VM"
        echo ""
        read -p "Nhập lựa chọn [1/2]: " -r _choice
        case "$_choice" in
            1) REMOTE_MODE="vnc" ;;
            2) REMOTE_MODE="crd" ;;
            *) log_error "Lựa chọn không hợp lệ"; exit 1 ;;
        esac
    fi

    if [[ -z "$UBUNTU_SSH_KEY" ]]; then
        read -p "Nhập SSH public key cho user ubuntu: " -r UBUNTU_SSH_KEY
    fi
    if [[ -z "$UBUNTU_SSH_KEY" ]]; then
        log_error "SSH key là bắt buộc"; exit 1
    fi

    if [[ "$REMOTE_MODE" == "vnc" ]] && [[ -z "$VNC_PASS" ]]; then
        read -s -p "Nhập VNC password (min 6 ký tự): " -r VNC_PASS
        echo ""
    fi
    if [[ "$REMOTE_MODE" == "vnc" ]] && [[ ${#VNC_PASS} -lt 6 ]]; then
        log_error "VNC password tối thiểu 6 ký tự"; exit 1
    fi

    parse_proxy_string "$proxy_string"
    validate_telegram_credentials

    echo ""
    log_info "Kế hoạch triển khai:"
    echo "  • Remote mode: $REMOTE_MODE"
    if [[ "$USE_PROXY" -eq 1 ]]; then
        echo "  • Proxy:       $PROXY_HOST:$PROXY_PORT"
    else
        echo "  • Proxy:       DISABLED (no-proxy mode)"
    fi
    echo "  • SSH key:     ${UBUNTU_SSH_KEY:0:40}..."
    echo "  • Telegram:    $([ -n "$TG_BOT_TOKEN" ] && echo "Enabled" || echo "Disabled")"
    echo ""
    read -p "Tiếp tục deploy? [Y/n] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
        log_info "Đã huỷ"; exit 0
    fi

    deploy_phase0_vps

    if [[ "$REMOTE_MODE" == "vnc" ]]; then
        deploy_phase1_vnc
    else
        deploy_phase1_crd
    fi

    detect_desktop_user

    deploy_phase2_proxy
    deploy_phase3_ip_verify
    deploy_phase4_aro
    deploy_phase5_watchdog

    deploy_phase6_finish
}

do_full_install() {
    local proxy_string="$1"
    local token="${2:-}"
    local chatid="${3:-}"
    
    show_banner
    echo ""
    
    require_root
    check_os
    
    log_info "Starting ARO Manager full installation..."
    echo ""
    
    # Parse inputs
    parse_proxy_string "$proxy_string"
    detect_desktop_user
    
    if [[ -n "$token" ]]; then
        TG_BOT_TOKEN="$token"
    fi

    if [[ -n "$chatid" ]]; then
        TG_CHAT_ID="$chatid"
    fi

    if [[ "${TG_ENABLED:-1}" == "0" ]]; then
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        log_info "Telegram notifications: DISABLED (--no-telegram)"
    else
        validate_telegram_credentials
    fi

    echo ""
    log_info "Installation plan:"
    if [[ "$USE_PROXY" -eq 1 ]]; then
        echo "  • Proxy: $PROXY_HOST:$PROXY_PORT"
    else
        echo "  • Proxy: DISABLED (no-proxy mode)"
    fi
    echo "  • CRD User: $CRD_USER"
    if [[ "${TG_ENABLED:-1}" == "0" ]]; then
        echo "  • Telegram: DISABLED"
    else
        echo "  • Telegram: $([ -n "$TG_BOT_TOKEN" ] && echo "Enabled" || echo "Disabled")"
    fi
    echo ""
    
    read -p "Continue with full installation? [Y/n] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    # Capture real IP BEFORE proxy is applied (root bypasses CRD-user rules)
    log_info "Detecting real IP before proxy setup..."
    local REAL_IP
    REAL_IP=$(get_real_ip)
    if [[ -z "$REAL_IP" ]]; then
        log_warn "Could not detect real IP — IP leak check will still run after proxy setup."
    else
        log_info "Real IP detected: $REAL_IP"
    fi

    deploy_phase2_proxy
    deploy_phase3_ip_verify
    deploy_phase4_aro
    deploy_phase5_watchdog

    echo ""
    log_info "=== PHASE 6: VERIFICATION ==="

    sleep 5
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              ✓ FULL INSTALLATION COMPLETE                     ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Services status:"
    systemctl is-active redsocks-aro && echo "  ✓ Redsocks: Running" || echo "  ✗ Redsocks: Not running"
    systemctl is-active aro-watchdog && echo "  ✓ Watchdog: Running" || echo "  ✗ Watchdog: Not running"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Check status:"
    echo "     $SCRIPT_NAME status"
    echo ""
    echo "  2. Test proxy:"
    echo "     $SCRIPT_NAME proxy test"
    echo ""
    echo "  3. View logs:"
    echo "     $SCRIPT_NAME watchdog log"
    echo ""
    echo "  4. Monitor ARO:"
    echo "     $SCRIPT_NAME watchdog status"
    echo ""
    
    # Send setup notification
    if [[ -n "$TG_BOT_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
        log_info "Sending setup notification to Telegram..."
        send_notify_setup_success "systemd" || true
    fi
}

# ───────────────────────────────────────────────────────────────
# COMMAND: DEBUG
# ───────────────────────────────────────────────────────────────

do_debug() {
    # ── Setup: tee output ra file log ──────────────────────────
    local debug_file="${DEBUG_LOG_DIR}/aro-debug-$(date +%Y%m%d-%H%M%S).log"
    
    # Redirect tất cả output của function này ra cả stdout lẫn file
    # Dùng subshell + tee để không ảnh hưởng phần còn lại của script
    {
        _do_debug_inner
    } 2>&1 | tee "$debug_file"
    
    echo ""
    echo "📁 Debug log saved to: $debug_file"
}

_do_debug_inner() {
    load_configs
    detect_desktop_user
    LATEST_LOG_FILE=$(get_latest_aro_log)
    
    # Array để collect các issues phát hiện được (dùng cho Summary cuối)
    local -a ISSUES=()
    local -a WARNINGS=()
    local -a OKS=()
    
    # Helper để add issue/warning/ok và print inline
    _issue()   { ISSUES+=("$1");   echo "  ❌ ISSUE: $1"; }
    _warn()    { WARNINGS+=("$1"); echo "  ⚠️  WARN:  $1"; }
    _ok()      { OKS+=("$1");      echo "  ✅ OK:    $1"; }
    _info()    { echo "  ℹ️  $1"; }
    _section() { 
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  $1"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    }
    
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         ARO Manager - Debug Report v${SCRIPT_VERSION}              ║"
    echo "║         Generated: $(date '+%Y-%m-%d %H:%M:%S')                    ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"

    # ══════════════════════════════════════════════════════════════
    # SECTION 1: ENVIRONMENT
    # ══════════════════════════════════════════════════════════════
    _section "1/6 🔍 ENVIRONMENT"
    
    _info "Hostname:    $HOSTNAME"
    _info "OS:          $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -o)"
    _info "Kernel:      $(uname -r)"
    _info "Uptime:      $(uptime -p 2>/dev/null || uptime)"
    _info "Env type:    $ENV_TYPE"
    _info "User:        $EFFECTIVE_USER (home: $EFFECTIVE_HOME)"
    _info "Display:     $DISPLAY_NUM"
    _info "XAUTHORITY:  $XAUTHORITY_PATH"
    echo ""
    
    # RAM
    local mem_free_mb; mem_free_mb=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
    local mem_total_mb; mem_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
    _info "RAM:         ${mem_free_mb}MB free / ${mem_total_mb}MB total"
    if [[ "$mem_free_mb" =~ ^[0-9]+$ ]] && [[ "$mem_free_mb" -lt 200 ]]; then
        _warn "Low RAM: only ${mem_free_mb}MB available — ARO may crash"
    fi

    # Disk
    local disk_free; disk_free=$(df -h "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "?")
    _info "Disk free:   $disk_free (on $SCRIPT_DIR)"

    # DISPLAY accessible?
    if [[ -n "$DISPLAY_NUM" ]]; then
        if DISPLAY="$DISPLAY_NUM" XAUTHORITY="$XAUTHORITY_PATH" xdpyinfo >/dev/null 2>&1; then
            _ok "Display $DISPLAY_NUM is accessible"
        else
            _issue "Display $DISPLAY_NUM is NOT accessible (xdpyinfo failed)"
        fi
    else
        _issue "DISPLAY_NUM is empty — cannot launch GUI app"
    fi

    # User home exists?
    if [[ -d "$EFFECTIVE_HOME" ]]; then
        _ok "User home exists: $EFFECTIVE_HOME"
    else
        _issue "User home NOT found: $EFFECTIVE_HOME"
    fi

    # ══════════════════════════════════════════════════════════════
    # SECTION 2: PROXY / REDSOCKS
    # ══════════════════════════════════════════════════════════════
    _section "2/6 🛡️  PROXY / REDSOCKS"
    
    _info "Proxy server: $PROXY_HOST:$PROXY_PORT"
    _info "Redsocks port: $REDSOCKS_PORT"
    echo ""
    
    # Config file
    if [[ -f "$REDSOCKS_CONF_FILE" ]]; then
        _ok "Redsocks config exists: $REDSOCKS_CONF_FILE"
    else
        _issue "Redsocks config MISSING: $REDSOCKS_CONF_FILE"
    fi
    
    # Service status
    echo ""
    echo "  [systemctl status redsocks-aro]"
    systemctl status redsocks-aro --no-pager -l 2>&1 | head -15 | sed 's/^/    /'
    echo ""
    
    if systemctl is-active --quiet redsocks-aro; then
        _ok "redsocks-aro service is ACTIVE"
    else
        _issue "redsocks-aro service is NOT active"
        local exit_code; exit_code=$(systemctl show redsocks-aro --property=ExecMainStatus --value 2>/dev/null || echo "?")
        _info "Last exit code: $exit_code"
    fi
    
    # Port listening?
    if ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
        _ok "Port $REDSOCKS_PORT is LISTENING"
    else
        _issue "Port $REDSOCKS_PORT is NOT listening"
    fi
    
    # recv-Q (hung detection)
    local recv_q; recv_q=$(ss -tlnp 2>/dev/null | grep "127.0.0.1:${REDSOCKS_PORT} " | awk '{print $2}' || echo "0")
    recv_q="${recv_q:-0}"
    _info "Redsocks recv-Q: $recv_q (threshold: $REDSOCKS_QUEUE_THRESHOLD)"
    if [[ "$recv_q" =~ ^[0-9]+$ ]] && [[ "$recv_q" -gt "$REDSOCKS_QUEUE_THRESHOLD" ]]; then
        _issue "Redsocks recv-Q=$recv_q EXCEEDS threshold — service is hung/overloaded"
    fi

    # iptables rules
    local iptables_rule_count; iptables_rule_count=$(iptables -t nat -L ARO_PROXY 2>/dev/null | grep -c "^" || echo "0")
    if iptables -t nat -L ARO_PROXY >/dev/null 2>&1; then
        _ok "iptables ARO_PROXY chain exists ($iptables_rule_count rules)"
    else
        _issue "iptables ARO_PROXY chain MISSING — kill-switch not active"
    fi
    
    # IPv6 block
    if ip6tables -L OUTPUT 2>/dev/null | grep -q "REJECT"; then
        _ok "IPv6 OUTPUT blocked (kill-switch active)"
    else
        _warn "IPv6 OUTPUT not blocked — potential IP leak"
    fi
    
    # Recent redsocks journal
    echo ""
    echo "  [journalctl redsocks-aro — last 10 lines]"
    journalctl -u redsocks-aro -n 10 --no-pager 2>/dev/null | sed 's/^/    /' || echo "    (no journal entries)"

    # ══════════════════════════════════════════════════════════════
    # SECTION 3: ARO APPLICATION
    # ══════════════════════════════════════════════════════════════
    _section "3/6 🎮 ARO APPLICATION"
    
    # Binary
    if [[ -x "$ARO_BINARY" ]]; then
        _ok "ARO binary exists and executable: $ARO_BINARY"
    else
        _issue "ARO binary NOT found or not executable: $ARO_BINARY"
    fi
    
    # Wrapper
    if [[ -x "$WRAPPER_SCRIPT" ]]; then
        if bash -n "$WRAPPER_SCRIPT" 2>/dev/null; then
            _ok "Wrapper script valid: $WRAPPER_SCRIPT"
        else
            _issue "Wrapper script has SYNTAX ERRORS: $WRAPPER_SCRIPT"
        fi
    else
        _issue "Wrapper script NOT found or not executable: $WRAPPER_SCRIPT"
    fi
    
    # Process
    if is_aro_running; then
        local aro_pid; aro_pid=$(get_aro_pid)
        local aro_mem; aro_mem=$(ps -o rss= -p "$aro_pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo "?")
        local aro_cpu; aro_cpu=$(ps -o %cpu= -p "$aro_pid" 2>/dev/null | tr -d ' ' || echo "?")
        _ok "ARO process RUNNING (PID: $aro_pid, MEM: ${aro_mem}MB, CPU: ${aro_cpu}%)"
    else
        _issue "ARO process NOT running"
    fi
    
    # Maintenance mode check
    if is_maintenance_mode; then
        local maint_age; maint_age=$(maintenance_age_mins)
        _warn "Maintenance mode is ACTIVE (${maint_age}m) — ARO intentionally stopped by user"
        _info "Run 'sudo ./aro-manager.sh start' to resume"
    fi
    
    # Tray state
    local tray; tray=$(get_aro_tray_state)
    _info "Tray state (from log): ${tray:-unknown}"
    if [[ "$tray" == "Online" ]]; then
        _ok "Tray state = Online"
    elif [[ -n "$tray" ]] && [[ "$tray" != "Online" ]]; then
        _warn "Tray state = $tray (not Online)"
    fi
    
    # Log directory
    if run_as_aro_user test -d "$ARO_LOG_DIR" 2>/dev/null; then
        local log_count; log_count=$(run_as_aro_user ls "$ARO_LOG_DIR"/*.log 2>/dev/null | wc -l || echo "0")
        _ok "ARO log directory exists ($log_count log files): $ARO_LOG_DIR"
    else
        _issue "ARO log directory NOT found: $ARO_LOG_DIR"
    fi
    
    # Log freshness
    if [[ -n "$LATEST_LOG_FILE" ]]; then
        _info "Latest log: $LATEST_LOG_FILE"
        if is_log_fresh; then
            _ok "Log is FRESH (updated within ${LOG_STALE_MINUTES}m)"
        else
            local log_age_min; log_age_min=$(( ( $(date +%s) - $(run_as_aro_user stat -c %Y "$LATEST_LOG_FILE" 2>/dev/null || echo 0) ) / 60 ))
            _warn "Log is STALE (last update: ${log_age_min}m ago, threshold: ${LOG_STALE_MINUTES}m)"
        fi
        
        # Tail 20 dòng cuối ARO log
        echo ""
        echo "  [ARO log — last 20 lines: $(basename "$LATEST_LOG_FILE")]"
        run_as_aro_user tail -n 20 "$LATEST_LOG_FILE" 2>/dev/null | sed 's/^/    /' || echo "    (cannot read log)"
    else
        _issue "No ARO log file found"
    fi
    
    # Wrapper log
    echo ""
    echo "  [Wrapper log — last 20 lines: $WRAPPER_LOG]"
    tail -n 20 "$WRAPPER_LOG" 2>/dev/null | sed 's/^/    /' || echo "    (wrapper log empty or not found)"

    # ══════════════════════════════════════════════════════════════
    # SECTION 4: WATCHDOG
    # ══════════════════════════════════════════════════════════════
    _section "4/6 🤖 WATCHDOG"
    
    # Service status
    echo "  [systemctl status aro-watchdog]"
    systemctl status aro-watchdog --no-pager -l 2>&1 | head -10 | sed 's/^/    /'
    echo ""
    
    if systemctl is-active --quiet aro-watchdog; then
        _ok "aro-watchdog service is ACTIVE"
    else
        _issue "aro-watchdog service is NOT active"
    fi
    
    # State file
    if [[ -f "$STATE_FILE" ]]; then
        _ok "State file exists: $STATE_FILE"
        echo ""
        echo "  [State file contents]"
        cat "$STATE_FILE" 2>/dev/null | sed 's/^/    /' || echo "    (cannot read)"
        echo ""
        
        # Parse key values từ state
        local retry_count; retry_count=$(state_get "retry_count" "0")
        local last_restart; last_restart=$(state_get "last_restart" "0")
        local stable_since; stable_since=$(state_get "stable_since" "0")
        
        _info "retry_count:  $retry_count / $MAX_RETRIES"
        
        if [[ "$last_restart" -gt 0 ]]; then
            local restart_ago=$(( ( $(date +%s) - last_restart ) / 60 ))
            _info "last_restart: ${restart_ago}m ago ($(date -d @"$last_restart" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown'))"
        else
            _info "last_restart: never"
        fi
        
        if [[ "$retry_count" -gt 0 ]]; then
            _warn "retry_count = $retry_count (watchdog has been restarting ARO)"
        fi
    else
        _warn "State file not found: $STATE_FILE (watchdog may not have started yet)"
    fi
    
    # Watchdog log
    echo ""
    echo "  [Watchdog log — last 20 lines: $WATCHDOG_LOG]"
    tail -n 20 "$WATCHDOG_LOG" 2>/dev/null | sed 's/^/    /' || echo "    (watchdog log empty or not found)"
    
    echo ""
    echo "  [journalctl aro-watchdog — last 10 lines]"
    journalctl -u aro-watchdog -n 10 --no-pager 2>/dev/null | sed 's/^/    /' || echo "    (no journal entries)"

    # ══════════════════════════════════════════════════════════════
    # SECTION 5: NETWORK LIVE TEST
    # ══════════════════════════════════════════════════════════════
    _section "5/6 🌐 NETWORK LIVE TEST"
    
    _info "Running live network tests as user '$EFFECTIVE_USER' (via transparent proxy)..."
    _info "This may take up to 30 seconds..."
    echo ""
    
    # Test 1: Kết nối thực tế qua transparent proxy (ubuntu user traffic)
    echo "  [Test 1: Transparent proxy connectivity]"
    local test_ip=""
    local test_ok=false
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        echo -n "    curl https://$endpoint ... "
        test_ip=$(sudo -u "$EFFECTIVE_USER" curl -s --max-time 8 "https://$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$test_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "✅ $test_ip"
            test_ok=true
            break
        else
            echo "❌ failed"
        fi
    done
    
    if $test_ok; then
        _ok "Transparent proxy working — exit IP: $test_ip"
        
        # Verify exit IP khớp với proxy server
        local proxy_ip; proxy_ip=$(getent hosts "$PROXY_HOST" 2>/dev/null | awk '{print $1}' | head -1 || echo "")
        if [[ -n "$proxy_ip" ]] && [[ "$test_ip" != "$proxy_ip" ]]; then
            _info "Note: Exit IP ($test_ip) differs from proxy host IP ($proxy_ip) — this is normal for shared proxies"
        fi
    else
        _issue "Transparent proxy NOT working — all endpoints failed"
    fi
    
    echo ""
    
    # Test 2: Kết nối trực tiếp đến proxy server (SOCKS5 target)
    echo "  [Test 2: SOCKS5 proxy server reachability]"
    echo -n "    Connecting to $PROXY_HOST:$PROXY_PORT ... "
    if timeout 8 bash -c "echo >/dev/tcp/$PROXY_HOST/$PROXY_PORT" 2>/dev/null; then
        echo "✅ reachable"
        _ok "Proxy server $PROXY_HOST:$PROXY_PORT is reachable"
    else
        echo "❌ unreachable"
        _issue "Proxy server $PROXY_HOST:$PROXY_PORT is NOT reachable (down or blocked)"
    fi
    
    echo ""
    
    # Test 3: DNS resolution
    echo "  [Test 3: DNS resolution]"
    echo -n "    Resolve $PROXY_HOST ... "
    local dns_result; dns_result=$(getent hosts "$PROXY_HOST" 2>/dev/null | awk '{print $1}' | head -1 || true)
    if [[ -n "$dns_result" ]]; then
        echo "✅ $dns_result"
        _ok "DNS resolves $PROXY_HOST → $dns_result"
    else
        echo "❌ failed"
        _issue "DNS cannot resolve $PROXY_HOST"
    fi
    
    echo ""
    
    # Test 4: IPv6 leak check
    echo "  [Test 4: IPv6 leak check (should fail)]"
    echo -n "    curl -6 https://ifconfig.me (as $EFFECTIVE_USER) ... "
    local ipv6_result; ipv6_result=$(sudo -u "$EFFECTIVE_USER" curl -6 -s --max-time 5 "https://ifconfig.me" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -z "$ipv6_result" ]]; then
        echo "✅ blocked (no IPv6 leak)"
        _ok "IPv6 leak test passed — no response (as expected)"
    else
        echo "❌ LEAKED: $ipv6_result"
        _issue "IPv6 LEAK detected: $ipv6_result — ip6tables rule may be missing"
    fi

    # ══════════════════════════════════════════════════════════════
    # SECTION 6: AUTO-DIAGNOSIS SUMMARY
    # ══════════════════════════════════════════════════════════════
    _section "6/6 📊 AUTO-DIAGNOSIS SUMMARY"
    
    local total_issues=${#ISSUES[@]}
    local total_warnings=${#WARNINGS[@]}
    local total_oks=${#OKS[@]}
    
    echo ""
    echo "  Results: ${total_oks} OK  |  ${total_warnings} warnings  |  ${total_issues} issues"
    echo ""
    
    if [[ $total_issues -gt 0 ]]; then
        echo "  ── Issues (action required) ──"
        for issue in "${ISSUES[@]}"; do
            echo "  ❌ $issue"
        done
        echo ""
    fi
    
    if [[ $total_warnings -gt 0 ]]; then
        echo "  ── Warnings ──"
        for warn in "${WARNINGS[@]}"; do
            echo "  ⚠️  $warn"
        done
        echo ""
    fi
    
    # Suggested fixes dựa trên pattern issues phát hiện được
    local has_suggestions=false
    
    echo "  ── Suggested fixes ──"
    
    # Pattern: redsocks hung
    if printf '%s\n' "${ISSUES[@]}" "${WARNINGS[@]}" 2>/dev/null | grep -q "recv-Q.*EXCEEDS\|hung"; then
        echo "  💡 Redsocks hung → restart: sudo systemctl restart redsocks-aro"
        has_suggestions=true
    fi
    
    # Pattern: redsocks not active
    if printf '%s\n' "${ISSUES[@]}" 2>/dev/null | grep -q "redsocks-aro service is NOT active"; then
        echo "  💡 Redsocks down → start: sudo systemctl start redsocks-aro"
        echo "  💡 Check logs: journalctl -u redsocks-aro -n 50"
        has_suggestions=true
    fi
    
    # Pattern: ARO not running
    if printf '%s\n' "${ISSUES[@]}" 2>/dev/null | grep -q "ARO process NOT running"; then
        if is_maintenance_mode; then
            echo "  💡 ARO is in maintenance mode → resume: sudo ./aro-manager.sh start"
        else
            echo "  💡 ARO not running → force start: sudo ./aro-manager.sh start"
        fi
        has_suggestions=true
    fi
    
    # Pattern: Display not accessible
    if printf '%s\n' "${ISSUES[@]}" 2>/dev/null | grep -q "Display.*NOT accessible"; then
        echo "  💡 Display issue → check VNC: systemctl status tigervnc@:1"
        echo "  💡 Or restart VNC: sudo systemctl restart tigervnc@:1"
        has_suggestions=true
    fi
    
    # Pattern: Transparent proxy not working but proxy server reachable
    if printf '%s\n' "${ISSUES[@]}" 2>/dev/null | grep -q "Transparent proxy NOT working"; then
        if printf '%s\n' "${OKS[@]}" 2>/dev/null | grep -q "reachable"; then
            echo "  💡 Redsocks config or iptables issue → re-apply: sudo ./aro-manager.sh proxy enable"
            has_suggestions=true
        fi
    fi
    
    # Pattern: IPv6 leak
    if printf '%s\n' "${ISSUES[@]}" 2>/dev/null | grep -q "IPv6 LEAK"; then
        echo "  💡 IPv6 leak → re-apply iptables: sudo ./aro-manager.sh proxy enable"
        has_suggestions=true
    fi
    
    # Pattern: iptables chain missing
    if printf '%s\n' "${ISSUES[@]}" 2>/dev/null | grep -q "iptables ARO_PROXY chain MISSING"; then
        echo "  💡 iptables rules lost (reboot?) → re-apply: sudo ./aro-manager.sh proxy enable"
        has_suggestions=true
    fi
    
    if ! $has_suggestions && [[ $total_issues -eq 0 ]]; then
        echo "  ✨ No issues detected — all systems nominal"
        echo "  💡 If ARO is still misbehaving, check the full logs above for clues"
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Debug complete — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════════════════"
}

# ───────────────────────────────────────────────────────────────
# COMMAND: ARO DIRECT CONTROL (v3.4.9)
# ───────────────────────────────────────────────────────────────

do_aro_stop() {
    require_root
    load_configs
    detect_desktop_user

    log_info "Stopping ARO and enabling maintenance mode..."

    # 1. Set maintenance mode TRƯỚC — để watchdog không restart ngay khi ARO bị kill
    maintenance_set

    # 2. Kill ARO
    if is_aro_running; then
        kill_aro
        log_success "ARO process stopped"
    else
        log_info "ARO was not running"
    fi

    # 3. Warn nếu watchdog đang chạy
    if systemctl is-active --quiet aro-watchdog; then
        log_warn "Watchdog is still running but will NOT restart ARO (maintenance mode active)"
        log_warn "Maintenance mode auto-expires in ${MAINTENANCE_EXPIRE_MINS} minutes"
        log_info "To resume: sudo ./aro-manager.sh start"
    fi

    log_success "ARO stopped. Maintenance mode ON — watchdog paused."
}

do_aro_start() {
    require_root
    load_configs
    detect_desktop_user

    log_info "Starting ARO..."
    aro_clear_give_up
    state_set "retry_count" "0"

    # 1. Check proxy trước — chỉ khi USE_PROXY=1
    if [[ "${USE_PROXY:-1}" -eq 1 ]]; then
        if ! systemctl is-active --quiet redsocks-aro; then
            log_error "Redsocks proxy is NOT running — cannot start ARO safely (kill-switch active)"
            log_error "Fix: sudo systemctl start redsocks-aro"
            exit 1
        fi

        if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
            log_error "Redsocks port $REDSOCKS_PORT is not listening — proxy not ready"
            log_error "Fix: sudo systemctl restart redsocks-aro"
            exit 1
        fi
    fi

    # 2. Clear maintenance mode
    if is_maintenance_mode; then
        log_info "Clearing maintenance mode..."
        maintenance_clear
    fi

    # 3. Nếu ARO đã đang chạy thì báo và thoát
    if is_aro_running; then
        local pid; pid=$(get_aro_pid)
        log_info "ARO is already running (PID: $pid)"
        return 0
    fi

    # 4. Nếu watchdog đang stop → start lại watchdog (watchdog sẽ tự launch ARO)
    if ! systemctl is-active --quiet aro-watchdog; then
        log_info "Watchdog is not running — starting watchdog (it will launch ARO)..."
        systemctl start aro-watchdog
        sleep 3
        if systemctl is-active --quiet aro-watchdog; then
            log_success "Watchdog started — ARO will launch within ${CHECK_INTERVAL}s"
        else
            log_error "Failed to start watchdog"
            exit 1
        fi
        return 0
    fi

    # 5. Watchdog đang chạy → launch ARO trực tiếp luôn (không đợi next cycle)
    log_info "Launching ARO directly..."
    LATEST_LOG_FILE=$(get_latest_aro_log)
    cleanup_aro_tmp
    launch_aro
    state_set "last_restart" "$(date +%s)"
    state_set "stable_since" "$(date +%s)"

    # 6. Poll tối đa 30s cho ARO start
    log_info "Waiting for ARO to start (up to 30s)..."
    local wait_start; wait_start=$(date +%s)
    while true; do
        local elapsed=$(( $(date +%s) - wait_start ))
        if [[ $elapsed -ge 30 ]]; then
            break
        fi
        sleep 3
        if is_aro_running; then
            local pid; pid=$(get_aro_pid)
            log_success "ARO started successfully (PID: $pid)"
            return 0
        fi
        echo -n "."
    done
    echo ""

    # 7. Kiểm tra wrapper log để diagnose nếu thất bại
    if ! is_aro_running; then
        log_error "ARO failed to start after 30s"
        log_error "Check wrapper log for details:"
        tail -5 "$WRAPPER_LOG" 2>/dev/null | sed 's/^/  /' || true
        log_info "Run 'sudo ./aro-manager.sh debug' for full diagnosis"
        exit 1
    fi
}

do_aro_restart() {
    require_root
    load_configs
    detect_desktop_user

    log_info "Restarting ARO..."

    # Stop (set maintenance + kill)
    maintenance_set
    if is_aro_running; then
        kill_aro
        log_info "ARO stopped"
    fi

    sleep 3

    # Clear maintenance và start
    maintenance_clear
    do_aro_start
}

# ───────────────────────────────────────────────────────────────
# COMMAND: STATUS (Unified)
# ───────────────────────────────────────────────────────────────

do_status() {
    show_banner
    echo ""
    
    if [[ ! -f "$PROXY_CONF_FILE" ]]; then
        log_error "ARO Manager not installed. Run: $SCRIPT_NAME full-install <proxy>"
        exit 1
    fi
    
    load_configs
    detect_desktop_user
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info
    get_last_online_info

    echo "═══════════════════════════════════════════════════════════════"
    echo "  ARO MANAGER STATUS v${SCRIPT_VERSION}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    echo "📋 Node Info:"
    echo "  Host:    $HOSTNAME"
    echo "  Env:     $ENV_TYPE"
    echo "  User:    $CRD_USER"
    echo "  Display: $DISPLAY_NUM"
    echo "  Serial:  $SERIAL"
    echo "  Email:   $EMAIL"
    echo "  Pub IP:  $PUBLIC_IP"

    local _tray_display
    if ! is_aro_running; then
        # Process dead → override bất kể log nói gì
        _tray_display="⚫ Stopped (process not running)"
    else
        case "$TRAY_STATUS" in
            Online)     _tray_display="🟢 Online" ;;
            NoInternet) _tray_display="🔴 NoInternet (connecting...)" ;;
            Offline)    _tray_display="🟡 Offline" ;;
            *)          _tray_display="❓ ${CONNECT_STATUS:-unknown} (api)" ;;
        esac
    fi
    echo "  Status:  $_tray_display"

    echo "  $LAST_ONLINE_LABEL${LAST_ONLINE_AGO:+ $LAST_ONLINE_AGO}"
    echo ""

    echo "💰 Rewards:"
    echo "  Today:     $(format_number "$REWARD_TODAY") pts"
    echo "  Yesterday: $(format_number "$REWARD_YESTERDAY") pts"
    echo "  Uptime:    $(format_uptime "$UPTIME_RATIO")%"
    echo ""

    echo "🔌 Proxy:"
    if [[ "${USE_PROXY:-1}" -eq 0 ]]; then
        echo "  Mode:   ⚪ No-proxy (direct connection)"
    else
        echo "  Server:        $PROXY_HOST:$PROXY_PORT"
        echo "  Redsocks Port: $REDSOCKS_PORT"
        if systemctl is-active --quiet redsocks-aro; then
            echo "  Status: ✓ Running"
        else
            echo "  Status: ✗ Not running"
        fi
    fi
    echo ""

    echo "🤖 Watchdog:"
    if systemctl is-active --quiet aro-watchdog; then
        echo "  Status: ✓ Running"
    else
        echo "  Status: ✗ Not running"
    fi
    if [[ "${TG_ENABLED:-1}" == "1" ]]; then
        echo "  Telegram:  ✓ Enabled"
    else
        echo "  Telegram:  ✗ Disabled (run tele-on to enable)"
    fi

    # Maintenance mode indicator
    if is_maintenance_mode; then
        local maint_age; maint_age=$(maintenance_age_mins)
        local maint_expire_remaining=$(( MAINTENANCE_EXPIRE_MINS - maint_age ))
        echo "  ⏸️  Maintenance: ACTIVE (set ${maint_age}m ago, auto-expires in ${maint_expire_remaining}m)"
        echo "       ARO will NOT auto-restart until: sudo ./aro-manager.sh start"
    fi

    local retry_count; retry_count=$(state_get "retry_count" "0")
    echo "  Check Interval: ${CHECK_INTERVAL}s"
    echo "  Max Retries:    $MAX_RETRIES"
    echo "  Retry Count:    $retry_count/$MAX_RETRIES"
    echo ""

    echo "🎮 ARO Application:"
    if is_aro_running; then
        local aro_pid
        aro_pid=$(get_aro_pid)
        echo "  Status: ✓ Running (PID: $aro_pid)"
        if is_log_fresh; then
            echo "  Log:    ✓ Fresh (<${LOG_STALE_MINUTES}m)"
        else
            echo "  Log:    ⚠ Stale (>${LOG_STALE_MINUTES}m)"
        fi
    else
        echo "  Status: ✗ Not running"
    fi
    echo ""

    echo "🛡️  Security:"
    if iptables -t nat -L ARO_PROXY >/dev/null 2>&1; then
        echo "  Kill-switch: ✓ Active"
    else
        echo "  Kill-switch: ✗ Inactive"
    fi
    if ip6tables -L OUTPUT 2>/dev/null | grep -q "$CRD_USER"; then
        echo "  IPv6 Block:  ✓ Active"
    else
        echo "  IPv6 Block:  ✗ Inactive"
    fi
    local _ip_leak_st; _ip_leak_st=$(state_get "ip_leak_detected" "0")
    if [[ "$_ip_leak_st" == "1" ]]; then
        local _leak_ip; _leak_ip=$(state_get "ip_leak_exit_ip" "?")
        local _leak_since; _leak_since=$(state_get "ip_leak_since" "0")
        local _leak_mins=$(( ($(date +%s) - _leak_since) / 60 ))
        local _recovery_c; _recovery_c=$(state_get "ip_leak_recovery_count" "0")
        echo "  IP Leak:     ❌ LEAK DETECTED (${_leak_ip}) since ${_leak_mins}m — recovery ${_recovery_c}/${IP_LEAK_MAX_RECOVERY}"
    else
        echo "  IP Leak:     ✓ Not detected"
    fi
    echo ""

    echo "═══════════════════════════════════════════════════════════════"
}

# ───────────────────────────────────────────────────────────────
# COMMAND: PROXY SUBCOMMANDS
# ───────────────────────────────────────────────────────────────

do_proxy_test() {
    if [[ ! -f "$PROXY_CONF_FILE" ]]; then
        log_error "Proxy not installed"
        exit 1
    fi

    load_configs
    detect_desktop_user

    echo "═══════════════════════════════════════════════════════════════"
    echo "  IP LEAK TEST — user: $CRD_USER"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local _pass=0 _fail=0

    # Test 1: Redsocks service
    echo -n "Test 1: Redsocks service ... "
    if systemctl is-active --quiet redsocks-aro; then
        echo "✅ Running"
    else
        echo "❌ NOT running"
        (( _fail++ )) || true
    fi

    # Test 2: iptables ARO_PROXY chain
    echo -n "Test 2: iptables ARO_PROXY chain ... "
    if iptables -t nat -L ARO_PROXY >/dev/null 2>&1; then
        local rule_count; rule_count=$(iptables -t nat -L ARO_PROXY 2>/dev/null | grep -c "^" || echo "0")
        echo "✅ Active ($rule_count rules)"
    else
        echo "❌ MISSING — kill-switch not active!"
        (( _fail++ )) || true
    fi

    # Test 3: IPv6 block
    echo -n "Test 3: IPv6 block ... "
    local ipv6_result; ipv6_result=$(sudo -u "$CRD_USER" curl -6 -s --max-time 5 "https://ifconfig.me" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -z "$ipv6_result" ]]; then
        echo "✅ Blocked (no IPv6 leak)"
    else
        echo "❌ IPv6 LEAK: $ipv6_result"
        (( _fail++ )) || true
    fi

    # Test 4: Real IP (as root, bypasses iptables)
    echo -n "Test 4: Real IP (as root) ... "
    local real_ip=""
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        real_ip=$(curl -s --max-time 8 "https://$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        [[ "$real_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        real_ip=""
    done
    if [[ -n "$real_ip" ]]; then
        echo "$real_ip"
    else
        echo "⚠️  Could not determine (no internet as root)"
    fi

    # Test 5: Exit IP (as ubuntu user, through transparent proxy)
    echo -n "Test 5: Exit IP (as $CRD_USER via proxy) ... "
    local exit_ip=""
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        exit_ip=$(sudo -u "$CRD_USER" curl -s --max-time 10 "https://$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        [[ "$exit_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        exit_ip=""
    done
    if [[ -n "$exit_ip" ]]; then
        echo "$exit_ip"
    else
        echo "⚠️  No response (proxy may be blocking — kill-switch active)"
    fi

    # Test 6: Compare IPs
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    if [[ -z "$real_ip" ]] || [[ -z "$exit_ip" ]]; then
        echo "  ⚠️  INCONCLUSIVE — could not get both IPs for comparison"
    elif [[ "$exit_ip" == "$real_ip" ]]; then
        echo "  ❌ IP LEAK! Exit IP ($exit_ip) = Real IP ($real_ip)"
        echo "     Traffic is going DIRECT, not through proxy!"
        (( _fail++ )) || true
    else
        echo "  ✅ NO LEAK — Exit IP ($exit_ip) ≠ Real IP ($real_ip)"
        echo "     Traffic is going through proxy correctly."
        (( _pass++ )) || true
    fi
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    if [[ "$_fail" -eq 0 ]]; then
        log_success "All checks passed — no IP leak detected"
    else
        log_error "$_fail check(s) failed"
        echo "Fix: sudo ./aro-manager.sh proxy enable"
    fi
    echo "═══════════════════════════════════════════════════════════════"
}

do_proxy_enable() {
    require_root
    
    if [[ ! -f "$PROXY_CONF_FILE" ]]; then
        log_error "Proxy not installed"
        exit 1
    fi
    
    load_configs
    detect_desktop_user
    
    log_info "Enabling proxy..."

    create_redsocks_service
    create_iptables_restore_script
    setup_iptables_rules
    persist_iptables_rules
    systemctl daemon-reload
    systemctl start redsocks-aro
    
    sleep 2
    
    if systemctl is-active --quiet redsocks-aro; then
        log_success "Proxy enabled"
    else
        log_error "Failed to enable proxy"
        exit 1
    fi
}

do_proxy_disable() {
    require_root
    
    log_info "Disabling proxy..."
    
    systemctl stop redsocks-aro 2>/dev/null || true
    
    if [[ -f "$PROXY_CONF_FILE" ]]; then
        load_configs
        
        iptables -t nat -D OUTPUT -m owner --uid-owner "$CRD_USER" -j ARO_PROXY 2>/dev/null || true
        iptables -t nat -F ARO_PROXY 2>/dev/null || true
        iptables -t nat -X ARO_PROXY 2>/dev/null || true
        
        ip6tables -D OUTPUT -m owner --uid-owner "$CRD_USER" -j REJECT 2>/dev/null || true
    fi
    
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$IPTABLES_RULES_FILE" 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
    
    log_success "Proxy disabled"
}

# ───────────────────────────────────────────────────────────────
# COMMAND: WATCHDOG SUBCOMMANDS
# ───────────────────────────────────────────────────────────────

do_watchdog_start() {
    require_root
    
    log_info "Starting watchdog..."
    systemctl start aro-watchdog
    
    sleep 2
    
    if systemctl is-active --quiet aro-watchdog; then
        log_success "Watchdog started"
    else
        log_error "Failed to start watchdog"
        exit 1
    fi
}

do_watchdog_stop() {
    require_root
    
    log_info "Stopping watchdog..."
    systemctl stop aro-watchdog
    
    log_success "Watchdog stopped"
}

do_watchdog_restart() {
    require_root
    
    log_info "Restarting watchdog..."
    systemctl restart aro-watchdog
    
    sleep 2
    
    if systemctl is-active --quiet aro-watchdog; then
        log_success "Watchdog restarted"
    else
        log_error "Failed to restart watchdog"
        exit 1
    fi
}

do_watchdog_log() {
    if [[ -f "$WATCHDOG_LOG" ]]; then
        tail -f "$WATCHDOG_LOG"
    else
        echo "No watchdog log found at $WATCHDOG_LOG"
        exit 1
    fi
}

# ───────────────────────────────────────────────────────────────
# COMMAND: UNINSTALL
# ───────────────────────────────────────────────────────────────

do_uninstall() {
    require_root
    
    show_banner
    echo ""
    
    log_warn "This will completely remove ARO Manager (proxy + watchdog)"
    echo ""
    read -p "Are you sure? [y/N] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled"
        exit 0
    fi
    
    echo ""
    log_info "Starting uninstall..."
    
    # Stop services
    systemctl stop aro-watchdog 2>/dev/null || true
    systemctl stop redsocks-aro 2>/dev/null || true
    
    systemctl disable aro-watchdog 2>/dev/null || true
    systemctl disable redsocks-aro 2>/dev/null || true
    
    # Remove service files
    rm -f "$SYSTEMD_WATCHDOG_SERVICE"
    rm -f "$SYSTEMD_REDSOCKS_SERVICE"
    systemctl daemon-reload
    
    log_info "Services removed"
    
    # Remove iptables rules
    if [[ -f "$PROXY_CONF_FILE" ]]; then
        load_configs
        
        iptables -t nat -D OUTPUT -m owner --uid-owner "$CRD_USER" -j ARO_PROXY 2>/dev/null || true
        iptables -t nat -F ARO_PROXY 2>/dev/null || true
        iptables -t nat -X ARO_PROXY 2>/dev/null || true
        
        ip6tables -D OUTPUT -m owner --uid-owner "$CRD_USER" -j REJECT 2>/dev/null || true
        
        iptables-save > "$IPTABLES_RULES_FILE" 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        
        log_info "Firewall rules removed"
    fi
    
    # Remove wrapper
    rm -f "$WRAPPER_SCRIPT"
    log_info "Wrapper removed"
    
    # Remove configs
    rm -rf "$CONFIG_DIR"
    log_info "Configuration removed"
    
    # Remove state files
    rm -f "$PID_FILE"
    rm -f "$STATE_FILE"
    rm -f "$MAINTENANCE_FLAG"
    log_info "State files removed"
    
    echo ""
    log_success "Uninstall complete"
    echo ""
    echo "Note: Packages (redsocks, iptables) are still installed"
    echo "To remove: apt-get purge redsocks iptables-persistent"
    echo ""
}

do_update_watchdog_only() {
    # Gọi sau load_configs + detect_desktop_user đã được gọi từ do_update()
    log_info "=== Watchdog-only update (ARO will keep running) ==="
    echo ""

    local current_script="$SCRIPT_DIR/$SCRIPT_NAME"

    # ── Path check (giống do_update full) ──
    local service_exec=""
    if [[ -f "$SYSTEMD_WATCHDOG_SERVICE" ]]; then
        service_exec=$(grep '^ExecStart=' "$SYSTEMD_WATCHDOG_SERVICE" | cut -d'=' -f2- | awk '{print $1}' || true)
    fi

    if [[ -n "$service_exec" ]] && [[ "$service_exec" != "$current_script" ]]; then
        log_warn "Service is running from a different path: $service_exec"
        log_warn "Copying script to service path..."
        cp "$current_script" "$service_exec"
        chmod +x "$service_exec"
        log_info "Script copied to $service_exec"
    fi

    # Step 1/3: Sync configs (không restart ARO, không rebuild wrapper)
    log_info "Step 1/3: Syncing watchdog config..."
    save_watchdog_config
    save_proxy_config

    # Step 2/3: Rebuild watchdog service file + reload
    log_info "Step 2/3: Rebuilding watchdog service..."
    create_watchdog_service
    systemctl daemon-reload

    # Step 3/3: Restart watchdog only — ARO process tiếp tục chạy
    log_info "Step 3/3: Restarting watchdog service (ARO process untouched)..."

    # Mark this as an update restart so watchdog preserves ARO state and uptime.
    state_set "$UPDATE_RESTART_FLAG" "1"

    systemctl enable aro-watchdog >/dev/null 2>&1
    systemctl restart aro-watchdog
    sleep 3

    # ── Verify ──
    echo ""
    echo "Watchdog-only Update Verification:"

    local wd_status; wd_status=$(systemctl is-active aro-watchdog || echo "failed")
    if [[ "$wd_status" == "active" ]]; then
        echo "  ✓ Watchdog: Running (restarted with new script)"
    else
        echo "  ✗ Watchdog: $wd_status"
        log_error "Watchdog failed to restart"
        echo "Debug: journalctl -u aro-watchdog -n 30"
        exit 1
    fi

    local aro_pid; aro_pid=$(get_aro_pid || true)
    if [[ -n "$aro_pid" ]]; then
        echo "  ✓ ARO:      Still running (PID: $aro_pid) — uptime preserved ✅"
    else
        echo "  ⚠ ARO:      Not running (watchdog will start it shortly)"
    fi

    echo "  ✓ Version:  $SCRIPT_VERSION @ $current_script"
    echo "  ✓ Config:   Synced ($WATCHDOG_CONF_FILE)"
    echo ""

    log_success "Watchdog-only update complete. ARO uptime preserved."
    echo "Monitor: sudo $SCRIPT_NAME watchdog log"
}

do_update() {
    require_root
    show_banner
    echo ""

    # ── Parse flags ──
    local watchdog_only=0
    for arg in "$@"; do
        case "$arg" in
            --watchdog-only) watchdog_only=1 ;;
        esac
    done

    if [[ ! -f "$PROXY_CONF_FILE" ]]; then
        log_error "ARO Manager not installed. Run: $SCRIPT_NAME full-install <proxy>"
        exit 1
    fi

    load_configs
    detect_desktop_user

    # Nếu --watchdog-only: chỉ reload watchdog, không touch ARO
    if [[ "$watchdog_only" -eq 1 ]]; then
        do_update_watchdog_only
        return 0
    fi

    # ── Path check ──
    local service_exec=""
    if [[ -f "$SYSTEMD_WATCHDOG_SERVICE" ]]; then
        service_exec=$(grep '^ExecStart=' "$SYSTEMD_WATCHDOG_SERVICE" | cut -d'=' -f2- | awk '{print $1}' || true)
    fi

    local current_script="$SCRIPT_DIR/$SCRIPT_NAME"
    if [[ -n "$service_exec" ]] && [[ "$service_exec" != "$current_script" ]]; then
        log_warn "Service is running from a different path: $service_exec"
        log_warn "Current script path: $current_script"
        echo ""
        read -p "Copy this script to the service path? [Y/n] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            cp "$current_script" "$service_exec"
            chmod +x "$service_exec"
            log_info "Script copied to $service_exec"
        else
            log_warn "Continuing without copying script..."
        fi
    fi

    # ── Stop services ──
    log_info "Step 1/5: Stopping watchdog..."
    systemctl stop aro-watchdog 2>/dev/null || true
    sleep 2

    log_info "Step 2/5: Stopping ARO process..."
    kill_aro
    sleep 2

    # ── Rebuild ──
    log_info "Step 3/5: Rebuilding launch wrapper..."
    if [[ "${USE_PROXY:-1}" -eq 0 ]]; then
        create_wrapper_script_no_proxy
    else
        create_wrapper_script
    fi

    log_info "Step 4/5: Rebuilding configs + services..."
    save_proxy_config
    save_watchdog_config
    if [[ "${USE_PROXY:-1}" -eq 1 ]]; then
        create_redsocks_service
        create_iptables_restore_script
    fi
    create_watchdog_service
    systemctl daemon-reload

    # ── Restart ──
    log_info "Step 5/5: Starting services..."

    if [[ "${USE_PROXY:-1}" -eq 1 ]]; then
        systemctl restart redsocks-aro
        sleep 3
    fi

    systemctl enable aro-watchdog >/dev/null 2>&1
    systemctl start aro-watchdog
    sleep 3

    # ── Verify & report ──
    echo ""
    echo "Update Verification:"
    
    if [[ "${USE_PROXY:-1}" -eq 0 ]]; then
        echo "  ⚪ Redsocks: Disabled (no-proxy mode)"
        rs_status="active" # fake active so it doesn't fail the update check
    else
        local rs_status; rs_status=$(systemctl is-active redsocks-aro || echo "failed")
        if [[ "$rs_status" == "active" ]]; then
            echo "  ✓ Redsocks: Running"
        else
            echo "  ✗ Redsocks: $rs_status"
        fi
    fi

    local wd_status; wd_status=$(systemctl is-active aro-watchdog || echo "failed")
    if [[ "$wd_status" == "active" ]]; then
        echo "  ✓ Watchdog: Running"
    else
        echo "  ✗ Watchdog: $wd_status"
    fi

    if [[ "${USE_PROXY:-1}" -eq 0 ]]; then
        echo "  ✓ Wrapper: No-proxy mode (direct launch)"
    elif grep -q "ss -tlnp" "$WRAPPER_SCRIPT" 2>/dev/null; then
        echo "  ✓ Wrapper: Updated (ss check)"
    else
        echo "  ⚠ Wrapper: Still using nc check (check script logic)"
    fi

    echo "  ✓ Version: $SCRIPT_VERSION @ $current_script"
    echo "  ✓ Config:  Synced ($WATCHDOG_CONF_FILE)"
    echo ""

    if [[ "$rs_status" == "active" ]] && [[ "$wd_status" == "active" ]]; then
        log_success "Update complete. Watchdog will restart ARO in a few seconds."
        echo "Monitor logs: sudo $SCRIPT_NAME watchdog log"
    else
        log_error "Update failed. Some services are not running."
        echo "Debug: journalctl -u aro-watchdog -n 30"
        exit 1
    fi
}

# ───────────────────────────────────────────────────────────────
# HELP & USAGE
# ───────────────────────────────────────────────────────────────

do_dashboard_config() {
    require_root

    if [[ ! -f "$WATCHDOG_CONF_FILE" ]]; then
        log_error "ARO Manager chưa được cài đặt. Chạy: $SCRIPT_NAME full-install <proxy>"
        exit 1
    fi

    # Parse args: --enable=1|0  --url=http://...  --db-api=key
    local opt_enable="" opt_url="" opt_api_key=""
    for arg in "$@"; do
        case "$arg" in
            --enable=*)  opt_enable="${arg#--enable=}" ;;
            --url=*)     opt_url="${arg#--url=}" ;;
            --db-api=*)  opt_api_key="${arg#--db-api=}" ;;
            status)      ;; # handled below
            *)
                log_error "Argument không hợp lệ: $arg"
                echo "Usage: $SCRIPT_NAME dashboard [status] [--enable=1|0] [--url=URL] [--db-api=KEY]"
                exit 1
                ;;
        esac
    done

    # Helper: update hoặc append key=value vào conf file
    _conf_set() {
        local key="$1" val="$2"
        if grep -q "^${key}=" "$WATCHDOG_CONF_FILE" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$WATCHDOG_CONF_FILE"
        else
            echo "${key}=${val}" >> "$WATCHDOG_CONF_FILE"
        fi
    }

    local changed=0

    if [[ -n "$opt_enable" ]]; then
        if [[ "$opt_enable" == "1" ]] || [[ "$opt_enable" == "true" ]]; then
            _conf_set "DASHBOARD_ENABLED" "true"
        else
            _conf_set "DASHBOARD_ENABLED" "false"
        fi
        changed=1
    fi

    if [[ -n "$opt_url" ]]; then
        _conf_set "DASHBOARD_URL" "\"${opt_url}\""
        changed=1
    fi

    if [[ -n "$opt_api_key" ]]; then
        _conf_set "DASHBOARD_API_KEY" "\"${opt_api_key}\""
        changed=1
    fi

    # Load config để hiển thị trạng thái hiện tại
    load_configs

    echo ""
    echo "══════════════════════════════════════"
    echo "  Dashboard Configuration — $HOSTNAME"
    echo "══════════════════════════════════════"
    if [[ "${DASHBOARD_ENABLED:-false}" == "true" ]]; then
        echo "  Status:  ✅ ENABLED"
    else
        echo "  Status:  ⭕ DISABLED"
    fi
    echo "  URL:     ${DASHBOARD_URL:-(chưa đặt)}"
    echo "  API Key: ${DASHBOARD_API_KEY:+(đã đặt, ẩn)}${DASHBOARD_API_KEY:-  (chưa đặt)}"
    echo "══════════════════════════════════════"
    echo ""

    if [[ $changed -eq 0 ]]; then
        return 0
    fi

    # Reload watchdog để áp dụng config mới (ARO giữ nguyên)
    log_info "Áp dụng config mới — reload watchdog (ARO không bị restart)..."
    do_update_watchdog_only
}

show_usage() {
    show_banner
    cat << EOF

USAGE:
  $SCRIPT_NAME <command> [arguments]

MAIN COMMANDS:
  deploy <proxy> --ssh-key KEY [--vnc-pass PASS] [--crd] [--no-proxy] [--no-telegram]
                      [dashboard --enable=1 --url=URL --db-api=KEY]
                      --no-proxy:     deploy without SOCKS5 proxy (direct connection)
                      --no-telegram:  tắt Telegram notifications (bảo vệ bot token)
                      dashboard:      kích hoạt dashboard ngay khi deploy xong

  full-install [<proxy>] [--no-proxy] [--token TOKEN] [--chatid ID] [--no-telegram]
                      --no-proxy:     install without proxy (proxy string optional)
                      --no-telegram:  tắt Telegram notifications (bảo vệ bot token)

  setup vps [--ssh-key KEY]
                      Cài VPS cơ bản: user, swap, SSH, XFCE, firewall
  setup vnc [--vnc-pass PASS]
                      Cài TigerVNC (XFCE đã có sẵn)
  setup all [--ssh-key KEY] [--vnc-pass PASS]
                      setup vps + setup vnc (chuẩn bị máy mẫu để clone)

  status              Show complete status (proxy + watchdog + ARO)
  debug               Run full diagnostic: services, logs, network live test
                      Auto-detects issues and suggests fixes
                      Output saved to: aro-debug-YYYYMMDD-HHMMSS.log
  start               Start ARO manually (clears maintenance mode, starts watchdog if needed)
  stop                Stop ARO and pause watchdog auto-restart (maintenance mode ON)
  restart             Stop then start ARO
  fix-wrapper         Recreate the ARO launch wrapper script (use if ARO is blocked by wrapper error)
  update              Cập nhật script: rebuild wrapper + restart toàn bộ services
  update --watchdog-only
                      Chỉ reload watchdog (ARO giữ nguyên, không mất uptime)
  tele-off            Tắt Telegram notifications trên node này
  tele-on             Bật lại Telegram notifications trên node này
  report              Send daily report to Telegram immediately
  test-telegram       Gửi tin nhắn Telegram thử để kiểm tra kết nối
  dashboard [status]  Xem trạng thái cấu hình dashboard
  dashboard --enable=1|0 --url=URL --db-api=KEY
                      Kích hoạt/tắt dashboard reporting
  uninstall           Remove everything

PROXY COMMANDS:
  proxy test          Test IP leak and proxy connectivity
  proxy enable        Enable proxy (if disabled)
  proxy disable       Disable proxy temporarily

WATCHDOG COMMANDS:
  watchdog start      Start watchdog service
  watchdog stop       Stop watchdog service
  watchdog restart    Restart watchdog service
  watchdog log        View watchdog log (live tail)
  watchdog-loop       Internal: watchdog main loop (used by service)

EXAMPLES:
  # Full installation
  sudo bash $SCRIPT_NAME full-install "proxy.com:1234:user:pass" \\
    --token "123456:ABC..." --chatid "987654321"

  # Deploy với CRD, không dùng proxy
  sudo bash $SCRIPT_NAME deploy --crd --ssh-key "ssh-rsa AAAA..." --no-proxy

  # Full install không proxy
  sudo bash $SCRIPT_NAME full-install --no-proxy --token "123:ABC..." --chatid "987"

  # Install không có Telegram (bảo vệ bot token khỏi rate limit)
  sudo bash $SCRIPT_NAME full-install "proxy.com:1234:user:pass" --no-telegram

  # Tắt/bật Telegram trên node hiện tại
  sudo bash $SCRIPT_NAME tele-off
  sudo bash $SCRIPT_NAME tele-on

  # Check status
  sudo bash $SCRIPT_NAME status

  # Stop ARO (watchdog paused — won't auto-restart)
  sudo bash $SCRIPT_NAME stop

  # Start ARO again (clears maintenance mode)
  sudo bash $SCRIPT_NAME start

  # Quick restart
  sudo bash $SCRIPT_NAME restart

  # Test proxy
  sudo bash $SCRIPT_NAME proxy test

  # View logs
  sudo bash $SCRIPT_NAME watchdog log

  # Disable proxy temporarily
  sudo bash $SCRIPT_NAME proxy disable

  # Re-enable
  sudo bash $SCRIPT_NAME proxy enable

  # Chuẩn bị máy mẫu để clone nhiều LXC
  sudo bash $SCRIPT_NAME setup all \
    --ssh-key "ssh-rsa AAAA..." \
    --vnc-pass "mypass123"

  # Chỉ cài VNC (VPS đã có XFCE)
  sudo bash $SCRIPT_NAME setup vnc --vnc-pass "mypass123"

  # Kích hoạt dashboard cho node (chạy trên từng VPS)
  sudo bash $SCRIPT_NAME dashboard --enable=1 --url=http://1.2.3.4 --db-api=my_shared_key

  # Tắt dashboard
  sudo bash $SCRIPT_NAME dashboard --enable=0

  # Xem cấu hình dashboard hiện tại
  sudo bash $SCRIPT_NAME dashboard status

LOGS:
  Main log: $MAIN_LOG
  Watchdog log: $WATCHDOG_LOG
  Wrapper log: $WRAPPER_LOG
  Redsocks: journalctl -u redsocks-aro -f
  Watchdog service: journalctl -u aro-watchdog -f

CONFIGURATION:
  Proxy: $PROXY_CONF_FILE
  Watchdog: $WATCHDOG_CONF_FILE
  Redsocks: $REDSOCKS_CONF_FILE

EOF
}

# ───────────────────────────────────────────────────────────────
# MAIN EXECUTION
# ───────────────────────────────────────────────────────────────

main() {
    # Create log files
    touch "$MAIN_LOG" 2>/dev/null || true
    touch "$WATCHDOG_LOG" 2>/dev/null || true
    
    local cmd="${1:-}"
    shift || true
    
    case "$cmd" in
        deploy)
            local proxy_str=""
            if [[ ! "${1:-}" == --* ]]; then
                proxy_str="${1:-}"
                shift || true
            fi

            local has_vnc_pass=0
            local has_crd=0

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vnc-pass)     VNC_PASS="$2";       has_vnc_pass=1; shift 2 ;;
                    --crd)          REMOTE_MODE="crd";   has_crd=1;      shift   ;;
                    --ssh-key)      UBUNTU_SSH_KEY="$2";                 shift 2 ;;
                    --token)        TG_BOT_TOKEN="$2";                   shift 2 ;;
                    --chatid)       TG_CHAT_ID="$2";                     shift 2 ;;
                    --no-proxy)     USE_PROXY=0;                         shift   ;;
                    --no-telegram)  TG_ENABLED=0;                        shift   ;;
                    dashboard)                                            shift   ;;
                    --enable=*)     local _db_en="${1#--enable=}"
                                    if [[ "$_db_en" == "1" ]] || [[ "$_db_en" == "true" ]]; then
                                        DASHBOARD_ENABLED="true"
                                    else
                                        DASHBOARD_ENABLED="false"
                                    fi
                                                                         shift   ;;
                    --url=*)        DASHBOARD_URL="${1#--url=}";         shift   ;;
                    --db-api=*)     DASHBOARD_API_KEY="${1#--db-api=}";  shift   ;;
                    *) shift ;;
                esac
            done

            if [[ -z "$proxy_str" ]] && [[ "$USE_PROXY" -eq 1 ]]; then
                log_error "Proxy string là bắt buộc (hoặc dùng --no-proxy)"
                exit 1
            fi

            # Conflict check
            if [[ $has_vnc_pass -eq 1 ]] && [[ $has_crd -eq 1 ]]; then
                log_error "--vnc-pass và --crd không thể dùng cùng nhau"
                exit 1
            fi

            # Infer mode từ --vnc-pass
            if [[ $has_vnc_pass -eq 1 ]]; then
                REMOTE_MODE="vnc"
            fi

            do_deploy "$proxy_str"
            SHOW_FOOTER_ON_EXIT=1
            ;;

        full-install)
            local proxy_str=""
            if [[ ! "${1:-}" == --* ]]; then
                proxy_str="${1:-}"
                shift || true
            fi
            
            local token=""
            local chatid=""
            
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --token)
                        token="$2"
                        shift 2
                        ;;
                    --chatid)
                        chatid="$2"
                        shift 2
                        ;;
                    --no-proxy)
                        USE_PROXY=0
                        shift
                        ;;
                    --no-telegram)
                        TG_ENABLED=0
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            if [[ -z "$proxy_str" ]] && [[ "$USE_PROXY" -eq 1 ]]; then
                log_error "Proxy string required (or use --no-proxy)"
                echo ""
                echo "Usage: $SCRIPT_NAME full-install <proxy> [--token TOKEN] [--chatid ID]"
                echo "       $SCRIPT_NAME full-install --no-proxy [--token TOKEN] [--chatid ID]"
                echo "       $SCRIPT_NAME full-install <proxy> --no-telegram"
                echo ""
                exit 1
            fi
            
            do_full_install "$proxy_str" "$token" "$chatid"
            SHOW_FOOTER_ON_EXIT=1
            ;;
            
        status)
            do_status
            SHOW_FOOTER_ON_EXIT=1
            ;;

        tele-off)
            load_configs
            TG_ENABLED=0
            save_watchdog_config
            state_set "tg_enabled" "0"   # Có hiệu lực ngay, không cần restart watchdog
            echo "✅ Telegram notifications DISABLED (hiệu lực ngay lập tức)"
            echo "   Run './aro-manager.sh tele-on' to re-enable."
            ;;

        tele-on)
            load_configs
            TG_ENABLED=1
            save_watchdog_config
            state_set "tg_enabled" "1"   # Có hiệu lực ngay, không cần restart watchdog
            echo "✅ Telegram notifications ENABLED (hiệu lực ngay lập tức)"
            echo "   Run './aro-manager.sh tele-off' to disable."
            ;;

        debug)
            do_debug
            SHOW_FOOTER_ON_EXIT=1
            ;;

        fix-wrapper)
            require_root
            load_configs
            detect_desktop_user
            log_info "Recreating wrapper script..."
            if [[ "${USE_PROXY:-1}" -eq 0 ]]; then
                create_wrapper_script_no_proxy
            else
                create_wrapper_script
            fi
            if verify_wrapper_script; then
                log_success "Wrapper fixed successfully at $WRAPPER_SCRIPT"
                log_info "You can now run: sudo ./aro-manager.sh start"
            else
                log_error "Wrapper fix failed — check logs"
                exit 1
            fi
            ;;

        start)
            do_aro_start
            SHOW_FOOTER_ON_EXIT=1
            ;;

        stop)
            do_aro_stop
            SHOW_FOOTER_ON_EXIT=1
            ;;

        restart)
            do_aro_restart
            SHOW_FOOTER_ON_EXIT=1
            ;;
            
        proxy)
            local subcmd="${1:-}"
            case "$subcmd" in
                test)
                    do_proxy_test
                    ;;
                enable)
                    do_proxy_enable
                    ;;
                disable)
                    do_proxy_disable
                    ;;
                *)
                    echo "Usage: $SCRIPT_NAME proxy {test|enable|disable}"
                    exit 1
                    ;;
            esac
            SHOW_FOOTER_ON_EXIT=1
            ;;
            
        setup)
            local subcmd="${1:-}"
            shift || true

            # Parse arguments dùng chung cho tất cả setup subcommands
            local _ssh_key="" _vnc_pass=""
            local _tmp_args=("$@")
            local i=0
            while [[ $i -lt ${#_tmp_args[@]} ]]; do
                case "${_tmp_args[$i]}" in
                    --ssh-key)
                        i=$(( i + 1 ))
                        _ssh_key="${_tmp_args[$i]:-}"
                        ;;
                    --vnc-pass)
                        i=$(( i + 1 ))
                        _vnc_pass="${_tmp_args[$i]:-}"
                        ;;
                esac
                i=$(( i + 1 ))
            done

            case "$subcmd" in
                vps)
                    require_root
                    check_os
                    UBUNTU_SSH_KEY="$_ssh_key"
                    if [[ -z "$UBUNTU_SSH_KEY" ]]; then
                        read -p "Nhập SSH public key cho user ubuntu: " -r UBUNTU_SSH_KEY
                    fi
                    if [[ -z "$UBUNTU_SSH_KEY" ]]; then
                        log_error "SSH key là bắt buộc"; exit 1
                    fi
                    log_info "Chạy Phase 0: VPS Preparation..."
                    deploy_phase0_vps
                    log_success "setup vps hoàn tất."
                    ;;

                vnc)
                    require_root
                    VNC_PASS="$_vnc_pass"
                    if [[ -z "$VNC_PASS" ]]; then
                        read -s -p "Nhập VNC password (tối thiểu 6 ký tự): " -r VNC_PASS
                        echo ""
                    fi
                    if [[ ${#VNC_PASS} -lt 6 ]]; then
                        log_error "VNC password tối thiểu 6 ký tự"; exit 1
                    fi
                    log_info "Chạy Phase 1: TigerVNC Setup..."
                    deploy_phase1_vnc
                    log_success "setup vnc hoàn tất."
                    ;;

                all)
                    require_root
                    check_os
                    UBUNTU_SSH_KEY="$_ssh_key"
                    VNC_PASS="$_vnc_pass"
                    if [[ -z "$UBUNTU_SSH_KEY" ]]; then
                        read -p "Nhập SSH public key cho user ubuntu: " -r UBUNTU_SSH_KEY
                    fi
                    if [[ -z "$UBUNTU_SSH_KEY" ]]; then
                        log_error "SSH key là bắt buộc"; exit 1
                    fi
                    if [[ -z "$VNC_PASS" ]]; then
                        read -s -p "Nhập VNC password (tối thiểu 6 ký tự): " -r VNC_PASS
                        echo ""
                    fi
                    if [[ ${#VNC_PASS} -lt 6 ]]; then
                        log_error "VNC password tối thiểu 6 ký tự"; exit 1
                    fi
                    log_info "Chạy Phase 0: VPS Preparation..."
                    deploy_phase0_vps
                    log_info "Chạy Phase 1: TigerVNC Setup..."
                    deploy_phase1_vnc
                    log_success "setup all hoàn tất. Máy sẵn sàng để clone."
                    ;;

                *)
                    echo "Usage: $SCRIPT_NAME setup {vps|vnc|all} [options]"
                    echo ""
                    echo "  setup vps [--ssh-key KEY]"
                    echo "  setup vnc [--vnc-pass PASS]"
                    echo "  setup all [--ssh-key KEY] [--vnc-pass PASS]"
                    exit 1
                    ;;
            esac
            SHOW_FOOTER_ON_EXIT=1
            ;;

        watchdog)
            local subcmd="${1:-}"
            case "$subcmd" in
                start)
                    do_watchdog_start
                    ;;
                stop)
                    do_watchdog_stop
                    ;;
                restart)
                    do_watchdog_restart
                    ;;
                log)
                    do_watchdog_log
                    ;;
                *)
                    echo "Usage: $SCRIPT_NAME watchdog {start|stop|restart|log}"
                    exit 1
                    ;;
            esac
            SHOW_FOOTER_ON_EXIT=1
            ;;
            
        watchdog-loop)
            # Internal command - called by systemd service
            load_configs
            detect_desktop_user
            watchdog_loop
            ;;

        _restore_iptables)
            # Internal command - called by redsocks-aro.service ExecStartPost
            # Re-applies iptables kill-switch rules after redsocks starts.
            # LXC containers lose iptables state on restart; netfilter-persistent
            # is unreliable in LXC, so we re-apply rules from redsocks service itself.
            if [[ ! -f "$PROXY_CONF_FILE" ]]; then
                exit 0
            fi
            load_configs
            detect_desktop_user
            setup_iptables_rules 2>/dev/null || true
            ;;
            
        report)
            # Send daily report to Telegram on demand
            if [[ ! -f "$PROXY_CONF_FILE" ]]; then
                log_error "ARO Manager not installed. Run: $SCRIPT_NAME full-install <proxy>"
                exit 1
            fi
            load_configs
            detect_desktop_user
            if [[ -z "$TG_BOT_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
                log_error "Telegram not configured. Check $WATCHDOG_CONF_FILE"
                exit 1
            fi
            log_info "Sending report to Telegram..."
            send_daily_report
            log_success "Report sent."
            SHOW_FOOTER_ON_EXIT=1
            ;;

        rollback-wrapper)
            if [[ -f "${WRAPPER_SCRIPT}.bak" ]]; then
                cp "${WRAPPER_SCRIPT}.bak" "$WRAPPER_SCRIPT"
                chmod +x "$WRAPPER_SCRIPT"
                log_success "Wrapper rolled back from backup"
            else
                log_error "No backup found at ${WRAPPER_SCRIPT}.bak"
            fi
            SHOW_FOOTER_ON_EXIT=1
            ;;

        update)
            do_update "$@"
            SHOW_FOOTER_ON_EXIT=1
            ;;

        uninstall)
            do_uninstall
            SHOW_FOOTER_ON_EXIT=1
            ;;

        dashboard)
            do_dashboard_config "$@"
            SHOW_FOOTER_ON_EXIT=1
            ;;

        test-telegram)
            load_configs
            if [[ -z "$TG_BOT_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
                log_error "TG_BOT_TOKEN hoặc TG_CHAT_ID chưa được cấu hình"
                log_info "Chạy deploy trước hoặc kiểm tra: $WATCHDOG_CONF_FILE"
                exit 1
            fi
            log_info "Testing Telegram connection..."
            log_info "  Direct:   https://api.telegram.org"
            log_info "  Fallback: ${TG_API_FALLBACK_URL:-https://tele-api.nauthnael.workers.dev}"

            local test_msg="🔧 <b>[ARO TEST] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
──────────────────────
✅ Telegram connection OK
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

            if send_telegram "$test_msg"; then
                log_success "Telegram test passed!"
            else
                log_error "Telegram test FAILED — cả direct lẫn fallback đều không kết nối được"
                log_error "Kiểm tra bot token và chat ID có đúng không"
                exit 1
            fi
            ;;

        -h|--help|help)
            show_usage
            ;;
            
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"

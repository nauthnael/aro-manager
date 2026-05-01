#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ARO Manager - Unified Proxy + Watchdog Management Script v3.4.8
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
SCRIPT_VERSION="3.4.8"
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

# Proxy settings
REDSOCKS_PORT=12345
PROXY_HOST=""
PROXY_PORT=""
PROXY_USER=""
PROXY_PASS=""

# ── Watchdog timing ──────────────────────────────────────────────
CHECK_INTERVAL=30           # Chu kỳ watchdog: 30s đủ responsive mà không waste CPU
LOG_STALE_MINUTES=10        # Log không update >10m = ARO frozen hoặc crash
DISCONNECT_ALERT_MINUTES=15 # Disconnected >15m mới trigger restart (tránh false positive)
STARTUP_TIMEOUT=120         # Chờ app init (VNC/X11) trước khi check log
RESET_STABLE_HOURS=2        # Sau 2h stable liên tục, reset retry counter về 0
MAX_RETRIES=5               # 5 lần retry với backoff trước khi give up
BACKOFF_TIMES="0 0 30 60 120"  # retry 1&2: ngay lập tức; 3: 30s; 4: 60s; 5: 120s
DAILY_REPORT_HOUR=7         # Giờ gửi daily report (0–23, không dùng leading zero)

# Proxy connectivity check
PROXY_CHECK_INTERVAL=300          # real proxy test every 5 minutes
PROXY_DOWN_NOTIFY_MAX=15          # max Telegram alerts per hour khi proxy server lỗi
PROXY_DOWN_NOTIFY_INTERVAL=$(( 3600 / PROXY_DOWN_NOTIFY_MAX ))

# ── Stuck-connecting watchdog ───────────────────────────────────
STUCK_THRESHOLD_MINUTES=5   # tray=NoInternet >5m = stuck thực sự (không phải fluctuation)
CONNECTING_GRACE_SECS=180   # Sau launch, cho ARO 3 phút để connect trước khi coi là stuck
CONNECTING_WAIT_SECS=300    # Chờ tối đa 5 phút cho ARO reconnect sau restart
CONNECTING_POLL_INTERVAL=30 # Poll tray state mỗi 30s
PROXY_RESTART_TIMEOUT_SECS=60 # Chờ tối đa 60s cho redsocks restart functional
REDSOCKS_QUEUE_THRESHOLD=500  # recv-Q >500 bytes = redsocks backpressure, coi là hung
                             # (empirically: healthy redsocks thường <100)

# Telegram
TRAY_STATUS="unknown"              # Trạng thái thực của ARO app (từ tray state log)
TRAY_STATUS_TS=0                   # Epoch khi TRAY_STATUS được set
TG_BOT_TOKEN=""
TG_CHAT_ID=""

# Throttle states
_last_proxy_down_notify=0
_last_pre_restart_notify=0
PRE_RESTART_NOTIFY_COOLDOWN=300   # Tối thiểu 5 phút giữa 2 lần gửi pre-restart notification

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
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════╗
║         ARO Manager - Complete Node Management v3.4.8         ║
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
    vnc_cmd=$(ps -eo args 2>/dev/null \
        | { grep -E '^/usr/(bin/)?X(tigervnc|vnc|org)' 2>/dev/null || true; } \
        | head -n1 || true)

    # Extract display number: token dạng ":N" đứng sau tên binary (có khoảng trắng bao quanh)
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
    detect_environment
    case "$ENV_TYPE" in
        lxc_vnc)
            detect_vnc_user
            ;;
        *)
            detect_crd_user
            ;;
    esac
}

parse_proxy_string() {
    local proxy_str="$1"
    
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
    
    if [[ -z "$TG_BOT_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
        return 0
    fi
    
    local escaped_msg
    escaped_msg=$(echo "$message" | sed 's/"/\\"/g')
    
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":\"${escaped_msg}\",\"parse_mode\":\"HTML\"}" \
        --max-time 10 2>/dev/null || echo "000")
    
    if [[ "$http_code" != "200" ]]; then
        watchdog_log "WARNING: Telegram notification failed (HTTP $http_code)"
    fi
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
    apt-get install -y -qq \
        redsocks \
        iptables \
        iptables-persistent \
        netfilter-persistent \
        netcat-openbsd \
        curl \
        psmisc \
        > /dev/null 2>&1
    
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
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"

# === Timing ===
CHECK_INTERVAL=$CHECK_INTERVAL
LOG_STALE_MINUTES=$LOG_STALE_MINUTES
DISCONNECT_ALERT_MINUTES=$DISCONNECT_ALERT_MINUTES
STARTUP_TIMEOUT=$STARTUP_TIMEOUT
RESET_STABLE_HOURS=$RESET_STABLE_HOURS
CONNECTING_GRACE_SECS=$CONNECTING_GRACE_SECS
CONNECTING_WAIT_SECS=$CONNECTING_WAIT_SECS
STUCK_THRESHOLD_MINUTES=$STUCK_THRESHOLD_MINUTES
REDSOCKS_QUEUE_THRESHOLD=$REDSOCKS_QUEUE_THRESHOLD
PROXY_RESTART_TIMEOUT_SECS=$PROXY_RESTART_TIMEOUT_SECS

# === Restart Policy ===
MAX_RETRIES=$MAX_RETRIES
BACKOFF_TIMES="$BACKOFF_TIMES"

# === Daily Report ===
DAILY_REPORT_HOUR=$DAILY_REPORT_HOUR

# === ARO Binary ===
ARO_BINARY="$WRAPPER_SCRIPT"

# === ARO Run User ===
ARO_RUN_USER="$CRD_USER"
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
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'ss -tlnp | grep -q ":${REDSOCKS_PORT} " && fuser -k ${REDSOCKS_PORT}/tcp 2>/dev/null || true'
ExecStart=$redsocks_bin -c $REDSOCKS_CONF_FILE
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
    
    # 3. Các thành phần bắt buộc có mặt
    local checks=("redsocks-aro" "ss -tlnp" "REDSOCKS_PORT" "REAL_ARO" 'exec "$REAL_ARO"')
    for check in "${checks[@]}"; do
        if ! grep -q "$check" "$wrapper" 2>/dev/null; then
            log_error "Wrapper missing required component: $check"
            return 1
        fi
    done
    
    # 4. Bash syntax check
    if ! bash -n "$wrapper" 2>/dev/null; then
        log_error "Wrapper has syntax errors"
        return 1
    fi
    
    return 0
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
    SERIAL="N/A"; EMAIL="N/A"; CONNECT_STATUS="N/A"
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
        # Tìm dòng tray=Online ĐẦU TIÊN sau Net init hiện tại
        local online_ts=""
        if [[ -n "$net_init_ts" ]]; then
            online_ts=$(run_as_aro_user grep "linux tray icon synced to state=Online" "$LATEST_LOG_FILE" 2>/dev/null \
                | awk -v cutoff="$net_init_ts" '$0 > cutoff' \
                | head -1 \
                | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || true)
        fi

        if [[ -n "$online_ts" ]]; then
            local ep; ep=$(date -d "$online_ts" +%s 2>/dev/null || echo 0)
            if [[ "$ep" -gt 0 ]]; then
                LAST_ONLINE_LABEL="🟢 Online since"
                LAST_ONLINE_AGO=$(format_time_ago $(( now - ep )))
            fi
        else
            LAST_ONLINE_LABEL="🟢 Currently online"
            LAST_ONLINE_AGO=""
        fi
    elif [[ "$tray_state" == "NoInternet" ]] || [[ "$tray_state" == "Offline" ]]; then
        # Tìm lần Online cuối cùng trong log
        local last_online_ts
        last_online_ts=$(run_as_aro_user grep "linux tray icon synced to state=Online" "$LATEST_LOG_FILE" 2>/dev/null \
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

    # Grep tìm dòng "linux tray icon synced to state=" cuối cùng
    local state
    state=$(run_as_aro_user grep "linux tray icon synced to state=" "$LATEST_LOG_FILE" 2>/dev/null \
        | tail -1 \
        | grep -oP "state=\K[A-Za-z]+" 2>/dev/null || true)
    
    echo "$state"
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
    last_online_line=$(run_as_aro_user grep "linux tray icon synced to state=Online" "$LATEST_LOG_FILE" 2>/dev/null | tail -1 || true)

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
}

launch_aro() {
    watchdog_log "Launching ARO via wrapper: $WRAPPER_SCRIPT"
    watchdog_log "  Display: $DISPLAY_NUM | XAUTH: $XAUTHORITY_PATH"
    if command -v sudo >/dev/null 2>&1 && sudo -n -u "$EFFECTIVE_USER" true 2>/dev/null; then
        sudo -u "$EFFECTIVE_USER" \
            env DISPLAY="$DISPLAY_NUM" XAUTHORITY="$XAUTHORITY_PATH" LIBGL_ALWAYS_SOFTWARE="1" \
            "$WRAPPER_SCRIPT" >/dev/null 2>&1 &
    else
        local launch_cmd="DISPLAY=\"${DISPLAY_NUM}\" XAUTHORITY=\"${XAUTHORITY_PATH}\" LIBGL_ALWAYS_SOFTWARE=1 \"${WRAPPER_SCRIPT}\""
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

    local msg="✅ <b>[ARO RESTARTED] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 User: ${EFFECTIVE_USER}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🔄 Retry: ${retry_count}/${MAX_RETRIES}
──────────────────────
💰 Reward today:     ${f_today} pts
💰 Reward yesterday: ${f_yest} pts
📶 Uptime: ${f_up}%
${LAST_ONLINE_LABEL}: ${LAST_ONLINE_AGO}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

send_notify_max_retries() {
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info

    local msg="🚨 <b>[ARO MAX RETRIES] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
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

    local msg="⚠️ <b>[ARO RESTARTING] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 User: ${EFFECTIVE_USER}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
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

    local msg="🚨 <b>[PROXY DOWN] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
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

    local msg="✅ <b>[PROXY RECOVERED] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
✓ Redsocks service restarted OK
🔧 Context: ${context_label}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

send_notify_redsocks_restarted() {
    local msg="🔄 <b>[REDSOCKS RESTARTED] ${HOSTNAME}</b>
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

    local msg="✅ <b>[ARO RECONNECTED] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 User: ${EFFECTIVE_USER}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 Exit IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
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

    local msg="⚠️ <b>[ARO STUCK] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
──────────────────────
❌ ARO không kết nối được sau ${CONNECTING_WAIT_SECS}s
🔧 Context: ${cause_label}
🔄 Retry: ${retry_count}/${MAX_RETRIES}
👉 <b>Cần kiểm tra thủ công!</b>
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}

send_notify_proxy_dead() {
    local msg="🚨 <b>[PROXY DEAD] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
⏱️ Timeout: ${PROXY_RESTART_TIMEOUT_SECS}s
❌ Redsocks restart FAILED — ARO đang tắt
🛑 Kill-switch đang hoạt động
👉 <b>Cần can thiệp thủ công!</b>
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
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

    local msg="📊 <b>[ARO DAILY REPORT] ${HOSTNAME}</b>
──────────────────────
22: 🖥️ VPS: ${HOSTNAME}
23: 🔢 Serial: ${SERIAL}
24: 📧 Account: ${EMAIL}
25: 🌐 IP: ${PUBLIC_IP}
26: 🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
27: ─────── Reward ───────
28: 💰 Today:     ${f_today} pts
29: 💰 Yesterday: ${f_yest} pts
30: ${trend}
31: 📶 Uptime: ${f_up}%
32: 📡 Status: ${tray_display}
33: ${LAST_ONLINE_LABEL}: ${LAST_ONLINE_AGO}
34: 📅 Date: $(date '+%Y-%m-%d %H:%M:%S')"

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

    local msg="🚀 <b>[ARO MANAGER INSTALLED] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 ARO User: ${EFFECTIVE_USER}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
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
        send_notify_proxy_down "redsocks service not running"

        # Attempt auto-recovery
        watchdog_log "Attempting to restart proxy service..."
        systemctl restart redsocks-aro 2>/dev/null || true
        sleep 3

        if systemctl is-active --quiet redsocks-aro; then
            watchdog_log "SUCCESS: Proxy service recovered"
            send_notify_proxy_recovered
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
            send_notify_redsocks_restarted
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
# upstream routing failure. Runs every PROXY_CHECK_INTERVAL (5m).

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
        send_notify_proxy_down "proxy server unreachable or credentials rejected"
        return 1
    fi

    watchdog_log "Real proxy check OK — exit IP: ${exit_ip}"
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
        send_notify_pre_restart "Transparent proxy broken (redsocks hung/iptables error)" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)"
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
            send_notify_proxy_recovered "stuck_connecting"
            launch_aro
            state_set "last_restart" "$(date +%s)"
            _wait_for_aro_online "redsocks_recovered"
        else
            watchdog_log "Redsocks recovery FAILED after ${PROXY_RESTART_TIMEOUT_SECS}s — ARO stays down"
            send_notify_proxy_dead
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
        send_notify_pre_restart "Upstream SOCKS5 proxy server unreachable" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)"
        kill_aro
        send_notify_proxy_down "proxy server unreachable"
        return 0
    fi

    # ── Bước 3: Mạng OK hết nhưng ARO vẫn stuck ────────────────
    # Có thể app gặp vấn đề nội bộ
    watchdog_log "Network path OK but ARO still stuck — restarting ARO app"
    send_notify_pre_restart "Network OK but ARO app stuck internally" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)"
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
        watchdog_log "Waiting... tray=${tray_state:-unknown} ${elapsed}s / ${CONNECTING_WAIT_SECS}s"

        if [[ "$tray_state" == "Online" ]]; then
            watchdog_log "ARO online successfully after ${elapsed}s (context: $context)"
            send_notify_aro_reconnected "$context" "$elapsed"
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
        send_notify_aro_stuck_manual "$retry_count" "$context"
    else
        watchdog_log "MAX RETRIES reached ($MAX_RETRIES) — giving up"
        send_notify_max_retries
        state_set "retry_count" "0"
    fi
    
    _WAIT_FOR_ARO_ONLINE_RUNNING=false
    return 0
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

watchdog_loop() {
    watchdog_log "=== ARO Manager Watchdog Started ==="
    watchdog_log "Version: $SCRIPT_VERSION"
    watchdog_log "Host: $HOSTNAME"
    watchdog_log "Env: $ENV_TYPE"
    watchdog_log "User: $EFFECTIVE_USER"
    watchdog_log "Display: $DISPLAY_NUM | XAUTH: $XAUTHORITY_PATH"
    watchdog_log "Proxy: $PROXY_HOST:$PROXY_PORT"
    watchdog_log "Check interval: ${CHECK_INTERVAL}s"
    
    # Initialize state
    state_set "retry_count" "0"
    state_set "last_restart" "0"
    state_set "last_report" "0"
    state_set "stable_since" "$(date +%s)"

    local last_daily_hour=-1
    local last_proxy_check_epoch=0   # tracks real proxy check timer

    while true; do
        local now; now=$(date +%s)

        # ── Real proxy check every PROXY_CHECK_INTERVAL (5 min) ──
        if [[ $(( now - last_proxy_check_epoch )) -ge $PROXY_CHECK_INTERVAL ]]; then
            check_real_proxy || true   # failure already logged + notified inside
            last_proxy_check_epoch=$(date +%s)
        fi

        # ── Redsocks service / port check (every cycle) ──
        if ! check_proxy_health; then
            watchdog_log "Proxy unhealthy, skipping ARO checks this cycle"
            sleep "$CHECK_INTERVAL"
            continue
        fi
        
        # Check if ARO is running
        if is_aro_running; then
            LATEST_LOG_FILE=$(get_latest_aro_log)
            
            if is_log_fresh; then
                # Log đang được ghi đều — check tray state thực sự
                local tray_state
                tray_state=$(get_aro_tray_state)
                local now; now=$(date +%s)

                case "$tray_state" in
                    Online)
                        # ── ARO connected & healthy ──────────────────────
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
                        ;;
                    
                    Offline)
                        # Vừa khởi động hoặc đang check mạng — kiểm tra grace period
                        local last_restart; last_restart=$(state_get "last_restart" "0")
                        local since_launch=$(( now - last_restart ))

                        if is_in_grace_period; then
                            local remaining=$(( CONNECTING_GRACE_SECS - since_launch ))
                            watchdog_log "ARO tray=Offline, in startup grace period (${remaining}s remaining)"
                        else
                            watchdog_log "ARO tray=Offline beyond grace period — treating as stuck"
                            local stuck_mins=$(( since_launch / 60 ))
                            handle_stuck_connecting "$stuck_mins"
                        fi
                        ;;

                    NoInternet)
                        # Stuck — tính thời gian
                        local stuck_mins
                        stuck_mins=$(get_disconnected_since_minutes)
                        watchdog_log "ARO process running, tray=NoInternet for ${stuck_mins}m"

                        if [[ "$stuck_mins" -ge "$STUCK_THRESHOLD_MINUTES" ]]; then
                            handle_stuck_connecting "$stuck_mins"
                        else
                            watchdog_log "Monitoring... (${stuck_mins}m < threshold ${STUCK_THRESHOLD_MINUTES}m)"
                        fi
                        ;;

                    *)
                        # State không xác định hoặc log chưa có entry tray
                        watchdog_log "ARO tray state unknown ('${tray_state}') — monitoring"
                        ;;
                esac
            else
                # ── Log stale (>LOG_STALE_MINUTES) ──
                watchdog_log "ARO process running but log is stale (>${LOG_STALE_MINUTES}m)"

                if check_disconnect_alert; then
                    watchdog_log "Recent disconnect detected, attempting restart"
                    
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
                        send_notify_pre_restart "Log stale >$LOG_STALE_MINUTES min, disconnected ${disc_mins}min" "$(get_aro_tray_state)" "$disc_mins" "$retry_count"

                        # Kill and restart
                        kill_aro
                        sleep 3
                        launch_aro
                        
                        state_set "last_restart" "$(date +%s)"
                        state_set "stable_since" "$(date +%s)"
                        
                        # Wait for startup
                        watchdog_log "Waiting ${STARTUP_TIMEOUT}s for ARO to start..."
                        sleep "$STARTUP_TIMEOUT"
                        
                        if is_aro_running && is_log_fresh; then
                            watchdog_log "ARO restarted successfully (retry $retry_count/$MAX_RETRIES)"
                            send_notify_restart_success "$retry_count"
                        else
                            watchdog_log "ARO restart verification failed (retry $retry_count/$MAX_RETRIES)"
                        fi
                    else
                        watchdog_log "MAX RETRIES REACHED ($MAX_RETRIES) - giving up"
                        send_notify_max_retries
                        state_set "retry_count" "0"
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
                
                send_notify_pre_restart "ARO process not found (crashed or killed)" "not_running" "0" "$retry_count"
                launch_aro
                state_set "last_restart" "$(date +%s)"
                state_set "stable_since" "$(date +%s)"
                
                sleep "$STARTUP_TIMEOUT"
                
                if is_aro_running; then
                    watchdog_log "ARO started successfully"
                    send_notify_restart_success "$retry_count"
                else
                    watchdog_log "ARO failed to start"
                fi
            else
                watchdog_log "MAX RETRIES REACHED ($MAX_RETRIES) - giving up"
                send_notify_max_retries
                state_set "retry_count" "0"
            fi
        fi
        
        # Daily report
        local current_hour
        current_hour=$(( 10#$(date +%H) ))   # Force base-10, an toàn với 08, 09
        
        if [[ $current_hour -eq $DAILY_REPORT_HOUR ]] && [[ $last_daily_hour -ne $current_hour ]]; then
            watchdog_log "Sending daily report..."
            send_daily_report
            last_daily_hour=$current_hour
        elif [[ $current_hour -ne $DAILY_REPORT_HOUR ]]; then
            last_daily_hour=-1
        fi
        
        # Sleep until next check
        sleep "$CHECK_INTERVAL"
    done
}

create_watchdog_service() {
    log_info "Creating watchdog systemd service..."
    
    cat > "$SYSTEMD_WATCHDOG_SERVICE" << EOF
[Unit]
Description=ARO Manager Watchdog with Proxy Protection
After=network.target redsocks-aro.service
Requires=redsocks-aro.service

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/$SCRIPT_NAME watchdog-loop
Restart=on-failure
RestartSec=10s
User=root

[Install]
WantedBy=multi-user.target
EOF
    
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
    local disk_total_gb; disk_total_gb=$(df -BG / | awk 'NR==2 {gsub("G",""); print $2}' || echo 20)
    local swap_size=""
    local swap_mb=0
    
    if [[ "$disk_total_gb" -lt 16 ]]; then
        swap_size="1G"; swap_mb=1024
    elif [[ "$disk_total_gb" -lt 30 ]]; then
        swap_size="2G"; swap_mb=2048
    else
        swap_size="4G"; swap_mb=4096
    fi
    
    log_info "Disk: ${disk_total_gb}GB — Sẽ tạo swap ${swap_size}..."
    fallocate -l "$swap_size" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    log_success "Đã tạo và kích hoạt swap ${swap_size}."
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

    local msg="🚀 <b>[ARO DEPLOY COMPLETE] ${HOSTNAME}</b>
──────────────────────
🖥️ Host:     ${HOSTNAME}
🌐 IP:       ${machine_ip}
🔗 Remote:   ${vnc_or_crd}
🖥️ Env:      ${ENV_TYPE}
👤 User:     ubuntu
──────────────────────
🔌 Proxy:    ${PROXY_HOST}:${PROXY_PORT}
🤖 Watchdog: ✅ Active
──────────────────────
🔢 Serial:   ${SERIAL:-Chờ ARO kết nối...}
📧 Account:  ${EMAIL:-N/A}
──────────────────────
📡 Kết nối:
   <code>${machine_ip}:${VNC_PORT}</code>
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
        local swap_total; swap_total=$(free -m | awk '/^Swap:/ {print $2}' || echo 0)
        if [[ "${swap_total:-0}" -gt 0 ]]; then
            log_info "[SKIP] Swap đã tồn tại: ${swap_total}MB"
        else
            _create_swap
        fi
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
    install_packages
    create_config_directory
    save_proxy_config
    save_watchdog_config
    create_redsocks_config
    create_redsocks_service
    setup_iptables_rules
    persist_iptables_rules
    create_wrapper_script
    start_redsocks_service
}

deploy_phase3_ip_verify() {
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
    echo "  • Proxy:       $PROXY_HOST:$PROXY_PORT"
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
    
    validate_telegram_credentials
    
    echo ""
    log_info "Installation plan:"
    echo "  • Proxy: $PROXY_HOST:$PROXY_PORT"
    echo "  • CRD User: $CRD_USER"
    echo "  • Telegram: $([ -n "$TG_BOT_TOKEN" ] && echo "Enabled" || echo "Disabled")"
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
        send_notify_setup_success "systemd"
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
        echo "  💡 ARO not running → force start: sudo ./aro-manager.sh start"
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
    echo "  Server:        $PROXY_HOST:$PROXY_PORT"
    echo "  Redsocks Port: $REDSOCKS_PORT"
    if systemctl is-active --quiet redsocks-aro; then
        echo "  Status: ✓ Running"
    else
        echo "  Status: ✗ Not running"
    fi
    echo ""

    echo "🤖 Watchdog:"
    if systemctl is-active --quiet aro-watchdog; then
        echo "  Status: ✓ Running"
    else
        echo "  Status: ✗ Not running"
    fi
    local retry_count
    retry_count=$(state_get "retry_count" "0")
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
    
    log_info "Running IP leak test for user: $CRD_USER"
    echo ""
    
    echo "Test 1: Redsocks service check..."
    if systemctl is-active --quiet redsocks-aro; then
        echo "  ✓ Redsocks is running"
    else
        echo "  ✗ Redsocks is NOT running"
        exit 1
    fi
    echo ""
    
    echo "Test 2: Redsocks port check..."
    if nc -z 127.0.0.1 "$REDSOCKS_PORT" 2>/dev/null; then
        echo "  ✓ Port $REDSOCKS_PORT is listening"
    else
        echo "  ✗ Port $REDSOCKS_PORT is NOT listening"
        exit 1
    fi
    echo ""
    
    echo "Test 3: IP address test (as user $CRD_USER)..."
    echo ""
    
    local test_ip
    test_ip=$(sudo -u "$CRD_USER" timeout 10 curl -s ifconfig.me 2>/dev/null || echo "FAILED")
    
    if [[ "$test_ip" == "FAILED" ]]; then
        echo "  ⚠️  Could not fetch IP (kill-switch may be active)"
    else
        echo "  Current IP: $test_ip"
        echo ""
        echo "  ⚠️  VERIFY: This should be your PROXY IP, not datacenter IP!"
    fi
    echo ""
    
    echo "Test 4: DNS resolution..."
    if sudo -u "$CRD_USER" timeout 5 nslookup google.com >/dev/null 2>&1; then
        echo "  ✓ DNS resolution works"
    else
        echo "  ⚠️  DNS resolution failed"
    fi
    echo ""
    
    echo "═══════════════════════════════════════════════════════════════"
    echo "Test complete. Verify IP matches your proxy location."
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
    
    setup_iptables_rules
    persist_iptables_rules
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
    rm -f "$PID_FILE" "$STATE_FILE" "${STATE_FILE}.lock"
    
    echo ""
    log_success "Uninstall complete"
    echo ""
    echo "Note: Packages (redsocks, iptables) are still installed"
    echo "To remove: apt-get purge redsocks iptables-persistent"
    echo ""
}

do_update() {
    require_root
    show_banner
    echo ""

    if [[ ! -f "$PROXY_CONF_FILE" ]]; then
        log_error "ARO Manager not installed. Run: $SCRIPT_NAME full-install <proxy>"
        exit 1
    fi

    load_configs
    detect_desktop_user

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
    create_wrapper_script

    log_info "Step 4/5: Rebuilding watchdog service..."
    create_watchdog_service
    systemctl daemon-reload

    # ── Restart ──
    log_info "Step 5/5: Starting services..."

    if ! systemctl is-active --quiet redsocks-aro; then
        systemctl start redsocks-aro
        sleep 3
    fi

    systemctl start aro-watchdog
    sleep 3

    # ── Verify & report ──
    echo ""
    echo "Update Verification:"
    
    local rs_status; rs_status=$(systemctl is-active redsocks-aro || echo "failed")
    if [[ "$rs_status" == "active" ]]; then
        echo "  ✓ Redsocks: Running"
    else
        echo "  ✗ Redsocks: $rs_status"
    fi

    local wd_status; wd_status=$(systemctl is-active aro-watchdog || echo "failed")
    if [[ "$wd_status" == "active" ]]; then
        echo "  ✓ Watchdog: Running"
    else
        echo "  ✗ Watchdog: $wd_status"
    fi

    if grep -q "ss -tlnp" "$WRAPPER_SCRIPT" 2>/dev/null; then
        echo "  ✓ Wrapper: Updated (ss check)"
    else
        echo "  ⚠ Wrapper: Still using nc check (check script logic)"
    fi

    echo "  ✓ Version: $SCRIPT_VERSION @ $current_script"
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

show_usage() {
    show_banner
    cat << EOF

USAGE:
  $SCRIPT_NAME <command> [arguments]

MAIN COMMANDS:
  deploy <proxy> --ssh-key KEY [--vnc-pass PASS] [--token TOKEN] [--chatid ID]
                      Triển khai hoàn chỉnh: VPS + VNC + Proxy + ARO + Watchdog

  deploy <proxy> --crd --ssh-key KEY [--token TOKEN] [--chatid ID]
                      Như trên nhưng dùng Chrome Remote Desktop thay VNC

  full-install <proxy> [--token TOKEN] [--chatid ID]
                      Cài proxy + ARO + watchdog (VPS đã có sẵn XFCE/VNC)

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
  fix-wrapper         Recreate the ARO launch wrapper script (use if ARO is blocked by wrapper error)
  update              Cập nhật script: rebuild wrapper + restart services
  report              Send daily report to Telegram immediately
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

  # Check status
  sudo bash $SCRIPT_NAME status

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
            local proxy_str="${1:-}"
            if [[ -z "$proxy_str" ]]; then
                log_error "Proxy string là bắt buộc"
                exit 1
            fi
            shift || true

            local has_vnc_pass=0
            local has_crd=0

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vnc-pass) VNC_PASS="$2";       has_vnc_pass=1; shift 2 ;;
                    --crd)      REMOTE_MODE="crd";   has_crd=1;      shift   ;;
                    --ssh-key)  UBUNTU_SSH_KEY="$2";                 shift 2 ;;
                    --token)    TG_BOT_TOKEN="$2";                   shift 2 ;;
                    --chatid)   TG_CHAT_ID="$2";                     shift 2 ;;
                    *) shift ;;
                esac
            done

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
            if [[ -z "${1:-}" ]]; then
                log_error "Proxy string required"
                echo ""
                echo "Usage: $SCRIPT_NAME full-install <proxy> [--token TOKEN] [--chatid ID]"
                echo ""
                exit 1
            fi
            
            local proxy_str="$1"
            shift || true
            
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
                    *)
                        shift
                        ;;
                esac
            done
            
            do_full_install "$proxy_str" "$token" "$chatid"
            SHOW_FOOTER_ON_EXIT=1
            ;;
            
        status)
            do_status
            SHOW_FOOTER_ON_EXIT=1
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
            create_wrapper_script
            if verify_wrapper_script; then
                log_success "Wrapper fixed successfully at $WRAPPER_SCRIPT"
                log_info "You can now run: sudo ./aro-manager.sh start"
            else
                log_error "Wrapper fix failed — check logs"
                exit 1
            fi
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
            do_update
            SHOW_FOOTER_ON_EXIT=1
            ;;

        uninstall)
            do_uninstall
            SHOW_FOOTER_ON_EXIT=1
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

#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ARO Manager - Unified Proxy + Watchdog Management Script v2.2.0
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
SCRIPT_VERSION="2.2.0"
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
WRAPPER_LOG="/var/log/aro-proxy-wrapper.log"

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

# Watchdog settings (defaults)
CHECK_INTERVAL=30
LOG_STALE_MINUTES=10
DISCONNECT_ALERT_MINUTES=15
STARTUP_TIMEOUT=120
RESET_STABLE_HOURS=2
MAX_RETRIES=5
BACKOFF_TIMES="0 0 30 60 120"
DAILY_REPORT_HOUR=7

# Proxy connectivity check
PROXY_CHECK_INTERVAL=300          # real proxy test every 5 minutes
PROXY_DOWN_NOTIFY_MAX=15          # max Telegram alerts per hour when proxy is down
PROXY_DOWN_NOTIFY_INTERVAL=$(( 3600 / PROXY_DOWN_NOTIFY_MAX ))  # = 240s between alerts

# Telegram
TG_BOT_TOKEN=""
TG_CHAT_ID=""

# Runtime
CURRENT_USER=$(whoami)
CRD_USER=""
EFFECTIVE_USER=""
EFFECTIVE_HOME=""
ARO_LOG_DIR=""
ARO_DATA_DIR=""
HOSTNAME=$(hostname)
export DISPLAY=":20"
export XAUTHORITY=""
export LIBGL_ALWAYS_SOFTWARE="1"

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
║         ARO Manager - Complete Node Management v2.2.0         ║
║      Transparent Proxy + Watchdog + Kill-Switch Protection    ║
╠═══════════════════════════════════════════════════════════════╣
║  GitHub: https://github.com/nauthnael/aro-node-manager        ║
║  X/Twitter: https://x.com/tuangg                              ║
╚═══════════════════════════════════════════════════════════════╝
EOF
}

show_footer() {
    cat << 'EOF'
─────────────────────────────────────────────────────────────
 Thanks for using ARO Manager! Follow @tuangg on X/Twitter
 for updates, tips and new scripts: https://x.com/tuangg
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

detect_crd_user() {
    # Detect Chrome Remote Desktop user
    local user
    user=$(ps aux | grep '[c]hrome-remote-desktop' | awk '{print $1}' | head -n1)
    
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
    
    CRD_USER="$user"
    EFFECTIVE_USER="$user"
    EFFECTIVE_HOME=$(eval echo "~$user")
    ARO_LOG_DIR="$EFFECTIVE_HOME/.local/share/com.aro.ARONetwork/logs"
    ARO_DATA_DIR="$EFFECTIVE_HOME/.local/share/com.aro.ARONetwork"
    export XAUTHORITY="$EFFECTIVE_HOME/.Xauthority"
    
    log_info "Detected CRD user: $CRD_USER (home: $EFFECTIVE_HOME)"
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
    
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":\"${escaped_msg}\",\"parse_mode\":\"HTML\"}" \
        > /dev/null 2>&1 || true
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
        log_warn "Cannot resolve proxy hostname, using hostname directly"
        proxy_ip="$PROXY_HOST"
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

create_wrapper_script() {
    log_info "Creating ARO launch wrapper with proxy checks..."
    
    cat > "$WRAPPER_SCRIPT" << 'EOF'
#!/bin/bash
# ARO Manager - Launch Wrapper with Proxy Protection
# This wrapper ensures ARO only runs when proxy is healthy

REAL_ARO="/usr/bin/ARO"
LOG="/var/log/aro-proxy-wrapper.log"
REDSOCKS_PORT=12345

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

# Check 2: Is redsocks port listening?
if ! timeout 3 nc -z 127.0.0.1 "$REDSOCKS_PORT" 2>/dev/null; then
    log_msg "CRITICAL: Redsocks port $REDSOCKS_PORT not responding!"
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
    
    chmod +x "$WRAPPER_SCRIPT"
    log_success "Wrapper created at $WRAPPER_SCRIPT"
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
    echo "$ratio" | awk '{printf "%.1f", $1 * 100}' || echo "N/A"
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
    [[ -n "$val" ]] && REWARD_TODAY="$val"

    val=$(echo "$lines" | grep -oP '(?<="yesterday":)[0-9.]+' 2>/dev/null | tail -1 || true)
    [[ -n "$val" ]] && REWARD_YESTERDAY="$val"

    val=$(echo "$lines" | grep -oP '(?<="uptime":)[0-9.]+' 2>/dev/null | tail -1 || true)
    [[ -n "$val" ]] && UPTIME_RATIO="$val"

    val=$(echo "$lines" | grep -oP '(?<="publicIp":")[^"]+' 2>/dev/null | tail -1 || true)
    [[ -n "$val" ]] && PUBLIC_IP="$val"

    return 0
}

get_last_online_info() {
    LAST_ONLINE_LABEL="❓ No connection history"
    LAST_ONLINE_AGO=""

    [[ -z "$LATEST_LOG_FILE" ]] && return 0
    ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null && return 0

    local now; now=$(date +%s)
    local log_content
    log_content=$(run_as_aro_user tail -n 500 "$LATEST_LOG_FILE" 2>/dev/null || true)

    local last_connected_line
    last_connected_line=$(echo "$log_content" | grep '"connect":"connected"' 2>/dev/null | tail -1 || true)
    if [[ -z "$last_connected_line" ]]; then
        LAST_ONLINE_LABEL="❓ Never connected in recent log"
        return 0
    fi

    local last_ts_str
    last_ts_str=$(echo "$last_connected_line" \
        | grep -oP '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null | tr -d '[' || true)
    local last_epoch=0
    [[ -n "$last_ts_str" ]] && last_epoch=$(date -d "$last_ts_str" +%s 2>/dev/null || echo 0)
    if [[ "$last_epoch" -eq 0 ]]; then
        LAST_ONLINE_LABEL="❓ Could not parse timestamp"
        return 0
    fi

    local elapsed=$(( now - last_epoch ))
    local ago_str; ago_str=$(format_time_ago "$elapsed")

    if [[ "$CONNECT_STATUS" == "connected" ]]; then
        local first_conn_ts
        first_conn_ts=$(echo "$log_content" | grep '"connect":"connected"' 2>/dev/null | head -1 \
            | grep -oP '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null | tr -d '[' || true)
        local sess_epoch=0
        [[ -n "$first_conn_ts" ]] && sess_epoch=$(date -d "$first_conn_ts" +%s 2>/dev/null || echo 0)
        if [[ "$sess_epoch" -gt 0 ]]; then
            LAST_ONLINE_LABEL="🟢 Online since"
            LAST_ONLINE_AGO=$(format_time_ago $(( now - sess_epoch )))
        else
            LAST_ONLINE_LABEL="🟢 Currently online"
            LAST_ONLINE_AGO="$ago_str"
        fi
    else
        LAST_ONLINE_LABEL="🔴 Last online"
        LAST_ONLINE_AGO="$ago_str"
    fi
    return 0
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

kill_aro() {
    watchdog_log "Killing ARO process..."
    pkill -u "$EFFECTIVE_USER" -x ARO 2>/dev/null || true
    sleep 2
    pkill -9 -u "$EFFECTIVE_USER" -x ARO 2>/dev/null || true
    sleep 1
}

launch_aro() {
    watchdog_log "Launching ARO via wrapper: $WRAPPER_SCRIPT"
    if command -v sudo >/dev/null 2>&1 && sudo -n -u "$EFFECTIVE_USER" true 2>/dev/null; then
        sudo -u "$EFFECTIVE_USER" \
            env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" LIBGL_ALWAYS_SOFTWARE="1" \
            "$WRAPPER_SCRIPT" >/dev/null 2>&1 &
    else
        local launch_cmd="DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY LIBGL_ALWAYS_SOFTWARE=1 $WRAPPER_SCRIPT"
        su - "$EFFECTIVE_USER" -c "$launch_cmd" >/dev/null 2>&1 &
    fi
    watchdog_log "ARO launch initiated (PID: $!)"
}

# ── Telegram notification templates ────────────────────────────

send_notify_restart_success() {
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

# Epoch of last proxy-down Telegram alert (throttle state, in-memory)
_last_proxy_down_notify=0

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
    local msg="✅ <b>[PROXY RECOVERED] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
✓ Redsocks service restarted successfully
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

    local msg="📊 <b>[ARO DAILY REPORT] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
─────── Reward ───────
💰 Today:     ${f_today} pts
💰 Yesterday: ${f_yest} pts
${trend}
📶 Uptime: ${f_up}%
🟢 Status: ${CONNECT_STATUS}
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

    # Check redsocks port
    if ! nc -z 127.0.0.1 "$REDSOCKS_PORT" 2>/dev/null; then
        watchdog_log "WARNING: Redsocks port $REDSOCKS_PORT not responding"
        return 1
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
            --socks5-hostname "${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" \
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
            grep -v "^${key}=" "$STATE_FILE" > "$temp" 2>/dev/null || true
        else
            : > "$temp"
        fi
        
        echo "${key}=${value}" >> "$temp"
        mv "$temp" "$STATE_FILE"
        
    ) 200>"$lock"
}

watchdog_loop() {
    watchdog_log "=== ARO Manager Watchdog Started ==="
    watchdog_log "Version: $SCRIPT_VERSION"
    watchdog_log "Host: $HOSTNAME"
    watchdog_log "User: $EFFECTIVE_USER"
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
            # ARO is running - check if healthy
            if is_log_fresh; then
                # ARO is healthy
                local retry_count
                retry_count=$(state_get "retry_count" "0")
                
                if [[ $retry_count -gt 0 ]]; then
                    watchdog_log "ARO healthy after recovery (retry count: $retry_count)"
                fi
                
                # Reset retry counter after stable period
                local stable_since
                stable_since=$(state_get "stable_since")
                local stable_duration=$(( $(date +%s) - stable_since ))
                local reset_threshold=$((RESET_STABLE_HOURS * 3600))
                
                if [[ $stable_duration -gt $reset_threshold ]] && [[ $retry_count -gt 0 ]]; then
                    watchdog_log "ARO stable for ${RESET_STABLE_HOURS}h, resetting retry counter"
                    state_set "retry_count" "0"
                fi
            else
                # ARO is running but log is stale
                watchdog_log "ARO process running but log is stale (>${LOG_STALE_MINUTES}m)"
                
                # Check for disconnect alert
                if check_disconnect_alert; then
                    watchdog_log "Recent disconnect detected, attempting restart"
                    
                    # Increment retry counter
                    local retry_count
                    retry_count=$(state_get "retry_count" "0")
                    retry_count=$((retry_count + 1))
                    state_set "retry_count" "$retry_count"
                    
                    if [[ $retry_count -le $MAX_RETRIES ]]; then
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
            retry_count=$((retry_count + 1))
            state_set "retry_count" "$retry_count"
            
            if [[ $retry_count -le $MAX_RETRIES ]]; then
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
                watchdog_log "MAX RETRIES REACHED ($MAX_RETRIES) - not attempting start"
                send_notify_max_retries
                state_set "retry_count" "0"
            fi
        fi
        
        # Daily report
        local current_hour
        current_hour=$(date +%H | sed 's/^0//')
        
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
    detect_crd_user
    
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

    echo ""
    log_info "=== PHASE 1: PROXY SETUP ==="

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

    echo ""
    log_info "=== PHASE 2: IP VERIFICATION (ANTI-LEAK CHECK) ==="
    echo ""
    echo "Waiting 5s for iptables rules to stabilise..."
    sleep 5

    verify_proxy_ip "$REAL_IP"

    echo ""
    log_info "=== PHASE 3: ARO INSTALLATION ==="

    install_aro_app

    echo ""
    log_info "=== PHASE 4: WATCHDOG SETUP ==="

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

    echo ""
    log_info "=== PHASE 5: VERIFICATION ==="

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
    detect_crd_user
    parse_node_info
    get_last_online_info

    echo "═══════════════════════════════════════════════════════════════"
    echo "  ARO MANAGER STATUS v${SCRIPT_VERSION}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    echo "📋 Node Info:"
    echo "  Host:    $HOSTNAME"
    echo "  User:    $CRD_USER"
    echo "  Serial:  $SERIAL"
    echo "  Email:   $EMAIL"
    echo "  Pub IP:  $PUBLIC_IP"
    echo "  Status:  $CONNECT_STATUS"
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
    detect_crd_user
    
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
    detect_crd_user
    
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

# ───────────────────────────────────────────────────────────────
# HELP & USAGE
# ───────────────────────────────────────────────────────────────

show_usage() {
    show_banner
    cat << EOF

USAGE:
  $SCRIPT_NAME <command> [arguments]

MAIN COMMANDS:
  full-install <proxy> [--token TOKEN] [--chatid ID]
                      Complete setup: proxy + watchdog + kill-switch

  status              Show complete status (proxy + watchdog + ARO)
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
            detect_crd_user
            watchdog_loop
            ;;
            
        report)
            # Send daily report to Telegram on demand
            if [[ ! -f "$PROXY_CONF_FILE" ]]; then
                log_error "ARO Manager not installed. Run: $SCRIPT_NAME full-install <proxy>"
                exit 1
            fi
            load_configs
            detect_crd_user
            if [[ -z "$TG_BOT_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
                log_error "Telegram not configured. Check $WATCHDOG_CONF_FILE"
                exit 1
            fi
            log_info "Sending report to Telegram..."
            send_daily_report
            log_success "Report sent."
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

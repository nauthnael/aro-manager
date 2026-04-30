import os
import re

file_path = "c:\\Users\\Administrator\\OneDrive\\Documents\\Claude\\Projects\\ARO  manager\\aro-manager.sh"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Update version to 3.0.0
content = content.replace("v2.4.0", "v3.0.0")
content = content.replace('SCRIPT_VERSION="2.4.0"', 'SCRIPT_VERSION="3.0.0"')

# 2. Add deploy variables
deploy_vars = """
# Deploy config
REMOTE_MODE=""          # "vnc" | "crd" — chọn lúc deploy
VNC_PASS=""             # VNC password (bắt buộc khi remote_mode=vnc)
UBUNTU_SSH_KEY=""       # SSH public key (bắt buộc)
VNC_DISPLAY=":1"
VNC_PORT="5901"
VNC_RESOLUTION="1280x800"
VNC_DEPTH="24"
"""
content = content.replace('export LIBGL_ALWAYS_SOFTWARE="1"', 'export LIBGL_ALWAYS_SOFTWARE="1"\n' + deploy_vars)

# 3. Add Deployment Helper Functions and Phases
deploy_functions = """
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

ExecStart=/usr/bin/vncserver $VNC_DISPLAY \\
    -geometry $VNC_RESOLUTION \\
    -depth $VNC_DEPTH \\
    -localhost no \\
    -rfbport $VNC_PORT \\
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
    apt-get install -y -qq wget curl gnupg2 btop fail2ban unattended-upgrades \
        software-properties-common apt-transport-https ca-certificates
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
        apt-get install -y -qq xfce4 xfce4-goodies dbus-x11 x11-xserver-utils \
            xserver-xorg-core xbase-clients xauth libgl1-mesa-dri \
            xscreensaver psmisc
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

    local machine_ip; machine_ip=$(get_real_ip)

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
"""

old_full_install = """do_full_install() {
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
}"""

new_full_install = """do_full_install() {
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
}"""

content = content.replace(old_full_install, deploy_functions + "\n" + new_full_install)

main_cmd_case_old = """    case "$cmd" in
        full-install)"""

main_cmd_case_new = """    case "$cmd" in
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

        full-install)"""

content = content.replace(main_cmd_case_old, main_cmd_case_new)

old_usage = """MAIN COMMANDS:
  full-install <proxy> [--token TOKEN] [--chatid ID]
                      Complete setup: proxy + watchdog + kill-switch"""

new_usage = """MAIN COMMANDS:
  deploy <proxy> --ssh-key KEY [--vnc-pass PASS] [--token TOKEN] [--chatid ID]
                      Triển khai hoàn chỉnh: VPS + VNC + Proxy + ARO + Watchdog

  deploy <proxy> --crd --ssh-key KEY [--token TOKEN] [--chatid ID]
                      Như trên nhưng dùng Chrome Remote Desktop thay VNC

  full-install <proxy> [--token TOKEN] [--chatid ID]
                      Cài proxy + ARO + watchdog (VPS đã có sẵn XFCE/VNC)"""

content = content.replace(old_usage, new_usage)

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Patch applied successfully.")

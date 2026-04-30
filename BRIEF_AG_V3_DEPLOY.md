# Brief for Antigravity — ARO Manager v3.0.0: Lệnh `deploy` tích hợp VPS + VNC/CRD + ARO

## Tổng quan nhiệm vụ
Tích hợp logic từ `setup_vps.sh` và `setup-tigervnc.sh` vào `aro-manager.sh`, tạo lệnh mới `deploy` chạy toàn bộ từ A-Z. Đây là thay đổi lớn nhất từ trước đến nay, bump version lên **3.0.0**.

## Files tham chiếu (đọc trước khi code)
- `aro-manager.sh` — file chính, cần chỉnh sửa
- `setup_vps.sh` — nguồn logic Phase 0 (VPS prep)
- `setup-tigervnc.sh` — nguồn logic Phase 1 VNC

---

## Quy tắc bắt buộc

1. **`set -euo pipefail`** luôn được giữ. Mọi lệnh có thể fail phải bọc `|| true` hoặc dùng `if/fi`.
2. **Không dùng `&&` chain cho điều kiện** — luôn dùng `if/then/fi` để tránh bug set -e.
3. **Idempotent**: mỗi step kiểm tra đã cài chưa → log `[SKIP]` hoặc `[DONE]`.
4. **Bump version**: `2.4.0` → `3.0.0` ở đủ 3 chỗ: header comment, `SCRIPT_VERSION`, `show_banner()`.
5. **Giữ nguyên** toàn bộ logic hiện tại: proxy, watchdog, status, report, proxy test — không động vào.
6. **Push lên GitHub** sau khi xong: `https://github.com/nauthnael/aro-manager`

---

## Thay đổi cần thực hiện

---

### 1. Thêm biến global mới (sau phần ENV_TYPE)

```bash
# Deploy config
REMOTE_MODE=""          # "vnc" | "crd" — chọn lúc deploy
VNC_PASS=""             # VNC password (bắt buộc khi remote_mode=vnc)
UBUNTU_SSH_KEY=""       # SSH public key (bắt buộc)
VNC_DISPLAY=":1"
VNC_PORT="5901"
VNC_RESOLUTION="1280x800"
VNC_DEPTH="24"
```

---

### 2. Thêm command `deploy` vào `main()`

**Cú pháp:**
```
# VNC — --vnc-pass ngầm định mode VNC, truyền password luôn
sudo bash aro-manager.sh deploy <proxy> --vnc-pass PASS --ssh-key "KEY" [--token TOKEN] [--chatid ID]

# CRD — flag --crd khai báo rõ ràng
sudo bash aro-manager.sh deploy <proxy> --crd --ssh-key "KEY" [--token TOKEN] [--chatid ID]

# Interactive — không truyền mode, script hỏi lúc chạy
sudo bash aro-manager.sh deploy <proxy> --ssh-key "KEY" [--token TOKEN] [--chatid ID]
```

**Parse arguments — logic đầy đủ:**

```bash
case "deploy")
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
```

**Logic interactive + validate** (đặt ở đầu `do_deploy()`, sau require_root):

```bash
# Nếu chưa có mode → hỏi interactive
if [[ -z "$REMOTE_MODE" ]]; then
    echo ""
    echo "Chọn phương thức remote desktop:"
    echo "  1) VNC (TigerVNC) — khuyến nghị cho LXC"
    echo "  2) CRD (Chrome Remote Desktop) — cho bare-metal / VM"
    echo ""
    read -p "Lựa chọn [1/2]: " -r _choice
    case "$_choice" in
        1) REMOTE_MODE="vnc" ;;
        2) REMOTE_MODE="crd" ;;
        *) log_error "Lựa chọn không hợp lệ (nhập 1 hoặc 2)"; exit 1 ;;
    esac
fi

# Validate SSH key (bắt buộc)
if [[ -z "$UBUNTU_SSH_KEY" ]]; then
    read -p "Nhập SSH public key cho user ubuntu: " -r UBUNTU_SSH_KEY
fi
if [[ -z "$UBUNTU_SSH_KEY" ]]; then
    log_error "SSH key là bắt buộc"; exit 1
fi

# Validate VNC password (bắt buộc nếu mode VNC)
if [[ "$REMOTE_MODE" == "vnc" ]] && [[ -z "$VNC_PASS" ]]; then
    read -s -p "Nhập VNC password (tối thiểu 6 ký tự): " -r VNC_PASS
    echo ""
fi
if [[ "$REMOTE_MODE" == "vnc" ]] && [[ ${#VNC_PASS} -lt 6 ]]; then
    log_error "VNC password tối thiểu 6 ký tự"; exit 1
fi
```

---

### 3. Hàm `do_deploy()` — cấu trúc chính

```bash
do_deploy() {
    local proxy_string="$1"
    shift

    show_banner
    require_root
    check_os

    # Parse thêm arguments
    # ... parse --ssh-key, --vnc-pass, --token, --chatid, --crd, --vnc

    # ── Bước A: Chọn remote mode ──────────────────────────────────
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

    # ── Bước B: Validate bắt buộc ─────────────────────────────────
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

    # ── Hiện summary và xác nhận ──────────────────────────────────
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

    # ── Phase 0: VPS Preparation ──────────────────────────────────
    deploy_phase0_vps

    # ── Phase 1: Remote Desktop ───────────────────────────────────
    if [[ "$REMOTE_MODE" == "vnc" ]]; then
        deploy_phase1_vnc
    else
        deploy_phase1_crd
    fi

    # ── Detect user sau khi setup xong ───────────────────────────
    detect_desktop_user

    # ── Phase 2-5: Proxy + IP check + ARO + Watchdog ─────────────
    # Tái sử dụng logic từ full-install (extract thành sub-functions)
    deploy_phase2_proxy
    deploy_phase3_ip_verify
    deploy_phase4_aro
    deploy_phase5_watchdog

    # ── Phase 6: Verification + Telegram report ───────────────────
    deploy_phase6_finish
}
```

---

### 4. `deploy_phase0_vps()` — VPS Preparation (từ setup_vps.sh)

Logic theo thứ tự, **mỗi bước kiểm tra idempotent**:

#### 4a. Tạo/verify user ubuntu
```bash
if id "ubuntu" &>/dev/null; then
    log_info "[SKIP] User ubuntu đã tồn tại"
    # Vẫn append SSH key nếu chưa có
    _append_ssh_key_if_needed
else
    log_info "Tạo user ubuntu..."
    useradd -m -s /bin/bash ubuntu
    usermod -aG sudo ubuntu
    _setup_ssh_key
fi

# Đảm bảo NOPASSWD sudo
if [[ ! -f /etc/sudoers.d/ubuntu-nopasswd ]]; then
    echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu-nopasswd
    chmod 440 /etc/sudoers.d/ubuntu-nopasswd
fi
passwd -l ubuntu 2>/dev/null || true
```

#### 4b. apt update + upgrade
```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
```

#### 4c. Swap — **SKIP nếu LXC**
```bash
# Phát hiện LXC: không cho phép tạo swapfile
local is_lxc=0
local virt; virt=$(systemd-detect-virt --container 2>/dev/null || true)
[[ "$virt" == "lxc" ]] && is_lxc=1

if [[ $is_lxc -eq 1 ]]; then
    log_info "[SKIP] Môi trường LXC — bỏ qua cấu hình swap"
else
    # Kiểm tra swap đã tồn tại chưa
    local swap_total; swap_total=$(free -m | awk '/^Swap:/ {print $2}' || echo 0)
    if [[ "${swap_total:-0}" -gt 0 ]]; then
        log_info "[SKIP] Swap đã tồn tại: ${swap_total}MB"
    else
        # Tạo swap theo dung lượng disk (logic từ setup_vps.sh)
        # disk < 16GB → 1G | < 30GB → 2G | >= 30GB → 4G
        _create_swap
    fi
    # Áp dụng tối ưu swap (luôn chạy, idempotent qua file sysctl)
    _apply_swap_optimization
fi
```

#### 4d. SSH Hardening
```bash
if [[ -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; then
    log_info "[SKIP] SSH hardening đã được cấu hình"
else
    _setup_ssh_hardening   # logic rollback từ setup_vps.sh
fi
```

#### 4e. Cài utilities + fail2ban + unattended-upgrades
```bash
apt-get install -y -qq wget curl gnupg2 btop fail2ban unattended-upgrades \
    software-properties-common apt-transport-https ca-certificates

# fail2ban config (idempotent — ghi đè file là OK)
_configure_fail2ban
_configure_unattended_upgrades
```

#### 4f. UFW Firewall
```bash
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 5901/tcp    # TigerVNC
ufw allow 11235/tcp   # OptimAI (giữ lại cho tương lai)
ufw --force enable
```

#### 4g. XFCE install (skip nếu đã cài)
```bash
if dpkg -l xfce4 2>/dev/null | grep -q '^ii'; then
    log_info "[SKIP] XFCE đã được cài đặt"
else
    apt-get install -y -qq xfce4 xfce4-goodies dbus-x11 x11-xserver-utils \
        xserver-xorg-core xbase-clients xauth libgl1-mesa-dri \
        xscreensaver psmisc
    apt-get purge -y light-locker 2>/dev/null || true
fi

# Xwrapper (idempotent)
cat > /etc/X11/Xwrapper.config << 'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF
```

#### 4h. Polkit + XFCE power config + screensaver off
```bash
# Chạy lại mỗi lần cũng OK (ghi đè file config)
_configure_polkit_colord        # /etc/polkit-1/localauthority/...
_configure_xfce_power_manager   # ~/.config/xfce4/...
_disable_xscreensaver_autostart # ~/.config/autostart/...
# chown -R ubuntu:ubuntu cho tất cả ~/.config/...
```

---

### 5. `deploy_phase1_vnc()` — TigerVNC (từ setup-tigervnc.sh)

```bash
deploy_phase1_vnc() {
    log_info "=== PHASE 1: TIGERVNC SETUP ==="

    # Cài package (skip nếu đã có)
    if dpkg -l tigervnc-standalone-server 2>/dev/null | grep -q '^ii'; then
        log_info "[SKIP] TigerVNC đã được cài đặt"
    else
        apt-get install -y -qq tigervnc-standalone-server tigervnc-common dbus-x11
    fi

    local vnc_dir="/home/ubuntu/.vnc"
    install -d -o ubuntu -g ubuntu -m 700 "$vnc_dir"

    # Password: skip nếu đã có, KHÔNG ghi đè
    if [[ -f "$vnc_dir/passwd" ]]; then
        log_info "[SKIP] VNC password đã tồn tại"
    else
        echo "$VNC_PASS" | vncpasswd -f > "$vnc_dir/passwd"
        chmod 600 "$vnc_dir/passwd"
        chown ubuntu:ubuntu "$vnc_dir/passwd"
        log_success "VNC password đã được đặt"
    fi

    # xstartup (luôn update — idempotent)
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

    # Systemd service (luôn tạo/update)
    _create_vnc_service

    systemctl daemon-reload
    systemctl enable vncserver.service >/dev/null 2>&1

    # Restart nếu đang chạy, start nếu chưa
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
```

`_create_vnc_service()`:
```bash
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
```

---

### 6. `deploy_phase1_crd()` — Chrome Remote Desktop

Dùng lại logic CRD từ `setup_vps.sh` (bước 8: patch adduser.conf, cài .deb với fallback repo, cấu hình XFCE session). Code hoàn toàn tương tự, chỉ đóng gói thành function.

---

### 7. Refactor Phase 2-5 từ `do_full_install()`

Tách `do_full_install()` thành các sub-functions để `do_deploy()` tái sử dụng:

```bash
deploy_phase2_proxy()    # install_packages + save configs + create redsocks + iptables + start service
deploy_phase3_ip_verify() # get_real_ip + verify_proxy_ip
deploy_phase4_aro()      # install_aro_app
deploy_phase5_watchdog() # create_watchdog_service + enable + start
```

`do_full_install()` vẫn giữ nguyên, gọi các sub-functions này theo thứ tự.

---

### 8. `deploy_phase6_finish()` — Verification + Telegram report

```bash
deploy_phase6_finish() {
    log_info "=== PHASE 6: VERIFICATION ==="

    apt-get autoremove -y -qq 2>/dev/null || true

    # Lấy IP máy (chạy dưới root, không qua proxy)
    local machine_ip; machine_ip=$(get_real_ip)

    # Summary console
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              ✓ DEPLOY HOÀN TẤT                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Services:"
    systemctl is-active vncserver   2>/dev/null && echo "  ✓ VNC:      Running (port $VNC_PORT)" || true
    systemctl is-active redsocks-aro 2>/dev/null && echo "  ✓ Redsocks: Running" || true
    systemctl is-active aro-watchdog 2>/dev/null && echo "  ✓ Watchdog: Running" || true
    echo ""
    echo "  Remote: $machine_ip:$VNC_PORT (VNC)"
    echo ""

    # Gửi Telegram report
    if [[ -n "$TG_BOT_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
        _send_deploy_report "$machine_ip"
    fi
}
```

`_send_deploy_report()`:
```bash
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
📡 Kết nối VNC:
   <code>${machine_ip}:${VNC_PORT}</code>
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
    log_success "Deploy report đã gửi về Telegram"
}
```

---

### 9. Cập nhật `show_usage()` — thêm lệnh deploy

```
MAIN COMMANDS:
  deploy <proxy> --ssh-key KEY [--vnc-pass PASS] [--token TOKEN] [--chatid ID]
                      Triển khai hoàn chỉnh: VPS + VNC + Proxy + ARO + Watchdog

  deploy <proxy> --crd --ssh-key KEY [--token TOKEN] [--chatid ID]
                      Như trên nhưng dùng Chrome Remote Desktop thay VNC

  full-install <proxy> [--token TOKEN] [--chatid ID]
                      Cài proxy + ARO + watchdog (VPS đã có sẵn XFCE/VNC)
  ...
```

---

### 10. Checklist trước khi push

```bash
# 1. Syntax check
bash -n aro-manager.sh && echo "SYNTAX OK"

# 2. Version check — phải thấy 3.0.0 đủ 3 chỗ
grep "3\.0\.0" aro-manager.sh | head -5

# 3. Confirm deploy command tồn tại
grep -n "deploy)" aro-manager.sh
```

Nếu tất cả pass → push lên `https://github.com/nauthnael/aro-manager`.

---

*Brief soạn bởi: Manager (Claude) — ARO Manager v3.0.0, ngày 2026-04-29*

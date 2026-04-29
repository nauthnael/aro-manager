#!/bin/bash
# =============================================================================
# setup-tigervnc-aro.sh
# Cài TigerVNC + autostart XFCE + ARO trên LXC Ubuntu 24 (không cần kết nối)
# Chạy với: sudo bash setup-tigervnc-aro.sh
# =============================================================================

set -e

# --- Cấu hình ---
VNC_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "ubuntu")}"
VNC_DISPLAY=":1"
VNC_PORT="5901"
VNC_RESOLUTION="1280x800"
VNC_DEPTH="24"
ARO_EXEC="/opt/ARO/aro"          # <-- Sửa đường dẫn ARO tại đây
ARO_FLAGS="--no-sandbox --disable-gpu --disable-dev-shm-usage"

# --- Màu sắc output ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =============================================================================
# Kiểm tra
# =============================================================================
[ "$EUID" -ne 0 ] && error "Vui lòng chạy với sudo: sudo bash $0"
id "$VNC_USER" &>/dev/null || error "User '$VNC_USER' không tồn tại"

VNC_HOME=$(getent passwd "$VNC_USER" | cut -d: -f6)
info "Sẽ cài đặt cho user: $VNC_USER (home: $VNC_HOME)"

# =============================================================================
# 1. Cài TigerVNC
# =============================================================================
info "Cài TigerVNC..."
apt-get update -qq
apt-get install -y tigervnc-standalone-server tigervnc-common dbus-x11

# =============================================================================
# 2. Đặt mật khẩu VNC (nếu chưa có)
# =============================================================================
VNC_DIR="$VNC_HOME/.vnc"
mkdir -p "$VNC_DIR"

if [ ! -f "$VNC_DIR/passwd" ]; then
    warn "Chưa có mật khẩu VNC. Đặt mật khẩu mặc định 'aroaro' (đổi sau bằng: vncpasswd)"
    echo "aroaro" | su -c "vncpasswd -f > '$VNC_DIR/passwd'" "$VNC_USER"
    chmod 600 "$VNC_DIR/passwd"
else
    info "Mật khẩu VNC đã tồn tại, giữ nguyên."
fi

# =============================================================================
# 3. Tạo xstartup — XFCE + ARO tự động khởi động
# =============================================================================
info "Tạo ~/.vnc/xstartup..."
cat > "$VNC_DIR/xstartup" << XSTARTUP
#!/bin/bash
# Khởi động môi trường D-Bus
export DBUS_SESSION_BUS_ADDRESS=\$(dbus-launch --sh-syntax | grep DBUS_SESSION_BUS_ADDRESS | cut -d= -f2-)

# Biến môi trường cơ bản
export XDG_SESSION_TYPE=x11
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
mkdir -p "\$XDG_RUNTIME_DIR"
chmod 700 "\$XDG_RUNTIME_DIR"

# Khởi động XFCE
startxfce4 &
XFCE_PID=\$!

# Chờ XFCE khởi động xong (~5 giây)
sleep 5

# Khởi động ARO
if [ -x "$ARO_EXEC" ]; then
    "$ARO_EXEC" $ARO_FLAGS &
else
    notify-send "ARO" "Không tìm thấy ARO tại: $ARO_EXEC" 2>/dev/null || true
fi

# Giữ session sống
wait \$XFCE_PID
XSTARTUP

chmod +x "$VNC_DIR/xstartup"
chown -R "$VNC_USER:$VNC_USER" "$VNC_DIR"

# =============================================================================
# 4. Tạo systemd service để VNC tự khởi động khi boot
# =============================================================================
info "Tạo systemd service: vncserver-aro.service..."
cat > /etc/systemd/system/vncserver-aro.service << SERVICE
[Unit]
Description=TigerVNC Display Server for ARO
After=network.target syslog.target

[Service]
Type=forking
User=$VNC_USER
Group=$(id -gn "$VNC_USER")

# Dọn lock file cũ nếu có
ExecStartPre=-/usr/bin/vncserver -kill $VNC_DISPLAY
ExecStartPre=-/bin/rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

# Khởi động VNC với XFCE + ARO
ExecStart=/usr/bin/vncserver $VNC_DISPLAY \
    -geometry $VNC_RESOLUTION \
    -depth $VNC_DEPTH \
    -localhost no \
    -rfbport $VNC_PORT \
    -rfbauth $VNC_DIR/passwd

ExecStop=/usr/bin/vncserver -kill $VNC_DISPLAY

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

# =============================================================================
# 5. Enable và start service
# =============================================================================
info "Bật và khởi động service..."
systemctl daemon-reload
systemctl enable vncserver-aro.service
systemctl restart vncserver-aro.service

# Đợi service khởi động
sleep 3

# =============================================================================
# 6. Kiểm tra kết quả
# =============================================================================
info "Kiểm tra trạng thái..."
if systemctl is-active --quiet vncserver-aro.service; then
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Cài đặt thành công!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "  Display    : DISPLAY=$VNC_DISPLAY"
    echo "  VNC Port   : $VNC_PORT"
    echo "  Password   : (trong $VNC_DIR/passwd)"
    echo "  ARO path   : $ARO_EXEC"
    echo ""
    echo "  Kết nối VNC (nếu cần xem): <IP-container>:$VNC_PORT"
    echo "  Đổi mật khẩu VNC         : su -c 'vncpasswd' $VNC_USER"
    echo "  Xem log                  : journalctl -u vncserver-aro -f"
    echo ""
    warn "Nếu ARO chưa chạy, kiểm tra đường dẫn ARO_EXEC trong script: $ARO_EXEC"
else
    error "Service không khởi động được. Kiểm tra: journalctl -u vncserver-aro -xe"
fi

#!/bin/bash
# =============================================================================
# setup-tigervnc.sh
# Cài TigerVNC + autostart XFCE trên LXC Ubuntu 24
# Chạy với: sudo bash setup-tigervnc.sh
# =============================================================================

set -e

# --- Cấu hình ---
VNC_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "ubuntu")}"
VNC_DISPLAY=":1"
VNC_PORT="5901"
VNC_RESOLUTION="1280x800"
VNC_DEPTH="24"

# --- Màu sắc output ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =============================================================================
# Kiểm tra
# =============================================================================
[ "$EUID" -ne 0 ] && error "Vui lòng chạy với sudo: sudo bash $0"
id "$VNC_USER" &>/dev/null || error "User '$VNC_USER' không tồn tại"

VNC_HOME=$(getent passwd "$VNC_USER" | cut -d: -f6)
info "Cài đặt cho user: $VNC_USER (home: $VNC_HOME)"

# =============================================================================
# 1. Cài TigerVNC
# =============================================================================
info "Cài TigerVNC..."
apt-get update -qq
apt-get install -y tigervnc-standalone-server tigervnc-common dbus-x11

# =============================================================================
# 2. Đặt mật khẩu VNC
# =============================================================================
VNC_DIR="$VNC_HOME/.vnc"
VNC_GID=$(id -gn "$VNC_USER")

# Tạo thư mục với đúng ownership ngay từ đầu
install -d -o "$VNC_USER" -g "$VNC_GID" -m 700 "$VNC_DIR"

if [ ! -f "$VNC_DIR/passwd" ]; then
    warn "Chưa có mật khẩu VNC. Đặt mật khẩu mặc định 'changeme'"
    warn "Đổi sau bằng lệnh: vncpasswd  (chạy với user $VNC_USER)"
    # Tạo file passwd với root rồi fix ownership
    echo "changeme" | vncpasswd -f > "$VNC_DIR/passwd"
    chmod 600 "$VNC_DIR/passwd"
    chown "$VNC_USER:$VNC_GID" "$VNC_DIR/passwd"
else
    info "Mật khẩu VNC đã tồn tại, giữ nguyên."
fi

# =============================================================================
# 3. Tạo xstartup — khởi động XFCE
# =============================================================================
info "Tạo ~/.vnc/xstartup..."
cat > "$VNC_DIR/xstartup" << 'XSTARTUP'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

export XDG_SESSION_TYPE=x11
export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

exec startxfce4
XSTARTUP

chmod +x "$VNC_DIR/xstartup"
chown -R "$VNC_USER:$VNC_USER" "$VNC_DIR"

# =============================================================================
# 4. Tạo systemd service
# =============================================================================
info "Tạo systemd service: vncserver.service..."
cat > /etc/systemd/system/vncserver.service << SERVICE
[Unit]
Description=TigerVNC Display Server
After=network.target syslog.target

[Service]
Type=forking
User=$VNC_USER
Group=$(id -gn "$VNC_USER")

ExecStartPre=-/usr/bin/vncserver -kill $VNC_DISPLAY
ExecStartPre=-/bin/rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

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
# 5. Enable và start
# =============================================================================
info "Bật và khởi động service..."
systemctl daemon-reload
systemctl enable vncserver.service
systemctl restart vncserver.service
sleep 3

# =============================================================================
# 6. Kết quả
# =============================================================================
if systemctl is-active --quiet vncserver.service; then
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN} Cài đặt thành công!${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo "  Display  : DISPLAY=$VNC_DISPLAY (port $VNC_PORT)"
    echo "  Kết nối  : <IP-container>:$VNC_PORT"
    echo "  Password : changeme  →  đổi bằng: su -c 'vncpasswd' $VNC_USER"
    echo "  Log      : journalctl -u vncserver -f"
    echo ""
else
    error "Service không khởi động. Kiểm tra: journalctl -u vncserver -xe"
fi

# Brief for Antigravity — Fix VNC IP trong Telegram report (v3.0.0 → v3.1.0)

## Vấn đề
Khi deploy trên LXC, Telegram report đang gửi **IP public** để remote VNC.
Nhưng LXC nằm sau firewall nội bộ → IP public không thể dùng để kết nối VNC.
Cần gửi **IP nội bộ của card mạng** (ví dụ: `192.168.1.39`) thay thế.

---

## Thay đổi cần thực hiện

### 1. Bump version: `3.0.0` → `3.1.0` (đủ 3 chỗ)

---

### 2. Thêm hàm `get_local_ip()` (đặt gần `get_real_ip()`)

```bash
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
```

---

### 3. Sửa `deploy_phase6_finish()` — chọn IP theo môi trường

Tìm đoạn lấy IP hiện tại:
```bash
local machine_ip; machine_ip=$(get_real_ip)
```

Thay bằng:
```bash
local machine_ip=""
if [[ "$ENV_TYPE" == "lxc_vnc" ]]; then
    machine_ip=$(get_local_ip)
    log_info "LXC environment — dùng IP nội bộ: $machine_ip"
else
    machine_ip=$(get_real_ip)
    log_info "IP public: $machine_ip"
fi
```

---

### 4. Không thay đổi gì khác

Phần còn lại của `_send_deploy_report()` và toàn bộ script giữ nguyên.

---

## Checklist trước khi push

```bash
bash -n aro-manager.sh && echo "SYNTAX OK"
grep "3\.1\.0" aro-manager.sh | head -5
```

Nếu pass → push lên `https://github.com/nauthnael/aro-manager`

---

*Brief soạn bởi: Manager (Claude) — ARO Manager v3.1.0, ngày 2026-04-29*

# Brief for Antigravity — Fix VNC Launch (v2.3.0 → v2.4.0)

## Bối cảnh
Script `aro-manager.sh` hiện tại (v2.3.0) đã hỗ trợ môi trường LXC + TigerVNC, nhưng ARO app không khởi động được do 3 bug trong quá trình detect environment và launch. Nhiệm vụ của AG là fix đúng 3 bug đó, không thay đổi gì ngoài phạm vi được mô tả.

---

## File cần chỉnh sửa

**`aro-manager.sh`** — duy nhất 1 file.

---

## Quy tắc bắt buộc trước khi code

1. **Bump version**: Sửa `SCRIPT_VERSION`, header comment (dòng 3), và banner `show_banner()` từ `2.3.0` → `2.4.0`.
2. **Không phá vỡ `set -euo pipefail`**: Mọi lệnh có thể trả về non-zero phải được bọc `|| true` hoặc `{ cmd || true; }`.
3. **Không thay đổi** logic proxy, iptables, watchdog loop, Telegram, hay bất kỳ function nào ngoài 3 fix được liệt kê dưới đây.

---

## Fix A — Sửa regex detect display number trong `detect_vnc_user()`

### Vấn đề
Hiện tại code dùng:
```bash
ps aux | grep -E '[X](tigervnc|vnc)' | grep -oP ':\d+' | head -n1
```
`ps aux` có cột `TIME` dạng `0:00` → regex `:\d+` bắt `:00` từ cột TIME **trước** khi bắt tới `:1` từ cột COMMAND. Kết quả: `DISPLAY_NUM=":00"` thay vì `:1`.

### Fix
Thay toàn bộ đoạn detect display number và XAUTHORITY trong `detect_vnc_user()` bằng logic mới ở **Fix B** bên dưới (Fix A và Fix B được gộp chung vì cùng sửa trong `detect_vnc_user()`).

---

## Fix B — Sửa XAUTHORITY path trong `detect_vnc_user()`

### Vấn đề
Script hardcode path:
```bash
XAUTHORITY_PATH="$EFFECTIVE_HOME/.vnc/$(hostname):${display_num_only}.xauth"
```
Nhưng trên thực tế TigerVNC được start với flag `-auth /home/ubuntu/.Xauthority`, file `~/.vnc/hostname:N.xauth` không tồn tại → X server từ chối authorization → ARO crash ngay khi mở.

Debug log confirm:
```
Authorization required, but no authorization protocol specified
cannot open display: :1
```

### Fix
Đọc thẳng `-auth <path>` từ command line của process Xtigervnc thay vì giả định path. Fallback về `~/.Xauthority` nếu không tìm thấy.

### Code thay thế — phần detect display + XAUTHORITY trong `detect_vnc_user()`

Tìm đoạn code cũ này trong `detect_vnc_user()`:
```bash
    # Auto-detect display number from the VNC process command line
    local vnc_display=""
    vnc_display=$({ ps aux | grep -E '[X](tigervnc|vnc)' 2>/dev/null || true; } \
        | grep -oP ':\d+' | head -n1 || true)
    DISPLAY_NUM="${vnc_display:-:1}"
    ...
    # TigerVNC XAUTHORITY: ~/.vnc/<hostname>:<display_num>.xauth
    local display_num_only="${DISPLAY_NUM#:}"
    XAUTHORITY_PATH="$EFFECTIVE_HOME/.vnc/$(hostname):${display_num_only}.xauth"
```

Thay bằng:
```bash
    # Lấy full command line của VNC process (ps -eo args = chỉ cột COMMAND, không có TIME)
    local vnc_cmd=""
    vnc_cmd=$(ps -eo args 2>/dev/null \
        | { grep -E '^/usr/(bin/)?X(tigervnc|vnc|org)' 2>/dev/null || true; } \
        | head -n1 || true)

    # Extract display number: token dạng ":N" đứng sau tên binary (có khoảng trắng bao quanh)
    local vnc_display=""
    vnc_display=$(echo "$vnc_cmd" | grep -oP '(?<=\s):\d+(?=\s|$)' | head -n1 || true)
    DISPLAY_NUM="${vnc_display:-:1}"

    # Extract XAUTHORITY từ flag -auth của process Xtigervnc
    XAUTHORITY_PATH=$(echo "$vnc_cmd" | grep -oP '(?<=-auth )\S+' | head -n1 || true)
    # Fallback: ~/.Xauthority (TigerVNC default, cũng là path phổ biến nhất)
    [[ -z "$XAUTHORITY_PATH" ]] || [[ ! -f "$XAUTHORITY_PATH" ]] && \
        XAUTHORITY_PATH="$EFFECTIVE_HOME/.Xauthority"
```

---

## Fix C — Sửa wrapper log path trong `create_wrapper_script()`

### Vấn đề
Wrapper `/usr/local/bin/aro-launch` được chạy dưới user `ubuntu` nhưng log tới `/var/log/aro-proxy-wrapper.log` (thuộc root) → permission denied → wrapper vẫn chạy được nhưng không ghi log.

Debug log:
```
tee: /var/log/aro-proxy-wrapper.log: Permission denied
```

### Fix
Trong function `create_wrapper_script()`, tìm dòng:
```bash
LOG="/var/log/aro-proxy-wrapper.log"
```
Thay bằng:
```bash
LOG="/tmp/aro-wrapper.log"
```

---

## Kiểm tra sau khi code xong

AG tự kiểm tra bằng cách chạy lệnh sau và xác nhận không có lỗi syntax:
```bash
bash -n aro-manager.sh && echo "SYNTAX OK"
```

Sau đó grep để xác nhận version đã được bump đủ 3 chỗ:
```bash
grep -E "2\.[34]\.0" aro-manager.sh
```
Phải thấy đúng `2.4.0` xuất hiện ở: header comment, `SCRIPT_VERSION`, và trong `show_banner()`.

---

## Tóm tắt thay đổi

| Fix | Function | Thay đổi |
|-----|----------|----------|
| A+B | `detect_vnc_user()` | Dùng `ps -eo args` thay `ps aux`; extract `-auth` path từ process; fallback `~/.Xauthority` |
| C | `create_wrapper_script()` | Đổi LOG path từ `/var/log/aro-proxy-wrapper.log` → `/tmp/aro-wrapper.log` |
| - | `SCRIPT_VERSION` + header + banner | Bump `2.3.0` → `2.4.0` |

---

*Brief soạn bởi: Manager (Claude) — dự án ARO Manager, ngày 2026-04-29*

# BRIEF FOR ANTIGRAVITY — Update Telegram Notifications (v3.4.9 → v3.5.0)

## Mục tiêu
4 thay đổi cho tất cả Telegram notification templates:
1. **Thêm version vào header** mỗi message
2. **Thêm dòng VNC IP:5901** vào các notify có proxy info
3. **Xóa số thứ tự dòng** (22:, 23:, 24:...) trong `send_daily_report()`
4. **Fix "Online since" sai** — tính từ lần connect hiện tại, không phải từ log cũ

---

## Thay đổi 1 — Thêm version vào header tất cả messages

### Cách làm
Thay pattern `${HOSTNAME}</b>` thành `${HOSTNAME} | v${SCRIPT_VERSION}</b>` trong **tất cả** các message headers. Áp dụng cho toàn bộ các function sau:

- `send_notify_restart_success()` line ~1184
- `send_notify_max_retries()` line ~1207
- `send_notify_pre_restart()` line ~1237
- `send_notify_proxy_down()` line ~1266
- `send_notify_proxy_recovered()` line ~1284
- `send_notify_redsocks_restarted()` line ~1296
- `send_notify_aro_reconnected()` line ~1327
- `send_notify_aro_stuck_manual()` line ~1356
- `send_notify_proxy_dead()` line ~1373
- `send_daily_report()` line ~1409
- `send_notify_setup_success()` line ~1438
- `_send_deploy_report()` line ~2345

**Ví dụ:**
```bash
# Trước:
local msg="✅ <b>[ARO RESTARTED] ${HOSTNAME}</b>

# Sau:
local msg="✅ <b>[ARO RESTARTED] ${HOSTNAME} | v${SCRIPT_VERSION}</b>
```

---

## Thay đổi 2 — Thêm VNC IP vào notifications

### Helper function — thêm gần `get_local_ip()` (line ~2038)

```bash
get_vnc_access_ip() {
    # LXC/VM → dùng IP LAN của interface chính (chính xác hơn hostname -I)
    # VPS/bare metal → dùng public IP
    if [[ "$ENV_TYPE" == "lxc_vnc" ]] || [[ "$ENV_TYPE" == "lxc_crd" ]]; then
        # Lấy src IP của default route — đây là IP card mạng chính
        local ip=""
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
            | grep -oP '(?<=src )\S+' | head -1 || true)
        if [[ -z "$ip" ]]; then
            ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        fi
        echo "${ip:-N/A}"
    else
        # VPS: dùng public IP (chạy as root, bypass iptables)
        get_real_ip
    fi
}
```

### Áp dụng vào các notify function

Chỉ thêm dòng VNC vào các function **có dòng `🔌 Proxy:`** — tức là các notify liên quan đến trạng thái ARO/proxy mà user cần connect vào để fix. Không thêm vào `send_notify_proxy_dead()` hay `send_notify_redsocks_restarted()` (các notify này không cần VNC info vì chỉ là status update).

**Các function cần thêm:**
- `send_notify_restart_success()`
- `send_notify_pre_restart()`
- `send_notify_aro_reconnected()`
- `send_notify_aro_stuck_manual()`
- `send_notify_max_retries()`
- `send_notify_proxy_down()`
- `send_notify_proxy_dead()`
- `send_daily_report()`
- `send_notify_setup_success()`
- `_send_deploy_report()`

**Cách thêm — ngay sau dòng `🔌 Proxy:`:**
```bash
# Trước:
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}

# Sau:
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
🖥️ VNC:   $(get_vnc_access_ip):${VNC_PORT}
```

**Lưu ý:** `get_vnc_access_ip` gọi `ip route` hoặc `get_real_ip` — không tốn kém, nhưng nếu gọi nhiều lần trong cùng 1 function thì cache vào local variable:
```bash
local vnc_ip; vnc_ip=$(get_vnc_access_ip)
# Rồi dùng ${vnc_ip} thay vì $(get_vnc_access_ip) trong message body
```

---

## Thay đổi 3 — Xóa số thứ tự dòng trong `send_daily_report()`

Đây là bug AG tự thêm vào. Xóa toàn bộ prefix `22: `, `23: `, ..., `34: ` trong message template của `send_daily_report()`.

**Trước (lines ~1409–1423):**
```bash
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
```

**Sau:**
```bash
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
```

---

## Thay đổi 4 — Fix "Online since" tính sai

### Root cause
`get_last_online_info()` dùng awk string comparison để filter:
```bash
| awk -v cutoff="$net_init_ts" '$0 > cutoff'
```
String comparison theo ISO timestamp thường đúng, nhưng không reliable khi log format có ký tự đặc biệt hoặc khi `net_init_ts` không match chính xác. Quan trọng hơn: **log file không bị xóa khi restart ARO** — nó accumulate. Nếu `Net init` entry của session hiện tại không có trong 1000 dòng cuối của log dài, `net_init_ts` sẽ empty, và fallback về `tray=Online` cũ → "Online since 1d 13h".

### Fix

Thay logic trong `get_last_online_info()`, nhánh `tray_state == "Online"` (lines ~994–1013):

```bash
if [[ "$tray_state" == "Online" ]]; then
    local online_ts=""

    if [[ -n "$net_init_ts" ]]; then
        # Convert net_init_ts sang epoch để so sánh chính xác
        local net_init_ep; net_init_ep=$(date -d "$net_init_ts" +%s 2>/dev/null || echo 0)

        if [[ "$net_init_ep" -gt 0 ]]; then
            # Tìm dòng tray=Online ĐẦU TIÊN có timestamp > net_init_ep
            # Parse từng dòng, convert sang epoch, so sánh số
            online_ts=$(run_as_aro_user grep "linux tray icon synced to state=Online" "$LATEST_LOG_FILE" 2>/dev/null \
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
            online_ts=$(run_as_aro_user grep "linux tray icon synced to state=Online" "$LATEST_LOG_FILE" 2>/dev/null \
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
fi
```

### Tại sao fix này đúng
- Dùng **epoch comparison** (`$ep -gt $net_init_ep`) thay vì string comparison — chính xác 100%
- Fallback về `last_restart` từ state file nếu `Net init` không có trong log — đây là thời điểm watchdog launch ARO, tương đương "session bắt đầu từ lúc này"
- Không còn báo "Online since 1d 13h" sau khi restart vì `last_restart` luôn được update khi watchdog launch ARO

---

## Tóm tắt các file/lines cần sửa

| Thay đổi | Functions/lines |
|----------|----------------|
| Version trong header | Tất cả 12 notify functions — replace `${HOSTNAME}</b>` → `${HOSTNAME} \| v${SCRIPT_VERSION}</b>` |
| Thêm `get_vnc_access_ip()` | Thêm mới gần line 2038 |
| Thêm VNC IP vào message body | 10 notify functions — sau dòng `🔌 Proxy:` |
| Xóa số thứ tự | `send_daily_report()` line ~1409–1423 |
| Fix Online since | `get_last_online_info()` lines ~994–1013 |

## Version sau khi implement: `v3.5.0`

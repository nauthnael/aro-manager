# BRIEF FOR ANTIGRAVITY — Fix High Priority Issues + New Feature (v3.4.2 → v3.4.3)

## Mục tiêu
Fix 4 lỗi high priority và thêm 1 tính năng mới: **thông báo Telegram lý do ARO bị lỗi TRƯỚC KHI restart**, để user hiểu được tình trạng thay vì chỉ nhận được "restarted successfully".

---

## Bug 1 — Proxy hostname không resolve được khi dùng trong iptables (lines 593–617)

### Vấn đề
`setup_iptables_rules()` resolve `PROXY_HOST` bằng `getent hosts`. Nếu fail, fallback dùng hostname trực tiếp làm IP:

```bash
# line 595-597:
if [[ -z "$proxy_ip" ]]; then
    log_warn "Cannot resolve proxy hostname, using hostname directly"
    proxy_ip="$PROXY_HOST"   # ← hostname string, không phải IP
fi

# line 616-618: chỉ add bypass rule nếu IP format hợp lệ
if [[ "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    iptables -t nat -A ARO_PROXY -d "$proxy_ip" -j RETURN
fi
# ← Nếu proxy_ip là hostname: không add bypass → traffic đến proxy server bị redirect qua chính nó → vòng lặp
```

### Fix yêu cầu
Nếu `getent hosts` fail, thử resolve bằng `dig` hoặc `host` làm fallback. Nếu vẫn không ra IP, **dừng setup và báo lỗi rõ** thay vì tiếp tục với hostname:

```bash
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
```

---

## Bug 2 — Retry counter hiển thị "retry 6/5" (lines 1681–1685, 1731–1736)

### Vấn đề
Counter được increment TRƯỚC khi check giới hạn, ở cả 2 nơi:

```bash
# line 1681-1685 (log stale branch):
retry_count=$((retry_count + 1))      # ← tăng trước
state_set "retry_count" "$retry_count"
if [[ $retry_count -le $MAX_RETRIES ]]; then  # ← check sau
    # ... restart

# line 1731-1736 (not running branch):
retry_count=$((retry_count + 1))      # ← tương tự
state_set "retry_count" "$retry_count"
if [[ $retry_count -le $MAX_RETRIES ]]; then
```

Khi `retry_count` đang là 5 (`MAX_RETRIES=5`), tăng lên 6 → log "retry 6/5" → check `6 -le 5` = false → "MAX RETRIES REACHED". Counter lưu về 0 nhưng message đã sai.

### Fix yêu cầu
Check TRƯỚC khi tăng:

```bash
# Cả 2 nơi, sửa thành:
if [[ $retry_count -lt $MAX_RETRIES ]]; then
    retry_count=$((retry_count + 1))
    state_set "retry_count" "$retry_count"
    # ... restart, log "retry $retry_count/$MAX_RETRIES"
else
    # MAX_RETRIES đã đạt, không tăng thêm
    watchdog_log "MAX RETRIES REACHED ($MAX_RETRIES) - giving up"
    send_notify_max_retries
    state_set "retry_count" "0"
fi
```

---

## Bug 3 — `format_uptime()` có thể trả về empty string (line 781)

### Vấn đề
```bash
format_uptime() {
    local ratio="$1"
    if [[ -z "$ratio" ]] || [[ "$ratio" == "N/A" ]]; then echo "N/A"; return 0; fi
    echo "$ratio" | awk '{printf "%.1f", $1 * 100}' || echo "N/A"
}
```

`echo ... | awk ... || echo "N/A"` — toán tử `||` trong bash với pipeline: exit code của toàn bộ pipe là exit code của lệnh cuối cùng (awk). Nếu awk thành công nhưng output sai (ví dụ `ratio=""` lọt qua), awk vẫn return 0 → `echo "N/A"` không chạy. Nhưng quan trọng hơn: nếu awk fail (invalid input), stderr bị mất → output trống.

### Fix yêu cầu
```bash
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
```

---

## Bug 4 — Telegram notification fail silent hoàn toàn (line 347–350)

### Vấn đề
```bash
# send_telegram() kết thúc với:
> /dev/null 2>&1 || true
```

Rate limit, network down, invalid token đều bị nuốt im lặng. User không biết notification có được gửi hay không.

### Fix yêu cầu
Log lỗi nếu curl fail, nhưng KHÔNG block watchdog:

```bash
send_telegram() {
    local message="$1"
    # ... (escape logic giữ nguyên)
    
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
```

---

## Tính năng mới — Thông báo lý do lỗi TRƯỚC KHI restart

### Yêu cầu từ user
Hiện tại user chỉ nhận được thông báo sau khi restart thành công. User muốn biết **tại sao ARO bị restart** — tray state lúc đó là gì, lỗi gì detected, để có thể diagnose vấn đề.

### Thiết kế

#### 1. Thêm function `send_notify_pre_restart()`

```bash
send_notify_pre_restart() {
    local reason="$1"          # Mô tả lý do kỹ thuật
    local tray_state="$2"      # tray state lúc phát hiện
    local stuck_mins="${3:-0}" # Số phút đã stuck (nếu có)
    local retry_count="${4:-?}"

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
```

#### 2. Gọi `send_notify_pre_restart()` trước mỗi lần restart

**Trong `handle_stuck_connecting()` — Bước 1 (redsocks broken, line ~1439–1441):**
```bash
watchdog_log "Transparent proxy BROKEN — redsocks issue"
send_notify_pre_restart "Transparent proxy broken (redsocks hung/iptables error)" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)"
kill_aro
```

**Trong `handle_stuck_connecting()` — Bước 2 (proxy server down, line ~1479–1481):**
```bash
watchdog_log "Upstream proxy server DOWN — killing ARO to protect IP"
send_notify_pre_restart "Upstream SOCKS5 proxy server unreachable" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)"
kill_aro
```

**Trong `handle_stuck_connecting()` — Bước 3 (network OK nhưng ARO stuck, line ~1487–1490):**
```bash
watchdog_log "Network path OK but ARO still stuck — restarting ARO app"
send_notify_pre_restart "Network OK but ARO app stuck internally" "$tray_state" "$stuck_mins" "$(state_get retry_count 0)"
kill_aro
```

**Trong `watchdog_loop()` — log stale branch (line ~1676–1705):**
Thêm trước `kill_aro` ở line 1703:
```bash
local disc_mins; disc_mins=$(get_disconnect_duration)
send_notify_pre_restart "Log stale >$LOG_STALE_MINUTES min, disconnected ${disc_mins}min" "$(get_aro_tray_state)" "$disc_mins" "$retry_count"
kill_aro
```

**Trong `watchdog_loop()` — ARO not running branch (line ~1729–1737):**
```bash
watchdog_log "ARO not running, starting..."
send_notify_pre_restart "ARO process not found (crashed or killed)" "not_running" "0" "$retry_count"
launch_aro
```

#### 3. Lưu ý
- `send_notify_pre_restart()` KHÔNG cần parse node info (serial, reward) vì ARO có thể đang dead — chỉ cần thông tin proxy và lý do
- Không throttle function này (mỗi restart chỉ gửi 1 lần)
- Cần truyền `tray_state` từ context calling — đảm bảo đọc trước khi kill ARO

---

## Kết quả sau khi fix
- Proxy setup fail rõ ràng thay vì silently broken
- Retry counter luôn đúng, không bao giờ hiện "6/5"
- `format_uptime` luôn trả về giá trị hợp lệ
- Telegram log warning khi fail thay vì im lặng
- User nhận được notification lý do ARO bị restart TRƯỚC khi watchdog thực hiện restart

## Version sau khi fix: `v3.4.3`

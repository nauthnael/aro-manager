# BRIEF FOR ANTIGRAVITY — Fix Low Priority / Code Quality Issues (v3.4.4 → v3.4.5)

## Mục tiêu
Cleanup code quality: fix 4 vấn đề nhỏ liên quan đến tính đúng đắn và maintainability. Không thay đổi behavior chính, chỉ làm code rõ hơn và ít fragile hơn.

---

## Fix 1 — Magic numbers thiếu comment giải thích (lines 55–76)

### Vấn đề
Các constant không có giải thích tại sao chọn giá trị đó:

```bash
CHECK_INTERVAL=30             # tại sao 30s?
LOG_STALE_MINUTES=10          # tại sao 10 phút?
REDSOCKS_QUEUE_THRESHOLD=500  # tại sao 500?
STUCK_THRESHOLD_MINUTES=5     # tại sao 5 phút?
CONNECTING_GRACE_SECS=180     # tại sao 3 phút?
```

### Fix yêu cầu
Thêm comment giải thích rationale cho từng constant:

```bash
# ── Watchdog timing ──────────────────────────────────────────────
CHECK_INTERVAL=30           # Chu kỳ watchdog: 30s đủ responsive mà không waste CPU
LOG_STALE_MINUTES=10        # Log không update >10m = ARO frozen hoặc crash
DISCONNECT_ALERT_MINUTES=15 # Disconnected >15m mới trigger restart (tránh false positive)
RESET_STABLE_HOURS=2        # Sau 2h stable liên tục, reset retry counter về 0
MAX_RETRIES=5               # 5 lần retry với backoff trước khi give up
BACKOFF_TIMES="0 0 30 60 120"  # retry 1&2: ngay lập tức; 3: 30s; 4: 60s; 5: 120s

# ── Proxy / connection thresholds ────────────────────────────────
STUCK_THRESHOLD_MINUTES=5   # tray=NoInternet >5m = stuck thực sự (không phải fluctuation)
CONNECTING_GRACE_SECS=180   # Sau launch, cho ARO 3 phút để connect trước khi coi là stuck
REDSOCKS_QUEUE_THRESHOLD=500 # recv-Q >500 bytes = redsocks backpressure, coi là hung
                             # (empirically: healthy redsocks thường <100)
PROXY_RESTART_TIMEOUT_SECS=60  # Chờ tối đa 60s cho redsocks restart functional
```

---

## Fix 2 — Duplicate grace period check (lines 1428–1432 và 1645–1646)

### Vấn đề
Logic kiểm tra grace period được lặp lại ở 2 chỗ:

```bash
# Chỗ 1: handle_stuck_connecting() line 1428
if [[ "$last_restart" -gt 0 ]] && [[ "$since_launch" -lt "$CONNECTING_GRACE_SECS" ]]; then
    return 0
fi

# Chỗ 2: watchdog_loop() case Offline, line 1645
if [[ "$last_restart" -gt 0 ]] && [[ "$since_launch" -lt "$CONNECTING_GRACE_SECS" ]]; then
    watchdog_log "ARO tray=Offline, in startup grace period (${since_launch}s)"
    # không call handle_stuck_connecting
fi
```

Nếu logic grace period thay đổi, phải sửa 2 chỗ.

### Fix yêu cầu
Extract thành function `is_in_grace_period()`:

```bash
# Trả về 0 (true) nếu đang trong grace period sau launch
is_in_grace_period() {
    local last_restart; last_restart=$(state_get "last_restart" "0")
    local now; now=$(date +%s)
    local since_launch=$(( now - last_restart ))
    
    [[ "$last_restart" -gt 0 ]] && [[ "$since_launch" -lt "$CONNECTING_GRACE_SECS" ]]
}

# Optional: trả về số giây còn lại trong grace period
grace_period_remaining() {
    local last_restart; last_restart=$(state_get "last_restart" "0")
    local now; now=$(date +%s)
    local since_launch=$(( now - last_restart ))
    local remaining=$(( CONNECTING_GRACE_SECS - since_launch ))
    echo $(( remaining > 0 ? remaining : 0 ))
}
```

Thay 2 chỗ duplicate bằng:
```bash
# handle_stuck_connecting():
if is_in_grace_period; then
    local remaining; remaining=$(grace_period_remaining)
    watchdog_log "ARO disconnected ${stuck_mins}m but within grace period (${remaining}s remaining)"
    return 0
fi

# watchdog_loop() case Offline:
if is_in_grace_period; then
    local remaining; remaining=$(grace_period_remaining)
    watchdog_log "ARO tray=Offline, in startup grace period (${remaining}s remaining)"
else
    watchdog_log "ARO tray=Offline beyond grace period — treating as stuck"
    handle_stuck_connecting "$stuck_mins"
fi
```

---

## Fix 3 — Daily report hour parsing fragile (line 1758)

### Vấn đề
```bash
current_hour=$(date +%H | sed 's/^0//')
```

`date +%H` luôn cho 2 digits (00–23). `sed 's/^0//'` remove leading zero để tránh lỗi octal trong bash arithmetic (`08` và `09` bị treat là invalid octal). Cách này work nhưng:
- Không rõ ý định
- Nếu `DAILY_REPORT_HOUR` được set với leading zero (ví dụ `DAILY_REPORT_HOUR=07` trong config) thì so sánh `07 -eq 7` vẫn đúng trong bash nhưng inconsistent

### Fix yêu cầu
Dùng cách explicit và self-documenting hơn:

```bash
# Thay:
current_hour=$(date +%H | sed 's/^0//')

# Bằng:
current_hour=$(( 10#$(date +%H) ))   # Force base-10, an toàn với 08, 09
```

Comment thêm vào chỗ khai báo `DAILY_REPORT_HOUR`:
```bash
DAILY_REPORT_HOUR=7    # Giờ gửi daily report (0–23, không dùng leading zero)
```

---

## Fix 4 — `eval echo "~$user"` không an toàn (lines 246, 291)

### Vấn đề
```bash
EFFECTIVE_HOME=$(eval echo "~$user")
```

`eval` execute string như shell command. Nếu `$user` chứa ký tự đặc biệt (ví dụ: `ubuntu; rm -rf /tmp`), command injection xảy ra. Mặc dù `$user` đến từ `detect_desktop_user()` nên ít có nguy cơ, vẫn là anti-pattern.

### Fix yêu cầu
Dùng cách an toàn hơn với `getent passwd`:

```bash
# Thay:
EFFECTIVE_HOME=$(eval echo "~$user")

# Bằng:
EFFECTIVE_HOME=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
if [[ -z "$EFFECTIVE_HOME" ]]; then
    # Fallback cho trường hợp getent không có (container minimal)
    EFFECTIVE_HOME="/home/$user"
    [[ "$user" == "root" ]] && EFFECTIVE_HOME="/root"
fi
```

`getent passwd` không execute gì cả, hoàn toàn safe với user input bất kỳ.

---

## Kết quả sau khi fix
- Constants có documentation rõ ràng, dễ tune cho từng environment
- Grace period logic tập trung 1 chỗ, dễ maintain
- Daily report hour parsing rõ ràng, không phụ thuộc sed behavior
- Home directory detection không dùng eval, safe với mọi username

## Version sau khi fix: `v3.4.5`

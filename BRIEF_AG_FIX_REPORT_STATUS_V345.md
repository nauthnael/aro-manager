# BRIEF FOR ANTIGRAVITY — Fix Restart Spam + Status Inconsistency (v3.4.5 → v3.4.6)

## Mục tiêu
Fix 2 bug được report sau khi deploy v3.4.5:
1. Watchdog gửi notification "restart attempting" liên tục spam khi ARO không start được
2. `do_status()` hiện "🟢 Online" ở Node Info nhưng "✗ Not running" ở ARO Application cùng lúc

---

## Bug 1 — Notification spam khi ARO không start được

### Root cause
`send_notify_pre_restart()` không có throttle, nhưng được gọi mỗi cycle watchdog (30s) khi ARO không chạy:

```bash
# watchdog_loop() lines 1887–1892 — chạy mỗi 30s nếu ARO dead:
if [[ $retry_count -lt $MAX_RETRIES ]]; then
    retry_count=$((retry_count + 1))
    state_set "retry_count" "$retry_count"
    send_notify_pre_restart "ARO process not found..." "not_running" "0" "$retry_count"  # ← gửi mỗi 30s
    launch_aro
    ...
    sleep "$STARTUP_TIMEOUT"   # 120s
    if is_aro_running; then
        send_notify_restart_success ...
    else
        watchdog_log "ARO failed to start"   # ← không làm gì thêm, loop tiếp
    fi
```

Mỗi cycle: increment retry, gửi notification, launch (fail), sleep 120s, rồi vòng tiếp theo gửi notification lần nữa. Với 5 retries và STARTUP_TIMEOUT=120s, spam 5 notification trong ~10 phút, sau đó reset retry_count về 0 và bắt đầu lại → vô tận.

Tương tự ở nhánh "log stale" (line 1853), mỗi khi check_disconnect_alert() pass thì gửi notification.

### Fix yêu cầu

#### Bước 1 — Thêm throttle vào `send_notify_pre_restart()`

Tương tự pattern của `send_notify_proxy_down()`, thêm throttle state và cooldown:

```bash
# Thêm vào global variables section (gần _last_proxy_down_notify):
_last_pre_restart_notify=0
PRE_RESTART_NOTIFY_COOLDOWN=300   # Tối thiểu 5 phút giữa 2 lần gửi pre-restart notification
```

```bash
send_notify_pre_restart() {
    local reason="$1"
    local tray_state="$2"
    local stuck_mins="${3:-0}"
    local retry_count="${4:-?}"

    # Throttle: không spam — chỉ gửi nếu đã qua cooldown
    local now; now=$(date +%s)
    local since=$(( now - _last_pre_restart_notify ))
    if [[ $_last_pre_restart_notify -gt 0 ]] && [[ $since -lt $PRE_RESTART_NOTIFY_COOLDOWN ]]; then
        watchdog_log "Pre-restart notification throttled (${since}s since last, cooldown ${PRE_RESTART_NOTIFY_COOLDOWN}s)"
        return 0
    fi
    _last_pre_restart_notify=$now

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

#### Bước 2 — Reset throttle khi ARO thành công restart

Khi `send_notify_restart_success` hoặc `send_notify_aro_reconnected` được gọi (ARO đã online lại), reset `_last_pre_restart_notify=0` để lần sự cố tiếp theo gửi được ngay:

```bash
send_notify_restart_success() {
    _last_pre_restart_notify=0   # Reset throttle — ARO đã healthy
    ...
    # (phần còn lại giữ nguyên)
}

send_notify_aro_reconnected() {
    _last_pre_restart_notify=0   # Reset throttle — ARO đã online
    ...
    # (phần còn lại giữ nguyên)
}
```

---

## Bug 2 — `do_status()` hiện "🟢 Online" nhưng "✗ Not running"

### Root cause
`do_status()` đọc trạng thái từ **2 nguồn khác nhau**:

- **Node Info → Status 🟢 Online** (line 2783–2789): đọc `$TRAY_STATUS` — được parse từ **log file**, phản ánh lần cuối ARO ghi log (có thể từ trước khi crash)
- **ARO Application → ✗ Not running** (line 2824): gọi `is_aro_running()` — check **live process** qua pgrep

Khi ARO crash:
1. Log file vẫn còn entry cuối `"tray=Online"` từ trước khi crash
2. `TRAY_STATUS` = "Online" (từ cache hoặc log)
3. `is_aro_running()` = false (process đã dead)
4. Kết quả: Node Info nói Online, ARO Application nói Not running

Code `is_tray_status_stale(120)` (line 2763) chỉ refresh nếu cache >120s tuổi — nhưng nếu ARO crash trong vòng 120s sau lần refresh cuối, cache vẫn hiện "Online".

### Fix yêu cầu

#### Bước 1 — Luôn refresh parse_node_info() trong do_status()

Bỏ condition `is_tray_status_stale`, luôn gọi `parse_node_info()` khi chạy status:

```bash
# Thay (lines 2763–2765):
if is_tray_status_stale 120; then
    parse_node_info
fi

# Bằng:
LATEST_LOG_FILE=$(get_latest_aro_log)
parse_node_info
```

`parse_node_info()` chạy nhanh (vài grep trên log file), không tốn kém khi gọi thủ công.

#### Bước 2 — Cross-check TRAY_STATUS với live process trong Node Info

Trong `do_status()`, khi render phần "Status:" của Node Info, override display nếu process không chạy:

```bash
# Thay (lines 2782–2789):
local _tray_display
case "$TRAY_STATUS" in
    Online)     _tray_display="🟢 Online" ;;
    NoInternet) _tray_display="🔴 NoInternet (connecting...)" ;;
    Offline)    _tray_display="🟡 Offline" ;;
    *)          _tray_display="❓ ${CONNECT_STATUS:-unknown} (api)" ;;
esac
echo "  Status:  $_tray_display"

# Bằng:
local _tray_display
if ! is_aro_running; then
    # Process dead → override bất kể log nói gì
    _tray_display="⚫ Stopped (process not running)"
else
    case "$TRAY_STATUS" in
        Online)     _tray_display="🟢 Online" ;;
        NoInternet) _tray_display="🔴 NoInternet (connecting...)" ;;
        Offline)    _tray_display="🟡 Offline" ;;
        *)          _tray_display="❓ ${CONNECT_STATUS:-unknown} (api)" ;;
    esac
fi
echo "  Status:  $_tray_display"
```

Kết quả: khi process dead, cả Node Info và ARO Application đều nhất quán hiện trạng thái dừng.

---

## Tóm tắt thay đổi

| File | Dòng thay đổi | Mô tả |
|------|--------------|-------|
| globals | ~line 80 | Thêm `_last_pre_restart_notify=0` và `PRE_RESTART_NOTIFY_COOLDOWN=300` |
| `send_notify_pre_restart()` | ~line 1212 | Thêm throttle logic |
| `send_notify_restart_success()` | ~line 1169 | Thêm `_last_pre_restart_notify=0` reset |
| `send_notify_aro_reconnected()` | ~line 1280 | Thêm `_last_pre_restart_notify=0` reset |
| `do_status()` | ~line 2763 | Bỏ `is_tray_status_stale`, luôn gọi `parse_node_info()` |
| `do_status()` | ~line 2782 | Thêm `is_aro_running()` check trước khi render status |

## Version sau khi fix: `v3.4.6`
Cập nhật dòng version ở đầu script.

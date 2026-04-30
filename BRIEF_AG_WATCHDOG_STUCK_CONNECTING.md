# BRIEF: Watchdog – Fix nc bug + Phát hiện ARO stuck "Connecting" + Xử lý tự động

**File cần sửa:** `aro-manager.sh`  
**Script version hiện tại:** `3.2.0` → bump lên `3.3.0`  
**Ngày:** 2026-04-30  
**Priority:** CRITICAL — Bug nc làm watchdog tê liệt hoàn toàn + ARO không bao giờ được restart

---

## 0. BUG CRITICAL — Fix ngay trước mọi thứ khác: `nc` check làm watchdog tê liệt

### Triệu chứng thực tế (đã xác nhận qua log)

```
[07:25:41] WARNING: Redsocks port 12345 not responding
[07:25:41] Proxy unhealthy, skipping ARO checks this cycle
[07:26:11] Real proxy check OK — exit IP: 14.170.145.171   ← proxy ĐANG CHẠY TỐT
[07:28:25] WARNING: Redsocks port 12345 not responding
[07:28:25] Proxy unhealthy, skipping ARO checks this cycle
...lặp mãi...
```

**Hệ quả:** ARO bị tắt nhưng watchdog KHÔNG BAO GIỜ restart nó vì mỗi cycle đều bị block ở `check_proxy_health()`.

### Nguyên nhân

`check_proxy_health()` dùng `nc -z 127.0.0.1 12345` để check redsocks port. Lệnh này **không bao giờ thành công** với transparent proxy vì redsocks cần `SO_ORIGINAL_DST` header — direct connect từ nc không có header đó nên bị reject/timeout.

Test xác nhận:
```bash
$ ss -tlnp | grep 12345
LISTEN 4097  4096  127.0.0.1:12345   # port ĐANG LISTEN

$ nc -zv -w3 127.0.0.1 12345
nc: connect to 127.0.0.1 port 12345 timed out   # nc LUÔN FAIL
```

Redsocks và proxy đang hoạt động bình thường — `check_real_proxy` confirm exit IP thành công — nhưng watchdog nghĩ proxy đang lỗi.

### Fix — Thay nc bằng ss trong `check_proxy_health()`

**Tìm đoạn (khoảng line 1116):**
```bash
    # Check redsocks port
    if ! nc -z 127.0.0.1 "$REDSOCKS_PORT" 2>/dev/null; then
        watchdog_log "WARNING: Redsocks port $REDSOCKS_PORT not responding"
        return 1
    fi
```

**Thay bằng:**
```bash
    # Check redsocks port via ss (nc không hoạt động với transparent proxy)
    # Redsocks dùng SO_ORIGINAL_DST — direct connect từ nc bị reject là bình thường
    if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
        watchdog_log "WARNING: Redsocks port $REDSOCKS_PORT not in LISTEN state (ss check)"
        return 1
    fi
```

**Tương tự trong wrapper script** (`/usr/local/bin/aro-launch`, khoảng line 658):
```bash
# Tìm:
if ! timeout 3 nc -z 127.0.0.1 "$REDSOCKS_PORT" 2>/dev/null; then

# Thay bằng:
if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
```

### Verify sau khi fix

```bash
# Sau khi apply fix, watchdog phải log:
# [timestamp] Proxy health OK
# [timestamp] ARO not running, starting...
# KHÔNG còn thấy "Redsocks port not responding" nữa
```

---

## 1. Bối cảnh & Bug chính

### Vấn đề

ARO Desktop app thỉnh thoảng bị kẹt ở màn hình "Connecting..." với toast "There seems to be a network issue". Process ARO vẫn đang chạy, log vẫn được ghi đều đặn, nhưng node không còn earn rewards.

### Tại sao watchdog hiện tại không phát hiện được

ARO poll `get_node_stat` API mỗi ~11 giây → log file LUÔN được cập nhật khi process còn sống → `is_log_fresh()` luôn trả về `true` → watchdog đi vào nhánh "ARO healthy" và không làm gì thêm.

```
# Luồng hiện tại (BUG):
if is_aro_running; then
    if is_log_fresh; then        # ← luôn TRUE vì ARO ghi log mỗi 11s
        # coi là healthy ← SAI: fresh log ≠ connected!
        reset_retry_counter...
    else
        check_disconnect_alert   # ← không bao giờ chạy đến đây
```

`check_disconnect_alert` và `get_disconnect_duration` chỉ được gọi khi log **stale** (không được ghi >10 phút), nhưng điều đó không bao giờ xảy ra khi ARO đang chạy.

### Bằng chứng từ log thực tế

```
# ARO connected bình thường:
[2026-04-30 07:01:35] app_lib - get_node_stat response={"connect":"connected",...}

# ARO stuck connecting — log VẪN fresh nhưng status là disconnected:
[...] app_lib - get_node_stat response={"connect":"disconnected",...}

# Không có state "connecting" trong log — chỉ có 2 giá trị:
#   "connect":"connected"
#   "connect":"disconnected"
# UI hiển thị "Connecting..." khi app đang nhận "disconnected" response
```

Từ toàn bộ log file (3.1MB): `4808 × "connected"`, `422 × "disconnected"`. Không có giá trị nào khác.

---

## 2. Phát hiện bổ sung — Rewards API timeout KHÔNG phải lỗi kết nối

`get_rewards` đang fail liên tục với `code:500 context deadline exceeded`:

```
[...] app_lib - get_rewards response={"code":500,"message":"failed to send request: 
Get \"https://testnet-api.aro.network/api/keeper/rewards\": context deadline exceeded","data":null}
```

Trong khi đó `get_node_stat` vẫn trả về `"connect":"connected"`. Đây là **2 API khác nhau**: rewards endpoint bị chậm/lỗi tạm thời không đồng nghĩa ARO bị disconnect.

**Hệ quả:** `parse_node_info()` đang set `REWARD_TODAY="0"` và `REWARD_YESTERDAY="0"` mỗi khi rewards API fail → daily report báo sai.

---

## 3. Phát hiện bổ sung — `nc` check redsocks port không đáng tin

```bash
# Kết quả test thực tế:
$ ss -tlnp | grep 12345
LISTEN 4097  4096  127.0.0.1:12345   # port đang listen

$ nc -zv -w3 127.0.0.1 12345
nc: connect to 127.0.0.1 port 12345 timed out   # ← nhưng nc timeout!
```

Redsocks transparent proxy dùng `SO_ORIGINAL_DST` — direct connect từ nc không hoạt động đúng. `check_proxy_health()` hiện dùng `nc -z` không có timeout → có thể hang vô tận.

---

## 4. Thay đổi cần thực hiện

### 4.1 Thêm config variables (section config, khoảng line 56–68)

Thêm vào sau `PROXY_DOWN_NOTIFY_INTERVAL`:

```bash
# ── Stuck-connecting watchdog ───────────────────────────────────
CONNECTING_GRACE_SECS=180          # grace period sau launch (3 phút)
CONNECTING_WAIT_SECS=300           # chờ ARO reconnect sau restart (5 phút)
CONNECTING_POLL_INTERVAL=30        # poll interval trong khi chờ
PROXY_RESTART_TIMEOUT_SECS=60      # timeout chờ proxy restart
STUCK_THRESHOLD_MINUTES=5          # bao nhiêu phút "disconnected" = stuck
```

Thêm vào section `watchdog.conf` (khoảng line 463–474):

```bash
CONNECTING_GRACE_SECS=$CONNECTING_GRACE_SECS
CONNECTING_WAIT_SECS=$CONNECTING_WAIT_SECS
STUCK_THRESHOLD_MINUTES=$STUCK_THRESHOLD_MINUTES
PROXY_RESTART_TIMEOUT_SECS=$PROXY_RESTART_TIMEOUT_SECS
```

---

### 4.2 Hàm mới: `is_aro_connected()` — đặt sau `is_log_fresh()` (~line 896)

```bash
# Returns 0 (true) nếu ARO đang connected theo log mới nhất
# Returns 1 (false) nếu disconnected, hoặc không có entry nào
is_aro_connected() {
    LATEST_LOG_FILE=$(get_latest_aro_log)
    [[ -z "$LATEST_LOG_FILE" ]] && return 1
    ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null && return 1

    local last_status
    last_status=$(run_as_aro_user grep -oh '"connect":"[^"]*"' "$LATEST_LOG_FILE" 2>/dev/null \
        | tail -1 \
        | grep -o '"connect":"[^"]*"' \
        | sed 's/"connect":"//;s/"//' \
        || true)

    [[ "$last_status" == "connected" ]]
}
```

---

### 4.3 Hàm mới: `get_disconnected_since_minutes()` — đặt sau `get_disconnect_duration()` (~line 915)

Khác với `get_disconnect_duration()` hiện tại (chỉ đọc 100 dòng cuối), hàm này tính thời gian kể từ lần cuối log thấy `"connected"`.

```bash
# Returns số phút kể từ lần cuối ARO log thấy "connected"
# Nếu chưa bao giờ connected trong log → dùng (now - mtime_log_file) thay thế
get_disconnected_since_minutes() {
    LATEST_LOG_FILE=$(get_latest_aro_log)
    [[ -z "$LATEST_LOG_FILE" ]] && echo "0" && return 0
    ! run_as_aro_user test -f "$LATEST_LOG_FILE" 2>/dev/null && echo "0" && return 0

    local log_content
    log_content=$(run_as_aro_user tail -n 500 "$LATEST_LOG_FILE" 2>/dev/null || true)

    # Tìm dòng get_node_stat CUỐI CÙNG có "connected"
    local last_connected_line
    last_connected_line=$(echo "$log_content" \
        | grep 'get_node_stat' \
        | grep '"connect":"connected"' \
        | tail -1 || true)

    local now; now=$(date +%s)

    if [[ -n "$last_connected_line" ]]; then
        local ts_str
        ts_str=$(echo "$last_connected_line" \
            | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null || true)
        if [[ -n "$ts_str" ]]; then
            local ep; ep=$(date -d "$ts_str" +%s 2>/dev/null || echo 0)
            if [[ "$ep" -gt 0 ]]; then
                echo $(( (now - ep) / 60 ))
                return 0
            fi
        fi
    fi

    # Không tìm thấy "connected" → dùng thời điểm last_restart từ state
    local last_restart
    last_restart=$(state_get "last_restart" "0")
    if [[ "$last_restart" -gt 0 ]]; then
        echo $(( (now - last_restart) / 60 ))
    else
        echo "0"
    fi
}
```

---

### 4.4 Hàm mới: `handle_stuck_connecting()` — đặt sau `check_disconnect_alert()` (~line 1160)

```bash
# Xử lý khi ARO process đang chạy nhưng không connect được
# Param $1: số phút đã disconnected
handle_stuck_connecting() {
    local stuck_mins="${1:-0}"

    # ── Grace period: vừa khởi động, chưa đến lúc phán ─────────
    local last_restart; last_restart=$(state_get "last_restart" "0")
    local now; now=$(date +%s)
    local since_launch=$(( now - last_restart ))

    if [[ "$last_restart" -gt 0 ]] && [[ "$since_launch" -lt "$CONNECTING_GRACE_SECS" ]]; then
        local remaining=$(( CONNECTING_GRACE_SECS - since_launch ))
        watchdog_log "ARO disconnected ${stuck_mins}m but within grace period (${remaining}s remaining)"
        return 0
    fi

    watchdog_log "ARO stuck disconnected for ${stuck_mins}m — starting recovery"

    # ── Kiểm tra proxy thực sự ──────────────────────────────────
    local proxy_ok=false
    if check_real_proxy 2>/dev/null; then
        proxy_ok=true
    fi

    if $proxy_ok; then
        # ── CASE A: Proxy ok, lỗi ở phía ARO ──────────────────
        watchdog_log "Proxy OK — restarting ARO (stuck connecting)"
        _restart_aro_and_wait "proxy_ok"
    else
        # ── CASE B: Proxy offline gây ARO stuck ────────────────
        watchdog_log "Proxy DOWN — killing ARO, attempting proxy restart"
        kill_aro

        # Restart proxy và poll đến khi live hoặc timeout
        systemctl restart redsocks-aro 2>/dev/null || true
        local proxy_wait_start; proxy_wait_start=$(date +%s)
        local proxy_recovered=false

        while true; do
            local elapsed=$(( $(date +%s) - proxy_wait_start ))
            if [[ "$elapsed" -ge "$PROXY_RESTART_TIMEOUT_SECS" ]]; then
                break
            fi
            sleep 5
            if check_real_proxy 2>/dev/null; then
                proxy_recovered=true
                break
            fi
        done

        if $proxy_recovered; then
            watchdog_log "Proxy recovered — launching ARO"
            send_notify_proxy_recovered
            launch_aro
            state_set "last_restart" "$(date +%s)"
            _restart_aro_and_wait "proxy_recovered"
        else
            watchdog_log "Proxy restart FAILED after ${PROXY_RESTART_TIMEOUT_SECS}s — ARO stays down"
            send_notify_proxy_dead
            # ARO ở tắt, chờ manual
        fi
    fi
}

# Helper: chờ ARO connect sau khi đã launch, poll mỗi CONNECTING_POLL_INTERVAL
# Param $1: context label ("proxy_ok" | "proxy_recovered") dùng cho log
_restart_aro_and_wait() {
    local context="${1:-unknown}"
    local wait_start; wait_start=$(date +%s)
    local retry_count; retry_count=$(state_get "retry_count" "0")

    watchdog_log "Waiting up to ${CONNECTING_WAIT_SECS}s for ARO to connect (context: $context)..."

    while true; do
        local elapsed=$(( $(date +%s) - wait_start ))
        if [[ "$elapsed" -ge "$CONNECTING_WAIT_SECS" ]]; then
            break
        fi
        sleep "$CONNECTING_POLL_INTERVAL"

        if is_aro_connected; then
            watchdog_log "ARO reconnected successfully after ${elapsed}s (context: $context)"
            send_notify_aro_reconnected "$context" "$elapsed"
            state_set "retry_count" "0"
            state_set "stable_since" "$(date +%s)"
            return 0
        fi
        watchdog_log "Still waiting... ${elapsed}s / ${CONNECTING_WAIT_SECS}s"
    done

    # Hết thời gian, vẫn không connect
    retry_count=$(( retry_count + 1 ))
    state_set "retry_count" "$retry_count"
    watchdog_log "ARO still not connected after ${CONNECTING_WAIT_SECS}s (retry $retry_count/$MAX_RETRIES)"

    if [[ "$retry_count" -le "$MAX_RETRIES" ]]; then
        send_notify_aro_stuck_manual "$retry_count" "$context"
    else
        watchdog_log "MAX RETRIES reached ($MAX_RETRIES) — giving up"
        send_notify_max_retries
        state_set "retry_count" "0"
    fi
}
```

---

### 4.5 Sửa `check_proxy_health()` — thay nc check (~line 1116)

**Xóa:**
```bash
# Check redsocks port
if ! nc -z 127.0.0.1 "$REDSOCKS_PORT" 2>/dev/null; then
    watchdog_log "WARNING: Redsocks port $REDSOCKS_PORT not responding"
    return 1
fi
```

**Thay bằng:**
```bash
# Check redsocks port via ss (nc không reliable với transparent proxy)
if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
    watchdog_log "WARNING: Redsocks port $REDSOCKS_PORT not in LISTEN state"
    return 1
fi
```

Lý do: redsocks dùng transparent proxy (`SO_ORIGINAL_DST`), `nc` direct connect timeout. `ss -tlnp` check listen state là đủ và reliable.

---

### 4.6 Sửa `watchdog_loop()` — thêm check `is_aro_connected` trong nhánh log fresh (~line 1234)

**Tìm đoạn này (khoảng line 1234–1255):**

```bash
if is_aro_running; then
    # ARO is running - check if healthy
    if is_log_fresh; then
        # ARO is healthy
        local retry_count
        retry_count=$(state_get "retry_count" "0")
        
        if [[ $retry_count -gt 0 ]]; then
            watchdog_log "ARO healthy after recovery (retry count: $retry_count)"
        fi
        
        # Reset retry counter after stable period
        local stable_since
        stable_since=$(state_get "stable_since")
        local stable_duration=$(( $(date +%s) - stable_since ))
        local reset_threshold=$((RESET_STABLE_HOURS * 3600))
        
        if [[ $stable_duration -gt $reset_threshold ]] && [[ $retry_count -gt 0 ]]; then
            watchdog_log "ARO stable for ${RESET_STABLE_HOURS}h, resetting retry counter"
            state_set "retry_count" "0"
        fi
    else
        # ARO is running but log is stale
        ...
```

**Thay toàn bộ nhánh `if is_log_fresh; then ... else ... fi` bằng:**

```bash
if is_aro_running; then
    LATEST_LOG_FILE=$(get_latest_aro_log)
    
    if is_log_fresh; then
        # Log đang được ghi đều — check status thực sự
        if is_aro_connected; then
            # ── ARO connected & healthy ──────────────────────
            local retry_count
            retry_count=$(state_get "retry_count" "0")

            if [[ $retry_count -gt 0 ]]; then
                watchdog_log "ARO healthy after recovery (retry count: $retry_count)"
            fi

            local stable_since; stable_since=$(state_get "stable_since")
            local stable_duration=$(( $(date +%s) - stable_since ))
            local reset_threshold=$(( RESET_STABLE_HOURS * 3600 ))

            if [[ $stable_duration -gt $reset_threshold ]] && [[ $retry_count -gt 0 ]]; then
                watchdog_log "ARO stable for ${RESET_STABLE_HOURS}h, resetting retry counter"
                state_set "retry_count" "0"
            fi
        else
            # ── Log fresh nhưng status DISCONNECTED — stuck! ──
            local stuck_mins
            stuck_mins=$(get_disconnected_since_minutes)
            watchdog_log "ARO process running, log fresh, but DISCONNECTED for ${stuck_mins}m"

            if [[ "$stuck_mins" -ge "$STUCK_THRESHOLD_MINUTES" ]]; then
                handle_stuck_connecting "$stuck_mins"
            else
                watchdog_log "Disconnected ${stuck_mins}m < threshold ${STUCK_THRESHOLD_MINUTES}m, monitoring..."
            fi
        fi
    else
        # ── Log stale (>LOG_STALE_MINUTES) — logic cũ giữ nguyên ──
        watchdog_log "ARO process running but log is stale (>${LOG_STALE_MINUTES}m)"

        if check_disconnect_alert; then
            watchdog_log "Recent disconnect detected, attempting restart"
            # ... (giữ nguyên toàn bộ logic backoff + restart hiện tại)
        fi
    fi
```

---

### 4.7 Sửa `parse_node_info()` — giữ lại reward cũ khi API fail (~line 788)

**Vấn đề:** `parse_node_info()` reset `REWARD_TODAY="0"` ở đầu hàm. Nếu `get_rewards` API trả về code 500, grep không tìm thấy `"today":` trong 200 dòng log → `REWARD_TODAY` giữ giá trị "0". Daily report báo sai.

**Thêm 2 biến cache vào phần global variables (~line 704–711):**

```bash
# Cache reward values — giữ lại giá trị cuối cùng lấy được khi API lỗi
_CACHED_REWARD_TODAY="0"
_CACHED_REWARD_YESTERDAY="0"
_CACHED_UPTIME="0"
```

**Sửa `parse_node_info()` — phần extract rewards:**

Tìm đoạn:
```bash
val=$(echo "$lines" | grep -oP '(?<="today":)[0-9.]+' 2>/dev/null | tail -1 || true)
[[ -n "$val" ]] && REWARD_TODAY="$val"

val=$(echo "$lines" | grep -oP '(?<="yesterday":)[0-9.]+' 2>/dev/null | tail -1 || true)
[[ -n "$val" ]] && REWARD_YESTERDAY="$val"

val=$(echo "$lines" | grep -oP '(?<="uptime":)[0-9.]+' 2>/dev/null | tail -1 || true)
[[ -n "$val" ]] && UPTIME_RATIO="$val"
```

Thay bằng:
```bash
val=$(echo "$lines" | grep -oP '(?<="today":)[0-9.]+' 2>/dev/null | tail -1 || true)
if [[ -n "$val" ]]; then
    REWARD_TODAY="$val"
    _CACHED_REWARD_TODAY="$val"   # update cache
else
    REWARD_TODAY="$_CACHED_REWARD_TODAY"   # dùng giá trị cũ khi API lỗi
fi

val=$(echo "$lines" | grep -oP '(?<="yesterday":)[0-9.]+' 2>/dev/null | tail -1 || true)
if [[ -n "$val" ]]; then
    REWARD_YESTERDAY="$val"
    _CACHED_REWARD_YESTERDAY="$val"
else
    REWARD_YESTERDAY="$_CACHED_REWARD_YESTERDAY"
fi

val=$(echo "$lines" | grep -oP '(?<="uptime":)[0-9.]+' 2>/dev/null | tail -1 || true)
if [[ -n "$val" ]]; then
    UPTIME_RATIO="$val"
    _CACHED_UPTIME="$val"
else
    UPTIME_RATIO="$_CACHED_UPTIME"
fi
```

**Lưu ý:** Cache chỉ tồn tại trong memory của process watchdog (không persist qua restart). Nếu watchdog restart, cache về "0". Đây là acceptable vì thường sau restart ARO sẽ connected lại và API sẽ trả về data.

---

### 4.8 Thêm 4 Telegram notification templates — đặt sau `send_notify_proxy_recovered()` (~line 1020)

#### `send_notify_aro_reconnected` — ARO tự recover thành công

```bash
send_notify_aro_reconnected() {
    local context="${1:-unknown}"
    local elapsed_secs="${2:-0}"
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info
    get_last_online_info

    local f_today; f_today=$(format_number "$REWARD_TODAY")
    local f_yest;  f_yest=$(format_number "$REWARD_YESTERDAY")
    local f_up;    f_up=$(format_uptime "$UPTIME_RATIO")
    local elapsed_min=$(( elapsed_secs / 60 ))

    local cause_label="Proxy OK, ARO restarted"
    [[ "$context" == "proxy_recovered" ]] && cause_label="Proxy recovered + ARO restarted"

    local msg="✅ <b>[ARO RECONNECTED] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
👤 User: ${EFFECTIVE_USER}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🌐 Exit IP: ${PUBLIC_IP}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
──────────────────────
🔧 Cause: ${cause_label}
⏱️ Recovery time: ${elapsed_min}m ${elapsed_secs}s
💰 Reward today:     ${f_today} pts
💰 Reward yesterday: ${f_yest} pts
📶 Uptime: ${f_up}%
${LAST_ONLINE_LABEL}: ${LAST_ONLINE_AGO}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}
```

#### `send_notify_aro_stuck_manual` — Cần can thiệp tay

```bash
send_notify_aro_stuck_manual() {
    local retry_count="${1:-?}"
    local context="${2:-unknown}"
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info

    local cause_label="Proxy OK nhưng ARO không reconnect"
    [[ "$context" == "proxy_recovered" ]] && cause_label="Proxy đã recover nhưng ARO vẫn không connect"

    local msg="⚠️ <b>[ARO STUCK] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔢 Serial: ${SERIAL}
📧 Account: ${EMAIL}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
──────────────────────
❌ ARO không kết nối được sau ${CONNECTING_WAIT_SECS}s
🔧 Context: ${cause_label}
🔄 Retry: ${retry_count}/${MAX_RETRIES}
👉 <b>Cần kiểm tra thủ công!</b>
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}
```

#### `send_notify_proxy_dead` — Proxy không restart được

```bash
send_notify_proxy_dead() {
    local msg="🚨 <b>[PROXY DEAD] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
⏱️ Timeout: ${PROXY_RESTART_TIMEOUT_SECS}s
❌ Redsocks restart FAILED — ARO đang tắt
🛑 Kill-switch đang hoạt động
👉 <b>Cần can thiệp thủ công!</b>
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}
```

#### Sửa `send_notify_proxy_recovered` hiện có — thêm context

Template hiện tại chỉ báo "redsocks service restarted". Cần **thêm dòng** để phân biệt recovery do watchdog stuck vs proxy health check thông thường. Tìm hàm `send_notify_proxy_recovered` và thêm tham số optional:

```bash
send_notify_proxy_recovered() {
    local context="${1:-routine}"   # "routine" | "stuck_connecting"
    local context_label="Auto-recovery (routine check)"
    [[ "$context" == "stuck_connecting" ]] && context_label="Recovery triggered by ARO stuck-connecting"

    local msg="✅ <b>[PROXY RECOVERED] ${HOSTNAME}</b>
──────────────────────
🖥️ VPS: ${HOSTNAME}
🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
✓ Redsocks service restarted OK
🔧 Context: ${context_label}
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$msg"
}
```

Cập nhật lời gọi trong `handle_stuck_connecting`:
```bash
send_notify_proxy_recovered "stuck_connecting"
```

---

## 5. Luồng xử lý đầy đủ sau khi patch

```
Mỗi CHECK_INTERVAL (30s):
│
├─ check_real_proxy [mỗi PROXY_CHECK_INTERVAL = 5 phút]
├─ check_proxy_health [mỗi cycle — dùng ss thay nc]
│   └─ FAIL → restart redsocks → skip cycle nếu vẫn fail
│
└─ is_aro_running?
    ├─ NO → launch (logic cũ)
    └─ YES
        ├─ is_log_fresh?
        │   ├─ YES → is_aro_connected?
        │   │   ├─ YES → healthy ✓
        │   │   │   └─ reset counter nếu stable > 2h
        │   │   └─ NO → get_disconnected_since_minutes
        │   │       ├─ < STUCK_THRESHOLD (5m) → monitor, chờ thêm
        │   │       └─ >= 5m → handle_stuck_connecting()
        │   │           ├─ Trong grace period (3m) → skip
        │   │           ├─ Proxy OK
        │   │           │   → kill+restart ARO
        │   │           │   → poll 5m (mỗi 30s)
        │   │           │   ├─ Connected → notify_reconnected ✅
        │   │           │   └─ Timeout → notify_stuck_manual ⚠️
        │   │           └─ Proxy DOWN
        │   │               → kill ARO
        │   │               → restart proxy (poll 60s)
        │   │               ├─ Proxy ok → launch ARO → poll 5m
        │   │               │   ├─ Connected → notify_reconnected ✅
        │   │               │   └─ Timeout → notify_stuck_manual ⚠️
        │   │               └─ Proxy dead → notify_proxy_dead 🚨
        │   │
        │   └─ NO (stale >10m) → check_disconnect_alert (logic cũ)
        │
        └─ Daily report @ DAILY_REPORT_HOUR
```

---

## 6. Checklist kiểm tra sau khi patch

- [ ] `is_aro_connected` trả về đúng khi grep log thực tế
- [ ] `get_disconnected_since_minutes` trả về 0 khi đang connected
- [ ] `handle_stuck_connecting` không trigger trong grace period 3 phút sau launch
- [ ] `check_proxy_health` không còn dùng `nc`, thay bằng `ss`
- [ ] `parse_node_info` giữ reward cũ khi `get_rewards` trả về code 500
- [ ] Tất cả 4 Telegram templates mới hoạt động đúng
- [ ] `SCRIPT_VERSION` bump từ `3.2.0` → `3.3.0`
- [ ] Config variables mới được ghi vào `watchdog.conf` khi setup

---

## 7. Ghi chú quan trọng cho AG

**Filename có space:** ARO log file là `"ARO Desktop.log"` — mọi thao tác với file này phải dùng `run_as_aro_user` và luôn quote biến. Không dùng `$(ls ...)` trực tiếp làm argument của `tail`/`stat` — phải gán vào biến trước:
```bash
LATEST_LOG_FILE=$(get_latest_aro_log)
run_as_aro_user tail -n 200 "$LATEST_LOG_FILE"   # ✓
tail -n 200 $(get_latest_aro_log)                 # ✗ lỗi vì space
```

**Curl proxy format đúng:**
```bash
# Đúng:
curl --socks5-hostname "${PROXY_HOST}:${PROXY_PORT}" --proxy-user "${PROXY_USER}:${PROXY_PASS}" URL
# Hoặc:
curl -x "socks5h://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" URL

# Sai (format cũ trong check_real_proxy):
curl --socks5-hostname "${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" URL
# ← sẽ fail nếu PROXY_HOST chứa @ trong user/pass
```

Kiểm tra lại `check_real_proxy()` — nếu đang dùng format `USER:PASS@HOST:PORT` trong `--socks5-hostname` thì sửa lại thành `--proxy-user` riêng.

---

## 8. Thêm command `update` — để deploy script mới mà không cần cài lại từ đầu

### Mục đích

Khi có bản script mới, user cần 1 lệnh duy nhất để:
- Rebuild wrapper (`/usr/local/bin/aro-launch`) — áp dụng mọi fix mới nhất
- Rebuild watchdog service file — sync với SCRIPT_DIR hiện tại
- Restart tất cả services theo đúng thứ tự
- Verify kết quả và báo cáo

### Vị trí thêm code

**1. Thêm hàm `do_update()`** — đặt ngay trước `show_usage()` (section "HELP & USAGE")

**2. Thêm case `update)` vào `main()`** — đặt ngay trước `uninstall)`:
```
        update)
            do_update
            SHOW_FOOTER_ON_EXIT=1
            ;;
```

**3. Thêm dòng vào `show_usage()`** trong phần MAIN COMMANDS:
```
  update              Cập nhật script: rebuild wrapper + restart services
```
Đặt sau dòng `status` và trước dòng `report`.

### Logic của `do_update()`

```
do_update():
  1. require_root
  2. Kiểm tra đã install chưa (PROXY_CONF_FILE tồn tại)
  3. Load configs + detect_desktop_user

  4. Path check — đọc ExecStart từ $SYSTEMD_WATCHDOG_SERVICE
     → So sánh với "$SCRIPT_DIR/$SCRIPT_NAME" (script đang chạy)
     → Nếu khác: hỏi user có muốn copy script mới vào đúng path không
     → Nếu đồng ý: cp + chmod +x

  5. Stop watchdog service (systemctl stop aro-watchdog)
     → sleep 2

  6. Kill ARO process (pkill -u "$EFFECTIVE_USER" -x ARO)
     → Watchdog sẽ tự restart sau khi update xong
     → sleep 2

  7. Recreate wrapper: gọi create_wrapper_script()
     → Đây là bước áp dụng fix nc→ss vào /usr/local/bin/aro-launch

  8. Recreate service file: gọi create_watchdog_service()
     → systemctl daemon-reload

  9. Ensure redsocks running:
     → if ! systemctl is-active redsocks-aro: systemctl start redsocks-aro + sleep 3

  10. Start watchdog: systemctl start aro-watchdog + sleep 3

  11. Verify và in kết quả:
      ✓/✗ redsocks-aro active?
      ✓/✗ aro-watchdog active?
      ✓/⚠ wrapper dùng ss check? (grep "ss -tlnp" $WRAPPER_SCRIPT)
      ✓   Script version + path

  12. Nếu all OK: log_success + hướng dẫn theo dõi log
      Nếu có lỗi: log_error + exit 1
```

### Checklist bổ sung vào Section 6

- [ ] `sudo ./aro-manager.sh update` chạy thành công không lỗi
- [ ] Sau update, không còn log `"Redsocks port 12345 not responding"`
- [ ] Wrapper `/usr/local/bin/aro-launch` chứa `ss -tlnp` (không còn `nc -z`)
- [ ] Watchdog tự detect ARO không chạy và restart trong vòng 60s sau update

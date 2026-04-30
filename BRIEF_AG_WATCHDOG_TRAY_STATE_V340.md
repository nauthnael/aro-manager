# BRIEF: Watchdog v3.4.0 — Dùng Tray State phát hiện ARO stuck + Fix redsocks hung

**File cần sửa:** `aro-manager.sh`  
**Version hiện tại:** `3.3.1` → bump lên `3.4.0`  
**Ngày:** 2026-04-30  
**Priority:** HIGH — Toàn bộ logic stuck-connecting trong v3.3.0 dùng sai signal

---

## 1. Bối cảnh & Phát hiện mới

### Vấn đề với v3.3.0

Brief trước dùng `"connect":"connected/disconnected"` từ API response (`get_node_stat`) để detect ARO stuck. Qua debug thực tế, phát hiện đây là **signal sai**:

- Khi ARO hiển thị "Connecting..." + tray icon xám, log API vẫn trả về `"connect":"connected"`
- API response phản ánh trạng thái phía **server**, không phải client
- Hai trạng thái này có thể lệch nhau hoàn toàn

### Signal đúng — Tray State trong log

ARO tự ghi trạng thái thực của app vào log:

```
[2026-04-30 07:59:45.865] [INFO] app_lib - linux tray icon synced to state=Offline
[2026-04-30 07:59:50.346] [INFO] app_lib - linux tray icon synced to state=NoInternet
[2026-04-30 08:23:03.437] [INFO] app_lib - linux tray icon synced to state=Online
[2026-04-30 08:23:03.464] [INFO] app_lib - net: state -> Online
```

Ba states đã xác nhận:
| State | Ý nghĩa | Tray icon |
|---|---|---|
| `Offline` | App vừa khởi động, chưa check mạng | Xám |
| `NoInternet` | Không reach được internet qua proxy | Xám |
| `Online` | Mạng OK, ARO đang hoạt động | Xanh lá |

### Root cause của "Connecting..." — Redsocks bị treo

Qua debug xác nhận: khi ARO stuck NoInternet, kiểm tra redsocks thấy:

```bash
ss -tlnp | grep 12345
# LISTEN 4097   4096   127.0.0.1:12345
# Recv-Q = 4097, max backlog = 4096 → queue đầy tràn!
```

Redsocks service systemctl vẫn báo "active" nhưng **không accept connection mới**. Test trực tiếp:

```bash
sudo -u ubuntu curl --max-time 10 https://ifconfig.me   # → FAILED
curl --max-time 10 https://ifconfig.me                  # → 115.79.x.x (real IP, root bypass iptables)
```

**Fix duy nhất:** `systemctl restart redsocks-aro` → ARO kết nối lại ngay.

`check_real_proxy()` hiện tại **KHÔNG phát hiện được** vì nó dùng `--socks5-hostname` trực tiếp bằng root, bypass hoàn toàn iptables và redsocks transparent proxy path.

---

## 2. Timeline đầy đủ khi hoạt động đúng

```
08:23:03 — ARO khởi động (redsocks đã restart trước đó)
08:23:03 — linux tray icon synced to state=Online   ← NGAY LẬP TỨC
08:23:05 — get_node_stat "connect":"disconnected"   ← bình thường, server chưa sync
08:23:33 — get_node_stat "connect":"disconnected"
08:23:53 — get_node_stat "connect":"disconnected"
08:24:13 — get_node_stat "connect":"disconnected"
08:24:33 — get_node_stat "connect":"connected" + publicIp ← fully connected (~90s sau start)
```

**Quan trọng:** `state=Online` xuất hiện ngay khi start nếu proxy healthy. `get_node_stat "connected"` đến sau ~90 giây là bình thường — watchdog **không nên** restart ARO trong 90 giây này.

---

## 3. Thay đổi cần thực hiện

### 3.1 Thêm config variable (section config, ~line 66)

Thêm sau `PROXY_RESTART_TIMEOUT_SECS`:

```bash
REDSOCKS_QUEUE_THRESHOLD=500    # recv-Q vượt ngưỡng này = redsocks đang treo
```

Thêm vào watchdog.conf section:
```bash
REDSOCKS_QUEUE_THRESHOLD=$REDSOCKS_QUEUE_THRESHOLD
```

---

### 3.2 Hàm mới: `get_aro_tray_state()` — đặt trước `is_aro_connected()`

Mục đích: Đọc tray state cuối cùng từ ARO log.
Returns (echo): `"Online"`, `"NoInternet"`, `"Offline"`, hoặc `""` nếu không tìm thấy.

```
Logic:
  - Lấy LATEST_LOG_FILE (gọi get_latest_aro_log nếu chưa có)
  - Kiểm tra file tồn tại (dùng run_as_aro_user)
  - Grep tìm dòng "linux tray icon synced to state=" cuối cùng
  - Extract phần sau "state=" (chỉ lấy chữ cái, dùng grep -oP "state=\K[A-Za-z]+")
  - Echo kết quả (hoặc "" nếu không tìm thấy)

Grep command cần dùng:
  run_as_aro_user grep "linux tray icon synced to state=" "$LATEST_LOG_FILE" \
    | tail -1 \
    | grep -oP "state=\K[A-Za-z]+" 2>/dev/null || true
```

---

### 3.3 Sửa `is_aro_connected()` — dùng tray state thay vì API response

Tìm hàm `is_aro_connected()` trong script (thêm ở brief 3.3.0), thay toàn bộ nội dung:

```
Logic mới:
  - Gọi get_aro_tray_state()
  - Nếu state = "Online" → return 0 (true = connected)
  - Mọi trường hợp khác → return 1 (false)
```

---

### 3.4 Hàm mới: `check_redsocks_functional()` — đặt sau `check_real_proxy()`

Mục đích: Test xem traffic của ubuntu user có đi qua redsocks transparent proxy thành công không. Đây là test path THỰC SỰ mà ARO dùng (khác với `check_real_proxy()` dùng direct SOCKS5 bằng root).

```
Logic:
  - Chạy curl bằng EFFECTIVE_USER (không phải root):
    sudo -u "$EFFECTIVE_USER" curl -s --max-time 5 https://ifconfig.me 2>/dev/null
  - Nếu curl trả về IP hợp lệ (regex ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$) → return 0 (working)
  - Nếu fail hoặc timeout → return 1 (broken)

Lưu ý: Hàm này chỉ được gọi khi đã detect vấn đề (NoInternet state), 
KHÔNG gọi mỗi CHECK_INTERVAL để tránh request không cần thiết.
```

---

### 3.5 Sửa `check_proxy_health()` — thêm recv-Q check cho redsocks hung

Tìm đoạn ss check hiện tại (đã được sửa nc→ss ở v3.3.0):

```bash
if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
    watchdog_log "WARNING: Redsocks port $REDSOCKS_PORT not in LISTEN state (ss check)"
    return 1
fi
```

**Thêm ngay SAU đoạn đó** (trước `return 0`):

```
Logic mới — thêm sau ss check, trước return 0:

  Đọc recv-Q của port redsocks:
    recv_q = ss -tlnp | grep "127.0.0.1:$REDSOCKS_PORT " | awk '{print $2}'
  
  Nếu recv_q là số và recv_q > REDSOCKS_QUEUE_THRESHOLD:
    watchdog_log "WARNING: Redsocks recv-Q=${recv_q} > threshold=${REDSOCKS_QUEUE_THRESHOLD} — service hung!"
    
    # Attempt restart
    watchdog_log "Restarting hung redsocks..."
    systemctl restart redsocks-aro 2>/dev/null || true
    sleep 5
    
    Nếu systemctl is-active redsocks-aro:
      watchdog_log "SUCCESS: Redsocks restarted (queue cleared)"
      send_notify_redsocks_restarted   ← template mới, xem section 3.7
      return 0
    Else:
      watchdog_log "ERROR: Redsocks restart failed!"
      return 1

Sau đó return 0 như cũ.
```

---

### 3.6 Sửa `handle_stuck_connecting()` — rewrite toàn bộ logic

Hàm này trong v3.3.0 chưa phân biệt được redsocks hung vs proxy server down. Rewrite theo flow mới:

```
handle_stuck_connecting(stuck_mins):

  # Grace period check (giữ nguyên từ v3.3.0)
  last_restart = state_get "last_restart"
  since_launch = now - last_restart
  Nếu since_launch < CONNECTING_GRACE_SECS:
    log "in grace period (${remaining}s remaining)"
    return

  watchdog_log "ARO stuck NoInternet for ${stuck_mins}m — starting recovery"

  # ── Bước 1: Test path thực sự của ARO ──
  Nếu check_redsocks_functional() FAIL:
    # Redsocks transparent proxy bị broken (hung hoặc lỗi)
    watchdog_log "Transparent proxy BROKEN — redsocks issue"
    kill_aro
    
    # Restart redsocks và poll
    systemctl restart redsocks-aro 2>/dev/null || true
    proxy_wait_start = now
    redsocks_ok = false
    
    Loop (poll mỗi 5s, tối đa PROXY_RESTART_TIMEOUT_SECS):
      sleep 5
      Nếu check_redsocks_functional() PASS:
        redsocks_ok = true
        break
    
    Nếu redsocks_ok = false:
      watchdog_log "Redsocks cannot be recovered"
      send_notify_proxy_dead
      return   # ARO để tắt, chờ manual
    
    # Redsocks đã ok, launch ARO
    watchdog_log "Redsocks recovered — launching ARO"
    launch_aro
    state_set "last_restart" "$(date +%s)"
    
    # Poll chờ ARO online (dùng tray state)
    _wait_for_aro_online "redsocks_recovered"
    return

  # ── Bước 2: Redsocks functional nhưng ARO vẫn NoInternet ──
  # Có thể proxy server bị down, hoặc lỗi ở ARO app
  watchdog_log "Transparent proxy OK — checking upstream proxy server"
  
  Nếu check_real_proxy() FAIL:
    # Proxy server thực sự offline
    watchdog_log "Upstream proxy server DOWN"
    kill_aro
    send_notify_proxy_down "proxy server unreachable"
    return   # Không restart ARO khi proxy server down

  # ── Bước 3: Mọi thứ ok nhưng ARO vẫn stuck ──
  # Có thể ARO app gặp vấn đề nội bộ
  watchdog_log "Network OK but ARO still stuck — restarting ARO"
  kill_aro
  sleep 3
  launch_aro
  state_set "last_restart" "$(date +%s)"
  
  _wait_for_aro_online "proxy_ok_aro_restarted"
```

---

### 3.7 Hàm helper mới: `_wait_for_aro_online()` — poll tray state

Thay thế `_restart_aro_and_wait()` từ v3.3.0 (nếu đã có) hoặc thêm mới:

```
_wait_for_aro_online(context):
  wait_start = now
  
  Loop (poll mỗi CONNECTING_POLL_INTERVAL=30s, tối đa CONNECTING_WAIT_SECS=300s):
    sleep CONNECTING_POLL_INTERVAL
    elapsed = now - wait_start
    
    Nếu elapsed >= CONNECTING_WAIT_SECS: break
    
    tray_state = get_aro_tray_state()
    watchdog_log "Waiting... tray=${tray_state} ${elapsed}s/${CONNECTING_WAIT_SECS}s"
    
    Nếu tray_state = "Online":
      watchdog_log "ARO online after ${elapsed}s (context: $context)"
      send_notify_aro_reconnected "$context" "$elapsed"
      state_set "retry_count" "0"
      state_set "stable_since" "$(date +%s)"
      return 0
  
  # Hết timeout vẫn chưa online
  retry_count = state_get "retry_count" "0" + 1
  state_set "retry_count" "$retry_count"
  watchdog_log "ARO still not online after ${CONNECTING_WAIT_SECS}s (retry $retry_count/$MAX_RETRIES)"
  
  Nếu retry_count <= MAX_RETRIES:
    send_notify_aro_stuck_manual "$retry_count" "$context"
  Else:
    send_notify_max_retries
    state_set "retry_count" "0"
```

---

### 3.8 Sửa `watchdog_loop()` — thay nhánh `is_log_fresh` + `is_aro_connected`

Tìm đoạn đã sửa trong v3.3.0:

```bash
if is_log_fresh; then
    if is_aro_connected; then
        # healthy ...
    else
        stuck_mins=$(get_disconnected_since_minutes)
        if [[ "$stuck_mins" -ge "$STUCK_THRESHOLD_MINUTES" ]]; then
            handle_stuck_connecting "$stuck_mins"
        fi
    fi
```

**Thay bằng:**

```
if is_log_fresh; then
    LATEST_LOG_FILE=$(get_latest_aro_log)
    tray_state=$(get_aro_tray_state)
    
    case "$tray_state" in
      Online)
        # ── Healthy ──
        retry_count = state_get "retry_count" "0"
        Nếu retry_count > 0:
          watchdog_log "ARO healthy (tray=Online) after recovery"
        
        stable_since = state_get "stable_since"
        stable_duration = now - stable_since
        Nếu stable_duration > RESET_STABLE_HOURS*3600 và retry_count > 0:
          watchdog_log "ARO stable for ${RESET_STABLE_HOURS}h, resetting retry counter"
          state_set "retry_count" "0"
        ;;
      
      Offline)
        # Vừa khởi động — kiểm tra có trong grace period không
        since_launch = now - state_get "last_restart" "0"
        Nếu since_launch < CONNECTING_GRACE_SECS:
          watchdog_log "ARO tray=Offline, in startup grace period (${since_launch}s)"
        Else:
          watchdog_log "ARO tray=Offline beyond grace period — treating as stuck"
          stuck_mins = (now - state_get "last_restart" "0") / 60
          handle_stuck_connecting "$stuck_mins"
        ;;
      
      NoInternet)
        # Stuck — tính thời gian
        stuck_mins = get_disconnected_since_minutes()
        watchdog_log "ARO tray=NoInternet for ${stuck_mins}m"
        
        Nếu stuck_mins >= STUCK_THRESHOLD_MINUTES:
          handle_stuck_connecting "$stuck_mins"
        Else:
          watchdog_log "Monitoring... (${stuck_mins}m < threshold ${STUCK_THRESHOLD_MINUTES}m)"
        ;;
      
      *)
        # State không xác định hoặc log chưa có entry tray
        watchdog_log "ARO tray state unknown ('${tray_state}') — monitoring"
        ;;
    esac
```

---

### 3.9 Sửa `get_disconnected_since_minutes()` — dùng tray Online timestamp thay API

Hàm này trong v3.3.0 tìm timestamp của `get_node_stat "connected"`. Sửa lại để tìm timestamp của `tray icon synced to state=Online` — chính xác hơn:

```
Logic mới:
  - Grep tìm dòng "tray icon synced to state=Online" cuối cùng trong log
  - Extract timestamp từ đầu dòng: [2026-04-30 08:23:03.437]
    → format: \[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}
  - Tính (now - timestamp) / 60
  - Nếu không tìm thấy "Online" → dùng (now - last_restart) / 60
```

---

### 3.10 Thêm Telegram template mới: `send_notify_redsocks_restarted()`

Dùng khi `check_proxy_health()` phát hiện recv-Q overflow và tự restart thành công (không cần user can thiệp):

```
Template:
  🔄 [REDSOCKS RESTARTED] ${HOSTNAME}
  ──────────────────────
  🖥️ VPS: ${HOSTNAME}
  🔌 Proxy: ${PROXY_HOST}:${PROXY_PORT}
  ⚠️ Phát hiện: redsocks queue overflow
  ✓ Đã tự động restart thành công
  🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')
  
  Watchdog đang chờ ARO reconnect...
```

Đặt sau `send_notify_proxy_recovered()`.

---

### 3.11 Update `send_notify_aro_reconnected()` — thêm context redsocks_recovered

Tìm dòng:
```bash
local cause_label="Proxy OK, ARO restarted"
[[ "$context" == "proxy_recovered" ]] && cause_label="Proxy recovered + ARO restarted"
```

Thêm dòng:
```bash
[[ "$context" == "redsocks_recovered" ]] && cause_label="Redsocks hung → restarted → ARO reconnected"
[[ "$context" == "proxy_ok_aro_restarted" ]] && cause_label="Network OK, ARO app restarted"
```

---

## 4. Luồng xử lý đầy đủ v3.4.0

```
Mỗi CHECK_INTERVAL (30s):
│
├─ check_real_proxy [mỗi 5 phút — giữ nguyên]
│
├─ check_proxy_health [mỗi cycle]
│   1. systemctl active?       → NO  → restart redsocks
│   2. ss LISTEN on port?      → NO  → restart redsocks
│   3. recv-Q > 500 (hung)?    → YES → restart redsocks + send_notify_redsocks_restarted
│   → Tất cả pass: proxy infra OK
│   → Fail restart: skip cycle
│
└─ is_aro_running?
    ├─ NO → launch ARO (logic cũ)
    └─ YES
        ├─ is_log_fresh?
        │   ├─ YES → get_aro_tray_state()
        │   │   ├─ Online   → Healthy ✓ (reset counter nếu stable >2h)
        │   │   ├─ Offline  → Grace period check → nếu quá lâu: treat as stuck
        │   │   ├─ NoInternet >= 5m → handle_stuck_connecting()
        │   │   │   ├─ check_redsocks_functional() FAIL?
        │   │   │   │   → kill ARO → restart redsocks → poll 60s
        │   │   │   │   ├─ Redsocks ok → launch ARO → poll tray 5m
        │   │   │   │   │   ├─ Online → notify_aro_reconnected(redsocks_recovered) ✅
        │   │   │   │   │   └─ Timeout → notify_stuck_manual ⚠️
        │   │   │   │   └─ Redsocks dead → notify_proxy_dead 🚨
        │   │   │   │
        │   │   │   ├─ check_redsocks_functional() OK, check_real_proxy() FAIL?
        │   │   │   │   → kill ARO → notify_proxy_down (server offline) 🚨
        │   │   │   │
        │   │   │   └─ Cả 2 đều OK → restart ARO → poll tray 5m
        │   │   │       ├─ Online → notify_aro_reconnected(proxy_ok_aro_restarted) ✅
        │   │   │       └─ Timeout → notify_stuck_manual ⚠️
        │   │   │
        │   │   └─ Unknown → monitor
        │   │
        │   └─ NO (stale >10m) → logic cũ (check_disconnect_alert)
        │
        └─ Daily report @ DAILY_REPORT_HOUR
```

---

## 5. Checklist kiểm tra sau khi AG xong

```bash
# 1. Tray state detection hoạt động
LOG="/home/ubuntu/.local/share/com.aro.ARONetwork/logs/ARO Desktop.log"
grep "linux tray icon synced to state=" "$LOG" | tail -1 | grep -oP "state=\K[A-Za-z]+"
# → Phải ra: Online (hoặc NoInternet nếu đang stuck)

# 2. is_aro_connected() dùng tray state (không còn grep "connect":"connected")
grep -A 10 "is_aro_connected" aro-manager.sh | grep "tray\|Online"
# → Phải thấy reference đến tray state

# 3. recv-Q check có trong check_proxy_health
grep "recv_q\|REDSOCKS_QUEUE\|queue" aro-manager.sh | head -5
# → Phải có

# 4. check_redsocks_functional dùng sudo -u
grep -A 5 "check_redsocks_functional" aro-manager.sh | grep "EFFECTIVE_USER\|curl"
# → Phải thấy sudo -u EFFECTIVE_USER curl

# 5. Version bump
grep "SCRIPT_VERSION" aro-manager.sh | head -1
# → 3.4.0

# 6. Test thực tế — simulate redsocks hung:
# Không cần simulate, quan sát watchdog log sau khi deploy
sudo ./aro-manager.sh watchdog log
# → Không còn "Redsocks port 12345 not responding"
# → Sẽ thấy "ARO tray=Online — healthy" mỗi cycle
```

---

## 6. Ghi chú quan trọng cho AG

**Filename có space:** Log file là `"ARO Desktop.log"` — LUÔN quote và dùng `run_as_aro_user`. Không dùng `$(ls ...)` trực tiếp làm argument.

**`check_redsocks_functional()` phải chạy bằng `EFFECTIVE_USER`** (ubuntu), không phải root. Nếu chạy bằng root sẽ bypass iptables và luôn trả về pass — đây là lỗi của `check_real_proxy()` hiện tại.

**Không gọi `check_redsocks_functional()` trong `check_proxy_health()`** — hàm này chỉ dùng trong `handle_stuck_connecting()`. `check_proxy_health()` chỉ dùng recv-Q check (local, không tốn network).

**Grace period logic:** Sau khi launch ARO, `state=Offline` → `state=Online` diễn ra trong vài giây. Không trigger stuck khi trong CONNECTING_GRACE_SECS.

**`state=Online` + `get_node_stat "disconnected"`** là bình thường trong ~90 giây đầu sau khi ARO start. Watchdog track tray state (Online = healthy), không track API state cho mục đích stuck detection.

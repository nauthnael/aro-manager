# BRIEF: Fix report/status sai trạng thái + Last online sai — v3.4.1

**File cần sửa:** `aro-manager.sh`  
**Version hiện tại:** `3.4.0` → bump lên `3.4.1`  
**Ngày:** 2026-04-30  
**Scope:** 3 bug fixes, không thay đổi watchdog logic

---

## Bug #1 — CRITICAL: Report và Status hiển thị sai khi ARO đang "Connecting..."

### Nguyên nhân

`send_daily_report()` và `do_status()` đều dùng `${CONNECT_STATUS}` — biến này lấy từ `parse_node_info()`, đọc `"connect":"connected/disconnected"` trong API response của ARO log.

Đã xác nhận thực tế: khi ARO hiển thị "Connecting..." (tray=NoInternet), API vẫn trả về `"connect":"connected"` (server-side cached state). Report gửi về Telegram và lệnh `status` đều hiển thị "connected" — **sai hoàn toàn**.

### Fix — Thêm `TRAY_STATUS` vào `parse_node_info()`

**Tìm phần global variables (~line 704)**, thêm sau các biến hiện có:

```bash
TRAY_STATUS="unknown"   # Trạng thái thực của ARO app (từ tray state log)
```

**Tìm cuối hàm `parse_node_info()`**, thêm trước `return 0`:

```bash
    # Lấy tray state thực — đây là trạng thái thực của app, không phải API cache
    local ts
    ts=$(get_aro_tray_state 2>/dev/null || true)
    [[ -n "$ts" ]] && TRAY_STATUS="$ts" || TRAY_STATUS="unknown"
```

### Fix — Sửa hiển thị trong `send_daily_report()`

**Tìm dòng:**
```bash
🟢 Status: ${CONNECT_STATUS}
```

**Thay bằng:**
```bash
$(  case "$TRAY_STATUS" in
      Online)      echo "🟢 Status: Online (connected)" ;;
      NoInternet)  echo "🔴 Status: NoInternet (connecting...)" ;;
      Offline)     echo "🟡 Status: Offline" ;;
      *)           echo "❓ Status: ${CONNECT_STATUS} (api)" ;;
    esac
)
```

Vì heredoc/variable trong message string phức tạp, cách đơn giản hơn là tạo biến local trước:

```bash
# Thêm TRƯỚC local msg= trong send_daily_report():
local tray_display
case "$TRAY_STATUS" in
    Online)     tray_display="🟢 Online (connected)" ;;
    NoInternet) tray_display="🔴 NoInternet (connecting...)" ;;
    Offline)    tray_display="🟡 Offline" ;;
    *)          tray_display="❓ ${CONNECT_STATUS:-unknown}" ;;
esac

# Sau đó trong msg, thay:
🟢 Status: ${CONNECT_STATUS}
# Thành:
📡 Status: ${tray_display}
```

### Fix — Sửa hiển thị trong `do_status()`

**Tìm dòng:**
```bash
echo "  Status:  $CONNECT_STATUS"
```

**Thay bằng:**
```bash
local _tray_display
case "$TRAY_STATUS" in
    Online)     _tray_display="🟢 Online" ;;
    NoInternet) _tray_display="🔴 NoInternet (connecting...)" ;;
    Offline)    _tray_display="🟡 Offline" ;;
    *)          _tray_display="❓ ${CONNECT_STATUS:-unknown} (api)" ;;
esac
echo "  Status:  $_tray_display"
```

---

## Bug #2 — HIGH: `get_last_online_info()` tính thời gian sai

### Nguyên nhân 1 — Dùng API response thay vì tray state

Hàm hiện dùng `grep '"connect":"connected"'` để tìm thời điểm ARO connected. Như đã phân tích, API có thể báo "connected" khi thực ra đang NoInternet.

### Nguyên nhân 2 — "Online since" tính sai session

Logic hiện tại: lấy entry `"connect":"connected"` **đầu tiên** trong 500 dòng log làm "Online since". 500 dòng có thể trải qua nhiều lần restart — session start tìm được có thể là của lần trước, báo thời gian online ảo quá dài.

### Fix — Rewrite `get_last_online_info()` dùng tray state

**Thay toàn bộ nội dung hàm `get_last_online_info()`:**

```
Logic mới:

1. Init defaults: LAST_ONLINE_LABEL="❓ No connection history", LAST_ONLINE_AGO=""

2. Kiểm tra LATEST_LOG_FILE tồn tại (giữ nguyên)

3. Lấy tray_state hiện tại = get_aro_tray_state()

4. Tìm timestamp của dòng "Net init" gần nhất (startup hiện tại):
   grep "Net init" trong tail -n 1000 của log → lấy dòng cuối → extract timestamp
   → Đây là thời điểm ARO start lần này

5. Nếu tray_state = "Online":
   → Tìm dòng "linux tray icon synced to state=Online" ĐẦU TIÊN
     SAU timestamp "Net init" hiện tại
   → Nếu tìm được: LAST_ONLINE_LABEL="🟢 Online since"
                    LAST_ONLINE_AGO = format_time_ago(now - timestamp_online)
   → Nếu không tìm được: LAST_ONLINE_LABEL="🟢 Currently online"
                          LAST_ONLINE_AGO=""

6. Nếu tray_state = "NoInternet" hoặc "Offline":
   → Tìm dòng "linux tray icon synced to state=Online" cuối cùng trong log
   → Nếu tìm được: LAST_ONLINE_LABEL="🔴 Last online"
                    LAST_ONLINE_AGO = format_time_ago(now - timestamp_last_online)
   → Nếu không tìm được: LAST_ONLINE_LABEL="❓ Never connected in recent log"
                          LAST_ONLINE_AGO=""

7. Nếu tray_state unknown:
   → Fallback về cách cũ (grep "connect":"connected") nhưng chỉ trong 200 dòng cuối
```

**Grep commands AG cần dùng:**

```bash
# Tìm timestamp Net init gần nhất (startup hiện tại)
run_as_aro_user grep "Net init" "$LATEST_LOG_FILE" 2>/dev/null \
    | tail -1 \
    | grep -oP '\[\K\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || true

# Tìm tất cả dòng tray=Online sau một timestamp cụ thể
# (lọc theo so sánh string timestamp — ISO format nên so sánh được)
run_as_aro_user grep "linux tray icon synced to state=Online" "$LATEST_LOG_FILE" 2>/dev/null \
    | awk -v cutoff="$net_init_ts" '$0 > cutoff' \
    | head -1    # đầu tiên sau Net init = lúc connected trong session này

# Tìm lần Online cuối cùng (khi đang disconnected)
run_as_aro_user grep "linux tray icon synced to state=Online" "$LATEST_LOG_FILE" 2>/dev/null \
    | tail -1
```

---

## Bug #3 — MEDIUM: `check_redsocks_functional()` timeout 10s, 1 endpoint

### Fix

**Tìm hàm `check_redsocks_functional()`**, sửa lại:

```
Logic mới:
  - Thử lần lượt 3 endpoints: ifconfig.me, api.ipify.org, icanhazip.com
  - Mỗi endpoint: --max-time 5 (không phải 10)
  - Nếu bất kỳ endpoint nào trả về IP hợp lệ → return 0
  - Nếu tất cả fail → return 1

Lưu ý: Dùng sudo -u "$EFFECTIVE_USER" curl (không phải root)
```

---

## Checklist kiểm tra sau khi fix

```bash
# 1. Khi ARO đang connected bình thường — report/status phải hiện "Online"
sudo ./aro-manager.sh status | grep Status
# → "🟢 Online"

sudo ./aro-manager.sh report
# → Telegram: "📡 Status: 🟢 Online (connected)"

# 2. Khi ARO đang connecting (kill redsocks để test)
sudo systemctl stop redsocks-aro
sudo -u ubuntu /usr/local/bin/aro-launch &
sleep 10
sudo ./aro-manager.sh status | grep Status
# → "🔴 NoInternet (connecting...)"
sudo systemctl start redsocks-aro   # restore

# 3. Last online time hợp lý
sudo ./aro-manager.sh status | grep -i "online"
# → "🟢 Online since X minutes" (tính từ lần start gần nhất, không phải session cũ)

# 4. check_redsocks_functional timeout 5s
time (sudo -u ubuntu curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
# → Phải complete trong 5s

# 5. Version
grep SCRIPT_VERSION aro-manager.sh | head -1
# → 3.4.1
```

---

## Lưu ý cho AG

- `get_aro_tray_state()` đã được implement đúng trong v3.4.0 — chỉ cần gọi nó, không sửa
- `TRAY_STATUS` là biến global mới, cần khai báo ở phần global variables và set trong `parse_node_info()`
- `parse_node_info()` được gọi trước `get_last_online_info()` trong cả `send_daily_report()` và `do_status()` — thứ tự này đúng, giữ nguyên
- Không sửa `CONNECT_STATUS` — vẫn giữ để backward compat, chỉ thêm `TRAY_STATUS` song song

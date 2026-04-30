# BRIEF: Thêm command `update` vào aro-manager.sh

**File cần sửa:** `aro-manager.sh`  
**Script version hiện tại:** `3.3.0` → bump lên `3.3.1`  
**Ngày:** 2026-04-30  
**Scope:** Chỉ thêm 1 command mới — không đụng vào logic hiện tại

---

## Bối cảnh

Hiện tại khi có bản script mới, user phải tự tay stop service, copy file, reload daemon, restart từng service theo đúng thứ tự. Nếu làm sai thứ tự có thể ARO chạy không qua proxy (IP leak). Cần 1 lệnh duy nhất làm tất cả an toàn.

---

## Yêu cầu

Thêm command `sudo ./aro-manager.sh update` với các chức năng:

1. Rebuild `/usr/local/bin/aro-launch` (wrapper) — áp dụng mọi thay đổi mới nhất trong `create_wrapper_script()`
2. Rebuild watchdog systemd service file — sync với `SCRIPT_DIR` hiện tại
3. Restart services đúng thứ tự: redsocks trước, watchdog sau
4. Verify kết quả và in báo cáo rõ ràng

---

## 3 chỗ cần thêm code

### Chỗ 1 — Hàm `do_update()` mới

Đặt ngay trước comment section `# HELP & USAGE` (tìm dòng `show_usage() {`).

**Logic theo thứ tự:**

```
require_root
show_banner

Kiểm tra đã install chưa:
  → Nếu PROXY_CONF_FILE không tồn tại: log_error + exit 1

load_configs
detect_desktop_user

── Path check ──
Đọc ExecStart từ SYSTEMD_WATCHDOG_SERVICE:
  service_exec = dòng "ExecStart=..." → lấy phần đầu tiên (path đến script)
  current_script = "$SCRIPT_DIR/$SCRIPT_NAME"

Nếu service_exec != current_script (và service_exec không rỗng):
  → In cảnh báo: service đang dùng path khác
  → Hỏi user: "Copy script này sang đúng vị trí? [Y/n]"
  → Nếu Y: cp current_script → service_exec, chmod +x
  → Nếu N: log_warn và tiếp tục (user biết mình đang làm gì)

── Stop services ──
log_info "Step 1/5: Stopping watchdog..."
systemctl stop aro-watchdog
sleep 2

log_info "Step 2/5: Stopping ARO process..."
pkill -u "$EFFECTIVE_USER" -x ARO 2>/dev/null || true
sleep 2

── Rebuild ──
log_info "Step 3/5: Rebuilding launch wrapper..."
create_wrapper_script()          ← hàm đã có sẵn trong script

log_info "Step 4/5: Rebuilding watchdog service..."
create_watchdog_service()        ← hàm đã có sẵn trong script
systemctl daemon-reload

── Restart ──
log_info "Step 5/5: Starting services..."

Nếu redsocks-aro không active:
  → systemctl start redsocks-aro + sleep 3

systemctl start aro-watchdog
sleep 3

── Verify & report ──
In bảng kết quả:
  redsocks-aro active?   → ✓ Running / ✗ FAILED
  aro-watchdog active?   → ✓ Running / ✗ FAILED
  wrapper dùng ss check? → grep "ss -tlnp" $WRAPPER_SCRIPT
                           ✓ Updated / ⚠ nc check còn đó (cần check lại AG)
  Script version + path  → ✓ $SCRIPT_VERSION @ $current_script

Nếu redsocks và watchdog đều OK:
  → log_success "Update complete. Watchdog sẽ tự restart ARO trong vài giây."
  → In hướng dẫn: "sudo $SCRIPT_NAME watchdog log"

Nếu có service fail:
  → log_error
  → In gợi ý debug: journalctl -u aro-watchdog -n 30
  → exit 1
```

---

### Chỗ 2 — Thêm case vào `main()` 

Tìm đoạn này trong `main()`:

```bash
        uninstall)
            do_uninstall
```

Thêm ngay phía TRÊN đoạn đó:

```bash
        update)
            do_update
            SHOW_FOOTER_ON_EXIT=1
            ;;

```

---

### Chỗ 3 — Thêm vào `show_usage()`

Tìm dòng này trong `show_usage()`:

```
  status              Show complete status (proxy + watchdog + ARO)
```

Thêm dòng mới ngay sau:

```
  update              Cập nhật script: rebuild wrapper + restart services
```

---

## Verify sau khi AG xong

Chạy các lệnh này để kiểm tra:

```bash
# 1. Help phải hiện dòng update
sudo ./aro-manager.sh help | grep update

# 2. Chạy update thực tế
sudo ./aro-manager.sh update

# 3. Wrapper phải dùng ss, không còn nc
grep "ss -tlnp\|nc -z" /usr/local/bin/aro-launch

# 4. Watchdog phải tự restart ARO trong 60s
sudo ./aro-manager.sh watchdog log
# → Phải thấy: "ARO not running, starting..." (không còn "Redsocks port not responding")
```

---

## Lưu ý

- **Không đụng vào** `create_wrapper_script()` hay `create_watchdog_service()` — chỉ gọi chúng, không sửa nội dung (các fix nc→ss đã được thực hiện ở brief trước v3.3.0)
- Hàm `do_update()` chỉ orchestrate, không tự viết lại logic của các hàm khác
- Thứ tự stop/start **bắt buộc**: redsocks phải running trước khi watchdog start (kill-switch cần redsocks)

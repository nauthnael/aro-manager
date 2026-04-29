# Brief for Antigravity — ARO Manager Script Analysis

## Mục tiêu
Đọc toàn bộ file `aro-manager.sh` và phân tích để nắm vững kiến trúc, các thành phần chức năng, và các điểm cần lưu ý trước khi thực hiện bất kỳ thay đổi nào.

---

## File cần đọc

- **`aro-manager.sh`** (file chính, ~2100 dòng) — trong cùng thư mục với brief này.

---

## Yêu cầu phân tích

Sau khi đọc xong, AG cần trả lời đầy đủ các mục sau:

### 1. Tổng quan script
- Script làm gì? Chạy trên nền tảng nào?
- Version hiện tại là bao nhiêu?
- Script yêu cầu quyền gì để chạy?

### 2. Danh sách tất cả lệnh (commands)
Liệt kê đầy đủ tất cả lệnh người dùng có thể gọi từ CLI, kèm mô tả ngắn từng lệnh.

Format:
```
<command>         — <mô tả ngắn>
```

### 3. Kiến trúc các thành phần chính
Mô tả từng nhóm chức năng lớn trong script:
- **Proxy layer** (redsocks, iptables, kill-switch): hoạt động như thế nào?
- **Watchdog loop**: chu kỳ kiểm tra ra sao, khi nào restart ARO?
- **Environment detection**: detect_desktop_user() phân nhánh thế nào?
- **Telegram notifications**: các loại thông báo nào đang có?
- **ARO app management**: cài đặt và launch ARO như thế nào?
- **Config system**: config được lưu ở đâu, load thế nào?

### 4. Các biến global quan trọng
Liệt kê các biến global cốt lõi (không phải tất cả), chú thích ý nghĩa và giá trị mặc định.

### 5. Luồng thực thi `full-install`
Mô tả step-by-step toàn bộ luồng khi chạy lệnh `full-install`, từ Phase 1 đến Phase 5.

### 6. Luồng watchdog loop
Mô tả logic vòng lặp `watchdog_loop()`:
- Kiểm tra real proxy (check_real_proxy) theo chu kỳ nào?
- Kiểm tra redsocks service (check_proxy_health) theo chu kỳ nào?
- Khi nào thì restart ARO?
- Backoff strategy là gì?
- Daily report gửi lúc nào?

### 7. Environment detection
Giải thích cách script phân biệt môi trường:
- LXC + TigerVNC (`lxc_vnc`) → xử lý thế nào?
- Chrome Remote Desktop (`crd`) → xử lý thế nào?
- Biến `DISPLAY_NUM` và `XAUTHORITY_PATH` được set như thế nào trong mỗi trường hợp?

### 8. Các điểm kỹ thuật cần chú ý
Liệt kê các "gotcha" hoặc quy ước kỹ thuật mà AG phải tuân theo khi chỉnh sửa script:
- `set -euo pipefail` ảnh hưởng gì? Cần xử lý thế nào?
- Cách dùng `|| true` và `{ cmd || true; } | next` để tránh abort?
- Cách dùng `run_as_aro_user()` để chạy lệnh đúng user?
- Quy tắc bump version khi sửa code?

### 9. Các file và path quan trọng
Liệt kê tất cả path file quan trọng: config, log, service, binary, wrapper.

### 10. Những gì KHÔNG nên thay đổi
Ghi chú các phần code nhạy cảm hoặc đã được fix bug cẩn thận mà AG cần cẩn thận khi chỉnh sửa.

---

## Output mong đợi

AG trả lời dưới dạng **báo cáo phân tích rõ ràng**, đủ 10 mục trên. Không cần viết lại code. Chỉ cần phân tích và mô tả chính xác những gì đang có trong script.

Khi AG đã hoàn tất phân tích và manager (Claude) đã review xong → AG mới được phép nhận task coding tiếp theo.

---

*Brief soạn bởi: Manager (Claude) — dự án ARO Manager v2.3.0*

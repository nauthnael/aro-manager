# Brief for Antigravity — Fix set -e bug + Push to GitHub (v2.4.0)

## Tổng quan
Có 1 bug trong code v2.4.0 vừa viết, cần sửa trước khi push lên GitHub. File cần chỉnh sửa duy nhất là `aro-manager.sh`.

---

## Bug cần sửa — XAUTHORITY fallback trong `detect_vnc_user()`

### Vấn đề
Dòng hiện tại:
```bash
[[ -z "$XAUTHORITY_PATH" ]] || [[ ! -f "$XAUTHORITY_PATH" ]] && \
    XAUTHORITY_PATH="$EFFECTIVE_HOME/.Xauthority"
```

Script dùng `set -euo pipefail`. Khi XAUTHORITY được detect đúng và file tồn tại, cả 2 điều kiện đều trả về `false` → toàn bộ expression exit code = 1 → bash abort script ngay tại đây do `set -e`. Script chết không báo lỗi.

### Fix — đổi sang dạng `if/fi` (an toàn với `set -e`)
Thay dòng trên bằng:
```bash
if [[ -z "$XAUTHORITY_PATH" ]] || [[ ! -f "$XAUTHORITY_PATH" ]]; then
    XAUTHORITY_PATH="$EFFECTIVE_HOME/.Xauthority"
fi
```

Không thay đổi gì khác trong function này.

---

## Quy tắc bắt buộc
- **Không bump version** — v2.4.0 giữ nguyên, chỉ sửa 1 dòng logic.
- **Không thay đổi** bất kỳ function hay logic nào khác ngoài đoạn trên.

---

## Sau khi sửa xong — Push lên GitHub

Chạy lần lượt:
```bash
bash -n aro-manager.sh && echo "SYNTAX OK"
```
Nếu SYNTAX OK → push lên GitHub repo: `https://github.com/nauthnael/aro-manager`

---

*Brief soạn bởi: Manager (Claude) — dự án ARO Manager, ngày 2026-04-29*

# BRIEF FOR ANTIGRAVITY — Hotfix: Wrapper REDSOCKS_PORT Empty (v3.4.7 → v3.4.8)

## Mức độ: CRITICAL — ARO bị block launch trên TẤT CẢ máy

## Root Cause

Wrapper log trên tất cả máy CT hiện tại:
```
CRITICAL: Redsocks port  not in LISTEN state!
ARO launch BLOCKED (kill-switch active)
```

Chú ý `Redsocks port ` — **port là empty string**, không có số.

**Nguyên nhân**: Brief BRIEF_AG_FIX_CRITICAL_V341 yêu cầu fix Bug 3 bằng Phương án A — đổi heredoc từ `<< 'EOF'` thành `<< EOF` để `$REDSOCKS_PORT` được expand. AG đã implement đúng, nhưng **expand xảy ra tại thời điểm `create_wrapper_script()` chạy** (lúc deploy/setup), không phải lúc wrapper chạy. Tại thời điểm đó, `REDSOCKS_PORT` chưa được load từ config file → expand ra empty string → wrapper được ghi với `REDSOCKS_PORT=` (trống).

Wrapper bị bake vào file với nội dung:
```bash
REDSOCKS_PORT=    # ← trống
...
if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
    # grep ": " → không match bất cứ gì → ARO bị block mãi mãi
```

---

## Fix yêu cầu

### Bước 1 — Revert Phương án A, implement Phương án B trong `create_wrapper_script()`

Trong hàm `create_wrapper_script()`, tìm đoạn heredoc tạo wrapper. Hiện tại dùng `<< EOF` (không quote), cần:

1. **Đổi lại thành `<< 'EOF'`** (có quote — no expansion)
2. **Thay dòng hardcode `REDSOCKS_PORT=...`** trong body wrapper bằng dòng đọc từ config lúc runtime:

```bash
# Thay dòng này trong body wrapper (dù là số cũ, empty, hay bất cứ gì):
REDSOCKS_PORT=...

# Bằng:
REDSOCKS_PORT=$(grep '^REDSOCKS_PORT=' /etc/aro-manager/proxy.conf 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"   # fallback nếu config không có
```

Sau fix, toàn bộ wrapper body dùng `<< 'EOF'` — không có biến nào bị expand lúc tạo file. Wrapper đọc port từ config lúc nó được execute — luôn đúng.

### Bước 2 — Tạo lại wrapper trên các máy đã bị lỗi

Sau khi fix code, cần có lệnh để apply wrapper mới mà **không cần deploy lại toàn bộ**. Thêm subcommand `fix-wrapper` vào main():

```bash
fix-wrapper)
    require_root
    load_configs
    detect_desktop_user
    log_info "Recreating wrapper script..."
    create_wrapper_script
    if verify_wrapper_script; then
        log_success "Wrapper fixed successfully at $WRAPPER_SCRIPT"
        log_info "You can now run: sudo ./aro-manager.sh start"
    else
        log_error "Wrapper fix failed — check logs"
        exit 1
    fi
    ;;
```

Thêm vào usage/help:
```
  fix-wrapper       Recreate the ARO launch wrapper script (use if ARO is blocked by wrapper error)
```

---

## Verify sau khi fix

Sau khi AG implement, kiểm tra:

```bash
# 1. Tạo lại wrapper
sudo ./aro-manager.sh fix-wrapper

# 2. Kiểm tra port trong wrapper đúng không
grep REDSOCKS_PORT /usr/local/bin/aro-launch

# Kết quả phải là:
# REDSOCKS_PORT=$(grep '^REDSOCKS_PORT=' /etc/aro-manager/proxy.conf ...
# KHÔNG phải: REDSOCKS_PORT=12345 (hardcode) hay REDSOCKS_PORT= (empty)

# 3. Chạy lại ARO
sudo ./aro-manager.sh start
```

---

## Version sau khi fix: `v3.4.8`

# BRIEF FOR ANTIGRAVITY — Fix Medium Priority Issues (v3.4.3 → v3.4.4)

## Mục tiêu
Fix 4 vấn đề medium priority: wrapper update verify yếu, thiếu rollback khi update, `_wait_for_aro_online` có thể nest, và tray state cache không có timestamp.

---

## Bug 1 — Wrapper update verification quá yếu (trong `do_update()` hoặc `setup`)

### Vấn đề
Sau khi tạo/update wrapper script, code chỉ check xem file có chứa string `"ss -tlnp"` không:

```bash
# Kiểu check hiện tại (từ audit):
if grep -q "ss -tlnp" "$WRAPPER_SCRIPT" 2>/dev/null; then
    echo "  ✓ Wrapper: Updated (ss check)"
else
    echo "  ⚠ Wrapper: Still using nc check"
fi
```

File có thể bị truncate, corrupt, hoặc thiếu phần exec mà vẫn pass check này.

### Fix yêu cầu
Thêm function `verify_wrapper_script()` kiểm tra đầy đủ:

```bash
verify_wrapper_script() {
    local wrapper="$WRAPPER_SCRIPT"
    
    # 1. File tồn tại và executable
    if [[ ! -x "$wrapper" ]]; then
        log_error "Wrapper not found or not executable: $wrapper"
        return 1
    fi
    
    # 2. Shebang hợp lệ
    if ! head -1 "$wrapper" | grep -q "^#!/"; then
        log_error "Wrapper missing shebang"
        return 1
    fi
    
    # 3. Các thành phần bắt buộc có mặt
    local checks=("redsocks-aro" "ss -tlnp" "REDSOCKS_PORT" "REAL_ARO" 'exec "$REAL_ARO"')
    for check in "${checks[@]}"; do
        if ! grep -q "$check" "$wrapper" 2>/dev/null; then
            log_error "Wrapper missing required component: $check"
            return 1
        fi
    done
    
    # 4. Bash syntax check
    if ! bash -n "$wrapper" 2>/dev/null; then
        log_error "Wrapper has syntax errors"
        return 1
    fi
    
    log_success "Wrapper verified OK: $wrapper"
    return 0
}
```

Gọi `verify_wrapper_script` sau `create_wrapper_script` trong `setup_proxy_config()` / `do_deploy()`.

---

## Bug 2 — Không có rollback khi update/redeploy làm hỏng wrapper

### Vấn đề
`create_wrapper_script()` ghi đè trực tiếp lên `$WRAPPER_SCRIPT` (line 650: `cat > "$WRAPPER_SCRIPT"`). Nếu quá trình bị interrupt giữa chừng hoặc heredoc bị broken, wrapper cũ bị mất không thể phục hồi. ARO sẽ bị block launch cho đến khi can thiệp thủ công.

### Fix yêu cầu
Thêm backup-before-overwrite trong `create_wrapper_script()`:

```bash
create_wrapper_script() {
    log_info "Creating ARO launch wrapper with proxy checks..."
    
    # Backup existing wrapper nếu có
    if [[ -f "$WRAPPER_SCRIPT" ]]; then
        local backup="${WRAPPER_SCRIPT}.bak"
        cp "$WRAPPER_SCRIPT" "$backup"
        log_info "Backed up existing wrapper to $backup"
    fi
    
    # Ghi ra file tạm trước
    local tmp_wrapper="${WRAPPER_SCRIPT}.new"
    cat > "$tmp_wrapper" << 'EOF'
    ... (nội dung wrapper giữ nguyên)
EOF
    
    chmod +x "$tmp_wrapper"
    
    # Verify file tạm trước khi replace
    if bash -n "$tmp_wrapper" 2>/dev/null && grep -q 'exec "$REAL_ARO"' "$tmp_wrapper"; then
        mv "$tmp_wrapper" "$WRAPPER_SCRIPT"
        log_success "Wrapper created at $WRAPPER_SCRIPT"
    else
        rm -f "$tmp_wrapper"
        log_error "New wrapper failed verification — keeping existing wrapper"
        return 1
    fi
}
```

Ngoài ra, thêm lệnh `rollback-wrapper` trong main command dispatch để user có thể restore bằng tay:

```bash
"rollback-wrapper")
    if [[ -f "${WRAPPER_SCRIPT}.bak" ]]; then
        cp "${WRAPPER_SCRIPT}.bak" "$WRAPPER_SCRIPT"
        chmod +x "$WRAPPER_SCRIPT"
        log_success "Wrapper rolled back from backup"
    else
        log_error "No backup found at ${WRAPPER_SCRIPT}.bak"
    fi
    ;;
```

---

## Bug 3 — `_wait_for_aro_online()` có thể bị gọi lồng nhau (line 1464, 1493)

### Vấn đề
`handle_stuck_connecting()` được gọi từ `watchdog_loop()`. Bên trong `handle_stuck_connecting()`, sau khi restart ARO, gọi `_wait_for_aro_online()`. Trong thời gian `_wait_for_aro_online()` đang chờ (có thể đến `CONNECTING_WAIT_SECS` giây), nếu watchdog loop tiếp tục (do signal hoặc background process), có thể gọi lại `handle_stuck_connecting()` → `_wait_for_aro_online()` lần nữa.

Thực tế nguy cơ là thấp vì bash là single-threaded, nhưng `_wait_for_aro_online()` không có guard. Nếu bị gọi từ `_wait_for_aro_online()` timeout branch mà chưa return, sẽ có 2 vòng poll chạy song song nếu có background job.

### Fix yêu cầu
Thêm flag guard trong `_wait_for_aro_online()`:

```bash
_WAIT_FOR_ARO_ONLINE_RUNNING=false

_wait_for_aro_online() {
    local context="${1:-unknown}"
    
    # Guard: không cho chạy lồng nhau
    if [[ "$_WAIT_FOR_ARO_ONLINE_RUNNING" == "true" ]]; then
        watchdog_log "WARNING: _wait_for_aro_online already running (context: $context) — skipping"
        return 0
    fi
    _WAIT_FOR_ARO_ONLINE_RUNNING=true
    
    # ... (logic hiện tại giữ nguyên)
    
    # Cleanup khi xong (cả success và timeout path)
    _WAIT_FOR_ARO_ONLINE_RUNNING=false
}
```

Đặt `_WAIT_FOR_ARO_ONLINE_RUNNING=false` ở phần global variables (gần line 105).

---

## Bug 4 — Tray state cache không có timestamp (line 861)

### Vấn đề
`TRAY_STATUS` là global được set một lần qua `parse_node_info()`. Watchdog dùng `get_aro_tray_state()` trực tiếp trong loop (line 1617), nhưng một số chỗ khác (ví dụ trong `do_status`) dùng `$TRAY_STATUS` global — không biết giá trị này cũ bao nhiêu.

Nếu `parse_node_info()` không được gọi trong cycle đó, `TRAY_STATUS` có thể là giá trị từ cycle trước.

### Fix yêu cầu
Thêm timestamp cho cache:

```bash
# Thêm vào global variables section:
TRAY_STATUS=""
TRAY_STATUS_TS=0   # epoch khi TRAY_STATUS được set

# Trong parse_node_info() sau khi set TRAY_STATUS:
TRAY_STATUS="$ts"
TRAY_STATUS_TS=$(date +%s)

# Thêm helper function:
get_tray_status_age() {
    local now; now=$(date +%s)
    echo $(( now - TRAY_STATUS_TS ))
}

is_tray_status_stale() {
    local max_age="${1:-120}"  # default: stale nếu > 2 phút
    [[ $(get_tray_status_age) -gt $max_age ]]
}
```

Trong `do_status()`, nếu `is_tray_status_stale 120` thì re-parse trước khi hiển thị:

```bash
# Trong do_status(), trước khi print tray state:
if is_tray_status_stale 120; then
    LATEST_LOG_FILE=$(get_latest_aro_log)
    parse_node_info
fi
```

---

## Kết quả sau khi fix
- Wrapper được verify đầy đủ sau mỗi lần tạo/update
- Wrapper cũ được backup trước khi ghi đè, có thể rollback bằng lệnh
- `_wait_for_aro_online` không thể chạy lồng nhau
- `do_status` luôn hiển thị tray state mới nhất, không dùng cache cũ

## Version sau khi fix: `v3.4.4`

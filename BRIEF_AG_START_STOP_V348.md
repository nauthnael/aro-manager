# BRIEF FOR ANTIGRAVITY — New Feature: start / stop / restart + Maintenance Mode (v3.4.8 → v3.4.9)

## Mục tiêu
Thêm 3 lệnh mới để user control ARO trực tiếp: `start`, `stop`, `restart`.
Kết hợp với **maintenance mode** — cơ chế báo watchdog "user chủ động dừng ARO, đừng tự restart".

---

## Thiết kế Maintenance Mode

### Flag file
```
/tmp/aro_maintenance
```
- File **tồn tại** → watchdog biết user đã dừng ARO chủ động → skip mọi restart
- File **không tồn tại** → watchdog hoạt động bình thường
- File tự **expire sau 60 phút** (dùng mtime để check) → tránh user quên, ARO không chạy cả ngày

### Constants — thêm vào globals section (gần STATE_FILE, line ~46)
```bash
MAINTENANCE_FLAG="/tmp/aro_maintenance"
MAINTENANCE_EXPIRE_MINS=60    # Tự hết hạn sau 60 phút
```

### Helper functions — thêm gần các helper state function
```bash
# Set maintenance mode (tạo flag file)
maintenance_set() {
    touch "$MAINTENANCE_FLAG"
    watchdog_log "Maintenance mode ENABLED by user"
}

# Clear maintenance mode (xóa flag file)
maintenance_clear() {
    rm -f "$MAINTENANCE_FLAG"
    watchdog_log "Maintenance mode CLEARED"
}

# Check có đang trong maintenance mode không (kể cả check expire)
is_maintenance_mode() {
    [[ ! -f "$MAINTENANCE_FLAG" ]] && return 1   # không có flag → không maintenance
    
    # Kiểm tra expiry: nếu file cũ hơn MAINTENANCE_EXPIRE_MINS → tự expire
    if find "$MAINTENANCE_FLAG" -mmin +"$MAINTENANCE_EXPIRE_MINS" 2>/dev/null | grep -q .; then
        rm -f "$MAINTENANCE_FLAG"
        watchdog_log "Maintenance mode expired (>${MAINTENANCE_EXPIRE_MINS}m) — auto-cleared"
        return 1
    fi
    
    return 0
}

# Trả về số phút maintenance đã active
maintenance_age_mins() {
    if [[ -f "$MAINTENANCE_FLAG" ]]; then
        echo $(( ( $(date +%s) - $(stat -c %Y "$MAINTENANCE_FLAG" 2>/dev/null || echo 0) ) / 60 ))
    else
        echo "0"
    fi
}
```

---

## Sửa `watchdog_loop()` — thêm maintenance check

Trong `watchdog_loop()`, ngay sau dòng `local now; now=$(date +%s)` (đầu vòng while), thêm:

```bash
# ── Maintenance mode check ──────────────────────────────────
if is_maintenance_mode; then
    local maint_age; maint_age=$(maintenance_age_mins)
    watchdog_log "Maintenance mode active (${maint_age}m) — skipping ARO checks"
    sleep "$CHECK_INTERVAL"
    continue
fi
```

---

## 3 Functions mới: `do_aro_start()`, `do_aro_stop()`, `do_aro_restart()`

### `do_aro_stop()`
```bash
do_aro_stop() {
    require_root
    load_configs
    detect_desktop_user

    log_info "Stopping ARO and enabling maintenance mode..."

    # 1. Set maintenance mode TRƯỚC — để watchdog không restart ngay khi ARO bị kill
    maintenance_set

    # 2. Kill ARO
    if is_aro_running; then
        kill_aro
        log_success "ARO process stopped"
    else
        log_info "ARO was not running"
    fi

    # 3. Warn nếu watchdog đang chạy
    if systemctl is-active --quiet aro-watchdog; then
        log_warn "Watchdog is still running but will NOT restart ARO (maintenance mode active)"
        log_warn "Maintenance mode auto-expires in ${MAINTENANCE_EXPIRE_MINS} minutes"
        log_info "To resume: sudo ./aro-manager.sh start"
    fi

    log_success "ARO stopped. Maintenance mode ON — watchdog paused."
}
```

### `do_aro_start()`
```bash
do_aro_start() {
    require_root
    load_configs
    detect_desktop_user

    log_info "Starting ARO..."

    # 1. Check proxy trước — nếu redsocks không chạy thì báo lỗi rõ ràng
    if ! systemctl is-active --quiet redsocks-aro; then
        log_error "Redsocks proxy is NOT running — cannot start ARO safely (kill-switch active)"
        log_error "Fix: sudo systemctl start redsocks-aro"
        exit 1
    fi

    if ! ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
        log_error "Redsocks port $REDSOCKS_PORT is not listening — proxy not ready"
        log_error "Fix: sudo systemctl restart redsocks-aro"
        exit 1
    fi

    # 2. Clear maintenance mode
    if is_maintenance_mode; then
        log_info "Clearing maintenance mode..."
        maintenance_clear
    fi

    # 3. Nếu ARO đã đang chạy thì báo và thoát
    if is_aro_running; then
        local pid; pid=$(get_aro_pid)
        log_info "ARO is already running (PID: $pid)"
        return 0
    fi

    # 4. Nếu watchdog đang stop → start lại watchdog (watchdog sẽ tự launch ARO)
    if ! systemctl is-active --quiet aro-watchdog; then
        log_info "Watchdog is not running — starting watchdog (it will launch ARO)..."
        systemctl start aro-watchdog
        sleep 3
        if systemctl is-active --quiet aro-watchdog; then
            log_success "Watchdog started — ARO will launch within ${CHECK_INTERVAL}s"
        else
            log_error "Failed to start watchdog"
            exit 1
        fi
        return 0
    fi

    # 5. Watchdog đang chạy → launch ARO trực tiếp luôn (không đợi next cycle)
    log_info "Launching ARO directly..."
    LATEST_LOG_FILE=$(get_latest_aro_log)
    launch_aro
    state_set "last_restart" "$(date +%s)"
    state_set "stable_since" "$(date +%s)"

    # 6. Poll tối đa 30s cho ARO start
    log_info "Waiting for ARO to start (up to 30s)..."
    local wait_start; wait_start=$(date +%s)
    while true; do
        local elapsed=$(( $(date +%s) - wait_start ))
        if [[ $elapsed -ge 30 ]]; then
            break
        fi
        sleep 3
        if is_aro_running; then
            local pid; pid=$(get_aro_pid)
            log_success "ARO started successfully (PID: $pid)"
            return 0
        fi
        echo -n "."
    done
    echo ""

    # 7. Kiểm tra wrapper log để diagnose nếu thất bại
    if ! is_aro_running; then
        log_error "ARO failed to start after 30s"
        log_error "Check wrapper log for details:"
        tail -5 "$WRAPPER_LOG" 2>/dev/null | sed 's/^/  /' || true
        log_info "Run 'sudo ./aro-manager.sh debug' for full diagnosis"
        exit 1
    fi
}
```

### `do_aro_restart()`
```bash
do_aro_restart() {
    require_root
    load_configs
    detect_desktop_user

    log_info "Restarting ARO..."

    # Stop (set maintenance + kill)
    maintenance_set
    if is_aro_running; then
        kill_aro
        log_info "ARO stopped"
    fi

    sleep 3

    # Clear maintenance và start
    maintenance_clear
    do_aro_start
}
```

---

## Sửa `do_status()` — hiển thị maintenance mode

Trong `do_status()`, phần **🤖 Watchdog** (sau dòng hiện thị watchdog status), thêm:

```bash
# Maintenance mode indicator
if is_maintenance_mode; then
    local maint_age; maint_age=$(maintenance_age_mins)
    local maint_expire_remaining=$(( MAINTENANCE_EXPIRE_MINS - maint_age ))
    echo "  ⏸️  Maintenance: ACTIVE (set ${maint_age}m ago, auto-expires in ${maint_expire_remaining}m)"
    echo "       ARO will NOT auto-restart until: sudo ./aro-manager.sh start"
fi
```

---

## Sửa `_do_debug_inner()` — warn về maintenance mode

Trong section **3/6 ARO APPLICATION**, sau check `is_aro_running`, thêm:

```bash
# Maintenance mode check
if is_maintenance_mode; then
    local maint_age; maint_age=$(maintenance_age_mins)
    _warn "Maintenance mode is ACTIVE (${maint_age}m) — ARO intentionally stopped by user"
    _info "Run 'sudo ./aro-manager.sh start' to resume"
fi
```

Thêm vào Suggestions engine (section 6) — nếu ARO not running VÀ maintenance mode:
```bash
# Pattern: ARO not running + maintenance mode
if printf '%s\n' "${ISSUES[@]}" | grep -q "ARO process NOT running" && is_maintenance_mode; then
    echo "  💡 ARO is in maintenance mode → resume: sudo ./aro-manager.sh start"
    has_suggestions=true
fi
```

---

## Sửa `do_uninstall()` — cleanup maintenance flag

Trong `do_uninstall()`, phần "Remove state files", thêm:
```bash
rm -f "$MAINTENANCE_FLAG"
```

---

## Thêm vào `main()` — 3 case mới

Thêm vào case statement trong `main()`, SAU case `fix-wrapper)` và TRƯỚC case `proxy)`:

```bash
start)
    do_aro_start
    SHOW_FOOTER_ON_EXIT=1
    ;;

stop)
    do_aro_stop
    SHOW_FOOTER_ON_EXIT=1
    ;;

restart)
    do_aro_restart
    SHOW_FOOTER_ON_EXIT=1
    ;;
```

---

## Cập nhật `show_usage()` — thêm 3 lệnh mới

Trong `show_usage()`, sau dòng `status`, thêm:

```
  start               Start ARO manually (clears maintenance mode, starts watchdog if needed)
  stop                Stop ARO and pause watchdog auto-restart (maintenance mode ON)
  restart             Stop then start ARO
```

Thêm examples:
```
  # Stop ARO (watchdog paused — won't auto-restart)
  sudo bash $SCRIPT_NAME stop

  # Start ARO again (clears maintenance mode)
  sudo bash $SCRIPT_NAME start

  # Quick restart
  sudo bash $SCRIPT_NAME restart
```

---

## Tóm tắt flow

```
User: ./aro-manager.sh stop
  → touch /tmp/aro_maintenance
  → kill ARO process
  → watchdog thấy flag → skip mọi restart cycle

User: ./aro-manager.sh start
  → check redsocks OK
  → rm /tmp/aro_maintenance
  → nếu watchdog stop → systemctl start aro-watchdog
  → nếu watchdog running → launch_aro() trực tiếp
  → poll 30s → báo kết quả

Auto-expire sau 60 phút:
  → is_maintenance_mode() detect file cũ → tự xóa → watchdog resume bình thường
```

---

## Version sau khi implement: `v3.4.9`

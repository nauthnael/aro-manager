# BRIEF FOR ANTIGRAVITY — New Feature: `debug` Command (v3.4.6 → v3.4.7)

## Mục tiêu
Thêm command `debug` vào script. Khi chạy `sudo ./aro-manager.sh debug`, script sẽ:
1. Thu thập toàn bộ thông tin diagnostic về ARO, proxy, watchdog, network
2. Chạy auto-diagnosis để highlight vấn đề
3. Tự động save output ra file log có timestamp
4. In kết quả ra stdout đồng thời

---

## Cách tích hợp vào script

### 1. Thêm file log path vào globals (gần MAIN_LOG, line ~37)
```bash
DEBUG_LOG_DIR="$SCRIPT_DIR"   # Save debug log cùng folder với script
```

### 2. Thêm function `do_debug()` — đặt trước `do_status()` khoảng line ~2750

### 3. Thêm case vào `main()` (sau case `status)` khoảng line ~3390)
```bash
debug)
    do_debug
    SHOW_FOOTER_ON_EXIT=1
    ;;
```

### 4. Thêm vào usage/help text

---

## Implement function `do_debug()`

```bash
do_debug() {
    # ── Setup: tee output ra file log ──────────────────────────
    local debug_file="${DEBUG_LOG_DIR}/aro-debug-$(date +%Y%m%d-%H%M%S).log"
    
    # Redirect tất cả output của function này ra cả stdout lẫn file
    # Dùng subshell + tee để không ảnh hưởng phần còn lại của script
    {
        _do_debug_inner
    } 2>&1 | tee "$debug_file"
    
    echo ""
    echo "📁 Debug log saved to: $debug_file"
}
```

Toàn bộ logic nằm trong `_do_debug_inner()`:

```bash
_do_debug_inner() {
    load_configs
    detect_desktop_user
    LATEST_LOG_FILE=$(get_latest_aro_log)
    
    # Array để collect các issues phát hiện được (dùng cho Summary cuối)
    local -a ISSUES=()
    local -a WARNINGS=()
    local -a OKS=()
    
    # Helper để add issue/warning/ok và print inline
    _issue()   { ISSUES+=("$1");   echo "  ❌ ISSUE: $1"; }
    _warn()    { WARNINGS+=("$1"); echo "  ⚠️  WARN:  $1"; }
    _ok()      { OKS+=("$1");      echo "  ✅ OK:    $1"; }
    _info()    { echo "  ℹ️  $1"; }
    _section() { 
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  $1"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    }
    
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         ARO Manager - Debug Report v${SCRIPT_VERSION}              ║"
    echo "║         Generated: $(date '+%Y-%m-%d %H:%M:%S')                    ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"

    # ══════════════════════════════════════════════════════════════
    # SECTION 1: ENVIRONMENT
    # ══════════════════════════════════════════════════════════════
    _section "1/6 🔍 ENVIRONMENT"
    
    _info "Hostname:    $HOSTNAME"
    _info "OS:          $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -o)"
    _info "Kernel:      $(uname -r)"
    _info "Uptime:      $(uptime -p 2>/dev/null || uptime)"
    _info "Env type:    $ENV_TYPE"
    _info "User:        $EFFECTIVE_USER (home: $EFFECTIVE_HOME)"
    _info "Display:     $DISPLAY_NUM"
    _info "XAUTHORITY:  $XAUTHORITY_PATH"
    echo ""
    
    # RAM
    local mem_free_mb; mem_free_mb=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
    local mem_total_mb; mem_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
    _info "RAM:         ${mem_free_mb}MB free / ${mem_total_mb}MB total"
    if [[ "$mem_free_mb" =~ ^[0-9]+$ ]] && [[ "$mem_free_mb" -lt 200 ]]; then
        _warn "Low RAM: only ${mem_free_mb}MB available — ARO may crash"
    fi

    # Disk
    local disk_free; disk_free=$(df -h "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "?")
    _info "Disk free:   $disk_free (on $SCRIPT_DIR)"

    # DISPLAY accessible?
    if [[ -n "$DISPLAY_NUM" ]]; then
        if DISPLAY="$DISPLAY_NUM" XAUTHORITY="$XAUTHORITY_PATH" xdpyinfo >/dev/null 2>&1; then
            _ok "Display $DISPLAY_NUM is accessible"
        else
            _issue "Display $DISPLAY_NUM is NOT accessible (xdpyinfo failed)"
        fi
    else
        _issue "DISPLAY_NUM is empty — cannot launch GUI app"
    fi

    # User home exists?
    if [[ -d "$EFFECTIVE_HOME" ]]; then
        _ok "User home exists: $EFFECTIVE_HOME"
    else
        _issue "User home NOT found: $EFFECTIVE_HOME"
    fi

    # ══════════════════════════════════════════════════════════════
    # SECTION 2: PROXY / REDSOCKS
    # ══════════════════════════════════════════════════════════════
    _section "2/6 🛡️  PROXY / REDSOCKS"
    
    _info "Proxy server: $PROXY_HOST:$PROXY_PORT"
    _info "Redsocks port: $REDSOCKS_PORT"
    echo ""
    
    # Config file
    if [[ -f "$REDSOCKS_CONF_FILE" ]]; then
        _ok "Redsocks config exists: $REDSOCKS_CONF_FILE"
    else
        _issue "Redsocks config MISSING: $REDSOCKS_CONF_FILE"
    fi
    
    # Service status
    echo ""
    echo "  [systemctl status redsocks-aro]"
    systemctl status redsocks-aro --no-pager -l 2>&1 | head -15 | sed 's/^/    /'
    echo ""
    
    if systemctl is-active --quiet redsocks-aro; then
        _ok "redsocks-aro service is ACTIVE"
    else
        _issue "redsocks-aro service is NOT active"
        local exit_code; exit_code=$(systemctl show redsocks-aro --property=ExecMainStatus --value 2>/dev/null || echo "?")
        _info "Last exit code: $exit_code"
    fi
    
    # Port listening?
    if ss -tlnp 2>/dev/null | grep -q ":${REDSOCKS_PORT} "; then
        _ok "Port $REDSOCKS_PORT is LISTENING"
    else
        _issue "Port $REDSOCKS_PORT is NOT listening"
    fi
    
    # recv-Q (hung detection)
    local recv_q; recv_q=$(ss -tlnp 2>/dev/null | grep "127.0.0.1:${REDSOCKS_PORT} " | awk '{print $2}' || echo "0")
    recv_q="${recv_q:-0}"
    _info "Redsocks recv-Q: $recv_q (threshold: $REDSOCKS_QUEUE_THRESHOLD)"
    if [[ "$recv_q" =~ ^[0-9]+$ ]] && [[ "$recv_q" -gt "$REDSOCKS_QUEUE_THRESHOLD" ]]; then
        _issue "Redsocks recv-Q=$recv_q EXCEEDS threshold — service is hung/overloaded"
    fi

    # iptables rules
    local iptables_rule_count; iptables_rule_count=$(iptables -t nat -L ARO_PROXY 2>/dev/null | grep -c "^" || echo "0")
    if iptables -t nat -L ARO_PROXY >/dev/null 2>&1; then
        _ok "iptables ARO_PROXY chain exists ($iptables_rule_count rules)"
    else
        _issue "iptables ARO_PROXY chain MISSING — kill-switch not active"
    fi
    
    # IPv6 block
    if ip6tables -L OUTPUT 2>/dev/null | grep -q "REJECT"; then
        _ok "IPv6 OUTPUT blocked (kill-switch active)"
    else
        _warn "IPv6 OUTPUT not blocked — potential IP leak"
    fi
    
    # Recent redsocks journal
    echo ""
    echo "  [journalctl redsocks-aro — last 10 lines]"
    journalctl -u redsocks-aro -n 10 --no-pager 2>/dev/null | sed 's/^/    /' || echo "    (no journal entries)"

    # ══════════════════════════════════════════════════════════════
    # SECTION 3: ARO APPLICATION
    # ══════════════════════════════════════════════════════════════
    _section "3/6 🎮 ARO APPLICATION"
    
    # Binary
    if [[ -x "$ARO_BINARY" ]]; then
        _ok "ARO binary exists and executable: $ARO_BINARY"
    else
        _issue "ARO binary NOT found or not executable: $ARO_BINARY"
    fi
    
    # Wrapper
    if [[ -x "$WRAPPER_SCRIPT" ]]; then
        if bash -n "$WRAPPER_SCRIPT" 2>/dev/null; then
            _ok "Wrapper script valid: $WRAPPER_SCRIPT"
        else
            _issue "Wrapper script has SYNTAX ERRORS: $WRAPPER_SCRIPT"
        fi
    else
        _issue "Wrapper script NOT found or not executable: $WRAPPER_SCRIPT"
    fi
    
    # Process
    if is_aro_running; then
        local aro_pid; aro_pid=$(get_aro_pid)
        local aro_mem; aro_mem=$(ps -o rss= -p "$aro_pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo "?")
        local aro_cpu; aro_cpu=$(ps -o %cpu= -p "$aro_pid" 2>/dev/null | tr -d ' ' || echo "?")
        _ok "ARO process RUNNING (PID: $aro_pid, MEM: ${aro_mem}MB, CPU: ${aro_cpu}%)"
    else
        _issue "ARO process NOT running"
    fi
    
    # Tray state
    local tray; tray=$(get_aro_tray_state)
    _info "Tray state (from log): ${tray:-unknown}"
    if [[ "$tray" == "Online" ]]; then
        _ok "Tray state = Online"
    elif [[ -n "$tray" ]] && [[ "$tray" != "Online" ]]; then
        _warn "Tray state = $tray (not Online)"
    fi
    
    # Log directory
    if run_as_aro_user test -d "$ARO_LOG_DIR" 2>/dev/null; then
        local log_count; log_count=$(run_as_aro_user ls "$ARO_LOG_DIR"/*.log 2>/dev/null | wc -l || echo "0")
        _ok "ARO log directory exists ($log_count log files): $ARO_LOG_DIR"
    else
        _issue "ARO log directory NOT found: $ARO_LOG_DIR"
    fi
    
    # Log freshness
    if [[ -n "$LATEST_LOG_FILE" ]]; then
        _info "Latest log: $LATEST_LOG_FILE"
        if is_log_fresh; then
            _ok "Log is FRESH (updated within ${LOG_STALE_MINUTES}m)"
        else
            local log_age_min; log_age_min=$(( ( $(date +%s) - $(run_as_aro_user stat -c %Y "$LATEST_LOG_FILE" 2>/dev/null || echo 0) ) / 60 ))
            _warn "Log is STALE (last update: ${log_age_min}m ago, threshold: ${LOG_STALE_MINUTES}m)"
        fi
        
        # Tail 20 dòng cuối ARO log
        echo ""
        echo "  [ARO log — last 20 lines: $(basename "$LATEST_LOG_FILE")]"
        run_as_aro_user tail -n 20 "$LATEST_LOG_FILE" 2>/dev/null | sed 's/^/    /' || echo "    (cannot read log)"
    else
        _issue "No ARO log file found"
    fi
    
    # Wrapper log
    echo ""
    echo "  [Wrapper log — last 20 lines: $WRAPPER_LOG]"
    tail -n 20 "$WRAPPER_LOG" 2>/dev/null | sed 's/^/    /' || echo "    (wrapper log empty or not found)"

    # ══════════════════════════════════════════════════════════════
    # SECTION 4: WATCHDOG
    # ══════════════════════════════════════════════════════════════
    _section "4/6 🤖 WATCHDOG"
    
    # Service status
    echo "  [systemctl status aro-watchdog]"
    systemctl status aro-watchdog --no-pager -l 2>&1 | head -10 | sed 's/^/    /'
    echo ""
    
    if systemctl is-active --quiet aro-watchdog; then
        _ok "aro-watchdog service is ACTIVE"
    else
        _issue "aro-watchdog service is NOT active"
    fi
    
    # State file
    if [[ -f "$STATE_FILE" ]]; then
        _ok "State file exists: $STATE_FILE"
        echo ""
        echo "  [State file contents]"
        cat "$STATE_FILE" 2>/dev/null | sed 's/^/    /' || echo "    (cannot read)"
        echo ""
        
        # Parse key values từ state
        local retry_count; retry_count=$(state_get "retry_count" "0")
        local last_restart; last_restart=$(state_get "last_restart" "0")
        local stable_since; stable_since=$(state_get "stable_since" "0")
        
        _info "retry_count:  $retry_count / $MAX_RETRIES"
        
        if [[ "$last_restart" -gt 0 ]]; then
            local restart_ago=$(( ( $(date +%s) - last_restart ) / 60 ))
            _info "last_restart: ${restart_ago}m ago ($(date -d @"$last_restart" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown'))"
        else
            _info "last_restart: never"
        fi
        
        if [[ "$retry_count" -gt 0 ]]; then
            _warn "retry_count = $retry_count (watchdog has been restarting ARO)"
        fi
    else
        _warn "State file not found: $STATE_FILE (watchdog may not have started yet)"
    fi
    
    # Watchdog log
    echo ""
    echo "  [Watchdog log — last 20 lines: $WATCHDOG_LOG]"
    tail -n 20 "$WATCHDOG_LOG" 2>/dev/null | sed 's/^/    /' || echo "    (watchdog log empty or not found)"
    
    echo ""
    echo "  [journalctl aro-watchdog — last 10 lines]"
    journalctl -u aro-watchdog -n 10 --no-pager 2>/dev/null | sed 's/^/    /' || echo "    (no journal entries)"

    # ══════════════════════════════════════════════════════════════
    # SECTION 5: NETWORK LIVE TEST
    # ══════════════════════════════════════════════════════════════
    _section "5/6 🌐 NETWORK LIVE TEST"
    
    _info "Running live network tests as user '$EFFECTIVE_USER' (via transparent proxy)..."
    _info "This may take up to 30 seconds..."
    echo ""
    
    # Test 1: Kết nối thực tế qua transparent proxy (ubuntu user traffic)
    echo "  [Test 1: Transparent proxy connectivity]"
    local test_ip=""
    local test_ok=false
    for endpoint in ifconfig.me api.ipify.org icanhazip.com; do
        echo -n "    curl https://$endpoint ... "
        test_ip=$(sudo -u "$EFFECTIVE_USER" curl -s --max-time 8 "https://$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$test_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "✅ $test_ip"
            test_ok=true
            break
        else
            echo "❌ failed"
        fi
    done
    
    if $test_ok; then
        _ok "Transparent proxy working — exit IP: $test_ip"
        
        # Verify exit IP khớp với proxy server
        local proxy_ip; proxy_ip=$(getent hosts "$PROXY_HOST" 2>/dev/null | awk '{print $1}' | head -1 || echo "")
        if [[ -n "$proxy_ip" ]] && [[ "$test_ip" != "$proxy_ip" ]]; then
            _info "Note: Exit IP ($test_ip) differs from proxy host IP ($proxy_ip) — this is normal for shared proxies"
        fi
    else
        _issue "Transparent proxy NOT working — all endpoints failed"
    fi
    
    echo ""
    
    # Test 2: Kết nối trực tiếp đến proxy server (SOCKS5 target)
    echo "  [Test 2: SOCKS5 proxy server reachability]"
    echo -n "    Connecting to $PROXY_HOST:$PROXY_PORT ... "
    if timeout 8 bash -c "echo >/dev/tcp/$PROXY_HOST/$PROXY_PORT" 2>/dev/null; then
        echo "✅ reachable"
        _ok "Proxy server $PROXY_HOST:$PROXY_PORT is reachable"
    else
        echo "❌ unreachable"
        _issue "Proxy server $PROXY_HOST:$PROXY_PORT is NOT reachable (down or blocked)"
    fi
    
    echo ""
    
    # Test 3: DNS resolution
    echo "  [Test 3: DNS resolution]"
    echo -n "    Resolve $PROXY_HOST ... "
    local dns_result; dns_result=$(getent hosts "$PROXY_HOST" 2>/dev/null | awk '{print $1}' | head -1 || true)
    if [[ -n "$dns_result" ]]; then
        echo "✅ $dns_result"
        _ok "DNS resolves $PROXY_HOST → $dns_result"
    else
        echo "❌ failed"
        _issue "DNS cannot resolve $PROXY_HOST"
    fi
    
    echo ""
    
    # Test 4: IPv6 leak check
    echo "  [Test 4: IPv6 leak check (should fail)]"
    echo -n "    curl -6 https://ifconfig.me (as $EFFECTIVE_USER) ... "
    local ipv6_result; ipv6_result=$(sudo -u "$EFFECTIVE_USER" curl -6 -s --max-time 5 "https://ifconfig.me" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -z "$ipv6_result" ]]; then
        echo "✅ blocked (no IPv6 leak)"
        _ok "IPv6 leak test passed — no response (as expected)"
    else
        echo "❌ LEAKED: $ipv6_result"
        _issue "IPv6 LEAK detected: $ipv6_result — ip6tables rule may be missing"
    fi

    # ══════════════════════════════════════════════════════════════
    # SECTION 6: AUTO-DIAGNOSIS SUMMARY
    # ══════════════════════════════════════════════════════════════
    _section "6/6 📊 AUTO-DIAGNOSIS SUMMARY"
    
    local total_issues=${#ISSUES[@]}
    local total_warnings=${#WARNINGS[@]}
    local total_oks=${#OKS[@]}
    
    echo ""
    echo "  Results: ${total_oks} OK  |  ${total_warnings} warnings  |  ${total_issues} issues"
    echo ""
    
    if [[ $total_issues -gt 0 ]]; then
        echo "  ── Issues (action required) ──"
        for issue in "${ISSUES[@]}"; do
            echo "  ❌ $issue"
        done
        echo ""
    fi
    
    if [[ $total_warnings -gt 0 ]]; then
        echo "  ── Warnings ──"
        for warn in "${WARNINGS[@]}"; do
            echo "  ⚠️  $warn"
        done
        echo ""
    fi
    
    # Suggested fixes dựa trên pattern issues phát hiện được
    local has_suggestions=false
    
    echo "  ── Suggested fixes ──"
    
    # Pattern: redsocks hung
    if printf '%s\n' "${ISSUES[@]}" "${WARNINGS[@]}" | grep -q "recv-Q.*EXCEEDS\|hung"; then
        echo "  💡 Redsocks hung → restart: sudo systemctl restart redsocks-aro"
        has_suggestions=true
    fi
    
    # Pattern: redsocks not active
    if printf '%s\n' "${ISSUES[@]}" | grep -q "redsocks-aro service is NOT active"; then
        echo "  💡 Redsocks down → start: sudo systemctl start redsocks-aro"
        echo "  💡 Check logs: journalctl -u redsocks-aro -n 50"
        has_suggestions=true
    fi
    
    # Pattern: ARO not running
    if printf '%s\n' "${ISSUES[@]}" | grep -q "ARO process NOT running"; then
        echo "  💡 ARO not running → force start: sudo ./aro-manager.sh start"
        has_suggestions=true
    fi
    
    # Pattern: Display not accessible
    if printf '%s\n' "${ISSUES[@]}" | grep -q "Display.*NOT accessible"; then
        echo "  💡 Display issue → check VNC: systemctl status tigervnc@:1"
        echo "  💡 Or restart VNC: sudo systemctl restart tigervnc@:1"
        has_suggestions=true
    fi
    
    # Pattern: Transparent proxy not working but proxy server reachable
    if printf '%s\n' "${ISSUES[@]}" | grep -q "Transparent proxy NOT working"; then
        if printf '%s\n' "${OKS[@]}" | grep -q "reachable"; then
            echo "  💡 Redsocks config or iptables issue → re-apply: sudo ./aro-manager.sh proxy enable"
            has_suggestions=true
        fi
    fi
    
    # Pattern: IPv6 leak
    if printf '%s\n' "${ISSUES[@]}" | grep -q "IPv6 LEAK"; then
        echo "  💡 IPv6 leak → re-apply iptables: sudo ./aro-manager.sh proxy enable"
        has_suggestions=true
    fi
    
    # Pattern: iptables chain missing
    if printf '%s\n' "${ISSUES[@]}" | grep -q "iptables ARO_PROXY chain MISSING"; then
        echo "  💡 iptables rules lost (reboot?) → re-apply: sudo ./aro-manager.sh proxy enable"
        has_suggestions=true
    fi
    
    if ! $has_suggestions && [[ $total_issues -eq 0 ]]; then
        echo "  ✨ No issues detected — all systems nominal"
        echo "  💡 If ARO is still misbehaving, check the full logs above for clues"
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Debug complete — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════════════════"
}
```

---

## Lưu ý implementation

1. **`tee` pattern**: Dùng `{ _do_debug_inner; } 2>&1 | tee "$debug_file"` để vừa print stdout vừa save file. Không cần user làm gì thêm.

2. **Indent style**: Mỗi line output trong `_do_debug_inner` dùng `echo "  text"` (2 spaces indent) cho dễ đọc khi mở file log.

3. **`sudo` requirement**: `do_debug` cần chạy với quyền root (giống `do_status`) vì cần đọc iptables, journalctl, run_as_aro_user. Thêm `require_root` ở đầu `do_debug()` nếu script yêu cầu (check pattern của `do_status` — hiện tại không có require_root, giữ nhất quán).

4. **Thời gian chạy**: Network live test mất ~10–30 giây do timeout curl. In `_info "Running live network tests..."` trước để user biết đang chờ là bình thường.

5. **`_issue`, `_warn`, `_ok` là local helpers** trong `_do_debug_inner` — không cần đặt tên phức tạp, chỉ dùng trong scope đó.

6. **Suggestions engine**: Dùng `printf '%s\n' "${ISSUES[@]}" | grep -q "..."` để match pattern trong issues array — đơn giản, không cần flag riêng.

---

## Thêm vào help/usage text

Trong function `show_help()` hoặc usage section, thêm:

```
  debug             Run full diagnostic: services, logs, network live test
                    Auto-detects issues and suggests fixes
                    Output saved to: aro-debug-YYYYMMDD-HHMMSS.log
```

---

## Version sau khi implement: `v3.4.7`

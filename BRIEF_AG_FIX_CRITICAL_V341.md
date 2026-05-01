# BRIEF FOR ANTIGRAVITY — Fix Critical Issues (v3.4.1 → v3.4.2)

## Mục tiêu
Fix 3 lỗi critical trong `aro-manager.sh` có thể gây mất state watchdog, crash launch command, hoặc proxy bị bypass silently.

---

## Bug 1 — Race condition trong `state_set()` (lines 1553–1572)

### Vấn đề
Khi `state_set()` fail do flock timeout (5s), subshell `exit 1` nhưng caller không biết vì không check exit code. Ngoài ra `|| true` ở line 1564 làm mất state nếu grep fail — `$temp` sẽ là empty file, rồi `mv` ghi đè `STATE_FILE` với file rỗng.

```bash
# Hiện tại (line 1564):
grep -v "^${key}=" "$STATE_FILE" > "$temp" 2>/dev/null || true
# Nếu STATE_FILE bị lock hoặc grep fail → $temp rỗng → STATE_FILE bị xóa sạch sau mv
```

### Fix yêu cầu
1. Sau subshell flock, kiểm tra exit code và log warning nếu fail:
   ```bash
   ) 200>"$lock" || watchdog_log "WARNING: state_set '$key' failed (flock timeout or write error)"
   ```
2. Bỏ `|| true` ở grep line, thay bằng logic an toàn hơn:
   ```bash
   if [[ -f "$STATE_FILE" ]]; then
       grep -v "^${key}=" "$STATE_FILE" > "$temp" 2>/dev/null
       # Nếu grep fail (file bị corrupt), vẫn giữ temp là empty thay vì overwrite
   else
       : > "$temp"
   fi
   ```
3. Verify `$temp` tồn tại trước khi `mv`:
   ```bash
   [[ -f "$temp" ]] && mv "$temp" "$STATE_FILE" || watchdog_log "WARNING: state temp file missing, skipping mv"
   ```

---

## Bug 2 — `DISPLAY_NUM` và `XAUTHORITY_PATH` unquoted trong `launch_aro()` (line 1056)

### Vấn đề
Khi `sudo` không khả dụng (else branch), script build command string với biến unquoted:

```bash
# Hiện tại (line 1056):
local launch_cmd="DISPLAY=$DISPLAY_NUM XAUTHORITY=$XAUTHORITY_PATH LIBGL_ALWAYS_SOFTWARE=1 $WRAPPER_SCRIPT"
su - "$EFFECTIVE_USER" -c "$launch_cmd" >/dev/null 2>&1 &
```

Nếu `DISPLAY_NUM` là `:1` (ổn) nhưng `XAUTHORITY_PATH` có space (ví dụ `/home/user name/.Xauthority`) thì command bị split sai. Ngoài ra biến không được escape nên có thể inject command.

### Fix yêu cầu
Quote các biến trong string:

```bash
local launch_cmd="DISPLAY=\"${DISPLAY_NUM}\" XAUTHORITY=\"${XAUTHORITY_PATH}\" LIBGL_ALWAYS_SOFTWARE=1 \"${WRAPPER_SCRIPT}\""
su - "$EFFECTIVE_USER" -c "$launch_cmd" >/dev/null 2>&1 &
```

---

## Bug 3 — `REDSOCKS_PORT` hardcoded trong wrapper script (line 657)

### Vấn đề
`create_wrapper_script()` dùng heredoc với `<< 'EOF'` (single-quote = no expansion), nên `REDSOCKS_PORT=12345` bị hardcode literal trong file `/usr/local/bin/aro-launch`:

```bash
# create_wrapper_script() line 650:
cat > "$WRAPPER_SCRIPT" << 'EOF'
...
REDSOCKS_PORT=12345   # line 657 trong wrapper — không đọc từ config
...
EOF
```

Nếu main script thay đổi `REDSOCKS_PORT` (line 49) và chạy lại `setup` hoặc `deploy`, wrapper sẽ check sai port → ARO bị block launch mà không có lý do rõ ràng.

### Fix yêu cầu
Đổi sang heredoc với `<< EOF` (không quote) để expand biến, **hoặc** (tốt hơn) viết port từ config file vào wrapper:

**Phương án A — dùng `<< EOF` thay vì `<< 'EOF'`:**
Thay dòng `cat > "$WRAPPER_SCRIPT" << 'EOF'` thành `cat > "$WRAPPER_SCRIPT" << EOF`

Lưu ý: khi làm vậy, các biến khác trong heredoc cũng sẽ bị expand — cần escape `$` cho các biến trong wrapper không muốn expand (như `$*`, `$@` ở dòng `exec "$REAL_ARO" "$@"`). Dùng `\$@`, `\$*`, `\$?` cho các biến thuộc wrapper.

**Phương án B — đọc từ config (được ưa thích hơn):**
Trong wrapper, thay dòng hardcode bằng:
```bash
REDSOCKS_PORT=$(grep '^REDSOCKS_PORT=' /etc/aro-manager/proxy.conf 2>/dev/null | cut -d'=' -f2 || echo "12345")
```

Đảm bảo `REDSOCKS_PORT` được lưu vào `/etc/aro-manager/proxy.conf` khi `setup_proxy_config()` chạy (hiện tại line 452 đã có `REDSOCKS_PORT="$REDSOCKS_PORT"`).

---

## Kết quả sau khi fix
- `state_set()` không còn silent-corrupt STATE_FILE khi flock timeout
- `launch_aro()` an toàn với path có space và không inject được command
- Wrapper luôn check đúng port kể cả sau khi config thay đổi

## Version sau khi fix: `v3.4.2`
Cập nhật dòng version ở line 2 và 16 của script.

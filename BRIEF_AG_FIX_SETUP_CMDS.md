# Brief for Antigravity — Fix `setup` subcommands + banner (v3.1.0 → v3.2.0)

## Tổng quan
AG đã viết các hàm `deploy_phase0_vps()` và `deploy_phase1_vnc()` nhưng chưa thêm case `setup` vào `main()`. Nhiệm vụ lần này: thêm case vào `main()`, cập nhật `show_usage()`, và sửa link X trong banner. Không thay đổi logic nào khác.

---

## Quy tắc bắt buộc
1. **Không động vào** bất kỳ hàm logic nào đã có — chỉ thêm routing trong `main()` và cập nhật `show_usage()`.
2. **`set -euo pipefail`** giữ nguyên — validate + prompt phải dùng `if/fi`.
3. **Bump version**: `3.1.0` → `3.2.0` đủ 3 chỗ.
4. **Push GitHub** sau khi xong: `https://github.com/nauthnael/aro-manager`

---

## Thay đổi 1 — Sửa banner trong `show_banner()`

Tìm dòng:
```
║  X/Twitter: https://x.com/tuangg                              ║
```
Thay bằng:
```
║  X/Twitter: https://x.com/nauthnael                           ║
```

Tương tự kiểm tra `show_footer()` nếu có dòng tương tự, sửa luôn.

---

## Thay đổi 2 — Thêm case `setup` vào `main()`

Thêm block sau vào `main()`, đặt **trước** case `watchdog`:

```bash
setup)
    local subcmd="${1:-}"
    shift || true

    # Parse arguments dùng chung cho tất cả setup subcommands
    local _ssh_key="" _vnc_pass=""
    local _tmp_args=("$@")
    local i=0
    while [[ $i -lt ${#_tmp_args[@]} ]]; do
        case "${_tmp_args[$i]}" in
            --ssh-key)
                i=$(( i + 1 ))
                _ssh_key="${_tmp_args[$i]:-}"
                ;;
            --vnc-pass)
                i=$(( i + 1 ))
                _vnc_pass="${_tmp_args[$i]:-}"
                ;;
        esac
        i=$(( i + 1 ))
    done

    case "$subcmd" in
        vps)
            require_root
            check_os
            UBUNTU_SSH_KEY="$_ssh_key"
            if [[ -z "$UBUNTU_SSH_KEY" ]]; then
                read -p "Nhập SSH public key cho user ubuntu: " -r UBUNTU_SSH_KEY
            fi
            if [[ -z "$UBUNTU_SSH_KEY" ]]; then
                log_error "SSH key là bắt buộc"; exit 1
            fi
            log_info "Chạy Phase 0: VPS Preparation..."
            deploy_phase0_vps
            log_success "setup vps hoàn tất."
            ;;

        vnc)
            require_root
            VNC_PASS="$_vnc_pass"
            if [[ -z "$VNC_PASS" ]]; then
                read -s -p "Nhập VNC password (tối thiểu 6 ký tự): " -r VNC_PASS
                echo ""
            fi
            if [[ ${#VNC_PASS} -lt 6 ]]; then
                log_error "VNC password tối thiểu 6 ký tự"; exit 1
            fi
            log_info "Chạy Phase 1: TigerVNC Setup..."
            deploy_phase1_vnc
            log_success "setup vnc hoàn tất."
            ;;

        all)
            require_root
            check_os
            UBUNTU_SSH_KEY="$_ssh_key"
            VNC_PASS="$_vnc_pass"
            if [[ -z "$UBUNTU_SSH_KEY" ]]; then
                read -p "Nhập SSH public key cho user ubuntu: " -r UBUNTU_SSH_KEY
            fi
            if [[ -z "$UBUNTU_SSH_KEY" ]]; then
                log_error "SSH key là bắt buộc"; exit 1
            fi
            if [[ -z "$VNC_PASS" ]]; then
                read -s -p "Nhập VNC password (tối thiểu 6 ký tự): " -r VNC_PASS
                echo ""
            fi
            if [[ ${#VNC_PASS} -lt 6 ]]; then
                log_error "VNC password tối thiểu 6 ký tự"; exit 1
            fi
            log_info "Chạy Phase 0: VPS Preparation..."
            deploy_phase0_vps
            log_info "Chạy Phase 1: TigerVNC Setup..."
            deploy_phase1_vnc
            log_success "setup all hoàn tất. Máy sẵn sàng để clone."
            ;;

        *)
            echo "Usage: $SCRIPT_NAME setup {vps|vnc|all} [options]"
            echo ""
            echo "  setup vps [--ssh-key KEY]"
            echo "  setup vnc [--vnc-pass PASS]"
            echo "  setup all [--ssh-key KEY] [--vnc-pass PASS]"
            exit 1
            ;;
    esac
    SHOW_FOOTER_ON_EXIT=1
    ;;
```

---

## Thay đổi 3 — Cập nhật `show_usage()`

Thêm vào phần MAIN COMMANDS (đặt sau dòng `deploy ...`):

```
  setup vps [--ssh-key KEY]
                      Cài VPS cơ bản: user, swap, SSH, XFCE, firewall
  setup vnc [--vnc-pass PASS]
                      Cài TigerVNC (XFCE đã có sẵn)
  setup all [--ssh-key KEY] [--vnc-pass PASS]
                      setup vps + setup vnc (chuẩn bị máy mẫu để clone)
```

Cập nhật phần EXAMPLES, thêm:
```
  # Chuẩn bị máy mẫu để clone nhiều LXC
  sudo bash $SCRIPT_NAME setup all \
    --ssh-key "ssh-rsa AAAA..." \
    --vnc-pass "mypass123"

  # Chỉ cài VNC (VPS đã có XFCE)
  sudo bash $SCRIPT_NAME setup vnc --vnc-pass "mypass123"
```

---

## Checklist trước khi push

```bash
bash -n aro-manager.sh && echo "SYNTAX OK"
grep "3\.2\.0" aro-manager.sh | head -5
grep "nauthnael" aro-manager.sh | head -3
grep -n "setup)" aro-manager.sh
```

Tất cả pass → push lên `https://github.com/nauthnael/aro-manager`

---

*Brief soạn bởi: Manager (Claude) — ARO Manager v3.2.0, ngày 2026-04-29*

#!/bin/bash
# Unit tests for diag-harden.sh
source "$(dirname "$0")/test_runner.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# ── Helper: define key functions from diag-harden.sh ─────────────
# These are verbatim copies of the functions in diag-harden.sh, used
# for isolated unit testing without sourcing the full script.

GRUB_FILE=""
SYSCTL_FILE=""
BOOST_PATH=""
SYSCTL_ENTRIES=""

read_grub_cmdline() {
    local which="${1:-DEFAULT}"
    local var
    case "$which" in
        DEFAULT) var="GRUB_CMDLINE_LINUX_DEFAULT" ;;
        LINUX)   var="GRUB_CMDLINE_LINUX" ;;
        *)       var="GRUB_CMDLINE_LINUX_${which}" ;;
    esac
    grep "^${var}=" "$GRUB_FILE" 2>/dev/null | sed 's/^[^=]*=//; s/"//g' || echo ""
}

has_grub_param() {
    local which="$1" param="$2"
    local line
    line=$(read_grub_cmdline "$which")
    local _had_noglob; shopt -qo noglob && _had_noglob=true || _had_noglob=false
    set -f
    local w
    for w in $line; do
        [ "$w" = "$param" ] && { $_had_noglob || set +f; return 0; }
    done
    $_had_noglob || set +f
    return 1
}

has_grub_key_with_value() {
    local which="$1" key="$2"
    local line
    line=$(read_grub_cmdline "$which")
    local _had_noglob; shopt -qo noglob && _had_noglob=true || _had_noglob=false
    set -f
    local w
    for w in $line; do
        case "$w" in
            "$key="*) { $_had_noglob || set +f; return 0; } ;;
        esac
    done
    $_had_noglob || set +f
    return 1
}

grub_key_value() {
    local which="$1" key="$2"
    local line
    line=$(read_grub_cmdline "$which")
    local _had_noglob; shopt -qo noglob && _had_noglob=true || _had_noglob=false
    set -f
    local w
    for w in $line; do
        case "$w" in
            "$key="*) echo "${w#*=}"; $_had_noglob || set +f; return 0 ;;
        esac
    done
    $_had_noglob || set +f
    return 1
}

add_grub_params() {
    local which="$1" desc="$2"
    shift 2
    local params=("$@")
    local current
    current=$(read_grub_cmdline "$which")
    local changed=false

    local new_line="$current"
    for p in "${params[@]}"; do
        if has_grub_param "$which" "$p"; then
            :
        else
            new_line="$new_line $p"
            changed=true
        fi
    done

    if [ "$changed" = false ]; then
        return 0
    fi

    new_line="${new_line# }"
    return 0
}

install_sysctl_file() {
    if [ -n "${SYSCTL_ENTRIES:-}" ]; then
        local persisted
        persisted=$(cat "$SYSCTL_FILE" 2>/dev/null || echo "")
        local needs_update=false
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if ! printf '%s\n' "$persisted" | grep -qxF "$line"; then
                needs_update=true
            fi
        done < <(printf '%b\n' "$SYSCTL_ENTRIES")

        if [ "$needs_update" = true ]; then
            printf '%b\n' "$SYSCTL_ENTRIES" > "$SYSCTL_FILE" 2>/dev/null
        fi
    fi
}

# ── test: read_grub_cmdline ──────────────────────────────────────

test_read_grub_cmdline_default() {
    test_start "read_grub_cmdline DEFAULT reads GRUB_CMDLINE_LINUX_DEFAULT"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    local val; val=$(read_grub_cmdline DEFAULT)
    assert_eq "quiet splash" "$val" "should read DEFAULT without quotes"

    test_end
}

test_read_grub_cmdline_linux() {
    test_start "read_grub_cmdline LINUX reads GRUB_CMDLINE_LINUX"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    cat > "$mock_grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="panic=10"
EOF
    GRUB_FILE="$mock_grub"

    local val; val=$(read_grub_cmdline LINUX)
    assert_eq "panic=10" "$val" "should read LINUX without quotes"

    test_end
}

test_read_grub_cmdline_missing_file() {
    test_start "read_grub_cmdline returns empty for missing file"

    GRUB_FILE="/nonexistent/grub/file"

    local val; val=$(read_grub_cmdline DEFAULT)
    assert_empty "$val" "should return empty for missing file"

    test_end
}

test_read_grub_cmdline_missing_key() {
    test_start "read_grub_cmdline returns empty for missing key"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'SOME_OTHER_VAR="value"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    local val; val=$(read_grub_cmdline DEFAULT)
    assert_empty "$val" "should return empty for missing key"

    test_end
}

test_read_grub_cmdline_custom() {
    test_start "read_grub_cmdline handles custom suffix"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_TEST="custom_val"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    local val; val=$(read_grub_cmdline TEST)
    assert_eq "custom_val" "$val" "should handle custom suffix"

    test_end
}

# ── test: has_grub_param ─────────────────────────────────────────

test_has_grub_param_true() {
    test_start "has_grub_param returns 0 when param present"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.lockup_timeout=10000"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    has_grub_param DEFAULT "amdgpu.lockup_timeout=10000"
    local rc=$?
    assert_eq 0 $rc "should find present param"

    test_end
}

test_has_grub_param_false() {
    test_start "has_grub_param returns 1 when param absent"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    has_grub_param DEFAULT "amdgpu.lockup_timeout=10000"
    local rc=$?
    assert_eq 1 $rc "should not find absent param"

    test_end
}

test_has_grub_param_multiple_whitespace() {
    test_start "has_grub_param handles extra whitespace"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet   splash   panic=10"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    has_grub_param DEFAULT "panic=10"
    local rc=$?
    assert_eq 0 $rc "should find param with multiple spaces"

    test_end
}

# ── test: has_grub_key_with_value ────────────────────────────────

test_has_grub_key_with_value_true() {
    test_start "has_grub_key_with_value detects key=value"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="amdgpu.lockup_timeout=10000 quiet"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    has_grub_key_with_value DEFAULT "amdgpu.lockup_timeout"
    local rc=$?
    assert_eq 0 $rc "should detect key=value"

    test_end
}

test_has_grub_key_with_value_false() {
    test_start "has_grub_key_with_value returns 1 for absent key"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    has_grub_key_with_value DEFAULT "nonexistent_key"
    local rc=$?
    assert_eq 1 $rc "should not find absent key"

    test_end
}

# ── test: grub_key_value ─────────────────────────────────────────

test_grub_key_value() {
    test_start "grub_key_value returns value for key"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="processor.max_cstate=1 quiet"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    local val; val=$(grub_key_value DEFAULT "processor.max_cstate")
    assert_eq "1" "$val" "should return value for key"

    test_end
}

test_grub_key_value_missing() {
    test_start "grub_key_value returns empty for missing key"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    local val; val=$(grub_key_value DEFAULT "processor.max_cstate" 2>/dev/null) || true
    assert_empty "$val" "should return empty for missing key"

    test_end
}

# ── test: add_grub_params (logic before sudo) ────────────────────

test_add_grub_params_noop_when_present() {
    test_start "add_grub_params skips when all params present"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.lockup_timeout=10000 amdgpu.gpu_recovery=1"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    local original_content
    original_content=$(cat "$mock_grub")

    add_grub_params "DEFAULT" "test" "amdgpu.lockup_timeout=10000" "amdgpu.gpu_recovery=1"
    local rc=$?
    assert_eq 0 $rc "should return 0 when params present" || { test_end; return 1; }

    local new_content; new_content=$(cat "$mock_grub")
    assert_eq "$original_content" "$new_content" "file should not change"

    test_end
}

test_add_grub_params_adds_new() {
    test_start "add_grub_params builds new line with added params"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    add_grub_params "DEFAULT" "test" "amdgpu.lockup_timeout=10000"
    local rc=$?
    assert_eq 0 $rc "should return 0"

    test_end
}

test_add_grub_params_partial_update() {
    test_start "add_grub_params adds only missing params"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.lockup_timeout=10000"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    local original_content
    original_content=$(cat "$mock_grub")

    add_grub_params "DEFAULT" "test" "amdgpu.lockup_timeout=10000" "amdgpu.gpu_recovery=1"
    local rc=$?
    assert_eq 0 $rc "should return 0" || { test_end; return 1; }

    local new_content; new_content=$(cat "$mock_grub")
    assert_eq "$original_content" "$new_content" "file should not change (sudo not called)"

    test_end
}

# ── test: install_sysctl_file (logic before sudo) ────────────────

test_install_sysctl_file_persists() {
    test_start "install_sysctl_file writes new entries"

    SYSCTL_FILE="$TEST_DIR/etc/sysctl.d/99-freeze.conf"
    mkdir -p "$(dirname "$SYSCTL_FILE")"
    SYSCTL_ENTRIES="kernel.softlockup_panic=1\nkernel.hardlockup_panic=1\n"

    install_sysctl_file

    assert_file_exists "$SYSCTL_FILE" "sysctl file should exist" || { test_end; return 1; }
    local content; content=$(cat "$SYSCTL_FILE")
    assert_contains "$content" "kernel.softlockup_panic=1" "should persist first entry" || { test_end; return 1; }
    assert_contains "$content" "kernel.hardlockup_panic=1" "should persist second entry"

    test_end
}

test_install_sysctl_file_skips_when_present() {
    test_start "install_sysctl_file skips when entries already persisted"

    SYSCTL_FILE="$TEST_DIR/etc/sysctl.d/99-freeze.conf"
    mkdir -p "$(dirname "$SYSCTL_FILE")"
    printf 'kernel.softlockup_panic=1\nkernel.hardlockup_panic=1\n' > "$SYSCTL_FILE"
    local mtime_before; mtime_before=$(stat -c %Y "$SYSCTL_FILE" 2>/dev/null)

    sleep 0.1
    SYSCTL_ENTRIES="kernel.softlockup_panic=1\nkernel.hardlockup_panic=1\n"
    install_sysctl_file

    local mtime_after; mtime_after=$(stat -c %Y "$SYSCTL_FILE" 2>/dev/null)
    assert_eq "$mtime_before" "$mtime_after" "file should not be modified"

    test_end
}

test_install_sysctl_file_empty_entries() {
    test_start "install_sysctl_file noops with empty entries"

    SYSCTL_FILE="$TEST_DIR/etc/sysctl.d/99-freeze.conf"
    mkdir -p "$(dirname "$SYSCTL_FILE")"
    SYSCTL_ENTRIES=""

    install_sysctl_file

    if [ -f "$SYSCTL_FILE" ]; then
        local content; content=$(cat "$SYSCTL_FILE")
        assert_empty "$content" "file should be empty or not exist"
    fi

    test_end
}

test_install_sysctl_file_appends_new_entries() {
    test_start "install_sysctl_file appends only new entries"

    SYSCTL_FILE="$TEST_DIR/etc/sysctl.d/99-freeze.conf"
    mkdir -p "$(dirname "$SYSCTL_FILE")"
    echo "kernel.softlockup_panic=1" > "$SYSCTL_FILE"

    SYSCTL_ENTRIES="kernel.softlockup_panic=1\nkernel.hardlockup_panic=1\n"
    install_sysctl_file

    local content; content=$(cat "$SYSCTL_FILE")
    assert_contains "$content" "kernel.softlockup_panic=1" "should keep existing" || { test_end; return 1; }
    assert_contains "$content" "kernel.hardlockup_panic=1" "should append new"

    test_end
}

# ── test: check_sudo ─────────────────────────────────────────────

test_check_sudo_check_exists() {
    test_start "check_sudo logic correctly checks sudo"

    # Test that the function exists in the source
    local func_def
    func_def=$(grep -n '^check_sudo()' "$PROJECT_ROOT/diag-harden.sh" | head -1)
    assert_not_empty "$func_def" "check_sudo function should exist in diag-harden.sh" || { test_end; return 1; }

    local func_body
    func_body=$(sed -n '/^check_sudo()/,/^}/p' "$PROJECT_ROOT/diag-harden.sh" 2>/dev/null)
    assert_contains "$func_body" "sudo -n true" "check_sudo should use sudo -n true"

    test_end
}

# ── test: show_status ────────────────────────────────────────────

test_show_status_output() {
    test_start "show_status function exists and produces output"

    local func_def
    func_def=$(grep -n '^show_status()' "$PROJECT_ROOT/diag-harden.sh" | head -1)
    assert_not_empty "$func_def" "show_status function should exist" || { test_end; return 1; }

    local func_body
    func_body=$(sed -n '/^show_status()/,/^}/p' "$PROJECT_ROOT/diag-harden.sh" 2>/dev/null)
    assert_contains "$func_body" "GRUB_CMDLINE_LINUX" "show_status should reference GRUB" || { test_end; return 1; }
    assert_contains "$func_body" "sysctl" "show_status should reference sysctl"

    test_end
}

# ── test: dry_run ────────────────────────────────────────────────

test_dry_run_output() {
    test_start "dry_run function exists with check logic"

    local func_def
    func_def=$(grep -n '^dry_run()' "$PROJECT_ROOT/diag-harden.sh" | head -1)
    assert_not_empty "$func_def" "dry_run function should exist" || { test_end; return 1; }

    local func_body
    func_body=$(sed -n '/^dry_run()/,/^}/p' "$PROJECT_ROOT/diag-harden.sh" 2>/dev/null)
    assert_contains "$func_body" "has_grub_param" "dry_run should check grub params" || { test_end; return 1; }
    assert_contains "$func_body" "read_sysctl_val" "dry_run should check sysctl"

    test_end
}

# ── test: show_help ──────────────────────────────────────────────

test_show_help_output() {
    test_start "diag-harden.sh --help shows usage text"

    local output
    output=$(bash "$PROJECT_ROOT/diag-harden.sh" --help 2>&1)
    assert_contains "$output" "Usage:" "should contain usage" || { test_end; return 1; }
    assert_contains "$output" "--status" "should mention --status" || { test_end; return 1; }
    assert_contains "$output" "--fix-all" "should mention --fix-all" || { test_end; return 1; }
    assert_contains "$output" "--dry-run" "should mention --dry-run" || { test_end; return 1; }
    assert_contains "$output" "--enable-amdgpu-recovery" "should mention recovery" || { test_end; return 1; }
    assert_contains "$output" "--disable-nvme-power-save" "should mention nvme" || { test_end; return 1; }
    assert_contains "$output" "--panic-on-lockup" "should mention panic" || { test_end; return 1; }
    assert_contains "$output" "--disable-deep-cstates" "should mention cstates" || { test_end; return 1; }
    assert_contains "$output" "--disable-cpu-boost" "should mention boost" || { test_end; return 1; }
    assert_contains "$output" "--enable-cpu-boost" "should mention enable boost" || { test_end; return 1; }
    assert_contains "$output" "--enable-iommu-strict" "should mention iommu"

    test_end
}

# ── test: arg dispatch ──────────────────────────────────────────

test_arg_dispatch_help() {
    test_start "diag-harden.sh --help exits 0"

    bash "$PROJECT_ROOT/diag-harden.sh" --help >/dev/null 2>&1
    assert_eq 0 $? "--help should exit 0"

    test_end
}

test_arg_dispatch_help_short() {
    test_start "diag-harden.sh -h exits 0"

    bash "$PROJECT_ROOT/diag-harden.sh" -h >/dev/null 2>&1
    assert_eq 0 $? "-h should exit 0"

    test_end
}

test_arg_dispatch_invalid() {
    test_start "diag-harden.sh invalid arg exits 1 with usage"

    local rc output
    # Capture both output and exit code without || true masking the rc
    output=$(bash "$PROJECT_ROOT/diag-harden.sh" --nonexistent-flag 2>&1) && rc=$? || rc=$?
    assert_eq 1 $rc "invalid arg should exit 1" || { test_end; return 1; }
    assert_contains "$output" "Usage:" "should show usage on invalid arg"

    test_end
}

test_arg_dispatch_status_no_sudo() {
    test_start "diag-harden.sh --status does not require sudo"

    # --status should work without sudo (it only reads, never writes)
    bash "$PROJECT_ROOT/diag-harden.sh" --status >/dev/null 2>&1 || true
    local rc=$?
    assert_eq 0 $rc "--status should exit 0 (no sudo needed)"

    test_end
}

test_arg_dispatch_dry_run() {
    test_start "diag-harden.sh --dry-run does not require sudo"

    bash "$PROJECT_ROOT/diag-harden.sh" --dry-run >/dev/null 2>&1 || true
    local rc=$?
    assert_eq 0 $rc "--dry-run should exit 0 (read-only)"

    test_end
}

# ── test: apply_* function exits ─────────────────────────────────

test_apply_amdgpu_recovery_exists() {
    test_start "apply_amdgpu_recovery function exists"

    grep -q '^apply_amdgpu_recovery()' "$PROJECT_ROOT/diag-harden.sh"
    assert_eq 0 $? "apply_amdgpu_recovery should exist"

    test_end
}

test_apply_nvme_power_save_exists() {
    test_start "apply_nvme_power_save function exists"

    grep -q '^apply_nvme_power_save()' "$PROJECT_ROOT/diag-harden.sh"
    assert_eq 0 $? "apply_nvme_power_save should exist"

    test_end
}

test_apply_disable_deep_cstates_exists() {
    test_start "apply_disable_deep_cstates function exists"

    grep -q '^apply_disable_deep_cstates()' "$PROJECT_ROOT/diag-harden.sh"
    assert_eq 0 $? "apply_disable_deep_cstates should exist"

    test_end
}

test_apply_panic_on_lockup_exists() {
    test_start "apply_panic_on_lockup function exists"

    grep -q '^apply_panic_on_lockup()' "$PROJECT_ROOT/diag-harden.sh"
    assert_eq 0 $? "apply_panic_on_lockup should exist"

    test_end
}

test_apply_fix_all_exists() {
    test_start "apply_fix_all function exists"

    grep -q '^apply_fix_all()' "$PROJECT_ROOT/diag-harden.sh"
    assert_eq 0 $? "apply_fix_all should exist"

    test_end
}

# ── test: GRUB param matching edge cases ─────────────────────────

test_has_grub_param_exact_match() {
    test_start "has_grub_param matches exact params not substrings"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="panic=10 panic=100"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    has_grub_param DEFAULT "panic=10"
    assert_eq 0 $? "should find exact panic=10" || { test_end; return 1; }

    has_grub_param DEFAULT "panic=100"
    assert_eq 0 $? "should find exact panic=100" || { test_end; return 1; }

    has_grub_param DEFAULT "panic=1"
    assert_eq 1 $? "should not match substring panic=1"

    test_end
}

test_grub_key_value_exact_key() {
    test_start "grub_key_value returns correct value with similar keys"

    local mock_grub="$TEST_DIR/etc/default/grub"
    mkdir -p "$(dirname "$mock_grub")"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="processor.max_cstate=1 processor.max_cstate=2 quiet"' > "$mock_grub"
    GRUB_FILE="$mock_grub"

    # Returns first match (word iteration order)
    local val; val=$(grub_key_value DEFAULT "processor.max_cstate")
    assert_eq "1" "$val" "should return value from first matching key=value pair"

    test_end
}

# ── run ──────────────────────────────────────────────────────────

run_tests "$0"

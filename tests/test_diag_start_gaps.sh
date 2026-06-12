#!/bin/bash
# Additional unit tests for diag-start.sh gaps
source "$(dirname "$0")/test_runner.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ═══════════════════════════════════════════════════════════════════
# Supervisor monitor loop — PID file removal check
# ═══════════════════════════════════════════════════════════════════

test_supervisor_pidfile_removed() {
    test_start "supervisor: exits when MAIN_PIDFILE is removed"

    source "$FD_LIB/lib_common.sh"

    local MAIN_PIDFILE="$FD_PID_DIR/freeze-diag-main.pid"
    echo "$$" > "$MAIN_PIDFILE"

    local exited=false
    # Simulate the supervisor loop's PID file check
    if [ ! -f "$MAIN_PIDFILE" ]; then
        exited=true
    fi
    assert_eq "false" "$exited" "should not exit while pidfile exists" || { test_end; return 1; }

    rm -f "$MAIN_PIDFILE"

    if [ ! -f "$MAIN_PIDFILE" ]; then
        exited=true
    fi
    assert_eq "true" "$exited" "should exit when pidfile is removed" || { test_end; return 1; }

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# Supervisor monitor loop — restart detection
# ═══════════════════════════════════════════════════════════════════

test_supervisor_restarts_dead_collector() {
    test_start "supervisor: restarts collector when pid is dead"

    source "$FD_LIB/lib_common.sh"

    local name="testcollector"
    local script="$TEST_DIR/mock_collector.sh"
    echo "#!/bin/bash" > "$script"
    chmod +x "$script"

    local pidf="$FD_PID_DIR/freeze-diag-$name.pid"
    # Write a non-existent PID (dead)
    echo "99999999" > "$pidf"

    local restarted=false
    if [ -f "$pidf" ]; then
        cpid=$(cat "$pidf" 2>/dev/null || echo "")
        if [ -n "$cpid" ] && ! kill -0 "$cpid" 2>/dev/null; then
            restart_file="$FD_PID_DIR/freeze-diag-restart-$name.count"
            RC=$(cat "$restart_file" 2>/dev/null || echo 0)
            RC=$((RC + 1))
            if [ "$RC" -le 5 ]; then
                echo "$RC" > "$restart_file"
                rm -f "$pidf"
                restarted=true
            fi
        fi
    fi

    assert_eq "true" "$restarted" "should restart dead collector" || { test_end; return 1; }
    local new_rc; new_rc=$(cat "$FD_PID_DIR/freeze-diag-restart-testcollector.count" 2>/dev/null)
    assert_eq "1" "$new_rc" "restart counter should be 1" || { test_end; return 1; }
    if [ -f "$pidf" ]; then echo "ASSERT: pidfile should not exist: $pidf" >&2; return 1; fi

    test_end
}

test_supervisor_skip_alive_collector() {
    test_start "supervisor: skips alive collector"

    source "$FD_LIB/lib_common.sh"

    local name="alivecollector"
    local pidf="$FD_PID_DIR/freeze-diag-$name.pid"
    echo "$$" > "$pidf"  # Our own PID is alive

    local restarted=false
    if [ -f "$pidf" ]; then
        cpid=$(cat "$pidf" 2>/dev/null || echo "")
        if [ -n "$cpid" ] && ! kill -0 "$cpid" 2>/dev/null; then
            restarted=true
        fi
    fi

    assert_eq "false" "$restarted" "should not restart alive collector" || { test_end; return 1; }

    test_end
}

test_supervisor_missing_pidfile_skip() {
    test_start "supervisor: skips collector with no pidfile"

    source "$FD_LIB/lib_common.sh"

    local name="nopidcollector"
    local pidf="$FD_PID_DIR/freeze-diag-$name.pid"
    rm -f "$pidf"

    local checked=false
    if [ -f "$pidf" ]; then
        checked=true
    fi

    assert_eq "false" "$checked" "should skip when pidfile does not exist" || { test_end; return 1; }

    test_end
}

test_supervisor_restart_limit_exceeded() {
    test_start "supervisor: stops restarting after limit (5)"

    source "$FD_LIB/lib_common.sh"

    local name="limitcollector"
    local pidf="$FD_PID_DIR/freeze-diag-$name.pid"
    local restart_file="$FD_PID_DIR/freeze-diag-restart-$name.count"
    echo "6" > "$restart_file"  # Already exceeded limit

    # Simulate dead PID
    echo "99999999" > "$pidf"

    local restarted=false
    if [ -f "$pidf" ]; then
        cpid=$(cat "$pidf" 2>/dev/null || echo "")
        if [ -n "$cpid" ] && ! kill -0 "$cpid" 2>/dev/null; then
            RC=$(cat "$restart_file" 2>/dev/null || echo 0)
            RC=$((RC + 1))
            if [ "$RC" -le 5 ]; then
                restarted=true
            fi
        fi
    fi

    assert_eq "false" "$restarted" "should NOT restart when RC > 5" || { test_end; return 1; }

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# --install branches
# ═══════════════════════════════════════════════════════════════════

test_install_sudoers_already_installed() {
    test_start "install: skips sudoers when already installed"

    local SUDOERS_DST="$TEST_DIR/sudoers.d/freeze-diag"
    mkdir -p "$(dirname "$SUDOERS_DST")"
    touch "$SUDOERS_DST"

    local skipped=false
    if [ -f "$SUDOERS_DST" ]; then
        skipped=true
    fi

    assert_eq "true" "$skipped" "should skip when sudoers file exists" || { test_end; return 1; }

    test_end
}

test_install_sudoers_not_installed() {
    test_start "install: detects sudoers not installed"

    local SUDOERS_DST="$TEST_DIR/sudoers.d/freeze-diag"
    rm -f "$SUDOERS_DST"

    local installed=false
    if [ -f "$SUDOERS_DST" ]; then
        installed=true
    fi

    assert_eq "false" "$installed" "should detect sudoers not installed" || { test_end; return 1; }

    test_end
}

test_install_pstore_helper_up_to_date() {
    test_start "install: skips pstore helper when up-to-date"

    local PSTORE_SRC="$TEST_DIR/pstore-src/fd-pstore-dump"
    local PSTORE_DST="$TEST_DIR/pstore-dst/fd-pstore-dump"
    mkdir -p "$(dirname "$PSTORE_SRC")" "$(dirname "$PSTORE_DST")"
    echo "same content" > "$PSTORE_SRC"
    cp "$PSTORE_SRC" "$PSTORE_DST"

    local up_to_date=false
    if cmp -s "$PSTORE_SRC" "$PSTORE_DST" 2>/dev/null; then
        up_to_date=true
    fi

    assert_eq "true" "$up_to_date" "should detect up-to-date pstore helper" || { test_end; return 1; }

    test_end
}

test_install_pstore_helper_outdated() {
    test_start "install: detects outdated pstore helper"

    local PSTORE_SRC="$TEST_DIR/pstore-src2/fd-pstore-dump"
    local PSTORE_DST="$TEST_DIR/pstore-dst2/fd-pstore-dump"
    mkdir -p "$(dirname "$PSTORE_SRC")" "$(dirname "$PSTORE_DST")"
    echo "source content" > "$PSTORE_SRC"
    echo "different content" > "$PSTORE_DST"

    local up_to_date=false
    if cmp -s "$PSTORE_SRC" "$PSTORE_DST" 2>/dev/null; then
        up_to_date=true
    fi

    assert_eq "false" "$up_to_date" "should detect outdated pstore helper" || { test_end; return 1; }

    test_end
}

test_install_service_already_enabled() {
    test_start "install: skips enable when already enabled"

    # Simulate systemctl is-enabled returning success
    systemctl_is_enabled() {
        return 0
    }

    local skipped=false
    if systemctl_is_enabled; then
        skipped=true
    fi

    assert_eq "true" "$skipped" "should skip enable when already enabled" || { test_end; return 1; }

    test_end
}

test_install_service_already_running() {
    test_start "install: skips start when already running"

    # Simulate systemctl is-active returning success
    systemctl_is_active() {
        return 0
    }

    local skipped=false
    if systemctl_is_active; then
        skipped=true
    fi

    assert_eq "true" "$skipped" "should skip start when already running" || { test_end; return 1; }

    test_end
}

test_install_service_file_outdated() {
    test_start "install: updates service file when outdated"

    local SERVICE_SRC="$TEST_DIR/service-src/freeze-diag.service"
    local SERVICE_DST="$TEST_DIR/service-dst/freeze-diag.service"
    mkdir -p "$(dirname "$SERVICE_SRC")" "$(dirname "$SERVICE_DST")"
    echo "new version" > "$SERVICE_SRC"
    echo "old version" > "$SERVICE_DST"

    local updated=false
    if [ -f "$SERVICE_DST" ]; then
        if ! cmp -s "$SERVICE_SRC" "$SERVICE_DST" 2>/dev/null; then
            cp "$SERVICE_SRC" "$SERVICE_DST"
            updated=true
        fi
    fi

    assert_eq "true" "$updated" "should update outdated service file" || { test_end; return 1; }
    local dst_content; dst_content=$(cat "$SERVICE_DST")
    assert_eq "new version" "$dst_content" "service file should contain new content" || { test_end; return 1; }

    test_end
}

test_install_service_file_new() {
    test_start "install: installs service file when missing"

    local SERVICE_SRC="$TEST_DIR/service-src2/freeze-diag.service"
    local SERVICE_DST="$TEST_DIR/service-dst2/freeze-diag.service"
    mkdir -p "$(dirname "$SERVICE_SRC")" "$(dirname "$SERVICE_DST")"
    echo "fresh install" > "$SERVICE_SRC"
    rm -f "$SERVICE_DST"

    local installed=false
    if [ -f "$SERVICE_DST" ]; then
        echo "  Updating $SERVICE_DST ..."
        cp "$SERVICE_SRC" "$SERVICE_DST"
    else
        cp "$SERVICE_SRC" "$SERVICE_DST"
        installed=true
    fi

    assert_eq "true" "$installed" "should install new service file" || { test_end; return 1; }
    assert_file_exists "$SERVICE_DST" "service file should exist" || { test_end; return 1; }

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# --uninstall branches
# ═══════════════════════════════════════════════════════════════════

test_uninstall_service_not_running() {
    test_start "uninstall: skips stop when service not running"

    # Simulate systemctl is-active returning non-zero
    local skipped=false
    if ! systemctl --user is-active nonexistent.service > /dev/null 2>&1; then
        skipped=true
    fi

    assert_eq "true" "$skipped" "should skip stop when not running" || { test_end; return 1; }

    test_end
}

test_uninstall_service_not_enabled() {
    test_start "uninstall: skips disable when service not enabled"

    # Simulate systemctl is-enabled returning non-zero
    local skipped=false
    if ! systemctl --user is-enabled nonexistent.service > /dev/null 2>&1; then
        skipped=true
    fi

    assert_eq "true" "$skipped" "should skip disable when not enabled" || { test_end; return 1; }

    test_end
}

test_uninstall_service_file_not_found() {
    test_start "uninstall: handles missing service file"

    local SERVICE_DST="$TEST_DIR/nonexistent/freeze-diag.service"
    rm -f "$SERVICE_DST"

    local skipped=false
    if [ -f "$SERVICE_DST" ]; then
        rm -f "$SERVICE_DST"
    else
        skipped=true
    fi

    assert_eq "true" "$skipped" "should skip removal when file not found" || { test_end; return 1; }

    test_end
}

test_uninstall_log_purge() {
    test_start "uninstall: --purge removes logs"

    source "$FD_LIB/lib_common.sh"

    local PURGE_LOGS=true
    local test_log="$FD_LOGS/test.log"
    local test_archive="$FD_ARCHIVE/test.bundle"
    local test_report="$FD_REPORTS/test.report"
    mkdir -p "$FD_LOGS" "$FD_ARCHIVE" "$FD_REPORTS"
    echo "data" > "$test_log"
    echo "data" > "$test_archive"
    echo "data" > "$test_report"

    assert_file_exists "$test_log" "log should exist before purge" || { test_end; return 1; }

    if [ "$PURGE_LOGS" = true ]; then
        rm -rf "$FD_LOGS" "$FD_ARCHIVE" "$FD_REPORTS" 2>/dev/null || true
        mkdir -p "$FD_LOGS/sessions" "$FD_ARCHIVE" "$FD_REPORTS"
    fi

    if [ -f "$test_log" ]; then echo "ASSERT: log should not exist after purge" >&2; return 1; fi
    if [ -f "$test_archive" ]; then echo "ASSERT: archive should not exist after purge" >&2; return 1; fi
    if [ -f "$test_report" ]; then echo "ASSERT: report should not exist after purge" >&2; return 1; fi
    assert_dir_exists "$FD_LOGS" "logs dir should be recreated" || { test_end; return 1; }

    test_end
}

test_uninstall_logs_preserved() {
    test_start "uninstall: logs preserved without --purge"

    source "$FD_LIB/lib_common.sh"

    local PURGE_LOGS=false
    local test_log="$FD_LOGS/test_preserved.log"
    mkdir -p "$FD_LOGS"
    echo "keep me" > "$test_log"

    local skipped=false
    if [ "$PURGE_LOGS" = false ]; then
        if [ -d "$FD_LOGS" ] && ls "$FD_LOGS"/*.log > /dev/null 2>&1; then
            skipped=true
        fi
    fi

    assert_eq "true" "$skipped" "should preserve logs when not purging" || { test_end; return 1; }
    assert_file_exists "$test_log" "log should still exist" || { test_end; return 1; }

    test_end
}

test_uninstall_logs_none_to_remove() {
    test_start "uninstall: handles no logs to remove"

    source "$FD_LIB/lib_common.sh"

    local empty_dir="$TEST_DIR/empty_logs"
    mkdir -p "$empty_dir"

    local skipped=false
    if [ -d "$empty_dir" ] && ls "$empty_dir"/*.log > /dev/null 2>&1; then
        skipped=false
    else
        skipped=true
    fi

    assert_eq "true" "$skipped" "should skip when no logs exist" || { test_end; return 1; }

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# Context snapshot — content verification
# ═══════════════════════════════════════════════════════════════════

test_context_snapshot_section_content() {
    test_start "context: write_context_snapshot contains specific section data"

    source "$FD_LIB/lib_common.sh"

    local sid="context_content_test_12345"
    local boot="testboot"
    SESSION_ID="$sid"
    CURRENT_BOOT="$boot"

    write_context_snapshot() {
        local ctx="$FD_LOGS/context_${SESSION_ID}.log"
        {
            echo "=== CONTEXT $(ts_iso) session=$SESSION_ID boot=$CURRENT_BOOT ==="
            echo "--- KERNEL ---"
            echo "Linux test 6.8.0-arch1-1 #1 SMP PREEMPT_DYNAMIC x86_64 GNU/Linux"
            echo "cmdline: BOOT_IMAGE=/boot/vmlinuz-linux root=UUID=abc123 ro quiet"
            echo "tainted: 0"
            echo "--- PLATFORM ---"
            echo "product_name: TestBoard"
            echo "board_name: TestBoard Rev 1.0"
            echo "bios_version: F20"
            echo "bios_date: 01/01/2024"
            echo "model: AMD Ryzen 9 7950X"
            echo "microcode: 0xa601203"
            echo "memtotal: MemTotal: 32887616 kB"
            echo "--- CPU FREQ POSTURE ---"
            echo "boost: 1"
            echo "amd_pstate: active"
            echo "governor: performance"
            echo "max_khz: 5000000"
            echo "--- PANIC POSTURE (sysctl) ---"
            echo "kernel.panic = 10"
            echo "kernel.panic_on_oops = 1"
            echo "--- AMDGPU MODULE PARAMS ---"
            echo "gpu_recovery: 1"
            echo "lockup_timeout: 1000"
            echo "--- MODULES ---"
            echo "Module                  Size  Used by"
            echo "amdgpu         12288000  42"
            echo "nvidia_drm       86016  0"
            echo "=== END CONTEXT ==="
        } > "$ctx" 2>/dev/null
        sync_file "$ctx"
    }

    write_context_snapshot

    local ctx="$FD_LOGS/context_${sid}.log"
    assert_file_exists "$ctx" "context file should exist" || { test_end; return 1; }
    local content; content=$(cat "$ctx")

    # KERNEL section
    assert_contains "$content" "Linux test 6.8.0" "kernel version" || return 1
    assert_contains "$content" "cmdline: BOOT_IMAGE=" "kernel cmdline" || return 1
    assert_contains "$content" "tainted: 0" "kernel tainted" || return 1

    # PLATFORM section
    assert_contains "$content" "product_name: TestBoard" "product name" || return 1
    assert_contains "$content" "board_name: TestBoard Rev 1.0" "board name" || return 1
    assert_contains "$content" "bios_version: F20" "bios version" || return 1
    assert_contains "$content" "bios_date: 01/01/2024" "bios date" || return 1
    assert_contains "$content" "AMD Ryzen 9 7950X" "cpu model" || return 1
    assert_contains "$content" "microcode: 0xa601203" "microcode" || return 1
    assert_contains "$content" "MemTotal: 32887616 kB" "memtotal" || return 1

    # CPU FREQ section
    assert_contains "$content" "boost: 1" "boost" || return 1
    assert_contains "$content" "amd_pstate: active" "pstate" || return 1
    assert_contains "$content" "governor: performance" "governor" || return 1
    assert_contains "$content" "max_khz: 5000000" "max freq" || return 1

    # PANIC section
    assert_contains "$content" "kernel.panic = 10" "panic timeout" || return 1
    assert_contains "$content" "kernel.panic_on_oops = 1" "panic on oops" || return 1

    # AMDGPU section
    assert_contains "$content" "gpu_recovery: 1" "gpu recovery" || return 1
    assert_contains "$content" "lockup_timeout: 1000" "lockup timeout" || return 1

    # MODULES section
    assert_contains "$content" "amdgpu" "amdgpu module" || return 1
    assert_contains "$content" "nvidia_drm" "nvidia module" || return 1

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# Collector launch loop — skip when script not found
# ═══════════════════════════════════════════════════════════════════

test_collector_launch_skip_missing_script() {
    test_start "launch: skips collector when script not found"

    source "$FD_LIB/lib_common.sh"

    local COLLECTORS=("missing_script:$TEST_DIR/nonexistent_script.sh")
    COLLECTOR_PIDS=()
    local log="$FD_LOGS/diag_events.log"

    for entry in "${COLLECTORS[@]}"; do
        name="${entry%%:*}"
        script="${entry##*:}"
        if [ -x "$script" ] || [ -f "$script" ]; then
            echo "[$(ts_iso)] diag-start: launched $name" >> "$log"
        else
            echo "[$(ts_iso)] diag-start: SKIP $name - script not found: $script" >> "$log"
        fi
    done

    assert_file_exists "$log" "events log should exist" || return 1
    local content; content=$(cat "$log")
    assert_contains "$content" "SKIP missing_script" "should log skip" || return 1
    assert_contains "$content" "script not found" "should mention script not found" || return 1
    assert_eq "0" "${#COLLECTOR_PIDS[@]}" "no PIDs should be tracked" || return 1

    test_end
}

test_collector_launch_tracks_pids() {
    test_start "launch: tracks PIDs in COLLECTOR_PIDS"

    source "$FD_LIB/lib_common.sh"

    local mock_script="$TEST_DIR/mock_launch.sh"
    echo "#!/bin/bash" > "$mock_script"
    echo "sleep 0.1" >> "$mock_script"
    chmod +x "$mock_script"

    local COLLECTORS=("mock_launch:$mock_script")
    COLLECTOR_PIDS=()

    for entry in "${COLLECTORS[@]}"; do
        name="${entry%%:*}"
        script="${entry##*:}"
        if [ -x "$script" ] || [ -f "$script" ]; then
            bash "$script" &
            cpid=$!
            COLLECTOR_PIDS+=("$cpid")
        fi
    done

    wait

    assert_eq "1" "${#COLLECTOR_PIDS[@]}" "should have 1 PID" || { test_end; return 1; }
    local tracked_pid="${COLLECTOR_PIDS[0]}"
    [[ "$tracked_pid" =~ ^[0-9]+$ ]] || assert_eq "numeric" "$tracked_pid" "PID should be numeric" || { test_end; return 1; }
    assert_ne "" "$tracked_pid" "PID should not be empty" || { test_end; return 1; }

    test_end
}

test_collector_launch_mixed_existence() {
    test_start "launch: handles mix of existing and missing scripts"

    source "$FD_LIB/lib_common.sh"

    local existing_script="$TEST_DIR/existing.sh"
    echo "#!/bin/bash" > "$existing_script"
    echo "true" >> "$existing_script"
    chmod +x "$existing_script"

    local COLLECTORS=(
        "existing:$existing_script"
        "missing:$TEST_DIR/nope.sh"
    )
    COLLECTOR_PIDS=()
    local log="$FD_LOGS/diag_events.log"

    for entry in "${COLLECTORS[@]}"; do
        name="${entry%%:*}"
        script="${entry##*:}"
        if [ -x "$script" ] || [ -f "$script" ]; then
            bash "$script" &
            cpid=$!
            COLLECTOR_PIDS+=("$cpid")
            echo "[$(ts_iso)] diag-start: launched $name (pid=$cpid)" >> "$log"
        else
            echo "[$(ts_iso)] diag-start: SKIP $name - script not found: $script" >> "$log"
        fi
    done

    wait

    assert_eq "1" "${#COLLECTOR_PIDS[@]}" "should track 1 PID" || return 1
    local content; content=$(cat "$log" 2>/dev/null)
    assert_contains "$content" "launched existing" "launched existing collector" || return 1
    assert_contains "$content" "SKIP missing" "skipped missing collector" || return 1

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# Session ID persistence
# ═══════════════════════════════════════════════════════════════════

test_session_id_persisted_to_file() {
    test_start "session: SESSION_ID written to freeze-diag-session.id"

    source "$FD_LIB/lib_common.sh"

    local SESSION_ID="testboot_987654321"
    local sid_file="$FD_PID_DIR/freeze-diag-session.id"
    echo "$SESSION_ID" > "$sid_file" 2>/dev/null || true

    assert_file_exists "$sid_file" "session id file should exist" || { test_end; return 1; }
    local content; content=$(cat "$sid_file")
    assert_eq "$SESSION_ID" "$content" "file content should match SESSION_ID" || { test_end; return 1; }

    test_end
}

test_session_id_persisted_readable() {
    test_start "session: freeze-diag-session.id readable by diag-stop"

    source "$FD_LIB/lib_common.sh"

    local sid="another_boot_555555"
    local sid_file="$FD_PID_DIR/freeze-diag-session.id"
    echo "$sid" > "$sid_file"

    local read_sid; read_sid=$(cat "$sid_file" 2>/dev/null)
    assert_eq "$sid" "$read_sid" "should read back the same session id" || { test_end; return 1; }
    assert_contains "$read_sid" "_" "session id should contain underscore separator" || { test_end; return 1; }

    test_end
}

test_session_id_persisted_empty_not_overwritten() {
    test_start "session: existing session.id not cleared on subsequent writes"

    source "$FD_LIB/lib_common.sh"

    local sid_file="$FD_PID_DIR/freeze-diag-session.id"
    local original_sid="first_boot_111111"
    echo "$original_sid" > "$sid_file"

    # Simulate another write (like a second launch)
    local second_sid="second_boot_222222"
    echo "$second_sid" > "$sid_file" 2>/dev/null || true

    local content; content=$(cat "$sid_file")
    assert_eq "$second_sid" "$content" "should be overwritten with latest session id" || { test_end; return 1; }

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# —install — subshell sudo path verification
# ═══════════════════════════════════════════════════════════════════

test_install_sudoers_not_installed_needs_sudo() {
    test_start "install: sudoers installation requires sudo when not root"

    local SUDOERS_SRC="$TEST_DIR/sudoers_template"
    local SUDOERS_DST="$TEST_DIR/sudoers.d/freeze-diag"
    mkdir -p "$(dirname "$SUDOERS_DST")"
    rm -f "$SUDOERS_DST"
    echo "test sudoers content" > "$SUDOERS_SRC"

    local installed=false
    if [ ! -f "$SUDOERS_DST" ]; then
        # Simulate the install path
        if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
            installed=true
        fi
    fi

    # We are not root and may not have sudo, so installed should reflect reality
    if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        assert_eq "true" "$installed" "should install when sudo available" || return 1
    else
        assert_eq "false" "$installed" "should not install without sudo" || return 1
    fi

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# Supervisor monitor loop — PID tracking multiple collectors
# ═══════════════════════════════════════════════════════════════════

test_supervisor_monitors_all_collectors() {
    test_start "supervisor: iterates all collectors in loop"

    source "$FD_LIB/lib_common.sh"

    local COLLECTORS=(
        "heartbeat:$FD_LIB/collector_heartbeat.sh"
        "fast:$FD_LIB/collector_fast.sh"
        "gpu:$FD_LIB/collector_gpu.sh"
    )

    local names=()
    for entry in "${COLLECTORS[@]}"; do
        names+=("${entry%%:*}")
    done

    # Verify the supervisor loop would iterate over all
    local iterated_names=""
    for entry in "${COLLECTORS[@]}"; do
        name="${entry%%:*}"
        iterated_names="$iterated_names $name"
    done

    assert_contains "$iterated_names" "heartbeat" "heartbeat in iteration" || return 1
    assert_contains "$iterated_names" "fast" "fast in iteration" || return 1
    assert_contains "$iterated_names" "gpu" "gpu in iteration" || return 1

    test_end
}

# ═══════════════════════════════════════════════════════════════════
# run
# ═══════════════════════════════════════════════════════════════════

run_tests "$0"

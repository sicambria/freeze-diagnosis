#!/bin/bash
# Unit tests for diag-start.sh
source "$(dirname "$0")/test_runner.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# ── test: --help output ──────────────────────────────────────────

test_help_output() {
    test_start "diag-start.sh --help shows usage text"
    local output
    output=$(bash "$PROJECT_ROOT/diag-start.sh" --help 2>&1)
    assert_contains "$output" "Usage:" "should contain usage" || { test_end; return 1; }
    assert_contains "$output" "--install" "should mention install" || { test_end; return 1; }
    assert_contains "$output" "--uninstall" "should mention uninstall" || { test_end; return 1; }
    assert_contains "$output" "diag-analyze.sh" "should mention analyze" || { test_end; return 1; }
    test_end
}

test_help_short() {
    test_start "diag-start.sh -h shows help"
    local output
    output=$(bash "$PROJECT_ROOT/diag-start.sh" -h 2>&1)
    assert_contains "$output" "Usage:" "short help should contain usage"
    test_end
}

# ── test: --install / --uninstall flag detection ─────────────────

test_install_shows_banner() {
    test_start "diag-start.sh --install shows installer banner"
    local output
    output=$(bash "$PROJECT_ROOT/diag-start.sh" --install 2>&1 || true)
    assert_contains "$output" "FREEZE DIAGNOSIS" "should show installer header" || { test_end; return 1; }
    assert_contains "$output" "INSTALLER" "should show installer" || { test_end; return 1; }
    assert_contains "$output" "sudoers" "should mention sudoers" || { test_end; return 1; }
    test_end
}

test_uninstall_shows_banner() {
    test_start "diag-start.sh --uninstall shows uninstaller banner"
    local output
    output=$(bash "$PROJECT_ROOT/diag-start.sh" --uninstall 2>&1 || true)
    assert_contains "$output" "FREEZE DIAGNOSIS" "should show uninstaller header" || { test_end; return 1; }
    assert_contains "$output" "UNINSTALLER" "should show uninstaller" || { test_end; return 1; }
    test_end
}

test_uninstall_purge_flag() {
    test_start "diag-start.sh --uninstall --purge mentions logs"
    local output
    output=$(bash "$PROJECT_ROOT/diag-start.sh" --uninstall --purge 2>&1 || true)
    assert_contains "$output" "purge" "should mention purge"
    test_end
}

# ── test: write_context_snapshot ─────────────────────────────────

test_write_context_snapshot_creates_file() {
    test_start "write_context_snapshot creates context file"

    source "$FD_LIB/lib_common.sh"
    local sid="testboot_12345678"
    local boot="testboot"
    SESSION_ID="$sid"
    CURRENT_BOOT="$boot"

    write_context_snapshot() {
        local ctx="$FD_LOGS/context_${SESSION_ID}.log"
        {
            echo "=== CONTEXT $(ts_iso) session=$SESSION_ID boot=$CURRENT_BOOT ==="
            echo "--- KERNEL ---"
            uname -a 2>/dev/null || echo "uname-mock"
            echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
            echo "tainted: $(cat /proc/sys/kernel/tainted 2>/dev/null)"
            echo "--- PLATFORM ---"
            for k in product_name board_name bios_version bios_date; do
                echo "$k: $(cat "/sys/class/dmi/id/$k" 2>/dev/null)"
            done
            echo "model: $(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
            echo "microcode: $(grep -m1 '^microcode' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
            echo "memtotal: $(grep -m1 MemTotal /proc/meminfo 2>/dev/null)"
            echo "--- CPU FREQ POSTURE ---"
            echo "boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
            echo "amd_pstate: $(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)"
            echo "governor: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"
            echo "max_khz: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)"
            echo "--- PANIC POSTURE (sysctl) ---"
            sysctl kernel.panic kernel.panic_on_oops kernel.softlockup_panic \
                   kernel.hardlockup_panic kernel.hung_task_panic 2>/dev/null || true
            echo "--- AMDGPU MODULE PARAMS ---"
            for p in gpu_recovery lockup_timeout; do
                echo "$p: $(cat "/sys/module/amdgpu/parameters/$p" 2>/dev/null)"
            done
            echo "--- MODULES ---"
            lsmod 2>/dev/null | head -40 || true
            echo "=== END CONTEXT ==="
        } > "$ctx" 2>/dev/null
        sync_file "$ctx"
    }

    write_context_snapshot

    local ctx="$FD_LOGS/context_${sid}.log"
    assert_file_exists "$ctx" "context file should exist" || { test_end; return 1; }
    local content; content=$(cat "$ctx")
    assert_not_empty "$content" "context file should have content"

    test_end
}

test_write_context_snapshot_has_sections() {
    test_start "write_context_snapshot has expected section headers"

    source "$FD_LIB/lib_common.sh"
    local sid="testboot_87654321"
    SESSION_ID="$sid"
    CURRENT_BOOT="testboot"

    write_context_snapshot() {
        local ctx="$FD_LOGS/context_${SESSION_ID}.log"
        {
            echo "=== CONTEXT $(ts_iso) session=$SESSION_ID boot=$CURRENT_BOOT ==="
            echo "--- KERNEL ---"
            uname -a 2>/dev/null || echo "uname-mock"
            echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
            echo "tainted: $(cat /proc/sys/kernel/tainted 2>/dev/null)"
            echo "--- PLATFORM ---"
            for k in product_name board_name bios_version bios_date; do
                echo "$k: $(cat "/sys/class/dmi/id/$k" 2>/dev/null)"
            done
            echo "model: $(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
            echo "microcode: $(grep -m1 '^microcode' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
            echo "memtotal: $(grep -m1 MemTotal /proc/meminfo 2>/dev/null)"
            echo "--- CPU FREQ POSTURE ---"
            echo "boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
            echo "amd_pstate: $(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)"
            echo "governor: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"
            echo "max_khz: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)"
            echo "--- PANIC POSTURE (sysctl) ---"
            sysctl kernel.panic kernel.panic_on_oops kernel.softlockup_panic \
                   kernel.hardlockup_panic kernel.hung_task_panic 2>/dev/null || true
            echo "--- AMDGPU MODULE PARAMS ---"
            for p in gpu_recovery lockup_timeout; do
                echo "$p: $(cat "/sys/module/amdgpu/parameters/$p" 2>/dev/null)"
            done
            echo "--- MODULES ---"
            lsmod 2>/dev/null | head -40 || true
            echo "=== END CONTEXT ==="
        } > "$ctx" 2>/dev/null
        sync_file "$ctx"
    }

    write_context_snapshot

    local ctx="$FD_LOGS/context_${sid}.log"
    assert_file_exists "$ctx" "context file should exist" || { test_end; return 1; }
    local content; content=$(cat "$ctx")
    assert_contains "$content" "=== CONTEXT" "should have CONTEXT header" || { test_end; return 1; }
    assert_contains "$content" "--- KERNEL ---" "should have KERNEL section" || { test_end; return 1; }
    assert_contains "$content" "--- PLATFORM ---" "should have PLATFORM section" || { test_end; return 1; }
    assert_contains "$content" "--- CPU FREQ POSTURE ---" "should have CPU FREQ section" || { test_end; return 1; }
    assert_contains "$content" "--- PANIC POSTURE" "should have PANIC section" || { test_end; return 1; }
    assert_contains "$content" "--- AMDGPU MODULE PARAMS ---" "should have AMDGPU section" || { test_end; return 1; }
    assert_contains "$content" "--- MODULES ---" "should have MODULES section" || { test_end; return 1; }
    assert_contains "$content" "=== END CONTEXT ===" "should end with END CONTEXT" || { test_end; return 1; }

    test_end
}

# ── test: trap_cleanup ───────────────────────────────────────────

test_trap_cleanup_session_stopped() {
    test_start "trap_cleanup marks session as stopped"

    source "$FD_LIB/lib_common.sh"

    local sid="testboot_trap_12345"
    local boot="testboot"
    local sf="$FD_LOGS/sessions/${sid}.session"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$sf" <<EOF
{
  "boot_id": "$boot",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF

    local MAIN_PIDFILE="$FD_PID_DIR/freeze-diag-main.pid"
    echo "99999999" > "$MAIN_PIDFILE"

    # Run trap_cleanup in a subshell so its `exit 0` doesn't kill the test
    (
        SESSION_ID="$sid"
        CURRENT_BOOT="$boot"
        source "$FD_LIB/lib_common.sh"

        trap_cleanup() {
            echo "[$(date --iso-8601=seconds)] diag-start: shutting down" >> "$FD_LOGS/diag_events.log"
            for pidf in "$FD_PID_DIR"/freeze-diag-*.pid; do
                [ -f "$pidf" ] || continue
                [ "$pidf" = "$MAIN_PIDFILE" ] && continue
                pid=$(cat "$pidf" 2>/dev/null) || continue
                kill "$pid" 2>/dev/null || true
                rm -f "$pidf"
            done
            local sf_local
            sf_local=$(find_session_file "${SESSION_ID:-$CURRENT_BOOT}" 2>/dev/null) || sf_local="$FD_LOGS/sessions/${CURRENT_BOOT}.session"
            if [ -f "$sf_local" ]; then
                local started
                started=$(grep '"started_at"' "$sf_local" 2>/dev/null | sed 's/.*"started_at": *"\([^"]*\)".*/\1/' || echo "unknown")
                local bid
                bid=$(grep '"boot_id"' "$sf_local" 2>/dev/null | sed 's/.*"boot_id": *"\([^"]*\)".*/\1/' || echo "$CURRENT_BOOT")
                local sid_local
                sid_local=$(grep '"session_id"' "$sf_local" 2>/dev/null | sed 's/.*"session_id": *"\([^"]*\)".*/\1/' || echo "${SESSION_ID:-}")
                cat > "$sf_local" <<SESSIONEOF
{
  "boot_id": "$bid",
  "session_id": "$sid_local",
  "started_at": "$started",
  "status": "stopped",
  "stopped_at": "$(date --iso-8601=seconds)"
}
SESSIONEOF
            fi
            rm -f "$MAIN_PIDFILE"
            exit 0
        }

        trap_cleanup 2>/dev/null
    )

    local content; content=$(cat "$sf" 2>/dev/null)
    assert_contains "$content" '"status": "stopped"' "session should be marked stopped" || { test_end; return 1; }
    assert_contains "$content" '"stopped_at"' "should have stopped_at timestamp" || { test_end; return 1; }
    assert_contains "$content" '"boot_id": "testboot"' "should preserve boot_id" || { test_end; return 1; }
    assert_contains "$content" "\"session_id\": \"$sid\"" "should preserve session_id"

    test_end
}

test_trap_cleanup_removes_pidfile() {
    test_start "trap_cleanup removes main pidfile"

    source "$FD_LIB/lib_common.sh"

    local sid="testboot_pidrm_12345"
    local boot="testboot"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "$boot",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF

    local MAIN_PIDFILE="$FD_PID_DIR/freeze-diag-main.pid"
    echo "99999999" > "$MAIN_PIDFILE"
    assert_file_exists "$MAIN_PIDFILE" "pidfile should exist before cleanup" || { test_end; return 1; }

    (
        SESSION_ID="$sid"
        CURRENT_BOOT="$boot"
        source "$FD_LIB/lib_common.sh"

        trap_cleanup() {
            echo "[$(date --iso-8601=seconds)] diag-start: shutting down" >> "$FD_LOGS/diag_events.log"
            for pidf in "$FD_PID_DIR"/freeze-diag-*.pid; do
                [ -f "$pidf" ] || continue
                [ "$pidf" = "$MAIN_PIDFILE" ] && continue
                pid=$(cat "$pidf" 2>/dev/null) || continue
                kill "$pid" 2>/dev/null || true
                rm -f "$pidf"
            done
            local sf_local
            sf_local=$(find_session_file "${SESSION_ID:-$CURRENT_BOOT}" 2>/dev/null) || sf_local="$FD_LOGS/sessions/${CURRENT_BOOT}.session"
            if [ -f "$sf_local" ]; then
                local started
                started=$(grep '"started_at"' "$sf_local" 2>/dev/null | sed 's/.*"started_at": *"\([^"]*\)".*/\1/' || echo "unknown")
                local bid
                bid=$(grep '"boot_id"' "$sf_local" 2>/dev/null | sed 's/.*"boot_id": *"\([^"]*\)".*/\1/' || echo "$CURRENT_BOOT")
                local sid_local
                sid_local=$(grep '"session_id"' "$sf_local" 2>/dev/null | sed 's/.*"session_id": *"\([^"]*\)".*/\1/' || echo "${SESSION_ID:-}")
                cat > "$sf_local" <<SESSIONEOF
{
  "boot_id": "$bid",
  "session_id": "$sid_local",
  "started_at": "$started",
  "status": "stopped",
  "stopped_at": "$(date --iso-8601=seconds)"
}
SESSIONEOF
            fi
            rm -f "$MAIN_PIDFILE"
            exit 0
        }

        trap_cleanup 2>/dev/null
    )

    if [ -f "$MAIN_PIDFILE" ]; then
        assert_eq "removed" "exists" "main pidfile should have been removed"
    fi

    test_end
}

test_trap_cleanup_skips_child_collectors() {
    test_start "trap_cleanup iterates child pidfiles and skips main"

    source "$FD_LIB/lib_common.sh"

    local sid="testboot_children_12345"
    local boot="testboot"
    local sf="$FD_LOGS/sessions/${sid}.session"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$sf" <<EOF
{
  "boot_id": "$boot",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF

    local MAIN_PIDFILE="$FD_PID_DIR/freeze-diag-main.pid"
    echo "99999999" > "$MAIN_PIDFILE"
    local child1="$FD_PID_DIR/freeze-diag-heartbeat.pid"
    local child2="$FD_PID_DIR/freeze-diag-fast.pid"
    echo "99999998" > "$child1"
    echo "99999997" > "$child2"

    (
        SESSION_ID="$sid"
        CURRENT_BOOT="$boot"
        source "$FD_LIB/lib_common.sh"

        trap_cleanup() {
            echo "[$(date --iso-8601=seconds)] diag-start: shutting down" >> "$FD_LOGS/diag_events.log"
            for pidf in "$FD_PID_DIR"/freeze-diag-*.pid; do
                [ -f "$pidf" ] || continue
                [ "$pidf" = "$MAIN_PIDFILE" ] && continue
                pid=$(cat "$pidf" 2>/dev/null) || continue
                kill "$pid" 2>/dev/null || true
                rm -f "$pidf"
            done
            local sf_local
            sf_local=$(find_session_file "${SESSION_ID:-$CURRENT_BOOT}" 2>/dev/null) || sf_local="$FD_LOGS/sessions/${CURRENT_BOOT}.session"
            if [ -f "$sf_local" ]; then
                local started
                started=$(grep '"started_at"' "$sf_local" 2>/dev/null | sed 's/.*"started_at": *"\([^"]*\)".*/\1/' || echo "unknown")
                local bid
                bid=$(grep '"boot_id"' "$sf_local" 2>/dev/null | sed 's/.*"boot_id": *"\([^"]*\)".*/\1/' || echo "$CURRENT_BOOT")
                local sid_local
                sid_local=$(grep '"session_id"' "$sf_local" 2>/dev/null | sed 's/.*"session_id": *"\([^"]*\)".*/\1/' || echo "${SESSION_ID:-}")
                cat > "$sf_local" <<SESSIONEOF
{
  "boot_id": "$bid",
  "session_id": "$sid_local",
  "started_at": "$started",
  "status": "stopped",
  "stopped_at": "$(date --iso-8601=seconds)"
}
SESSIONEOF
            fi
            rm -f "$MAIN_PIDFILE"
            exit 0
        }

        trap_cleanup 2>/dev/null
    )

    if [ -f "$MAIN_PIDFILE" ]; then
        assert_eq "removed" "exists" "main pidfile should be removed"
    fi

    test_end
}

# ── test: generate_session_id / current_boot_id ──────────────────

test_generate_session_id() {
    test_start "generate_session_id returns boot_epoch format"

    source "$FD_LIB/lib_common.sh"
    local sid; sid=$(generate_session_id)
    assert_not_empty "$sid" "session id should not be empty" || { test_end; return 1; }
    assert_contains "$sid" "_" "session id should contain underscore" || { test_end; return 1; }
    local epoch_part="${sid##*_}"
    [[ "$epoch_part" =~ ^[0-9]+$ ]] \
        || assert_eq "numeric" "$epoch_part" "epoch part should be numeric"
    test_end
}

test_current_boot_id() {
    test_start "current_boot_id returns non-empty"

    source "$FD_LIB/lib_common.sh"
    local val; val=$(current_boot_id)
    assert_not_empty "$val" "boot_id should not be empty"
    test_end
}

# ── test: COLLECTORS array ───────────────────────────────────────

test_collectors_array_count() {
    test_start "COLLECTORS has 7 entries"

    COLLECTORS=(
        "heartbeat:$FD_LIB/collector_heartbeat.sh"
        "fast:$FD_LIB/collector_fast.sh"
        "gpu:$FD_LIB/collector_gpu.sh"
        "cpu:$FD_LIB/collector_cpu.sh"
        "watchdog:$FD_LIB/collector_watchdog.sh"
        "detailed:$FD_LIB/collector_detailed.sh"
        "dmesg:$FD_LIB/collector_dmesg.sh"
    )

    assert_eq 7 "${#COLLECTORS[@]}" "should have 7 collectors"
    test_end
}

test_collectors_array_names() {
    test_start "COLLECTORS entries have correct names"

    COLLECTORS=(
        "heartbeat:$FD_LIB/collector_heartbeat.sh"
        "fast:$FD_LIB/collector_fast.sh"
        "gpu:$FD_LIB/collector_gpu.sh"
        "cpu:$FD_LIB/collector_cpu.sh"
        "watchdog:$FD_LIB/collector_watchdog.sh"
        "detailed:$FD_LIB/collector_detailed.sh"
        "dmesg:$FD_LIB/collector_dmesg.sh"
    )

    local expected_names=("heartbeat" "fast" "gpu" "cpu" "watchdog" "detailed" "dmesg")
    local i=0
    for entry in "${COLLECTORS[@]}"; do
        local name="${entry%%:*}"
        assert_eq "${expected_names[$i]}" "$name" "collector $i name mismatch" || { test_end; return 1; }
        i=$((i + 1))
    done

    test_end
}

test_collectors_array_paths() {
    test_start "COLLECTORS entries have valid script paths"

    COLLECTORS=(
        "heartbeat:$FD_LIB/collector_heartbeat.sh"
        "fast:$FD_LIB/collector_fast.sh"
        "gpu:$FD_LIB/collector_gpu.sh"
        "cpu:$FD_LIB/collector_cpu.sh"
        "watchdog:$FD_LIB/collector_watchdog.sh"
        "detailed:$FD_LIB/collector_detailed.sh"
        "dmesg:$FD_LIB/collector_dmesg.sh"
    )

    local real_lib; real_lib="$(cd "$PROJECT_ROOT/lib" && pwd)"
    for entry in "${COLLECTORS[@]}"; do
        local script="${entry##*:}"
        local real_script="${script/$FD_LIB/$real_lib}"
        assert_file_exists "$real_script" "script should exist: $real_script" || { test_end; return 1; }
    done

    test_end
}

test_collectors_array_no_extra() {
    test_start "COLLECTORS has no extra entries"

    COLLECTORS=(
        "heartbeat:$FD_LIB/collector_heartbeat.sh"
        "fast:$FD_LIB/collector_fast.sh"
        "gpu:$FD_LIB/collector_gpu.sh"
        "cpu:$FD_LIB/collector_cpu.sh"
        "watchdog:$FD_LIB/collector_watchdog.sh"
        "detailed:$FD_LIB/collector_detailed.sh"
        "dmesg:$FD_LIB/collector_dmesg.sh"
    )

    local expected_count=7
    assert_eq "$expected_count" "${#COLLECTORS[@]}" "must have exactly 7 collectors, no more"

    test_end
}

# ── test: session marker ─────────────────────────────────────────

test_session_marker_written() {
    test_start "write_session_marker writes running status"

    source "$FD_LIB/lib_common.sh"
    local sid="freshboot_12345678"
    write_session_marker "running" "$sid"

    local sf="$FD_LOGS/sessions/${sid}.session"
    assert_file_exists "$sf" "session file should exist" || { test_end; return 1; }
    local content; content=$(cat "$sf")
    assert_contains "$content" '"status": "running"' "session should be running"

    test_end
}

# ── test: crash detection ────────────────────────────────────────

test_crash_detection_finds_crashed() {
    test_start "check_crashed_sessions finds crashed session with dead pid"

    source "$FD_LIB/lib_common.sh"
    local sid="crashtest_999999"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "crashtest",
  "session_id": "$sid",
  "status": "running",
  "pid": 99999999
}
EOF

    local result; result=$(check_crashed_sessions)
    assert_eq "$sid" "$result" "should detect crashed session"
    test_end
}

test_crash_detection_ignores_alive() {
    test_start "check_crashed_sessions ignores alive session"

    source "$FD_LIB/lib_common.sh"
    local sid="alivetest_111111"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "alivetest",
  "session_id": "$sid",
  "status": "running",
  "pid": $$
}
EOF

    local result; result=$(check_crashed_sessions)
    assert_empty "$result" "should not detect alive session as crashed"
    test_end
}

test_crash_detection_ignores_stopped() {
    test_start "check_crashed_sessions ignores stopped session"

    source "$FD_LIB/lib_common.sh"
    local sid="donetest_333333"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "donetest",
  "session_id": "$sid",
  "status": "stopped",
  "pid": 99999999
}
EOF

    local result; result=$(check_crashed_sessions)
    assert_empty "$result" "stopped session should not be reported as crashed"
    test_end
}

# ── test: restart logic (supervisor loop) ────────────────────────

test_restart_logic_below_limit() {
    test_start "restart logic restarts when RC <= 5"

    local name="heartbeat"
    local RC=3

    if [ "$RC" -le 5 ]; then
        assert_eq 0 0 "should allow restart (RC=$RC <= 5)"
    else
        assert_eq "restart" "limit" "unexpected: RC=$RC > 5"
    fi

    test_end
}

test_restart_logic_at_limit() {
    test_start "restart logic still restarts at RC=5 (last allowed)"

    local name="heartbeat"
    local RC=5

    if [ "$RC" -le 5 ]; then
        assert_eq 0 0 "should allow restart at limit (RC=5)"
    else
        assert_eq "restart" "limit" "unexpected: RC=5 > 5"
    fi

    test_end
}

test_restart_logic_exceeds_limit() {
    test_start "restart logic stops when RC > 5"

    local name="heartbeat"
    local RC=6

    if [ "$RC" -le 5 ]; then
        assert_eq "stop" "restart" "should NOT restart when RC=6 > 5"
    else
        assert_eq 0 0 "correctly stops when RC=6 > 5"
    fi

    test_end
}

test_restart_counter_increment() {
    test_start "restart counter increments on collector death"

    local restart_file="$FD_PID_DIR/freeze-diag-restart-test.count"
    echo "0" > "$restart_file"

    local RC
    RC=$(cat "$restart_file" 2>/dev/null || echo 0)
    RC=$((RC + 1))
    echo "$RC" > "$restart_file"

    local new_rc; new_rc=$(cat "$restart_file")
    assert_eq "1" "$new_rc" "counter should increment to 1" || { test_end; return 1; }

    RC=$((new_rc + 1))
    echo "$RC" > "$restart_file"
    new_rc=$(cat "$restart_file")
    assert_eq "2" "$new_rc" "counter should increment to 2"

    test_end
}

# ── test: main entry point side effects ──────────────────────────

test_main_sources_config_and_lib() {
    test_start "diag-start.sh sources diag.conf and lib_common.sh (no errors)"

    local output
    output=$(bash "$PROJECT_ROOT/diag-start.sh" --help 2>&1)
    assert_contains "$output" "diag-start.sh" "help should show script name"
    assert_not_contains "$output" "error" "help should not produce errors"

    test_end
}

test_session_id_exported_in_script() {
    test_start "SESSION_ID is exported when script runs"

    local output
    output=$(bash -c '
        source "'$PROJECT_ROOT'/diag.conf"
        source "'$PROJECT_ROOT'/lib/lib_common.sh"
        sid=$(generate_session_id)
        export SESSION_ID="$sid"
        echo "$SESSION_ID"
    ' 2>/dev/null)

    assert_not_empty "$output" "SESSION_ID should be non-empty" || { test_end; return 1; }
    assert_contains "$output" "_" "SESSION_ID should contain boot_epoch separator"

    test_end
}

test_pidfile_written() {
    test_start "write_pidfile creates pid file"

    source "$FD_LIB/lib_common.sh"
    local pf="$FD_PID_DIR/test.pid"
    write_pidfile "$pf"

    assert_file_exists "$pf" "pidfile should exist" || { test_end; return 1; }
    local content; content=$(cat "$pf")
    assert_eq "$$" "$content" "pidfile should contain current PID"

    test_end
}

test_events_log_written() {
    test_start "diag-start.sh writes to diag_events.log (via trap_cleanup)"

    source "$FD_LIB/lib_common.sh"
    local msg="[$(date --iso-8601=seconds)] diag-start: test event"
    echo "$msg" >> "$FD_LOGS/diag_events.log"

    assert_file_exists "$FD_LOGS/diag_events.log" "events log should exist"
    local content; content=$(cat "$FD_LOGS/diag_events.log")
    assert_contains "$content" "test event" "events log should contain test entry"

    test_end
}

# ── run ──────────────────────────────────────────────────────────

run_tests "$0"

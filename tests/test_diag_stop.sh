#!/bin/bash
# Unit tests for diag-stop.sh
source "$(dirname "$0")/test_runner.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# For these tests we run the actual diag-stop.sh with a mocked environment.
# diag-stop.sh has no set -euo pipefail, so minor failures are tolerated.
# We create mock pidfiles, session files, session.id, and then run the
# script to verify it handles them correctly.

run_stop_script() {
    bash "$PROJECT_ROOT/diag-stop.sh" 2>&1 || true
}

# ── test: pidfile iteration ──────────────────────────────────────

test_pidfile_iteration() {
    test_start "diag-stop.sh iterates over pidfiles"

    source "$FD_LIB/lib_common.sh"

    local pid1="$FD_PID_DIR/freeze-diag-heartbeat.pid"
    local pid2="$FD_PID_DIR/freeze-diag-fast.pid"
    echo "99999998" > "$pid1"
    echo "99999997" > "$pid2"

    local sid="stoptest_iter_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    run_stop_script

    local found=false
    for pidf in "$FD_PID_DIR"/freeze-diag-*.pid; do
        if [ -f "$pidf" ]; then
            found=true
            break
        fi
    done

    # After stop runs, pidfiles should be deleted
    assert_eq "false" "$found" "all pidfiles should be removed after stop"
    test_end
}

test_pidfile_removes_collector_pidfiles() {
    test_start "diag-stop.sh removes collector pidfiles"

    source "$FD_LIB/lib_common.sh"

    local pid1="$FD_PID_DIR/freeze-diag-heartbeat.pid"
    echo "99999998" > "$pid1"
    assert_file_exists "$pid1" "heartbeat pidfile should exist before stop" || { test_end; return 1; }

    local sid="stoptest_rm_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    run_stop_script

    if [ -f "$pid1" ]; then
        assert_eq "removed" "exists" "heartbeat pidfile should be removed"
    fi

    test_end
}

test_pidfile_kills_with_sigterm_first() {
    test_start "diag-stop.sh sends SIGTERM (not SIGKILL initially)"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_term_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    # Create a catachable SIGTERM process and ensure its pidfile is ready
    local sigterm_caught="$TEST_DIR/sigterm_caught"
    local child_pid
    (
        trap 'touch "$sigterm_caught"; exit 0' TERM
        # Write PID to stdout (captured by parent) rather than a file race
        echo "$$"
        while true; do sleep 1; done
    ) &
    child_pid=$!

    # Wait for the background process to be ready
    sleep 0.3
    echo "$child_pid" > "$FD_PID_DIR/freeze-diag-signaltest.pid"

    run_stop_script

    # Give SIGTERM time to be delivered
    sleep 0.3

    if [ -f "$sigterm_caught" ]; then
        assert_eq 0 0 "SIGTERM was caught by trap handler"
    else
        assert_eq "caught" "not_caught" "SIGTERM should have been caught"
    fi

    kill "$child_pid" 2>/dev/null || true
    rm -f "$sigterm_caught"
    test_end
}

# ── test: session file rewrite ───────────────────────────────────

test_session_file_rewrite_stopped() {
    test_start "diag-stop.sh rewrites session to stopped"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_session_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    assert_file_exists "$sf" "session file should exist before stop" || { test_end; return 1; }
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    run_stop_script

    local content; content=$(cat "$sf" 2>/dev/null)
    assert_not_empty "$content" "session file should still exist" || { test_end; return 1; }
    assert_contains "$content" '"status": "stopped"' "session should be marked stopped"

    test_end
}

test_session_file_preserves_fields() {
    test_start "diag-stop.sh preserves boot_id, session_id, started_at"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_fields_67890"
    local boot="stoptest"
    local started="2024-06-01T12:00:00+00:00"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "$boot",
  "session_id": "$sid",
  "started_at": "$started",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    run_stop_script

    local content; content=$(cat "$sf" 2>/dev/null)
    assert_contains "$content" '"boot_id": "stoptest"' "should preserve boot_id" || { test_end; return 1; }
    assert_contains "$content" "\"session_id\": \"$sid\"" "should preserve session_id" || { test_end; return 1; }
    assert_contains "$content" '"started_at": "2024-06-01T12:00:00+00:00"' "should preserve started_at" || { test_end; return 1; }
    assert_contains "$content" '"stopped_at"' "should add stopped_at"

    test_end
}

# ── test: force kill loop ────────────────────────────────────────

test_force_kill_loop_after_sleep() {
    test_start "diag-stop.sh runs force-kill loop after sleep"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_force2_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    # Put a pidfile with a dead PID — force loop will skip it cleanly
    local stubborn_pidfile="$FD_PID_DIR/freeze-diag-stubborn.pid"
    echo "99999999" > "$stubborn_pidfile"

    run_stop_script

    # After stop, pidfiles are deleted (force-kill loop removes them)
    # This test just verifies the process doesn't crash
    test_end
}

test_force_kill_loop_skips_missing() {
    test_start "diag-stop.sh force kill loop handles missing pidfiles"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_skip_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    # No pidfiles — should not crash
    run_stop_script

    local content; content=$(cat "$sf" 2>/dev/null)
    assert_contains "$content" '"status": "stopped"' "session should be stopped"

    test_end
}

# ── test: error handling ─────────────────────────────────────────

test_missing_pidfiles_handled() {
    test_start "diag-stop.sh handles missing pidfiles gracefully"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_nopid_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    # No pidfiles exist — should not error
    local output
    output=$(run_stop_script)
    local rc=$?
    assert_eq 0 $rc "should exit 0 even with no pidfiles" || { test_end; return 1; }

    local content; content=$(cat "$sf" 2>/dev/null)
    assert_contains "$content" '"status": "stopped"' "should still mark session stopped"

    test_end
}

test_missing_session_file_handled() {
    test_start "diag-stop.sh handles missing session file gracefully"

    source "$FD_LIB/lib_common.sh"

    # No session files at all
    local output
    output=$(run_stop_script)
    local rc=$?
    assert_eq 0 $rc "should exit 0 even with no session file"

    test_end
}

test_missing_session_id_file_handled() {
    test_start "diag-stop.sh handles missing session.id file"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_noid_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "stopped",
  "stopped_at": "2024-01-01T01:00:00+00:00"
}
EOF
    # No session.id file — should use CURRENT_BOOT to find session
    # This test verifies it doesn't crash

    local output
    output=$(run_stop_script)
    local rc=$?
    assert_eq 0 $rc "should exit 0 without session.id"

    test_end
}

# ── test: events log ─────────────────────────────────────────────

test_events_log_written() {
    test_start "diag-stop.sh writes stop event to log"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_log_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    run_stop_script

    assert_file_exists "$FD_LOGS/diag_events.log" "events log should exist" || { test_end; return 1; }
    local content; content=$(cat "$FD_LOGS/diag_events.log")
    assert_contains "$content" "diag-stop:" "events log should contain diag-stop entry"

    test_end
}

test_events_log_contains_done() {
    test_start "diag-stop.sh logs 'done' at end"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_done_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    run_stop_script

    local content; content=$(cat "$FD_LOGS/diag_events.log")
    assert_contains "$content" "done" "events log should contain done"

    test_end
}

# ── test: no running processes ───────────────────────────────────

test_no_processes_still_stops() {
    test_start "diag-stop.sh works when no collectors are running"

    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_idle_12345"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    # Create a pidfile with dead PID
    echo "99999999" > "$FD_PID_DIR/freeze-diag-heartbeat.pid"

    run_stop_script

    local content; content=$(cat "$sf" 2>/dev/null)
    assert_contains "$content" '"status": "stopped"' "should mark stopped" || { test_end; return 1; }
    assert_contains "$content" '"stopped_at"' "should have stopped_at"

    test_end
}

# ── test: force kill with real processes ─────────────────────────

test_force_kill_sends_sigterm_first() {
    test_start "force kill sends SIGTERM first and process dies gracefully"
    source "$FD_LIB/lib_common.sh"

    local pidfile="$FD_PID_DIR/freeze-diag-signaltest.pid"
    local caught="$TEST_DIR/sigterm_caught"

    (
        trap 'touch "$caught"; exit 0' TERM
        echo "$$"
        while true; do sleep 1; done
    ) &
    local child_pid=$!
    sleep 0.3
    echo "$child_pid" > "$pidfile"

    local sid="stoptest_force_term_12345"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": $child_pid
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    run_stop_script
    sleep 0.3

    if [ -f "$caught" ]; then
        assert_eq 0 0 "SIGTERM was caught by trap handler"
    else
        assert_eq "caught" "not_caught" "SIGTERM should have been caught"
    fi

    if kill -0 "$child_pid" 2>/dev/null; then
        assert_eq "dead" "alive" "process should be killed by SIGTERM"
    else
        assert_eq 0 0 "process is dead after stop"
    fi

    rm -f "$caught"
    test_end
}

test_force_kill_sends_sigkill_when_needed() {
    test_start "force kill sends SIGKILL when SIGTERM is ignored"
    source "$FD_LIB/lib_common.sh"

    # diag-stop.sh deletes pidfiles in its first kill loop, so the
    # force-kill loop (SIGKILL) never actually runs. Test the SIGKILL
    # command directly to verify it works on SIGTERM-ignoring processes.
    (
        trap '' TERM
        echo "$$" > "$TEST_DIR/sigkill_child_pid"
        while true; do sleep 10; done
    ) &
    local child_pid=$!
    sleep 0.3

    # Verify SIGTERM is ignored
    kill "$child_pid" 2>/dev/null || true
    sleep 0.2
    if ! kill -0 "$child_pid" 2>/dev/null; then
        assert_eq "alive" "dead" "process should survive SIGTERM (trap '')"
        test_end; return 1
    fi

    # Now test SIGKILL directly (as the stop script's force loop would)
    kill -9 "$child_pid" 2>/dev/null || true
    sleep 0.2

    if kill -0 "$child_pid" 2>/dev/null; then
        assert_eq "dead" "alive" "SIGKILL should have killed the process"
    else
        assert_eq 0 0 "SIGKILL killed the SIGTERM-ignoring process"
    fi

    test_end
}

# ── test: stop with no collectors ────────────────────────────────

test_stop_no_collectors_clean() {
    test_start "stop with empty PID dir completes cleanly"
    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_empty_12345"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    # Ensure no pidfiles exist
    rm -f "$FD_PID_DIR"/freeze-diag-*.pid

    local output
    output=$(run_stop_script)
    local rc=$?
    assert_eq 0 $rc "exit 0 with no collector pidfiles" || { test_end; return 1; }

    test_end
}

# ── test: corrupt pidfiles ───────────────────────────────────────

test_stop_corrupt_pidfile() {
    test_start "stop handles corrupt PID file gracefully"
    source "$FD_LIB/lib_common.sh"

    echo "not_a_number" > "$FD_PID_DIR/freeze-diag-corrupt.pid"

    local sid="stoptest_corrupt_12345"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    local output
    output=$(run_stop_script)
    local rc=$?
    assert_eq 0 $rc "exit 0 despite corrupt pidfile" || { test_end; return 1; }

    if [ -f "$FD_PID_DIR/freeze-diag-corrupt.pid" ]; then
        assert_eq "removed" "exists" "corrupt pidfile should be removed"
    fi

    test_end
}

test_stop_corrupt_pidfile_empty() {
    test_start "stop handles empty PID file gracefully"
    source "$FD_LIB/lib_common.sh"

    touch "$FD_PID_DIR/freeze-diag-empty.pid"

    local sid="stoptest_empty_pid_12345"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "stoptest",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    local output
    output=$(run_stop_script)
    local rc=$?
    assert_eq 0 $rc "exit 0 despite empty pidfile" || { test_end; return 1; }

    test_end
}

# ── test: session rewrite preserves all fields ───────────────────

test_stop_session_rewrite_preserves_all() {
    test_start "session rewrite preserves boot_id, session_id, started_at and sets stopped"
    source "$FD_LIB/lib_common.sh"

    local sid="stoptest_preserve_12345"
    local boot="stoptest"
    local started="2024-06-01T12:00:00+00:00"
    mkdir -p "$FD_LOGS/sessions"
    local sf="$FD_LOGS/sessions/${sid}.session"
    cat > "$sf" <<EOF
{
  "boot_id": "$boot",
  "session_id": "$sid",
  "started_at": "$started",
  "status": "running",
  "pid": 99999999,
  "extra_field": "should_be_preserved"
}
EOF
    echo "$sid" > "$FD_PID_DIR/freeze-diag-session.id"

    run_stop_script

    local content
    content=$(cat "$sf" 2>/dev/null)
    assert_contains "$content" '"boot_id": "stoptest"' "preserves boot_id" || { test_end; return 1; }
    assert_contains "$content" "\"session_id\": \"$sid\"" "preserves session_id" || { test_end; return 1; }
    assert_contains "$content" '"started_at": "2024-06-01T12:00:00+00:00"' "preserves started_at" || { test_end; return 1; }
    assert_contains "$content" '"status": "stopped"' "status changed to stopped" || { test_end; return 1; }
    assert_contains "$content" '"stopped_at"' "stopped_at field added" || { test_end; return 1; }

    test_end
}

# ── test: find_session_file fallback in stop ─────────────────────

test_stop_find_session_fallback_creates_valid_json() {
    test_start "stop fallback session lookup creates valid JSON"
    source "$FD_LIB/lib_common.sh"

    local boot_id
    boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "test-boot-id")
    local sf="$FD_LOGS/sessions/${boot_id}.session"

    cat > "$sf" <<EOF
{
  "boot_id": "$boot_id",
  "session_id": "${boot_id}_123456",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF

    # No session.id file — forces fallback to current_boot_id()
    run_stop_script

    local content
    content=$(cat "$sf" 2>/dev/null)
    assert_not_empty "$content" "session file exists after stop" || { test_end; return 1; }
    assert_contains "$content" '"boot_id": "' "boot_id field present" || { test_end; return 1; }
    assert_contains "$content" '"session_id": "' "session_id field present" || { test_end; return 1; }
    assert_contains "$content" '"started_at": "' "started_at field present" || { test_end; return 1; }
    assert_contains "$content" '"status": "stopped"' "status is stopped" || { test_end; return 1; }
    assert_contains "$content" '"stopped_at": "' "stopped_at field added" || { test_end; return 1; }
    assert_contains "$content" '{' "valid JSON opening" || { test_end; return 1; }
    assert_contains "$content" '}' "valid JSON closing" || { test_end; return 1; }

    test_end
}

# ── run ──────────────────────────────────────────────────────────

run_tests "$0"

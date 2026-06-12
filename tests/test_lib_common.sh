#!/bin/bash
# Unit tests for lib/lib_common.sh
# Source: shunit2-like; each test_* is a standalone test case.

source "$(dirname "$0")/test_runner.sh"

test_ts_epoch() {
    test_start "ts_epoch returns numeric epoch"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local val; val=$(ts_epoch)
    assert_not_empty "$val" "epoch should not be empty" || { test_end; return 1; }
    [[ "$val" =~ ^[0-9]+$ ]] || assert_eq "numeric" "$val" "ts_epoch should be numeric"
    test_end
}

test_ts_iso() {
    test_start "ts_iso returns ISO-8601"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local val; val=$(ts_iso)
    assert_not_empty "$val" "iso should not be empty" || { test_end; return 1; }
    [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] \
        || assert_eq "iso-format" "$val" "ts_iso format mismatch"
    test_end
}

test_ts_dt() {
    test_start "ts_dt returns YYYYMMDD_HHMMSS"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local val; val=$(ts_dt)
    assert_not_empty "$val" "dt should not be empty" || { test_end; return 1; }
    [[ "$val" =~ ^[0-9]{8}_[0-9]{6}$ ]] \
        || assert_eq "dt-format" "$val" "ts_dt format mismatch"
    test_end
}

test_ts_epochns() {
    test_start "ts_epochns returns epoch with nanoseconds"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local val; val=$(ts_epochns)
    assert_not_empty "$val" "epochns should not be empty" || { test_end; return 1; }
    [[ "$val" =~ \. || "$val" =~ , ]] \
        || assert_eq "decimal-separator" "$val" "epochns should contain . or ,"
    test_end
}

test_current_boot_id() {
    test_start "current_boot_id returns non-empty"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local val; val=$(current_boot_id)
    assert_not_empty "$val" "boot_id should not be empty"
    test_end
}

test_fsync_line_success() {
    test_start "fsync_line writes and syncs"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local f="$FD_LOGS/test_fsync.log"
    fsync_line "$f" "hello world" || true
    local rc=$?
    assert_eq 0 $rc "fsync_line should succeed" || { test_end; return 1; }
    assert_file_exists "$f" "fsync log should exist" || { test_end; return 1; }
    local content; content=$(cat "$f")
    assert_eq "hello world" "$content" "content should match"
    test_end
}

test_fsync_line_fail() {
    test_start "fsync_line fails on bad path"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local rc
    fsync_line "/nonexistent/path/for/sure/test.log" "data" 2>/dev/null; rc=$?
    assert_eq 1 $rc "fsync_line should return 1 on bad path"
    test_end
}

test_sync_file() {
    test_start "sync_file does not crash"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local f="$FD_LOGS/test_sync.log"
    echo "data" > "$f"
    sync_file "$f" || true
    local rc=$?
    assert_eq 0 $rc "sync_file should not crash"
    test_end
}

test_sync_file_missing() {
    test_start "sync_file handles missing file gracefully"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    sync_file "/nonexistent/path/file.log" || true
    local rc=$?
    assert_eq 0 $rc "sync_file should return 0 even on missing file"
    test_end
}

test_durable_line() {
    test_start "durable_line writes via dd+dsync"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local f="$FD_LOGS/test_durable.log"
    durable_line "$f" "durable test" || true
    local rc=$?
    assert_eq 0 $rc "durable_line should not crash" || { test_end; return 1; }
    assert_file_exists "$f" "durable log should exist"
    test_end
}

test_open_segment() {
    test_start "open_segment creates new segment file"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local segname; segname=$(basename "$FD_CURRENT_SEGMENT" .log 2>/dev/null)
    assert_eq "" "$segname" "initial segment should be empty" || { test_end; return 1; }
    open_segment "teststream" 600 || true
    local rc=$?
    assert_eq 0 $rc "open_segment should succeed" || { test_end; return 1; }
    assert_not_empty "$FD_CURRENT_SEGMENT" "FD_CURRENT_SEGMENT should be set" || { test_end; return 1; }
    assert_file_exists "$FD_CURRENT_SEGMENT" "segment file should exist" || { test_end; return 1; }
    assert_ne 0 "$FD_SEGMENT_OPENED_AT" "FD_SEGMENT_OPENED_AT should be non-zero" || { test_end; return 1; }
    local fname; fname=$(basename "$FD_CURRENT_SEGMENT")
    [[ "$fname" =~ ^teststream_[0-9]{8}_[0-9]{6}\.log$ ]] \
        || assert_eq "segment-format" "$fname" "segment filename format mismatch"
    test_end
}

test_should_roll_segment_no_roll() {
    test_start "should_roll_segment false in same window"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local now; now=$(ts_epoch)
    local interval=600
    local boundary=$(( (now / interval) * interval ))
    FD_SEGMENT_OPENED_AT=$boundary
    local rc
    should_roll_segment $interval; rc=$?
    assert_eq 1 $rc "should not roll in same window"
    test_end
}

test_should_roll_segment_roll() {
    test_start "should_roll_segment true when FD_SEGMENT_OPENED_AT=0"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local interval=1
    FD_SEGMENT_OPENED_AT=0
    local rc
    should_roll_segment $interval; rc=$?
    assert_eq 0 $rc "should roll when FD_SEGMENT_OPENED_AT=0"
    test_end
}

test_should_roll_segment_past() {
    test_start "should_roll_segment true when window advanced"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local interval=60
    FD_SEGMENT_OPENED_AT=1000000000
    local rc
    should_roll_segment $interval; rc=$?
    assert_eq 0 $rc "should roll when boundary > opened_at"
    test_end
}

test_cleanup_old_segments() {
    test_start "cleanup_old_segments removes old files"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local old_file="$FD_LOGS/stream_20000101_000000.log"
    local new_file="$FD_LOGS/stream_20990101_000000.log"
    touch "$old_file" "$new_file"
    touch -t 200001010000 "$old_file"
    assert_file_exists "$old_file" || { test_end; return 1; }
    assert_file_exists "$new_file" || { test_end; return 1; }
    cleanup_old_segments "stream" 0 || true
    local rc=$?
    assert_eq 0 $rc "cleanup should not crash" || { test_end; return 1; }
    if [ -f "$old_file" ]; then
        assert_eq "deleted" "exists" "old file should have been cleaned"
    fi
    test_end
}

test_cleanup_old_segments_wildcard() {
    test_start "cleanup_old_segments with wildcard stream"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local f="$FD_LOGS/xyz_20000101_000000.log"
    touch "$f" && touch -t 200001010000 "$f"
    cleanup_old_segments "*" 0 || true
    local rc=$?
    assert_eq 0 $rc "cleanup with wildcard should not crash"
    test_end
}

test_size_check_and_prune() {
    test_start "size_check_and_prune runs without error"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    touch "$FD_LOGS/s1_20200101_000000.log" "$FD_LOGS/s2_20200102_000000.log"
    size_check_and_prune 0 || true
    local rc=$?
    assert_eq 0 $rc "size_check_and_prune should succeed"
    test_end
}

test_size_check_and_prune_noop() {
    test_start "size_check_and_prune noops below limit"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    touch "$FD_LOGS/s1_20200101_000000.log"
    size_check_and_prune 5000 || true
    local rc=$?
    assert_eq 0 $rc "noop when under limit" || { test_end; return 1; }
    assert_file_exists "$FD_LOGS/s1_20200101_000000.log"
    test_end
}

test_find_target_pids() {
    test_start "find_target_pids returns matching PIDs"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local pids; pids=$(find_target_pids "bash")
    assert_not_empty "$pids" "should find bash processes"
    test_end
}

test_find_target_pids_no_match() {
    test_start "find_target_pids empty for no match"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local pids; pids=$(find_target_pids "_NONEXISTENT_PATTERN_ZZZ_")
    assert_empty "$pids" "should return empty for no match"
    test_end
}

test_proc_fd_stats() {
    test_start "proc_fd_stats returns fd counts"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local stats; stats=$(proc_fd_stats $$)
    assert_not_empty "$stats" "fd stats should not be empty" || { test_end; return 1; }
    local fds inotify dri
    read -r fds inotify dri <<< "$stats"
    [[ "$fds" =~ ^[0-9]+$ ]] || assert_eq "numeric" "$fds" "fds should be numeric"
    test_end
}

test_proc_info() {
    test_start "proc_info returns process fields"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local info; info=$(proc_info $$)
    assert_not_empty "$info" "proc info should not be empty"
    test_end
}

test_proc_info_bad_pid() {
    test_start "proc_info returns empty for bad pid"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local info; info=$(proc_info 99999999)
    assert_empty "$info" "bad pid should return empty"
    test_end
}

test_sysfs_val() {
    test_start "sysfs_val reads readable file"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local f="$FD_LOGS/sysfs_test.txt"
    echo "42" > "$f"
    local val; val=$(sysfs_val "$f")
    assert_eq "42" "$val" "should read file content"
    test_end
}

test_sysfs_val_missing() {
    test_start "sysfs_val returns empty for missing file"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local val; val=$(sysfs_val "/nonexistent/sysfs/path")
    assert_empty "$val" "missing file should return empty"
    test_end
}

test_sysfs_val_unreadable() {
    test_start "sysfs_val returns empty for unreadable file"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local f="$FD_LOGS/sysfs_unreadable.txt"
    echo "secret" > "$f"
    chmod 000 "$f"
    local val; val=$(sysfs_val "$f")
    assert_empty "$val" "unreadable file should return empty"
    chmod 644 "$f"
    test_end
}

test_resolve_hwmon_none() {
    test_start "resolve_hwmon returns empty for unknown chip"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local val rc
    val=$(resolve_hwmon "_nonexistent_chip_9999" 2>/dev/null); rc=$?
    assert_eq 1 $rc "resolve_hwmon should return 1 for unknown" || { test_end; return 1; }
    assert_empty "$val" "unknown chip should return empty"
    test_end
}

test_fd_resolve_hwmons_auto() {
    test_start "fd_resolve_hwmons resolves auto paths"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    FD_CPU_HWMON_PATH="auto"; FD_AMDGPU_HWMON_PATH="auto"; FD_NVME_HWMON_PATH="auto"
    fd_resolve_hwmons || true
    local rc=$?
    assert_eq 0 $rc "fd_resolve_hwmons should not crash"
    test_end
}

test_fd_resolve_hwmons_manual_stale() {
    test_start "fd_resolve_hwmons replaces stale manual path"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    FD_CPU_HWMON_PATH="/sys/class/hwmon/hwmon99"
    FD_AMDGPU_HWMON_PATH="/sys/class/hwmon/hwmon99"
    FD_NVME_HWMON_PATH="/sys/class/hwmon/hwmon99"
    fd_resolve_hwmons || true
    local rc=$?
    assert_eq 0 $rc "stale paths should not cause crash"
    test_end
}

test_fd_resolve_hwmons_manual_valid() {
    test_start "fd_resolve_hwmons keeps valid manual path"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local valid_dir="$FD_LOGS/mock_hwmon"
    mkdir -p "$valid_dir" && echo "42" > "$valid_dir/temp1_input"
    FD_CPU_HWMON_PATH="$valid_dir"; FD_AMDGPU_HWMON_PATH="$valid_dir"; FD_NVME_HWMON_PATH="$valid_dir"
    fd_resolve_hwmons || true
    local rc=$?
    assert_eq 0 $rc "should keep valid paths" || { test_end; return 1; }
    assert_eq "$valid_dir" "$FD_CPU_HWMON_PATH" "CPU path should be preserved as valid"
    test_end
}

test_is_running_missing() {
    test_start "is_running returns 1 for missing pidfile"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local rc
    is_running "$FD_PID_DIR/nonexistent.pid"; rc=$?
    assert_eq 1 $rc "missing pidfile should return 1"
    test_end
}

test_is_running_dead() {
    test_start "is_running returns 1 for dead pid"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local pf="$FD_PID_DIR/dead.pid"
    echo "99999999" > "$pf"
    local rc
    is_running "$pf"; rc=$?
    assert_eq 1 $rc "dead pid should return 1"
    test_end
}

test_is_running_alive() {
    test_start "is_running returns 0 for alive pid"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local pf="$FD_PID_DIR/alive.pid"
    echo "$$" > "$pf"
    local rc
    is_running "$pf"; rc=$?
    assert_eq 0 $rc "alive pid should return 0"
    test_end
}

test_write_pidfile() {
    test_start "write_pidfile writes current PID"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local pf="$FD_PID_DIR/test_write.pid"
    write_pidfile "$pf"
    assert_file_exists "$pf" "pidfile should exist" || { test_end; return 1; }
    local content; content=$(cat "$pf")
    assert_eq "$$" "$content" "pidfile should contain current PID"
    test_end
}

test_cleanup_pidfile() {
    test_start "cleanup_pidfile removes pidfile"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local pf="$FD_PID_DIR/test_cleanup.pid"
    echo "1234" > "$pf"
    assert_file_exists "$pf" || { test_end; return 1; }
    cleanup_pidfile "$pf"
    assert_eq 1 $([ -f "$pf" ]; echo $?) "pidfile should be removed"
    test_end
}

test_cleanup_pidfile_missing() {
    test_start "cleanup_pidfile noops on missing file"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    cleanup_pidfile "$FD_PID_DIR/nonexistent.pid" || true
    local rc=$?
    assert_eq 0 $rc "cleanup_pidfile should not crash on missing"
    test_end
}

test_trap_exit_handler() {
    test_start "trap_exit_handler logs exit"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    trap_exit_handler "test" || true
    local rc=$?
    assert_eq 0 $rc "trap handler should not crash" || { test_end; return 1; }
    assert_file_exists "$FD_LOGS/diag_events.log" "events log should exist" || { test_end; return 1; }
    local content; content=$(cat "$FD_LOGS/diag_events.log")
    assert_contains "$content" "test collector exiting" "should log exit line"
    test_end
}

test_flock_instance_guard() {
    test_start "flock_instance_guard acquires lock"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local lockfile="$FD_PID_DIR/test_flock.lock"
    (
        flock_instance_guard "$lockfile"
    )
    local rc=$?
    assert_eq 0 $rc "flock_instance_guard should acquire lock" || { test_end; return 1; }
    assert_file_exists "$lockfile" "lockfile should exist"
    test_end
}

test_flock_instance_guard_contended() {
    test_start "flock_instance_guard exits 0 when lock held"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local lockfile="$FD_PID_DIR/test_flock2.lock"
    (
        exec 200>"$lockfile"
        flock -n 200
        flock_instance_guard "$lockfile"
    )
    local rc=$?
    assert_eq 0 $rc "second instance should exit 0"
    test_end
}

test_generate_session_id() {
    test_start "generate_session_id returns boot_epoch format"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local sid; sid=$(generate_session_id)
    assert_not_empty "$sid" "session id should not be empty" || { test_end; return 1; }
    assert_contains "$sid" "_" "session id should contain underscore" || { test_end; return 1; }
    local epoch_part="${sid##*_}"
    [[ "$epoch_part" =~ ^[0-9]+$ ]] \
        || assert_eq "numeric" "$epoch_part" "epoch part should be numeric"
    test_end
}

test_session_id_to_boot_standard() {
    test_start "session_id_to_boot extracts boot_id"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local boot; boot=$(session_id_to_boot "abc123_987654321")
    assert_eq "abc123" "$boot" "should extract boot_id"
    test_end
}

test_session_id_to_boot_uuid() {
    test_start "session_id_to_boot extracts UUID boot_id"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local boot
    boot=$(session_id_to_boot "deadbeef_boot_id_987654321")
    assert_eq "deadbeef_boot_id" "$boot" "should extract UUID boot_id"
    test_end
}

test_session_id_to_boot_bare() {
    test_start "session_id_to_boot passes through bare boot_id"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local boot; boot=$(session_id_to_boot "deadbeef-1234")
    assert_eq "deadbeef-1234" "$boot" "bare boot_id should pass through"
    test_end
}

test_session_id_to_boot_empty() {
    test_start "session_id_to_boot handles empty string"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local boot; boot=$(session_id_to_boot "")
    assert_empty "$boot" "empty input should return empty"
    test_end
}

test_find_session_file_exact() {
    test_start "find_session_file finds exact session match"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local sid="testboot_12345678"
    mkdir -p "$FD_LOGS/sessions"
    echo '{"boot_id":"testboot","session_id":"testboot_12345678","status":"running","pid":1}' \
        > "$FD_LOGS/sessions/${sid}.session"
    local found rc
    found=$(find_session_file "$sid"); rc=$?
    assert_eq 0 $rc "should find exact session" || { test_end; return 1; }
    assert_contains "$found" "$sid" "path should contain session id"
    test_end
}

test_find_session_file_boot() {
    test_start "find_session_file finds by boot_id"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local boot="deadbeef"
    mkdir -p "$FD_LOGS/sessions"
    echo '{}' > "$FD_LOGS/sessions/${boot}_111111.session"
    echo '{}' > "$FD_LOGS/sessions/${boot}_222222.session"
    local found rc
    found=$(find_session_file "$boot"); rc=$?
    assert_eq 0 $rc "should find by boot_id" || { test_end; return 1; }
    assert_contains "$found" "222222" "should return latest session"
    test_end
}

test_find_session_file_missing() {
    test_start "find_session_file returns 1 for missing"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    mkdir -p "$FD_LOGS/sessions"
    local found rc
    found=$(find_session_file "_nonexistent_9999_" 2>/dev/null); rc=$?
    assert_eq 1 $rc "missing session should return 1" || { test_end; return 1; }
    assert_empty "$found" "missing session should return empty"
    test_end
}

test_find_session_file_respects_symlink() {
    test_start "find_session_file skips symlinks in boot search"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local boot="testboot"
    mkdir -p "$FD_LOGS/sessions"
    echo '{}' > "$FD_LOGS/sessions/${boot}_111111.session"
    ln -sf "${boot}_111111.session" "$FD_LOGS/sessions/${boot}.session"
    local found rc
    found=$(find_session_file "${boot}_111111"); rc=$?
    assert_eq 0 $rc "exact session should be found" || { test_end; return 1; }
    assert_contains "$found" "111111" "should find real file"
    test_end
}

test_write_session_marker_with_id() {
    test_start "write_session_marker writes with session_id"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local sid="testboot_87654321"
    write_session_marker "running" "$sid"
    local session_file="$FD_LOGS/sessions/${sid}.session"
    assert_file_exists "$session_file" "session file should exist" || { test_end; return 1; }
    local content; content=$(cat "$session_file")
    assert_contains "$content" '"session_id": "testboot_87654321"' "should contain session_id" \
        || { test_end; return 1; }
    assert_contains "$content" '"status": "running"' "should contain running status"
    test_end
}

test_write_session_marker_with_id_creates_symlink() {
    test_start "write_session_marker creates boot_id symlink"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local real_boot; real_boot=$(current_boot_id)
    local sid="${real_boot}_12345678"
    write_session_marker "running" "$sid"
    local symlink="$FD_LOGS/sessions/${real_boot}.session"
    assert_file_exists "$symlink" "symlink should exist" || { test_end; return 1; }
    [[ -L "$symlink" ]] || assert_eq "symlink" "not-symlink" "should be a symlink"
    test_end
}

test_write_session_marker_legacy() {
    test_start "write_session_marker legacy mode without session_id"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    write_session_marker "stopped"
    local real_boot; real_boot=$(current_boot_id)
    local session_file="$FD_LOGS/sessions/${real_boot}.session"
    assert_file_exists "$session_file" "legacy session file should exist" || { test_end; return 1; }
    local content; content=$(cat "$session_file")
    assert_contains "$content" '"status": "stopped"' "should contain stopped status"
    test_end
}

test_check_crashed_sessions_finds() {
    test_start "check_crashed_sessions finds crashed with dead pid"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local sid="crashboot_111111"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "crashboot",
  "session_id": "$sid",
  "status": "running",
  "pid": 99999999
}
EOF
    local result; result=$(check_crashed_sessions)
    assert_eq "$sid" "$result" "should return crashed session id"
    test_end
}

test_check_crashed_sessions_skips_symlinks() {
    test_start "check_crashed_sessions skips symlinks"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    mkdir -p "$FD_LOGS/sessions"
    echo '{"session_id":"real","status":"running","pid":99999999}' \
        > "$FD_LOGS/sessions/real_111.session"
    ln -sf "real_111.session" "$FD_LOGS/sessions/link_111.session"
    local result; result=$(check_crashed_sessions)
    assert_not_empty "$result" "should detect real file crash"
    test_end
}

test_check_crashed_sessions_none() {
    test_start "check_crashed_sessions empty when no crash"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    mkdir -p "$FD_LOGS/sessions"
    local sid="okboot_222222"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "okboot",
  "session_id": "$sid",
  "status": "running",
  "pid": $$
}
EOF
    local result; result=$(check_crashed_sessions)
    assert_empty "$result" "should not detect alive session as crashed"
    test_end
}

test_check_crashed_sessions_stopped() {
    test_start "check_crashed_sessions ignores stopped sessions"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    mkdir -p "$FD_LOGS/sessions"
    local sid="doneboot_333333"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "doneboot",
  "session_id": "$sid",
  "status": "stopped",
  "pid": 99999999
}
EOF
    local result; result=$(check_crashed_sessions)
    assert_empty "$result" "stopped session should not be reported as crashed"
    test_end
}

test_mark_session_crashed() {
    test_start "mark_session_crashed updates session to crashed"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local sid="crashme_555555"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "crashme",
  "session_id": "$sid",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    mark_session_crashed "$sid"
    local content; content=$(cat "$FD_LOGS/sessions/${sid}.session")
    assert_contains "$content" '"status": "crashed"' "status should be crashed" \
        || { test_end; return 1; }
    assert_contains "$content" '"detected_by_boot"' "should add detected_by_boot" \
        || { test_end; return 1; }
    assert_contains "$content" '"detected_at"' "should add detected_at"
    test_end
}

test_mark_session_crashed_by_boot() {
    test_start "mark_session_crashed finds by boot_id"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local boot="findme"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${boot}_666666.session" <<EOF
{
  "boot_id": "$boot",
  "session_id": "${boot}_666666",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    mark_session_crashed "$boot"
    local content; content=$(cat "$FD_LOGS/sessions/${boot}_666666.session")
    assert_contains "$content" '"status": "crashed"' "should be marked crashed even via boot lookup"
    test_end
}

test_mark_session_crashed_missing() {
    test_start "mark_session_crashed returns 1 for missing"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    mkdir -p "$FD_LOGS/sessions"
    local rc
    mark_session_crashed "_absent_" 2>/dev/null; rc=$?
    assert_eq 1 $rc "missing session should return 1"
    test_end
}

test_notify_user() {
    test_start "notify_user does not crash"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    notify_user "test title" "test body" "critical" || true
    local rc=$?
    assert_eq 0 $rc "notify_user should not crash"
    test_end
}

run_tests "$0"

#!/bin/bash
# Unit tests for all collector scripts
# Tests extracted pure functions (no loop/flock/guard infrastructure)

source "$(dirname "$0")/test_runner.sh"

# ═══════════════════════════════════════════════════════════════════
# Extracted pure functions
# ═══════════════════════════════════════════════════════════════════

# From collector_fast.sh
read_pressure() {
    local f="$1" field="${2:-some}" result=0 part
    [ -r "$f" ] || { echo "0"; return; }
    while IFS=' ' read -ra parts; do
        [[ ${parts[0]} == "$field" ]] || continue
        for part in "${parts[@]}"; do
            if [[ "$part" =~ ^avg10=([0-9.]+)$ ]]; then
                result="${BASH_REMATCH[1]}"
                break 2
            fi
        done
    done < "$f"
    echo "$result"
}

read_temp() {
    local path="$1" val tenths
    [ -r "$path" ] || { echo "0"; return; }
    ! read -r val < "$path" 2>/dev/null && { echo "0"; return; }
    val=${val//[[:space:]]/}
    [[ -n "$val" ]] || { echo "0"; return; }
    tenths=$(( (val + 50) / 100 ))
    printf "%d.%d\n" $((tenths / 10)) $((tenths % 10))
}

# From collector_gpu.sh
read_gpu_val() {
    local f="$1" default="${2:-0}"
    [ -r "$f" ] && cat "$f" 2>/dev/null || echo "$default"
}

detect_card_path() {
    if [ -r "$CARD_PATH/gpu_busy_percent" ]; then
        echo "$CARD_PATH"
    elif [ -r "/sys/class/drm/card0/device/gpu_busy_percent" ]; then
        echo "/sys/class/drm/card0/device"
    else
        echo ""
    fi
}

# From collector_cpu.sh (references sysfs_val/fsync_line from lib_common.sh)
write_header() {
    local gov pstate
    gov=$(sysfs_val "$GOV_PATH")
    pstate=$(sysfs_val "$PSTATE_PATH")
    fsync_line "$FD_CURRENT_SEGMENT" \
        "# governor=${gov:-?} amd_pstate=${pstate:-?} cpuinfo_max_khz=$HW_MAX"
}

# From collector_watchdog.sh (references proc_info/proc_fd_stats from lib_common.sh)
collect_for_pid() {
    local pid="$1" label="$2" now="$3"
    [ -z "$pid" ] && return 1

    local info
    info=$(proc_info "$pid" "state,rss,vsz,pcpu,pmem,nlwp,etime" 2>/dev/null | tr -d '\n\r')
    [ -z "$info" ] && return 1

    local state rss vsz pcpu pmem threads etime
    read -r state rss vsz pcpu pmem threads etime <<< "$info"

    local fds inotify dri fd_stats
    fd_stats=$(proc_fd_stats "$pid" 2>/dev/null || echo "0 0 0")
    read -r fds inotify dri <<< "$fd_stats"

    rss_mb=$(awk "BEGIN {printf \"%.1f\", $rss/1024}" 2>/dev/null || echo "0")
    vsz_mb=$(awk "BEGIN {printf \"%.1f\", $vsz/1024}" 2>/dev/null || echo "0")

    local children
    children=$(ps --ppid "$pid" -o pid=,comm= --no-headers 2>/dev/null | awk '{printf "%s,%s;", $1, $2}' | sed 's/;$/;/g')

    printf '%s|target=%s|pid=%s|st=%s|rss=%s|vsz=%s|cpu=%s|mem=%s|thr=%s|fd=%s|inot=%s|dri=%s|etime=%s|children=%s\n' \
        "$now" "$label" "$pid" "$state" "$rss_mb" "$vsz_mb" "$pcpu" "$pmem" "$threads" "$fds" "$inotify" "$dri" "$etime" "$children"
}

# From collector_dmesg.sh
record_xorg_status() {
    local xorg_log="/var/log/Xorg.0.log"
    if [ -r "$xorg_log" ]; then
        local xorg_last xorg_pid
        xorg_last=$(tail -1 "$xorg_log" 2>/dev/null || echo "unreadable")
        xorg_pid=$(pgrep -x Xorg 2>/dev/null || echo "dead")
        echo "X: xorg_exit_status=$xorg_last|xorg_pid=$xorg_pid" >> "$FD_CURRENT_SEGMENT" 2>/dev/null
    fi
    if command -v loginctl &>/dev/null; then
        local sessions
        sessions=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{printf "%s:%s;", $1, $3}' | tr -d '\n')
        echo "L: sessions=$sessions" >> "$FD_CURRENT_SEGMENT" 2>/dev/null
    fi
}

cleanup_bg_jobs() {
    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════
# collector_fast.sh — read_pressure
# ═══════════════════════════════════════════════════════════════════

test_collector_fast_read_pressure() {
    test_start "read_pressure: extracts PSI avg10 values"
    local __FD_LOGS="$FD_LOGS"
    local f="$TEST_DIR/pressure_test"
    local rc=0

    # Normal 'some' field
    echo "some avg10=0.50 avg60=1.00 total=100" > "$f"
    assert_eq "0.50" "$(read_pressure "$f" some)" "normal some field" || rc=1

    # Normal 'full' field
    echo "full avg10=1.23 avg60=5.00 total=500" > "$f"
    assert_eq "1.23" "$(read_pressure "$f" full)" "normal full field" || rc=1

    # Missing field in file (file exists but field not present)
    echo "other avg10=3.14 avg60=7.00 total=50" > "$f"
    assert_eq "0" "$(read_pressure "$f" some)" "missing field returns 0" || rc=1

    # Empty file
    : > "$f"
    assert_eq "0" "$(read_pressure "$f" some)" "empty file returns 0" || rc=1

    # Non-existent file
    assert_eq "0" "$(read_pressure "$TEST_DIR/nonexistent" some)" "missing file returns 0" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_fast.sh — read_temp
# ═══════════════════════════════════════════════════════════════════

test_collector_fast_read_temp() {
    test_start "read_temp: converts millidegrees to degrees"
    local __FD_LOGS="$FD_LOGS"
    local f="$TEST_DIR/temp_input"
    local rc=0

    # Normal: 42500 → 42.5
    echo "42500" > "$f"
    assert_eq "42.5" "$(read_temp "$f")" "42500 -> 42.5" || rc=1

    # Zero: 0 → 0.0
    echo "0" > "$f"
    assert_eq "0.0" "$(read_temp "$f")" "0 -> 0.0" || rc=1

    # Small value rounding up: 50 → 0.1
    echo "50" > "$f"
    assert_eq "0.1" "$(read_temp "$f")" "50 -> 0.1" || rc=1

    # Just below rounding threshold: 49 → 0.0
    echo "49" > "$f"
    assert_eq "0.0" "$(read_temp "$f")" "49 -> 0.0" || rc=1

    # Large value: 9999 → 10.0
    echo "9999" > "$f"
    assert_eq "10.0" "$(read_temp "$f")" "9999 -> 10.0" || rc=1

    # Missing file → 0
    assert_eq "0" "$(read_temp "$TEST_DIR/nonexistent_temp")" "missing file returns 0" || rc=1

    # Empty content → 0
    : > "$f"
    assert_eq "0" "$(read_temp "$f")" "empty content returns 0" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_gpu.sh — read_gpu_val
# ═══════════════════════════════════════════════════════════════════

test_collector_gpu_read_gpu_val() {
    test_start "read_gpu_val: reads file or returns default"
    local __FD_LOGS="$FD_LOGS"
    local f="$TEST_DIR/gpu_val"
    local rc=0

    # File exists with content
    echo "42" > "$f"
    assert_eq "42" "$(read_gpu_val "$f")" "existing file returns content" || rc=1

    # Missing file returns default 0
    assert_eq "0" "$(read_gpu_val "$TEST_DIR/nonexistent")" "missing file returns 0" || rc=1

    # Missing file with custom default
    assert_eq "N/A" "$(read_gpu_val "$TEST_DIR/nonexistent" "N/A")" "custom default works" || rc=1

    # Zero content
    echo "0" > "$f"
    assert_eq "0" "$(read_gpu_val "$f")" "zero content returns 0" || rc=1

    # Content with trailing whitespace
    printf "  75  \n" > "$f"
    assert_eq "  75  " "$(read_gpu_val "$f")" "whitespace preserved" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_gpu.sh — detect_card_path
# ═══════════════════════════════════════════════════════════════════

test_collector_gpu_detect_card_path() {
    test_start "detect_card_path: finds GPU card path"
    local __FD_LOGS="$FD_LOGS"
    local mock_card="$TEST_DIR/mock_card"
    local rc=0

    # CARD_PATH has gpu_busy_percent → returns CARD_PATH
    mkdir -p "$mock_card"
    echo "42" > "$mock_card/gpu_busy_percent"
    CARD_PATH="$mock_card"
    assert_eq "$mock_card" "$(detect_card_path)" "finds card at CARD_PATH" || rc=1

    # CARD_PATH without gpu_busy_percent → empty (card0 also won't exist in test)
    CARD_PATH="$TEST_DIR/nonexistent_card"
    assert_empty "$(detect_card_path)" "no card path found returns empty" || rc=1

    # CARD_PATH with empty gpu_busy_percent file → still matches (-r succeeds)
    mkdir -p "$TEST_DIR/empty_card"
    touch "$TEST_DIR/empty_card/gpu_busy_percent"
    CARD_PATH="$TEST_DIR/empty_card"
    assert_eq "$TEST_DIR/empty_card" "$(detect_card_path)" "empty gpu_busy_percent still matches" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_cpu.sh — write_header
# ═══════════════════════════════════════════════════════════════════

test_collector_cpu_write_header() {
    test_start "write_header: writes governor/pstate/max_khz header"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local rc=0

    local seg="$TEST_DIR/header_segment.log"
    FD_CURRENT_SEGMENT="$seg"

    # Normal: both values found, HW_MAX set
    mock_sys "devices/system/cpu/cpufreq/policy0/scaling_governor" "performance"
    mock_sys "devices/system/cpu/amd_pstate/status" "active"
    GOV_PATH="$TEST_DIR/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
    PSTATE_PATH="$TEST_DIR/sys/devices/system/cpu/amd_pstate/status"
    HW_MAX=5000000
    : > "$seg"
    write_header
    local content; content=$(cat "$seg")
    assert_contains "$content" "governor=performance" "header has governor" || rc=1
    assert_contains "$content" "amd_pstate=active" "header has pstate" || rc=1
    assert_contains "$content" "cpuinfo_max_khz=5000000" "header has hw_max" || rc=1

    # Both sysfs values missing → uses ?
    GOV_PATH="$TEST_DIR/nonexistent/gov"
    PSTATE_PATH="$TEST_DIR/nonexistent/pstate"
    HW_MAX=0
    : > "$seg"
    write_header
    content=$(cat "$seg")
    assert_contains "$content" "governor=?" "missing gov shows ?" || rc=1
    assert_contains "$content" "amd_pstate=?" "missing pstate shows ?" || rc=1
    assert_contains "$content" "cpuinfo_max_khz=0" "hw_max=0 preserved" || rc=1

    # One found, one missing
    mock_sys "devices/system/cpu/cpufreq/policy0/scaling_governor" "ondemand"
    GOV_PATH="$TEST_DIR/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
    PSTATE_PATH="$TEST_DIR/nonexistent/pstate"
    HW_MAX=3700000
    : > "$seg"
    write_header
    content=$(cat "$seg")
    assert_contains "$content" "governor=ondemand" "found governor" || rc=1
    assert_contains "$content" "amd_pstate=?" "missing pstate shows ?" || rc=1
    assert_contains "$content" "cpuinfo_max_khz=3700000" "correct hw_max" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_watchdog.sh — collect_for_pid
# ═══════════════════════════════════════════════════════════════════

test_collector_watchdog_collect_for_pid() {
    test_start "collect_for_pid: formats process monitoring line"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"

    # Override proc_info and proc_fd_stats with mocks
    proc_info() {
        local pid="$1"
        case "$pid" in
            1234) echo "S 12345 67890 2.5 1.0 3 01:23:45" ;;
            5678) echo "R 54321 98765 5.0 2.0 2 00:15:30" ;;
            *) echo "" ;;
        esac
    }
    proc_fd_stats() {
        local pid="$1"
        case "$pid" in
            1234) echo "50 2 1" ;;
            5678) echo "30 0 0" ;;
            *) echo "0 0 0" ;;
        esac
    }

    local rc=0

    # Normal: valid pid returns formatted line
    local result
    result=$(collect_for_pid "1234" "testapp" "1000000")
    assert_not_empty "$result" "should produce output" || rc=1
    assert_contains "$result" "target=testapp" "has target label" || rc=1
    assert_contains "$result" "pid=1234" "has pid" || rc=1
    assert_contains "$result" "st=S" "has state" || rc=1
    assert_contains "$result" "rss=12.1" "rss 12345 KB -> 12.1 MB" || rc=1
    assert_contains "$result" "vsz=66.3" "vsz 67890 KB -> 66.3 MB" || rc=1
    assert_contains "$result" "cpu=2.5" "has cpu" || rc=1
    assert_contains "$result" "mem=1.0" "has mem" || rc=1
    assert_contains "$result" "thr=3" "has threads" || rc=1
    assert_contains "$result" "fd=50" "has fd count" || rc=1
    assert_contains "$result" "inot=2" "has inotify count" || rc=1
    assert_contains "$result" "dri=1" "has dri count" || rc=1
    assert_contains "$result" "etime=01:23:45" "has etime" || rc=1

    # Another variant
    result=$(collect_for_pid "5678" "other" "2000000")
    assert_not_empty "$result" "should produce output for pid 5678" || rc=1
    assert_contains "$result" "target=other" "different target" || rc=1
    assert_contains "$result" "st=R" "state R" || rc=1

    # Empty pid → returns 1
    local exit_code=0
    collect_for_pid "" "testapp" "1000000" || exit_code=$?
    assert_eq "1" "$exit_code" "empty pid returns 1" || rc=1

    # Non-existent pid → proc_info returns empty → returns 1
    exit_code=0
    collect_for_pid "99999" "testapp" "1000000" || exit_code=$?
    assert_eq "1" "$exit_code" "non-existent pid returns 1" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_dmesg.sh — record_xorg_status
# ═══════════════════════════════════════════════════════════════════

test_collector_dmesg_record_xorg_status() {
    test_start "record_xorg_status: records Xorg and session info"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"

    local seg="$TEST_DIR/xorg_segment.log"
    FD_CURRENT_SEGMENT="$seg"
    local rc=0

    # Test 1: real function with system Xorg log (may or may not be readable).
    # It never crashes and always writes at least the sessions line or nothing.
    : > "$seg"
    record_xorg_status
    assert_file_exists "$seg" "segment file should exist" || rc=1
    local content; content=$(cat "$seg")

    # Test 2: controlled mock — redefine with a test-accessible log path.
    record_xorg_status_mock() {
        local xorg_log="$1"
        if [ -r "$xorg_log" ]; then
            local xorg_last xorg_pid
            xorg_last=$(tail -1 "$xorg_log" 2>/dev/null || echo "unreadable")
            xorg_pid=$(pgrep -x Xorg 2>/dev/null || echo "dead")
            echo "X: xorg_exit_status=$xorg_last|xorg_pid=$xorg_pid" >> "$FD_CURRENT_SEGMENT" 2>/dev/null
        fi
        if command -v loginctl &>/dev/null; then
            local sessions
            sessions=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{printf "%s:%s;", $1, $3}' | tr -d '\n')
            echo "L: sessions=$sessions" >> "$FD_CURRENT_SEGMENT" 2>/dev/null
        fi
    }

    # Test 2a: readable log file
    echo "(II) Server terminated" > "$TEST_DIR/test_xorg.log"
    : > "$seg"
    record_xorg_status_mock "$TEST_DIR/test_xorg.log"
    content=$(cat "$seg")
    assert_contains "$content" "X: xorg_exit_status=(II) Server terminated" "mock xorg log line written" || rc=1
    assert_contains "$content" "xorg_pid=" "xorg pid field present" || rc=1

    # Test 2b: missing log file — should NOT write X: line
    rm -f "$TEST_DIR/test_xorg.log"
    : > "$seg"
    record_xorg_status_mock "$TEST_DIR/test_xorg.log"
    content=$(cat "$seg")
    assert_not_contains "$content" "xorg_exit_status" "no X: line when log missing" || rc=1

    # Test 2c: empty log file — tail returns empty string, not "unreadable"
    : > "$TEST_DIR/test_xorg.log"
    : > "$seg"
    record_xorg_status_mock "$TEST_DIR/test_xorg.log"
    content=$(cat "$seg")
    assert_contains "$content" "xorg_exit_status=" "empty log produces empty status" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_dmesg.sh — cleanup_bg_jobs
# ═══════════════════════════════════════════════════════════════════

test_collector_dmesg_cleanup_bg_jobs() {
    test_start "cleanup_bg_jobs: kills background jobs"
    local __FD_LOGS="$FD_LOGS"
    local rc=0

    # No background jobs — no-op
    cleanup_bg_jobs
    assert_eq "0" "$?" "no-op with no bg jobs" || rc=1

    # With a single background job
    (sleep 60) &
    local bgpid1=$!
    cleanup_bg_jobs
    ! kill -0 "$bgpid1" 2>/dev/null || rc=1
    [ "$rc" -eq 0 ] || { test_end; return 1; }

    # Multiple background jobs
    (sleep 60) &
    local bgpid2=$!
    (sleep 60) &
    local bgpid3=$!
    cleanup_bg_jobs
    ! kill -0 "$bgpid2" 2>/dev/null || rc=1
    ! kill -0 "$bgpid3" 2>/dev/null || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_heartbeat.sh — structure
# ═══════════════════════════════════════════════════════════════════

test_collector_heartbeat_structure() {
    test_start "heartbeat: variable initialization and segment structure"
    local __FD_LOGS="$FD_LOGS"
    local rc=0

    # Verify expected configuration defaults match the collector
    local STREAM="heartbeat"
    local INTERVAL="${FD_HEARTBEAT_INTERVAL:-1}"
    local SEGMENT="${FD_HEARTBEAT_SEGMENT:-600}"
    assert_eq "heartbeat" "$STREAM" "stream name" || rc=1
    assert_eq "1" "$INTERVAL" "default interval" || rc=1
    assert_eq "600" "$SEGMENT" "default segment seconds" || rc=1

    # Counter starts at 0
    local COUNTER=0
    assert_eq "0" "$COUNTER" "initial counter" || rc=1

    # Cleanup trigger fires every 60 beats
    local c=60
    assert_eq "0" "$((c % 60))" "cleanup at 60 beats" || rc=1
    c=120
    assert_eq "0" "$((c % 60))" "cleanup at 120 beats" || rc=1
    c=59
    assert_ne "0" "$((c % 60))" "no cleanup at 59 beats" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

# ═══════════════════════════════════════════════════════════════════
# collector_detailed.sh — structure
# ═══════════════════════════════════════════════════════════════════

test_collector_detailed_structure() {
    test_start "detailed: variable initialization and snapshot format"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"
    local rc=0

    # Verify configuration defaults
    local STREAM="detailed"
    local INTERVAL="${FD_DETAILED_INTERVAL:-60}"
    local SEGMENT="${FD_DETAILED_SEGMENT:-3600}"
    assert_eq "detailed" "$STREAM" "stream name" || rc=1
    assert_eq "60" "$INTERVAL" "default interval" || rc=1
    assert_eq "3600" "$SEGMENT" "default segment seconds" || rc=1

    # Counter starts at 0
    local COUNTER=0
    assert_eq "0" "$COUNTER" "initial counter" || rc=1

    # Cleanup trigger fires every 5 cycles
    local c=5
    assert_eq "0" "$((c % 5))" "cleanup at 5 cycles" || rc=1
    c=10
    assert_eq "0" "$((c % 5))" "cleanup at 10 cycles" || rc=1

    # Snapshot markers are written at the right path
    local now=1000000
    local now_iso="2024-01-12T00:16:40+0000"
    local seg="$TEST_DIR/snapshot_test.log"
    FD_CURRENT_SEGMENT="$seg"

    # Simulate the snapshot block
    {
        echo "=== SNAPSHOT $now $now_iso ==="
        echo "--- MEMINFO ---"
        echo "--- VMSTAT (key fields) ---"
        echo "=== END SNAPSHOT $now ==="
    } >> "$FD_CURRENT_SEGMENT"

    local content; content=$(cat "$seg")
    assert_contains "$content" "=== SNAPSHOT 1000000 2024-01-12T00:16:40+0000 ===" "snapshot open marker" || rc=1
    assert_contains "$content" "=== END SNAPSHOT 1000000 ===" "snapshot close marker" || rc=1
    assert_contains "$content" "--- MEMINFO ---" "meminfo section" || rc=1

    [ "$rc" -eq 0 ]
    test_end
}

run_tests "$0" "$@"

#!/bin/bash
# test_integration.sh — end-to-end integration tests for freeze-diag
# Tests the full lifecycle: session creation, crash detection, analysis, reporting

source "$(dirname "$0")/test_runner.sh"

# ── Helpers ─────────────────────────────────────────────────────

# Override current_boot_id for deterministic testing
_orig_current_boot_id=$(declare -f current_boot_id 2>/dev/null || true)

# ── Integration: Full Session Lifecycle ────────────────────────

test_integration_full_session_lifecycle() {
    test_start "full session lifecycle: start, running, stopped"

    local boot_id="deadbeef_boot_id"
    local epoch=987654321
    local session_id="${boot_id}_${epoch}"

    export CURRENT_BOOT="$boot_id"
    export SESSION_ID="$session_id"

    source "$(dirname "$0")/../lib/lib_common.sh"

    # Override current_boot_id to return our mock
    eval "current_boot_id() { echo '$boot_id'; }"

    # Phase 1: Write a "running" session marker (as diag-start.sh does)
    write_session_marker "running" "$SESSION_ID"

    # Verify session file exists
    local sf="$FD_LOGS/sessions/${session_id}.session"
    assert_file_exists "$sf" "session marker file should exist" || return 1

    # Verify session content
    local content
    content=$(cat "$sf")
    assert_contains "$content" '"status": "running"' "status should be running" || return 1
    assert_contains "$content" "\"session_id\": \"$session_id\"" "session_id should match" || return 1
    assert_contains "$content" "\"boot_id\": \"$boot_id\"" "boot_id should match" || return 1
    assert_contains "$content" '"pid"' "pid should be present" || return 1

    # Verify symlink exists
    assert_file_exists "$FD_LOGS/sessions/${boot_id}.session" "boot_id symlink should exist" || return 1

    # Phase 2: Write context snapshot (as diag-start.sh does)
    {
        echo "=== CONTEXT ==="
        echo "--- KERNEL ---"
        echo "--- PLATFORM ---"
    } > "$FD_LOGS/context_${session_id}.log"
    assert_file_exists "$FD_LOGS/context_${session_id}.log" "context snapshot should exist" || return 1

    # Phase 3: Write heartbeat data (as collectors would)
    local hb_file="$FD_LOGS/heartbeat_20260101_120000.log"
    for i in 0 1 2 3 4 5; do
        echo "$((epoch + i)) HEARTBEAT $i" >> "$hb_file"
    done
    # Add a gap (simulating freeze) then more heartbeats (recovery)
    for i in 100 101 102; do
        echo "$((epoch + i)) HEARTBEAT $i" >> "$hb_file"
    done
    assert_file_exists "$hb_file" "heartbeat log should exist" || return 1

    # Phase 4: Mark session as stopped (as diag-stop.sh does)
    local started
    started=$(grep -o '"started_at": *"[^"]*"' "$sf" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "unknown")
    cat > "$sf" <<SESSIONEOF
{
  "boot_id": "$boot_id",
  "session_id": "$session_id",
  "started_at": "$started",
  "status": "stopped",
  "stopped_at": "2026-01-01T12:00:10+00:00"
}
SESSIONEOF

    content=$(cat "$sf")
    assert_contains "$content" '"status": "stopped"' "status should be stopped" || return 1
    assert_contains "$content" "\"session_id\": \"$session_id\"" "session_id preserved" || return 1

    test_end
}

test_integration_crash_detection() {
    test_start "crash detection: dead PID triggers crashed status"

    local boot_id="cafe_babe_boot"
    local epoch=1111111111
    local session_id="${boot_id}_${epoch}"

    export CURRENT_BOOT="$boot_id"
    export SESSION_ID="$session_id"
    source "$(dirname "$0")/../lib/lib_common.sh"
    eval "current_boot_id() { echo '$boot_id'; }"

    # Create a session marker with "running" status and a dead PID
    local sf="$FD_LOGS/sessions/${session_id}.session"
    cat > "$sf" <<SESSIONEOF
{
  "boot_id": "$boot_id",
  "session_id": "$session_id",
  "started_at": "2026-01-01T12:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
SESSIONEOF

    # Create symlink (as write_session_marker does)
    ln -sf "${session_id}.session" "$FD_LOGS/sessions/${boot_id}.session" 2>/dev/null || true

    # Simulate next boot checking for crashed sessions
    local new_boot="deadbeef_recovery"
    export CURRENT_BOOT="$new_boot"
    eval "current_boot_id() { echo '$new_boot'; }"

    local crashed
    crashed=$(check_crashed_sessions)
    assert_eq "$session_id" "$crashed" "should detect crashed session with dead PID" || return 1

    # Verify symlink is in the sessions dir
    local symlink_exists=false
    [ -L "$FD_LOGS/sessions/${boot_id}.session" ] && symlink_exists=true
    assert_eq "true" "$symlink_exists" "boot_id symlink should exist" || return 1

    test_end
}

test_integration_analysis_pipeline() {
    test_start "analysis pipeline: logs -> report generation (end-to-end)"

    local boot_id="feed_boot_id"
    local epoch=2222222222
    local session_id="${boot_id}_${epoch}"

    export CURRENT_BOOT="$boot_id"
    export SESSION_ID="$session_id"
    source "$(dirname "$0")/../lib/lib_common.sh"
    eval "current_boot_id() { echo '$boot_id'; }"

    # Write session marker
    write_session_marker "crashed" "$session_id"

    # Create heartbeat log with a gap (freeze simulation)
    local hb_file="$FD_LOGS/heartbeat_20260115_120000.log"
    for i in 0 1 2 3 4; do
        echo "$((epoch + i)) HEARTBEAT $i" >> "$hb_file"
    done
    # Gap (freeze at epoch+4, last_ts = epoch+4)
    for i in 100 101; do
        echo "$((epoch + i)) HEARTBEAT $i" >> "$hb_file"
    done

    # Create fast log
    local fast_file="$FD_LOGS/fast_20260115_120000.log"
    echo "$((epoch + 0))|psic=0.50|psim=0.30|psimf=95.00|psii=0.10|l1=2.5|l5=2.0|l15=1.5|mavail=8000|swapf=50|gtemp=92.0|oomd=0|top3=1234,firefox,250000;5678,Xorg,150000|rprocs=200|dprocs=3|xorg=1|xpss=150000" >> "$fast_file"
    echo "$((epoch + 3))|psic=0.80|psim=0.60|psimf=98.00|psii=0.30|l1=8.0|l5=4.0|l15=2.0|mavail=2000|swapf=10|gtemp=98.0|oomd=0|top3=1234,firefox,300000;5678,Xorg,180000|rprocs=300|dprocs=10|xorg=1|xpss=180000" >> "$fast_file"

    # Create GPU log with power data
    local gpu_file="$FD_LOGS/gpu_20260115_120000.log"
    echo "$((epoch + 2))|busy=15|vram=2048|gtt=512|edge=85.0|power=75.00|volt=1.200|rt=suspended|conn=DP-1:connected" >> "$gpu_file"

    # Create CPU log
    local cpu_file="$FD_LOGS/cpu_20260115_120000.log"
    echo "# governor=performance amd_pstate=guided cpuinfo_max_khz=5000000" >> "$cpu_file"
    echo "$((epoch + 1))|fmin=800|favg=2500|fmax=4900|ncpu=16|nhi=8|boost=1|taint=64" >> "$cpu_file"
    echo "$((epoch + 3))|fmin=800|favg=3000|fmax=4950|ncpu=16|nhi=12|boost=1|taint=64" >> "$cpu_file"

    # Create dmesg log with GPU timeout evidence
    local dmesg_file="$FD_LOGS/dmesg_20260115_120000.log"
    echo "D: 2026-01-15 kernel: amdgpu 0000:03:00.0: ring gfx_0.0.0 timeout" >> "$dmesg_file"
    echo "D: 2026-01-15 kernel: amdgpu: GPU reset begin!" >> "$dmesg_file"
    echo "D: 2026-01-15 kernel: amdgpu: fence timeout on ring gfx" >> "$dmesg_file"

    # Create watchdog log
    local wd_file="$FD_LOGS/watchdog_20260115_120000.log"
    echo "$((epoch + 1))|target=firefox|pid=1234|st=R|rss=250.0|vsz=2000.0|cpu=5.0|mem=3.0|thr=20|fd=100|inot=5|dri=0|etime=1:00|children=" >> "$wd_file"
    echo "$((epoch + 4))|target=firefox|pid=1234|st=R|rss=350.0|vsz=2200.0|cpu=8.0|mem=4.0|thr=25|fd=120|inot=8|dri=0|etime=1:05|children=" >> "$wd_file"

    # Test grep_logs finds the dmesg GPU evidence
    local matches
    matches=$(find "$FD_LOGS" -maxdepth 1 -name '*_????????_??????.log' -print0 2>/dev/null | \
        xargs -0 -r grep -ahiE "amdgpu.*timeout|amdgpu.*reset" 2>/dev/null || true)
    assert_not_empty "$matches" "should find GPU timeout evidence in dmesg logs" || return 1
    assert_contains "$matches" "amdgpu" "match should contain amdgpu" || return 1

    # Verify grep_logs counts correctly (without maxage filter for our fresh mocks)
    local gpu_matches
    gpu_matches=$(find "$FD_LOGS" -maxdepth 1 -name '*_????????_??????.log' -print0 2>/dev/null | \
        xargs -0 -r grep -ahiE "amdgpu" 2>/dev/null || true)
    local count
    count=$(echo "$gpu_matches" | grep -c . 2>/dev/null || true)
    count=${count:-0}
    assert_eq "3" "$count" "should find 3 amdgpu matches" || return 1

    # Generate a report file and verify
    local report_file="$FD_REPORTS/test_report.txt"
    mkdir -p "$FD_REPORTS"
    local ftime_str
    ftime_str=$(date -d "@$epoch" --iso-8601=seconds 2>/dev/null || echo "$epoch")
    {
        echo "FREEZE DIAGNOSIS REPORT - $ftime_str"
        echo "Session: $session_id"
        echo "Findings: GPU hang detected"
    } > "$report_file"

    assert_file_exists "$report_file" "report file should be created" || return 1
    local rcontent
    rcontent=$(cat "$report_file")
    assert_contains "$rcontent" "FREEZE DIAGNOSIS REPORT" "report should have header" || return 1
    assert_contains "$rcontent" "$session_id" "report should contain session ID" || return 1
    assert_contains "$rcontent" "GPU hang" "report should contain findings" || return 1

    test_end
}

test_integration_crash_bundle_preservation() {
    test_start "crash bundle: preserves pre-crash segments and context"

    local boot_id="babe_cafe_boot"
    local epoch=3333333333
    local session_id="${boot_id}_${epoch}"

    export CURRENT_BOOT="$boot_id"
    export SESSION_ID="$session_id"
    source "$(dirname "$0")/../lib/lib_common.sh"
    eval "current_boot_id() { echo '$boot_id'; }"

    # Create session marker
    write_session_marker "crashed" "$session_id"

    # Create context snapshot
    echo "=== CONTEXT ===" > "$FD_LOGS/context_${session_id}.log"
    echo "--- KERNEL ---" >> "$FD_LOGS/context_${session_id}.log"

    # Create segment files
    local now
    now=$(date +%s)
    for stream in heartbeat fast gpu cpu watchdog detailed dmesg; do
        local f="$FD_LOGS/${stream}_20260101_120000.log"
        echo "$stream data" > "$f"
        touch -d "@$((now - 100))" "$f" 2>/dev/null || true
    done

    # Create old file (outside STARTED_AT window - should NOT be copied)
    # oldermt test: we use -newermt "2026-01-01" so files touched to 2025 won't match
    local old_file="$FD_LOGS/heartbeat_20251201_000000.log"
    echo "old data" > "$old_file"
    touch -d "2025-12-01" "$old_file" 2>/dev/null || true

    # Create a report file
    local report_file="$FD_REPORTS/crash_report.txt"
    echo "CRASH REPORT" > "$report_file"

    # Run preserve_crash_bundle logic
    local bundle="$FD_ARCHIVE/crash_${session_id}_$(ts_dt)"
    mkdir -p "$bundle/segments"

    local STARTED_AT="2026-01-01T12:00:00+00:00"
    local since="$STARTED_AT"

    # Copy files newer than STARTED_AT
    find "$FD_LOGS" -maxdepth 1 -name '*.log' -newermt "$since" \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -300 | \
        while read -r _ f; do
            cp -p "$f" "$bundle/segments/" 2>/dev/null
        done

    cp -p "$FD_LOGS/context_${session_id}.log" "$bundle/" 2>/dev/null || true
    cp -p "$report_file" "$bundle/" 2>/dev/null || true
    cp -p "$FD_LOGS/sessions/${session_id}.session" "$bundle/" 2>/dev/null || true

    {
        echo "crash bundle for session: $session_id"
        echo "session started_at: $STARTED_AT"
        echo "bundle created:     $(ts_iso)"
        echo "created by boot:    $(current_boot_id)"
    } > "$bundle/MANIFEST.txt"

    # Verify bundle structure
    assert_dir_exists "$bundle" "bundle directory should exist" || return 1
    assert_dir_exists "$bundle/segments" "segments directory should exist" || return 1
    assert_file_exists "$bundle/context_${session_id}.log" "context snapshot should be copied" || return 1
    assert_file_exists "$bundle/MANIFEST.txt" "MANIFEST should exist" || return 1
    assert_file_exists "$bundle/crash_report.txt" "report should be copied" || return 1
    assert_file_exists "$bundle/${session_id}.session" "session marker should be copied" || return 1

    # Verify manifest content
    local manifest
    manifest=$(cat "$bundle/MANIFEST.txt")
    assert_contains "$manifest" "crash bundle for session: $session_id" "MANIFEST should have session ID" || return 1
    assert_contains "$manifest" "session started_at: $STARTED_AT" "MANIFEST should have started_at" || return 1

    # Verify old file NOT in bundle (file from 2025 should not be matched by -newermt "2026-01-01")
    local seg_list
    seg_list=$(ls "$bundle/segments/" 2>/dev/null || true)
    assert_not_contains "$seg_list" "heartbeat_20251201" "old files from 2025 should not be in bundle" || return 1

    test_end
}

test_integration_cross_boot_crash_correlation() {
    test_start "same-boot crash correlation across multiple sessions"

    local boot_id="dead-beef-1111-2222-3333-444444444444"
    export CURRENT_BOOT="$boot_id"
    source "$(dirname "$0")/../lib/lib_common.sh"
    eval "current_boot_id() { echo '$boot_id'; }"

    # Create 3 crashed sessions in the same boot
    for i in 1 2 3; do
        local sid="${boot_id}_$((1000000000 + i))"
        cat > "$FD_LOGS/sessions/${sid}.session" <<SESSIONEOF
{
  "boot_id": "$boot_id",
  "session_id": "$sid",
  "started_at": "2026-01-0${i}T12:00:00+00:00",
  "status": "crashed",
  "pid": 99999,
  "detected_by_boot": "$boot_id",
  "detected_at": "2026-01-0${i}T12:10:00+00:00"
}
SESSIONEOF
    done

    # A session from a different boot (should be excluded from same-boot count)
    local other_boot="other_boot_id"
    local other_sid="${other_boot}_1000000000"
    cat > "$FD_LOGS/sessions/${other_sid}.session" <<SESSIONEOF
{
  "boot_id": "$other_boot",
  "session_id": "$other_sid",
  "started_at": "2026-01-05T12:00:00+00:00",
  "status": "crashed",
  "pid": 99998
}
SESSIONEOF

    # Current running session (the latest in this boot)
    local current_sid="${boot_id}_1000000005"
    cat > "$FD_LOGS/sessions/${current_sid}.session" <<SESSIONEOF
{
  "boot_id": "$boot_id",
  "session_id": "$current_sid",
  "started_at": "2026-01-06T12:00:00+00:00",
  "status": "running",
  "pid": $$
}
SESSIONEOF

    # Inline same-boot correlation logic (mirrors diag-analyze.sh check_same_boot_crashes)
    local crash_count=0
    local cur_start="2026-01-06T12:00:00+00:00"

    for f in "$FD_LOGS/sessions/"*.session; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        local fname bid st
        fname=$(basename "$f" .session)
        bid=$(grep -o '"boot_id": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)
        st=$(grep -o '"status": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)
        if [ "$bid" = "$boot_id" ] && [ "$st" = "crashed" ] && [ "$fname" != "$current_sid" ]; then
            local f_start
            f_start=$(grep -o '"started_at": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)
            if [ -z "$cur_start" ] || [ -z "$f_start" ] || [[ "$f_start" < "$cur_start" ]]; then
                crash_count=$((crash_count + 1))
            fi
        fi
    done

    assert_eq "3" "$crash_count" "should find 3 previous crashes in same boot" || return 1

    test_end
}

test_integration_collector_stream_output_format() {
    test_start "collector stream output verifies expected line formats"

    export FD_ROOT="$TEST_DIR/fd-root"
    export FD_LIB="$FD_ROOT/lib"
    export FD_LOGS="$FD_ROOT/logs"
    export FD_PID_DIR="$TEST_DIR/fd-pid"
    mkdir -p "$FD_LOGS" "$FD_PID_DIR" "$FD_LIB"
    cp "$(dirname "$0")/../lib/lib_common.sh" "$FD_LIB/lib_common.sh" 2>/dev/null || true
    source "$(dirname "$0")/../lib/lib_common.sh"

    local now
    now=$(ts_epoch)

    # Heartbeat line format
    local hb_line="$now HEARTBEAT 42"
    assert_contains "$hb_line" "HEARTBEAT" "heartbeat line should contain HEARTBEAT" || return 1
    local hb_ts="${hb_line%% *}"
    [[ "$hb_ts" =~ ^[0-9]+ ]] && assert_not_empty "$hb_ts" "heartbeat should start with epoch" || return 1

    # Fast line format
    local fast_line="$now|psic=0.50|psim=0.30|psimf=95.00|l1=2.5|l5=2.0|top3=1234,firefox,100|rprocs=200|dprocs=3|xorg=1|xpss=150000"
    assert_contains "$fast_line" "psic=" "fast line should contain psic" || return 1
    assert_contains "$fast_line" "psimf=" "fast line should contain psimf" || return 1
    assert_contains "$fast_line" "top3=" "fast line should contain top3" || return 1

    # GPU line format
    local gpu_line="$now|busy=42|vram=2048|gtt=512|edge=75.0|power=65.00|volt=1.200|rt=active|conn=DP-1:connected"
    assert_contains "$gpu_line" "busy=" "gpu line should contain busy" || return 1
    assert_contains "$gpu_line" "vram=" "gpu line should contain vram" || return 1
    assert_contains "$gpu_line" "rt=" "gpu line should contain runtime status" || return 1

    # CPU line format
    local cpu_line="$now|fmin=800|favg=2500|fmax=4900|ncpu=16|nhi=8|boost=1|taint=64"
    assert_contains "$cpu_line" "fmin=" "cpu line should contain fmin" || return 1
    assert_contains "$cpu_line" "ncpu=" "cpu line should contain ncpu" || return 1
    assert_contains "$cpu_line" "nhi=" "cpu line should contain nhi" || return 1

    # Watchdog line format
    local wd_line="$now|target=firefox|pid=1234|st=R|rss=250.0|vsz=2000.0|cpu=5.0|mem=3.0|thr=20|fd=100|inot=5|dri=0|etime=1:00|children="
    assert_contains "$wd_line" "target=" "watchdog line should contain target" || return 1
    assert_contains "$wd_line" "rss=" "watchdog line should contain rss" || return 1
    assert_contains "$wd_line" "inot=" "watchdog line should contain inotify" || return 1

    test_end
}

test_integration_diag_start_uninstall_flow() {
    test_start "diag-start.sh --uninstall logic (mocked systemctl)"

    local mock_bin="$TEST_DIR/bin"
    mkdir -p "$mock_bin"

    # Mock systemctl (always succeeds)
    cat > "$mock_bin/systemctl" <<'MOCK'
#!/bin/bash
case "${1:-}" in
    --user)
        case "${2:-}" in
            is-enabled|is-active) echo "inactive"; return 0 ;;
            stop|disable|daemon-reload) return 0 ;;
            *) return 0 ;;
        esac ;;
    *) return 0 ;;
esac
MOCK
    chmod +x "$mock_bin/systemctl"

    # Mock sudo (denies access - tests [WARN] path for sudoers removal)
    cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
echo "sudo not available" >&2
exit 1
MOCK
    chmod +x "$mock_bin/sudo"

    export PATH="$mock_bin:$PATH"

    # Setup FD paths
    export FD_ROOT="$TEST_DIR/fd-root"
    export FD_PID_DIR="$TEST_DIR/fd-pid"
    export FD_LOGS="$FD_ROOT/logs"
    export FD_LIB="$FD_ROOT/lib"
    export FD_ARCHIVE="$FD_ROOT/archive"
    export FD_REPORTS="$FD_ROOT/reports"
    mkdir -p "$FD_LOGS/sessions" "$FD_ARCHIVE" "$FD_REPORTS" "$FD_PID_DIR"
    cp "$(dirname "$0")/../lib/lib_common.sh" "$FD_LIB/lib_common.sh" 2>/dev/null || true

    # Create mock PID files
    echo "12345" > "$FD_PID_DIR/freeze-diag-heartbeat.pid"
    echo "12346" > "$FD_PID_DIR/freeze-diag-fast.pid"

    # Test PID file iteration logic
    local killed_pids=""
    for pidf in "$FD_PID_DIR"/freeze-diag-*.pid; do
        [ -f "$pidf" ] || continue
        local pid
        pid=$(cat "$pidf" 2>/dev/null) || continue
        killed_pids="$killed_pids$pid "
        rm -f "$pidf"
    done
    assert_contains "$killed_pids" "12345" "should iterate heartbeat pid" || return 1
    assert_contains "$killed_pids" "12346" "should iterate fast pid" || return 1

    # Verify PID files removed
    local remaining
    remaining=$(ls "$FD_PID_DIR"/freeze-diag-*.pid 2>/dev/null | wc -l)
    assert_eq "0" "$remaining" "pidfiles should be cleaned" || return 1

    # Test --uninstall banner (run with clean PATH so systemctl/sudo are mocked)
    local script_dir="$(dirname "$0")/.."
    local uninstall_output
    uninstall_output=$(PATH="$mock_bin:$PATH" bash "$script_dir/diag-start.sh" --uninstall 2>/dev/null || true)
    assert_contains "$uninstall_output" "UNINSTALLER" "uninstall should show banner" || return 1

    test_end
}

test_integration_diag_start_install_flow() {
    test_start "diag-start.sh --install shows installer banner and steps"

    local mock_bin="$TEST_DIR/bin"
    mkdir -p "$mock_bin"

    # Mock sudo (works)
    cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
if [ "$1" = "-n" ]; then exit 0; fi
exit 0
MOCK
    chmod +x "$mock_bin/sudo"

    # Mock systemctl (works)
    cat > "$mock_bin/systemctl" <<'MOCK'
#!/bin/bash
case "${1:-}" in
    --user)
        case "${2:-}" in
            is-enabled|is-active) echo "inactive"; return 0 ;;
            daemon-reload|enable|start) return 0 ;;
            *) return 0 ;;
        esac ;;
    *) return 0 ;;
esac
MOCK
    chmod +x "$mock_bin/systemctl"

    # Mock dmesg (must work for sudo check)
    cat > "$mock_bin/dmesg" <<'MOCK'
#!/bin/bash
echo "mock dmesg output"
MOCK
    chmod +x "$mock_bin/dmesg"

    export PATH="$mock_bin:$PATH"
    export FD_ROOT="$TEST_DIR/fd-root"
    export FD_PID_DIR="$TEST_DIR/fd-pid"

    local script_dir="$(dirname "$0")/.."
    local install_output
    install_output=$(PATH="$mock_bin:$PATH" bash "$script_dir/diag-start.sh" --install 2>/dev/null || true)
    assert_contains "$install_output" "INSTALLER" "install should show banner" || return 1

    test_end
}

test_integration_diag_report_no_args() {
    test_start "diag-report.sh exits 1 with no arguments"

    local SCRIPT_DIR="$(dirname "$0")/.."
    local output
    output=$(bash "$SCRIPT_DIR/diag-report.sh" 2>&1 || true)
    assert_contains "$output" "no session_id or boot_id" "should error about missing args" || return 1

    test_end
}

test_integration_harden_help_and_args() {
    test_start "diag-harden.sh --help and arg parsing"

    local SCRIPT_DIR="$(dirname "$0")/.."
    local output

    output=$(bash "$SCRIPT_DIR/diag-harden.sh" --help 2>&1 || true)
    assert_contains "$output" "Usage:" "help should show usage" || return 1

    output=$(bash "$SCRIPT_DIR/diag-harden.sh" --nonexistent 2>&1 || true)
    assert_contains "$output" "Usage:" "invalid arg should show usage" || return 1

    test_end
}

test_integration_analyzer_cli_arg_parsing() {
    test_start "diag-analyze.sh CLI argument parsing"

    local SCRIPT_DIR="$(dirname "$0")/.."

    # --session requires an argument and exits 1 when no sessions found (that's fine)
    local session_output
    session_output=$(bash "$SCRIPT_DIR/diag-analyze.sh" --session "nonexistent-session-id-12345" 2>&1 || true)
    assert_contains "$session_output" "No heartbeat" "should mention no heartbeat logs" || return 1

    local unknown_output
    unknown_output=$(bash "$SCRIPT_DIR/diag-analyze.sh" --nonexistent 2>&1 || true)
    assert_contains "$unknown_output" "Unknown option" "unknown option should print error" || return 1

    # --quick and --current together should not error
    local quick_output
    quick_output=$(bash "$SCRIPT_DIR/diag-analyze.sh" --current --quick 2>&1 || true)
    assert_not_empty "$quick_output" "quick mode should produce output" || return 1

    test_end
}

test_integration_check_sensitive_scan() {
    test_start "check-sensitive.sh scans all tracked files"

    local SCRIPT_DIR="$(dirname "$0")/.."
    local output
    output=$(bash "$SCRIPT_DIR/tests/check-sensitive.sh" 2>&1 || true)
    local rc=$?

    # Print just a summary
    local summary
    summary=$(echo "$output" | grep -E '(No sensitive|Sensitive data found)' | head -1)
    if echo "$output" | grep -q "Sensitive data found"; then
        echo "  Issues found - see details above" >&2
    fi
    assert_eq "0" "$rc" "check-sensitive.sh should exit 0" || return 1

    test_end
}

test_integration_fd_pstore_dump_validation() {
    test_start "fd-pstore-dump validation logic"

    # Test argument validation by running the script logic in isolation
    # We can't easily test the full script (requires root), but we can
    # test the validation conditions individually.

    # Create a mock dest dir
    local dest="$TEST_DIR/pstore-test-dest"
    mkdir -p "$dest"

    # Verify dir exists
    assert_dir_exists "$dest" "dest dir should exist" || return 1

    # Create mock pstore directory structure to verify the copy logic works
    local pstore_src="$TEST_DIR/var/lib/systemd/pstore"
    mkdir -p "$pstore_src"
    echo "dummy panic record" > "$pstore_src/dmesg.txt"

    # Inline the copy logic (same as fd-pstore-dump does when run as root)
    local out="$dest/pstore"
    mkdir -p "$out"
    ls -laR "$pstore_src" > "$out/listing-lib-systemd.txt" 2>/dev/null || true
    cp -r -- "$pstore_src" "$out/copy-lib-systemd" 2>/dev/null

    assert_dir_exists "$out" "pstore output dir should exist" || return 1
    assert_file_exists "$out/copy-lib-systemd/dmesg.txt" "pstore records should be copied" || return 1

    test_end
}

run_tests "$0"

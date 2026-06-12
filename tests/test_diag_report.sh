#!/bin/bash
# Unit tests for diag-report.sh
source "$(dirname "$0")/test_runner.sh"

# ---- Helpers ----

_import_preserve_crash_bundle() {
    source "$FD_LIB/lib_common.sh"
    local report_script
    report_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/diag-report.sh"
    eval "$(sed -n '/^preserve_crash_bundle() {/,/^}/p' "$report_script")"
}

# ---- Argument parsing tests ----

_test_parse_args() {
    SESSION_ID=""; BOOT_ID=""; QUIET=false; SESSION_ARG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) SESSION_ID="$2"; shift 2 ;;
            --boot) BOOT_ID="$2"; shift 2 ;;
            --quiet) QUIET=true; shift ;;
            *) return 1 ;;
        esac
    done
    if [ -n "$SESSION_ID" ]; then
        SESSION_ARG="--session $SESSION_ID"
        return 0
    elif [ -n "$BOOT_ID" ]; then
        SESSION_ARG="--boot $BOOT_ID"
        return 0
    else
        return 1
    fi
}

test_args_session() {
    test_start "--session sets SESSION_ID"
    _test_parse_args --session "testboot_1234567890"
    assert_eq "testboot_1234567890" "$SESSION_ID" "SESSION_ID" || { test_end; return 1; }
    assert_eq "--session testboot_1234567890" "$SESSION_ARG" "SESSION_ARG" || { test_end; return 1; }
    assert_eq "false" "$QUIET" "QUIET default" || { test_end; return 1; }
    test_end
}

test_args_boot() {
    test_start "--boot sets BOOT_ID"
    _test_parse_args --boot "myboot_123"
    assert_eq "myboot_123" "$BOOT_ID" "BOOT_ID" || { test_end; return 1; }
    assert_eq "--boot myboot_123" "$SESSION_ARG" "SESSION_ARG uses --boot" || { test_end; return 1; }
    test_end
}

test_args_quiet() {
    test_start "--quiet sets QUIET=true"
    _test_parse_args --session "s_1" --quiet
    assert_eq "true" "$QUIET" "QUIET" || { test_end; return 1; }
    assert_eq "s_1" "$SESSION_ID" "SESSION_ID preserved" || { test_end; return 1; }
    test_end
}

test_args_session_boot() {
    test_start "--session takes priority over --boot"
    _test_parse_args --boot "b_1" --session "s_1"
    assert_eq "s_1" "$SESSION_ID" "SESSION_ID" || { test_end; return 1; }
    assert_eq "--session s_1" "$SESSION_ARG" "SESSION_ARG" || { test_end; return 1; }
    test_end
}

test_args_no_args() {
    test_start "no args returns 1"
    _test_parse_args
    local rc=$?
    assert_eq 1 $rc "exit 1 with no args" || { test_end; return 1; }
    assert_empty "$SESSION_ARG" "SESSION_ARG empty" || { test_end; return 1; }
    test_end
}

test_args_both_empty() {
    test_start "--session and --boot both empty returns 1"
    _test_parse_args --session "" --boot ""
    local rc=$?
    assert_eq 1 $rc "exit 1 when both empty" || { test_end; return 1; }
    test_end
}

# ---- preserve_crash_bundle tests ----

test_preserve_bundle_creates_dirs_and_copies() {
    test_start "preserve_crash_bundle creates bundle dir, segments, copies files"
    local __FD_LOGS="$FD_LOGS"
    _import_preserve_crash_bundle

    local session_id="crash_1111111111"
    SESSION_ID="$session_id"
    BOOT_ID="crash"
    STARTED_AT="2024-01-01T12:00:00"
    REPORT_FILE="$FD_REPORTS/crash_report.txt"
    mkdir -p "$FD_REPORTS" "$FD_LOGS/sessions"
    echo "report content" > "$REPORT_FILE"
    SESSION_FILE="$FD_LOGS/sessions/${session_id}.session"
    printf '{"boot_id":"crash","started_at":"2024-01-01T12:00:00","status":"running","pid":99999999}\n' > "$SESSION_FILE"

    echo "kernel: ... cmdline: ... microcode: ..." > "$FD_LOGS/context_${session_id}.log"

    # Files: one older than STARTED_AT, two newer
    touch -d "2024-01-01T10:00:00" "$FD_LOGS/heartbeat_old.log"
    touch -d "2024-01-01T14:00:00" "$FD_LOGS/heartbeat_new.log"
    touch -d "2024-01-01T15:00:00" "$FD_LOGS/fast_new.log"

    sudo() { return 1; }
    export -f sudo 2>/dev/null || true

    preserve_crash_bundle || true

    local bundle
    bundle=$(find "$FD_ARCHIVE" -maxdepth 1 -type d -name "crash_${session_id}_*" 2>/dev/null | head -1)
    assert_not_empty "$bundle" "bundle dir exists" || { test_end; return 1; }
    assert_dir_exists "$bundle" "bundle dir" || { test_end; return 1; }
    assert_dir_exists "$bundle/segments" "segments dir" || { test_end; return 1; }
    assert_file_exists "$bundle/segments/heartbeat_new.log" "new heartbeat copied" || { test_end; return 1; }
    assert_file_exists "$bundle/segments/fast_new.log" "new fast copied" || { test_end; return 1; }

    if [ -f "$bundle/segments/heartbeat_old.log" ]; then
        echo "old file should NOT have been copied" >&2
        test_end; return 1
    fi

    assert_file_exists "$bundle/context_${session_id}.log" "context copied" || { test_end; return 1; }
    assert_file_exists "$bundle/pstore-listing-unprivileged.txt" "pstore listing" || { test_end; return 1; }
    assert_file_exists "$bundle/MANIFEST.txt" "MANIFEST" || { test_end; return 1; }

    local manifest
    manifest=$(cat "$bundle/MANIFEST.txt")
    assert_contains "$manifest" "crash bundle for session: $session_id" || { test_end; return 1; }
    assert_contains "$manifest" "session started_at: $STARTED_AT" || { test_end; return 1; }
    assert_contains "$manifest" "bundle created:" || { test_end; return 1; }
    assert_contains "$manifest" "created by boot:" || { test_end; return 1; }

    test_end
}

test_preserve_bundle_with_pstore_bin() {
    test_start "preserve_crash_bundle uses pstore dump when available"
    local __FD_LOGS="$FD_LOGS"
    _import_preserve_crash_bundle

    local session_id="pstore_test_2222222222"
    SESSION_ID="$session_id"
    BOOT_ID="pstore_test"
    STARTED_AT="2024-06-01T00:00:00"
    REPORT_FILE="$FD_REPORTS/pstore_report.txt"
    mkdir -p "$FD_REPORTS" "$FD_LOGS/sessions"
    echo "report" > "$REPORT_FILE"
    SESSION_FILE="$FD_LOGS/sessions/${session_id}.session"
    printf '{"boot_id":"pstore_test","started_at":"2024-06-01T00:00:00","status":"running","pid":99999999}\n' > "$SESSION_FILE"
    echo "ctx" > "$FD_LOGS/context_${session_id}.log"
    touch "$FD_LOGS/heartbeat_1.log"

    local mock_pstore="$TEST_DIR/mock_pstore_dump"
    cat > "$mock_pstore" <<'MOCKP'
#!/bin/bash
echo "mock pstore dump to $1" > "$1/pstore_dump_log.txt"
MOCKP
    chmod +x "$mock_pstore"
    FD_PSTORE_DUMP_BIN="$mock_pstore"

    sudo() { shift; "$@"; }
    export -f sudo 2>/dev/null || true

    preserve_crash_bundle || true

    local bundle
    bundle=$(find "$FD_ARCHIVE" -maxdepth 1 -type d -name "crash_${session_id}_*" 2>/dev/null | head -1)
    assert_not_empty "$bundle" "bundle exists" || { test_end; return 1; }
    assert_file_exists "$bundle/pstore_dump_log.txt" "pstore dump ran" || { test_end; return 1; }

    local events_log="$FD_LOGS/diag_events.log"
    assert_file_exists "$events_log" "events log" || { test_end; return 1; }
    local events
    events=$(cat "$events_log")
    assert_contains "$events" "pstore records preserved" "pstore event logged" || { test_end; return 1; }

    test_end
}

test_preserve_bundle_unknown_started_at() {
    test_start "preserve_crash_bundle falls back when STARTED_AT is unknown"
    local __FD_LOGS="$FD_LOGS"
    _import_preserve_crash_bundle

    local session_id="unknown_start_3333333333"
    SESSION_ID="$session_id"
    BOOT_ID="unknown_start"
    STARTED_AT="unknown"
    REPORT_FILE="$FD_REPORTS/unknown_report.txt"
    mkdir -p "$FD_REPORTS" "$FD_LOGS/sessions"
    echo "report" > "$REPORT_FILE"
    SESSION_FILE="$FD_LOGS/sessions/${session_id}.session"
    printf '{}' > "$SESSION_FILE"
    echo "ctx" > "$FD_LOGS/context_${session_id}.log"
    touch "$FD_LOGS/heartbeat_recent.log"

    sudo() { return 1; }
    export -f sudo 2>/dev/null || true

    preserve_crash_bundle || true

    local bundle
    bundle=$(find "$FD_ARCHIVE" -maxdepth 1 -type d -name "crash_${session_id}_*" 2>/dev/null | head -1)
    assert_not_empty "$bundle" "bundle created even with unknown STARTED_AT" || { test_end; return 1; }
    assert_dir_exists "$bundle" "bundle dir" || { test_end; return 1; }
    assert_file_exists "$bundle/MANIFEST.txt" "MANIFEST" || { test_end; return 1; }

    local manifest
    manifest=$(cat "$bundle/MANIFEST.txt")
    assert_contains "$manifest" "session started_at: unknown" || { test_end; return 1; }

    test_end
}

# ---- Full flow test ----

test_full_flow() {
    test_start "diag-report.sh generates report and bundle end-to-end"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"

    local session_id="fullflow_4444444444"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${session_id}.session" <<EOF
{
  "boot_id": "fullflow",
  "session_id": "$session_id",
  "started_at": "2024-09-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF

    echo "context snapshot" > "$FD_LOGS/context_${session_id}.log"
    touch "$FD_LOGS/heartbeat_1.log"

    bash "$(dirname "$0")/../diag-report.sh" --session "$session_id" --quiet 2>&1 || true

    local report
    report=$(ls -t "$FD_REPORTS"/crash_*.txt 2>/dev/null | head -1)
    assert_not_empty "$report" "report file" || { test_end; return 1; }
    assert_file_exists "$report" "report file exists" || { test_end; return 1; }

    local bundle
    bundle=$(find "$FD_ARCHIVE" -maxdepth 1 -type d -name "crash_${session_id}_*" 2>/dev/null | head -1)
    assert_not_empty "$bundle" "crash bundle" || { test_end; return 1; }
    assert_dir_exists "$bundle/segments" "segments" || { test_end; return 1; }
    assert_file_exists "$bundle/MANIFEST.txt" "MANIFEST" || { test_end; return 1; }

    local session_content
    session_content=$(cat "$FD_LOGS/sessions/${session_id}.session")
    assert_contains "$session_content" '"status": "crashed"' "session marked crashed" || { test_end; return 1; }

    test_end
}

test_full_flow_no_session_file() {
    test_start "diag-report.sh generates fallback when session file missing"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"

    local session_id="nofile_5555555555"
    mkdir -p "$FD_LOGS/sessions"

    bash "$(dirname "$0")/../diag-report.sh" --session "$session_id" --quiet 2>&1 || true

    local report
    report=$(ls -t "$FD_REPORTS"/crash_*.txt 2>/dev/null | head -1)
    assert_not_empty "$report" "fallback report" || { test_end; return 1; }

    test_end
}

# ---- Analysis failure tests ----

test_analysis_failure_fallback_report() {
    test_start "diag-report.sh generates fallback when analysis fails"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"

    local session_id="fail_ana_6666666666"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${session_id}.session" <<EOF
{
  "boot_id": "fail_ana",
  "session_id": "$session_id",
  "started_at": "2024-01-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/notify-send" <<'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/notify-send"
    export PATH="$TEST_DIR/bin:$PATH"

    bash "$(dirname "$0")/../diag-report.sh" --session "$session_id" --quiet 2>&1 || true

    local report
    report=$(ls -t "$FD_REPORTS"/crash_*.txt 2>/dev/null | head -1)
    assert_not_empty "$report" "fallback report exists" || { test_end; return 1; }

    local content
    content=$(cat "$report")
    assert_contains "$content" "CRASH DETECTED" "report contains CRASH DETECTED" || { test_end; return 1; }
    assert_contains "$content" "No detailed analysis was possible" "report contains fallback message" || { test_end; return 1; }

    test_end
}

# ---- TOP_FINDING extraction tests ----

test_top_finding_extracted_from_report() {
    test_start "TOP_FINDING extracts HIGH/MEDIUM from report"
    mkdir -p "$FD_REPORTS"

    local report_file="$FD_REPORTS/test_finding.txt"
    cat > "$report_file" <<EOF
Some header info
HIGH GPU hang detected at 12:00:00
  Evidence: amdgpu timeout on ring 0
Some footer
MEDIUM Memory pressure above 90%
  Evidence: swap usage at 95%
EOF

    local top_finding
    top_finding=$(grep -A1 "HIGH\|MEDIUM" "$report_file" 2>/dev/null | head -2 | tr '\n' ' ' || echo "Unknown cause")

    assert_contains "$top_finding" "HIGH" "top finding contains HIGH level" || { test_end; return 1; }
    assert_contains "$top_finding" "GPU hang" "top finding contains GPU hang evidence" || { test_end; return 1; }
    assert_not_contains "$top_finding" "MEDIUM" "top finding is first (HIGH not MEDIUM)" || { test_end; return 1; }

    test_end
}

test_top_finding_unknown_when_no_match() {
    test_start "TOP_FINDING returns Unknown cause when no HIGH/MEDIUM"
    mkdir -p "$FD_REPORTS"

    local report_file="$FD_REPORTS/test_no_finding.txt"
    echo "No issues detected" > "$report_file"

    local top_finding
    top_finding=$(grep -A1 "HIGH\|MEDIUM" "$report_file" 2>/dev/null | head -2 | tr '\n' ' ' || echo "Unknown cause")
    if [ -z "$top_finding" ]; then
        top_finding="Unknown cause"
    fi

    assert_eq "Unknown cause" "$top_finding" "fallback when no HIGH/MEDIUM" || { test_end; return 1; }

    test_end
}

# ---- STARTED_AT legacy fallback tests ----

test_started_at_legacy_fallback() {
    test_start "legacy fallback sets STARTED_AT from boot_id session file"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"

    local boot_id="legacy_fb_999"
    mkdir -p "$FD_LOGS/sessions"

    cat > "$FD_LOGS/sessions/${boot_id}.session" <<EOF
{
  "boot_id": "$boot_id",
  "started_at": "2024-03-15T08:30:00+00:00",
  "status": "crashed"
}
EOF

    # Simulate the fallback logic from diag-report.sh lines 59-65
    # Use a lookup id that find_session_file will NOT find
    local lookup_id="no_such_session_id_99999"
    STARTED_AT="unknown"
    local session_file
    session_file=$(find_session_file "$lookup_id" 2>/dev/null) || session_file=""
    if [ -n "$session_file" ]; then
        STARTED_AT=$(grep -o '"started_at": *"[^"]*"' "$session_file" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "unknown")
    elif [ -f "$FD_LOGS/sessions/${boot_id}.session" ]; then
        STARTED_AT=$(grep -o '"started_at": *"[^"]*"' "$FD_LOGS/sessions/${boot_id}.session" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "unknown")
    fi

    assert_eq "2024-03-15T08:30:00+00:00" "$STARTED_AT" "STARTED_AT from legacy fallback" || { test_end; return 1; }

    test_end
}

# ---- preserve_crash_bundle sudo journalctl tests ----

test_preserve_bundle_with_sudo_journalctl() {
    test_start "preserve_crash_bundle creates journal files with sudo"
    local __FD_LOGS="$FD_LOGS"
    _import_preserve_crash_bundle

    local session_id="sudo_journal_7777777777"
    SESSION_ID="$session_id"
    BOOT_ID="sudo_journal"
    STARTED_AT="2024-07-01T00:00:00"
    REPORT_FILE="$FD_REPORTS/sudo_report.txt"
    mkdir -p "$FD_REPORTS" "$FD_LOGS/sessions"
    echo "report" > "$REPORT_FILE"
    SESSION_FILE="$FD_LOGS/sessions/${session_id}.session"
    printf '{"boot_id":"sudo_journal","started_at":"2024-07-01T00:00:00","status":"running","pid":99999999}\n' > "$SESSION_FILE"
    echo "ctx" > "$FD_LOGS/context_${session_id}.log"
    touch "$FD_LOGS/heartbeat_recent.log"

    sudo() {
        case "$*" in
            *true*) return 0 ;;
            *journalctl*--list-boots*) echo " 0 deadbeef boot" ;;
            *journalctl*-b*-1*-n*) echo "[2024-07-01T00:01:00] mock journal tail" ;;
            *journalctl*-b*-1*-o*) echo "[2024-07-01T00:01:00] kernel: BUG: test fault"; echo "[2024-07-01T00:02:00] kernel: normal message" ;;
            *) return 1 ;;
        esac
    }
    export -f sudo 2>/dev/null || true

    preserve_crash_bundle || true

    local bundle
    bundle=$(find "$FD_ARCHIVE" -maxdepth 1 -type d -name "crash_${session_id}_*" 2>/dev/null | head -1)
    assert_not_empty "$bundle" "bundle exists" || { test_end; return 1; }
    assert_file_exists "$bundle/journal-prev-boot-tail.txt" "journal tail created" || { test_end; return 1; }
    assert_file_exists "$bundle/journal-prev-boot-faults.txt" "journal faults created" || { test_end; return 1; }
    assert_file_exists "$bundle/boots.txt" "boots list created" || { test_end; return 1; }

    test_end
}

# ---- preserve_crash_bundle no segments tests ----

test_preserve_bundle_no_segments() {
    test_start "preserve_crash_bundle works with no matching segments"
    local __FD_LOGS="$FD_LOGS"
    _import_preserve_crash_bundle

    local session_id="no_seg_8888888888"
    SESSION_ID="$session_id"
    BOOT_ID="no_seg"
    STARTED_AT="2024-08-01T00:00:00"
    REPORT_FILE="$FD_REPORTS/no_seg_report.txt"
    mkdir -p "$FD_REPORTS" "$FD_LOGS/sessions"
    echo "report" > "$REPORT_FILE"
    SESSION_FILE="$FD_LOGS/sessions/${session_id}.session"
    printf '{"boot_id":"no_seg","started_at":"2024-08-01T00:00:00","status":"running","pid":99999999}\n' > "$SESSION_FILE"

    # All log files older than STARTED_AT — none should be copied
    echo "ctx" > "$FD_LOGS/context_${session_id}.log"
    touch -d "2024-07-01T00:00:00" "$FD_LOGS/context_${session_id}.log"
    touch -d "2024-07-01T00:00:00" "$FD_LOGS/heartbeat_old.log"
    touch -d "2024-07-01T00:00:00" "$FD_LOGS/fast_old.log"

    sudo() { return 1; }
    export -f sudo 2>/dev/null || true

    preserve_crash_bundle || true

    local bundle
    bundle=$(find "$FD_ARCHIVE" -maxdepth 1 -type d -name "crash_${session_id}_*" 2>/dev/null | head -1)
    assert_not_empty "$bundle" "bundle exists" || { test_end; return 1; }
    assert_dir_exists "$bundle/segments" "segments dir exists" || { test_end; return 1; }

    local seg_count
    seg_count=$(find "$bundle/segments" -type f 2>/dev/null | wc -l)
    assert_eq 0 "$seg_count" "segments dir is empty" || { test_end; return 1; }

    assert_file_exists "$bundle/context_${session_id}.log" "context copied" || { test_end; return 1; }
    assert_file_exists "$bundle/MANIFEST.txt" "MANIFEST exists" || { test_end; return 1; }

    test_end
}

# ---- notify_user tests ----

test_notify_user_called_with_correct_args() {
    test_start "notify_user called with System freeze detected"
    local __FD_LOGS="$FD_LOGS"
    source "$FD_LIB/lib_common.sh"

    local session_id="notify_9999999999"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${session_id}.session" <<EOF
{
  "boot_id": "notify",
  "session_id": "$session_id",
  "started_at": "2024-10-01T00:00:00+00:00",
  "status": "running",
  "pid": 99999999
}
EOF
    echo "context" > "$FD_LOGS/context_${session_id}.log"
    touch "$FD_LOGS/heartbeat_1.log"

    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/notify-send" <<SCRIPT
#!/bin/bash
echo "NOTIFY:\$*" >> "${_TEST_DIR}/notify_captured.txt"
SCRIPT
    chmod +x "$TEST_DIR/bin/notify-send"
    export PATH="$TEST_DIR/bin:$PATH"

    bash "$(dirname "$0")/../diag-report.sh" --session "$session_id" --quiet 2>&1 || true

    local captured
    captured=$(cat "${_TEST_DIR}/notify_captured.txt" 2>/dev/null || echo "")
    assert_contains "$captured" "System freeze detected" "notify-send called with correct title" || { test_end; return 1; }

    test_end
}

# ---- Multiple --session edge cases ----

test_multiple_session_args_special_chars() {
    test_start "--session handles special characters"
    SESSION_ID=""; BOOT_ID=""; QUIET=false; SESSION_ARG=""

    _test_parse_args --session "test+session.123*"
    assert_eq "test+session.123*" "$SESSION_ID" "SESSION_ID with special regex chars" || { test_end; return 1; }
    assert_eq "--session test+session.123*" "$SESSION_ARG" "SESSION_ARG with special chars" || { test_end; return 1; }

    test_end
}

test_multiple_session_args_very_long() {
    test_start "--session handles very long ID"

    local long_id
    long_id=$(printf 's%0.s' {1..500})
    SESSION_ID=""; BOOT_ID=""; QUIET=false; SESSION_ARG=""

    _test_parse_args --session "$long_id"
    assert_eq "$long_id" "$SESSION_ID" "SESSION_ID with 500 chars" || { test_end; return 1; }
    assert_eq "--session $long_id" "$SESSION_ARG" "SESSION_ARG with long ID" || { test_end; return 1; }

    test_end
}

test_multiple_session_args_with_equals() {
    test_start "--session handles session IDs with equals"

    SESSION_ID=""; BOOT_ID=""; QUIET=false; SESSION_ARG=""

    _test_parse_args --session "session=with=equals"
    assert_eq "session=with=equals" "$SESSION_ID" "SESSION_ID with equals" || { test_end; return 1; }

    test_end
}

test_multiple_session_args_dashes() {
    test_start "--session handles UUID-style IDs"

    SESSION_ID=""; BOOT_ID=""; QUIET=false; SESSION_ARG=""

    _test_parse_args --session "mock-session-uuid-test-id"
    assert_eq "mock-session-uuid-test-id" "$SESSION_ID" "SESSION_ID from args" || { test_end; return 1; }
    assert_eq "--session mock-session-uuid-test-id" "$SESSION_ARG" "SESSION_ARG from args" || { test_end; return 1; }

    test_end
}

run_tests "$0"

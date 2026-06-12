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

run_tests "$0"

#!/bin/bash
# test_runner.sh — simple shared test harness for freeze-diag unit/integration tests
# Usage: source tests/test_runner.sh  (from the project root)
# Provides: mock, assert_*, test_start, test_end, run_tests

if [ -n "${_TEST_RUNNER_LOADED:-}" ]; then return 0; fi
_TEST_RUNNER_LOADED=1

PASS=0
FAIL=0
SKIP=0
CURRENT_TEST=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Test lifecycle ──────────────────────────────────────────────

test_start() {
    CURRENT_TEST="$1"
    printf "  ${CYAN}▶${NC} ${BOLD}%-60s${NC} " "$CURRENT_TEST"
}

test_end() {
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    elif [ "$rc" -eq 77 ]; then
        echo -e "${YELLOW}SKIP${NC}"
        SKIP=$((SKIP + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAIL=$((FAIL + 1))
    fi
    CURRENT_TEST=""
}

test_skip() {
    return 77
}

# ── Assertions ──────────────────────────────────────────────────

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" != "$actual" ]; then
        echo "ASSERT_EQ FAIL: $msg" >&2
        echo "  expected: '$expected'" >&2
        echo "  actual:   '$actual'" >&2
        return 1
    fi
}

assert_ne() {
    local not_expected="$1" actual="$2" msg="${3:-}"
    if [ "$not_expected" = "$actual" ]; then
        echo "ASSERT_NE FAIL: $msg" >&2
        echo "  not-expected == actual: '$actual'" >&2
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "ASSERT_CONTAINS FAIL: $msg" >&2
        echo "  needle: '$needle'" >&2
        echo "  haystack: '$haystack'" >&2
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "ASSERT_NOT_CONTAINS FAIL: $msg" >&2
        echo "  haystack must not contain '$needle'" >&2
        echo "  haystack: '$haystack'" >&2
        return 1
    fi
}

assert_empty() {
    local val="$1" msg="${2:-}"
    if [ -n "$val" ]; then
        echo "ASSERT_EMPTY FAIL: $msg" >&2
        echo "  value: '$val'" >&2
        return 1
    fi
}

assert_not_empty() {
    local val="$1" msg="${2:-}"
    if [ -z "$val" ]; then
        echo "ASSERT_NOT_EMPTY FAIL: $msg" >&2
        return 1
    fi
}

assert_true() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ASSERT_TRUE FAIL: expected 0 exit code, got $rc" >&2
        return 1
    fi
    return 0
}

assert_false() {
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "ASSERT_FALSE FAIL: expected non-zero exit code, got 0" >&2
        return 1
    fi
    return 0
}

assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [ ! -f "$path" ]; then
        echo "ASSERT_FILE_EXISTS FAIL: $msg" >&2
        echo "  path: '$path'" >&2
        return 1
    fi
}

assert_dir_exists() {
    local path="$1" msg="${2:-}"
    if [ ! -d "$path" ]; then
        echo "ASSERT_DIR_EXISTS FAIL: $msg" >&2
        echo "  path: '$path'" >&2
        return 1
    fi
}

# ── Mock helpers ────────────────────────────────────────────────

# Create a temporary directory for test isolation, cleaned up on EXIT
TEST_DIR=""
mock_setup() {
    TEST_DIR=$(mktemp -d "/tmp/freeze-diag-test.XXXXXX")
    trap 'mock_teardown' EXIT
    export _TEST_DIR="$TEST_DIR"
    export FD_ROOT="$TEST_DIR/fd-root"
    export FD_LIB="$FD_ROOT/lib"
    export FD_LOGS="$TEST_DIR/fd-root/logs"
    export FD_ARCHIVE="$TEST_DIR/fd-root/archive"
    export FD_REPORTS="$TEST_DIR/fd-root/reports"
    export FD_PID_DIR="$TEST_DIR/fd-pid"
    mkdir -p "$FD_LOGS/sessions" "$FD_ARCHIVE" "$FD_REPORTS" "$FD_PID_DIR" "$FD_LIB"
    # Copy the actual library for collectors that source it
    cp "$(dirname "$0")/../lib/lib_common.sh" "$FD_LIB/lib_common.sh" 2>/dev/null || true
    export FD_CPU_HWMON_PATH=""
    export FD_AMDGPU_HWMON_PATH=""
    export FD_NVME_HWMON_PATH=""
    export FD_HEARTBEAT_INTERVAL=1
    export FD_FAST_INTERVAL=5
    export FD_GPU_INTERVAL=5
    export FD_CPU_INTERVAL=2
    export FD_WATCHDOG_INTERVAL=10
    export FD_DETAILED_INTERVAL=60
    export FD_HEARTBEAT_SEGMENT=600
    export FD_FAST_SEGMENT=600
    export FD_GPU_SEGMENT=600
    export FD_CPU_SEGMENT=600
    export FD_WATCHDOG_SEGMENT=600
    export FD_DETAILED_SEGMENT=3600
    export FD_DMESG_SEGMENT=900
    export FD_RETENTION_MINUTES=129600
    export FD_MAX_DISK_MB=5000
    export FD_TARGETS="opencode testapp"
    export FD_AMDGPU_CARD_PATH=""
    export FD_DMESG_CMD="echo dmesg-mock"
    export FD_JOURNAL_CMD="echo journal-mock"
    export FD_AMDGPU_DEBUG_MASK_CMD="echo"
    export FD_PSTORE_DUMP_BIN="/usr/local/bin/fd-pstore-dump"
    export CURRENT_BOOT="deadbeef_boot_id"
    export SESSION_ID="${CURRENT_BOOT}_987654321"
}

mock_teardown() {
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR" 2>/dev/null || true
    fi
}

# Mock procfs files for tests
mock_proc() {
    local subpath="$1" content="$2"
    local dir="$TEST_DIR/proc/$(dirname "$subpath")"
    mkdir -p "$dir"
    echo "$content" > "$TEST_DIR/proc/$subpath"
}

mock_sys() {
    local subpath="$1" content="$2"
    local dir="$TEST_DIR/sys/$(dirname "$subpath")"
    mkdir -p "$dir"
    echo "$content" > "$TEST_DIR/sys/$subpath"
}

# Clean a temp dir for reuse
mock_reset_dir() {
    local d="$1"
    rm -rf "$d" 2>/dev/null || true
    mkdir -p "$d"
}

# ── Run all test functions ──
run_tests() {
    local script="$1" filter="${2:-}"
    local total=0 passed=0 failed=0 skipped=0
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Test Suite: $(basename "$script" .sh)${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local funcs
    funcs=$(declare -F | awk '{print $3}' | grep -E '^test_' | sort)
    for func in $funcs; do
        [ -n "$filter" ] && [[ "$func" != *"$filter"* ]] && continue
        total=$((total + 1))
        (
            mock_setup
            trap 'mock_teardown' EXIT
            "$func"
        )
        local rc=$?
        case $rc in
            0) passed=$((passed + 1)) ;;
            77) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}Results:${NC}"
    echo -e "    ${GREEN}Pass:${NC}  $passed"
    echo -e "    ${RED}Fail:${NC}  $failed"
    echo -e "    ${YELLOW}Skip:${NC}  $skipped"
    echo -e "    Total: $total"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    return $failed
}

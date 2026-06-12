#!/bin/bash
# run_tests.sh — master test runner for freeze-diag
# Usage: tests/run_tests.sh [--filter <pattern>] [--unit | --integration | --all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

FILTER=""
MODE="unit"

while [ $# -gt 0 ]; do
    case "$1" in
        --filter) FILTER="$2"; shift 2 ;;
        --unit) MODE="unit"; shift ;;
        --integration) MODE="integration"; shift ;;
        --all) MODE="all"; shift ;;
        --help|-h)
            echo "Usage: $0 [--filter <pattern>] [--unit | --integration | --all]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$PROJECT_DIR"

PASS_ALL=0
FAIL_ALL=0
SKIP_ALL=0

run_suite() {
    local label="$1" script="$2"
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  $label"
    echo "╚══════════════════════════════════════════════════╝"

    # Run test in sub-shell with timeout guard. Stream output directly
    # (don't capture to variable, which can hang on open FDs).
    local tmpout
    tmpout=$(mktemp)
    # Run with timeout and redirect to temp file
    timeout 120 bash "$script" > "$tmpout" 2>&1 || rc=$?
    rc=${rc:-0}
    cat "$tmpout"

    # Parse results from the full output
    local pass fail skip total
    pass=$(grep -oP '(?<=Pass:  )\d+' "$tmpout" | tail -1)
    fail=$(grep -oP '(?<=Fail:  )\d+' "$tmpout" | tail -1)
    skip=$(grep -oP '(?<=Skip:  )\d+' "$tmpout" | tail -1)
    total=$(grep -oP '(?<=Total: )\d+' "$tmpout" | tail -1)

    [ -n "$pass" ] && PASS_ALL=$((PASS_ALL + pass))
    [ -n "$fail" ] && FAIL_ALL=$((FAIL_ALL + fail))
    [ -n "$skip" ] && SKIP_ALL=$((SKIP_ALL + skip))

    rm -f "$tmpout" 2>/dev/null || true

    if [ "$rc" -ne 0 ]; then
        echo "  [FAIL] $script timed out or exited with code $rc" >&2
    fi
}

UNIT_TESTS=(
    "test_lib_common.sh"
    "test_collectors.sh"
    "test_diag_analyze.sh"
    "test_diag_start.sh"
    "test_diag_stop.sh"
    "test_diag_harden.sh"
    "test_diag_report.sh"
    "test_fd_pstore_dump.sh"
)

INTEGRATION_TESTS=(
    "test_integration.sh"
)

if [ "$MODE" = "unit" ] || [ "$MODE" = "all" ]; then
    for tf in "${UNIT_TESTS[@]}"; do
        [ -n "$FILTER" ] && [[ "$tf" != *"$FILTER"* ]] && continue
        run_suite "Unit: $tf" "tests/$tf"
    done
fi

if [ "$MODE" = "integration" ] || [ "$MODE" = "all" ]; then
    for tf in "${INTEGRATION_TESTS[@]}"; do
        [ -n "$FILTER" ] && [[ "$tf" != *"$FILTER"* ]] && continue
        if [ -f "tests/$tf" ]; then
            run_suite "Integration: $tf" "tests/$tf"
        fi
    done
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║                     FINAL                        ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Pass:  $PASS_ALL"
echo "║  Fail:  $FAIL_ALL"
echo "║  Skip:  $SKIP_ALL"
echo "║  Total: $((PASS_ALL + FAIL_ALL + SKIP_ALL))"
echo "╚══════════════════════════════════════════════════╝"
echo ""

exit $FAIL_ALL

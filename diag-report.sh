#!/bin/bash
# diag-report.sh — auto-run crash summary at login
# This is called by diag-start.sh when a crashed session is detected.
# Usage: diag-report.sh --boot <boot_id>
# Generates a quick summary and sends a desktop notification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/diag.conf"
source "$FD_LIB/lib_common.sh"

SESSION_ID=""
BOOT_ID=""
QUIET=false

while [ $# -gt 0 ]; do
    case "$1" in
        --session) SESSION_ID="$2"; shift 2 ;;
        --boot) BOOT_ID="$2"; shift 2 ;;
        --quiet) QUIET=true; shift ;;
        *) echo "Usage: diag-report.sh --session <session_id> | --boot <boot_id> [--quiet]"; exit 1 ;;
    esac
done

# Determine session identifier: prefer --session, fall back to --boot
if [ -n "$SESSION_ID" ]; then
    SESSION_ARG="--session $SESSION_ID"
elif [ -n "$BOOT_ID" ]; then
    SESSION_ARG="--boot $BOOT_ID"
else
    echo "diag-report: no session_id or boot_id provided" >&2
    exit 1
fi

REPORT_FILE="$FD_REPORTS/crash_$(ts_dt).txt"

# Generate quick analysis
# shellcheck disable=SC2086
"$SCRIPT_DIR/diag-analyze.sh" $SESSION_ARG --quick --output "$REPORT_FILE" 2>/dev/null || {
    local display_id="${SESSION_ID:-$BOOT_ID}"
    echo "diag-report: analysis failed for $display_id" >&2
    # Generate a minimal report even if analysis fails
    cat > "$REPORT_FILE" <<MINEOF
CRASH DETECTED — $display_id
═══════════════════════════════════
The previous session ended abnormally.
No detailed analysis was possible (logs may be empty).

Check logs manually in: $FD_LOGS
Run: $SCRIPT_DIR/diag-analyze.sh $SESSION_ARG
MINEOF
}

# Read top finding for notification
TOP_FINDING=$(grep -A1 "HIGH\|MEDIUM" "$REPORT_FILE" 2>/dev/null | head -2 | tr '\n' ' ' || echo "Unknown cause")

# Find session file and extract started_at
SESSION_FILE=$(find_session_file "${SESSION_ID:-$BOOT_ID}" 2>/dev/null) || SESSION_FILE=""
STARTED_AT="unknown"
if [ -n "$SESSION_FILE" ]; then
    STARTED_AT=$(grep -o '"started_at": *"[^"]*"' "$SESSION_FILE" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "unknown")
elif [ -f "$FD_LOGS/sessions/${BOOT_ID}.session" ]; then
    STARTED_AT=$(grep -o '"started_at": *"[^"]*"' "$FD_LOGS/sessions/${BOOT_ID}.session" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "unknown")
fi

notify_user \
    "System freeze detected" \
    "Previous session (${STARTED_AT:-unknown}) ended abnormally.\nTop finding: $TOP_FINDING\nFull report: $REPORT_FILE" \
    "critical"

# Mark session as crashed (handles both session_id and boot_id formats)
mark_session_crashed "${SESSION_ID:-$BOOT_ID}"

echo "diag-report: crash summary generated -> $REPORT_FILE" >> "$FD_LOGS/diag_events.log"

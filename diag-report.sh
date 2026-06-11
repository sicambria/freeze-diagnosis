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
    display_id="${SESSION_ID:-$BOOT_ID}"
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

# ---- Preserve a crash bundle in archive/ (never pruned) ----
# Everything a later RCA needs, frozen at detection time: the crashed
# session's pre-crash segments + context snapshot, the previous boot's
# journal tail and kernel-fault lines, pstore records, and the report.
preserve_crash_bundle() {
    local id="${SESSION_ID:-$BOOT_ID}"
    local bundle="$FD_ARCHIVE/crash_${id}_$(ts_dt)"
    mkdir -p "$bundle/segments"

    # Pre-crash segments: written since the crashed session started,
    # newest 300 files (the hours right before death are what matter;
    # a multi-day session must not balloon the bundle).
    local since="$STARTED_AT" f
    [ -n "$since" ] && [ "$since" != "unknown" ] || since="2 hours ago"
    find "$FD_LOGS" -maxdepth 1 -name '*.log' -newermt "$since" \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -300 | \
        while read -r _ f; do
            cp -p "$f" "$bundle/segments/" 2>/dev/null
        done

    # Context snapshot of the crashed session (kernel/BIOS/boost posture)
    cp -p "$FD_LOGS/context_${id}.log" "$bundle/" 2>/dev/null || true

    # Previous boot's journal: full tail + kernel-fault extraction
    if sudo -n true 2>/dev/null; then
        sudo -n journalctl -b -1 -n 800 -o short-precise --no-pager \
            > "$bundle/journal-prev-boot-tail.txt" 2>/dev/null || true
        sudo -n journalctl -b -1 -o short-precise --no-pager 2>/dev/null | \
            grep -aE 'BUG:|Oops|general protection|soft lockup|hung task|double fault|stack guard|invalid opcode|machine check|MCE|segfault|amdgpu.*(ERROR|timeout|reset|fault)|RIP: 0010' \
            > "$bundle/journal-prev-boot-faults.txt" || true
        sudo -n journalctl --list-boots --no-pager \
            > "$bundle/boots.txt" 2>/dev/null || true
    fi

    # Kernel panic records (root-only; via the installed helper)
    local pstore_bin="${FD_PSTORE_DUMP_BIN:-/usr/local/bin/fd-pstore-dump}"
    if [ -x "$pstore_bin" ] && sudo -n "$pstore_bin" "$bundle" >/dev/null 2>&1; then
        echo "diag-report: pstore records preserved in bundle" >> "$FD_LOGS/diag_events.log"
    else
        ls -la /var/lib/systemd/pstore /sys/fs/pstore \
            > "$bundle/pstore-listing-unprivileged.txt" 2>/dev/null || true
    fi

    # The analysis report + session marker
    cp -p "$REPORT_FILE" "$bundle/" 2>/dev/null || true
    cp -p "$SESSION_FILE" "$bundle/" 2>/dev/null || true

    {
        echo "crash bundle for session: $id"
        echo "session started_at: $STARTED_AT"
        echo "bundle created:     $(ts_iso)"
        echo "created by boot:    $(current_boot_id)"
    } > "$bundle/MANIFEST.txt"
    sync_file "$bundle/MANIFEST.txt"

    echo "diag-report: crash bundle -> $bundle" >> "$FD_LOGS/diag_events.log"
}
preserve_crash_bundle

echo "diag-report: crash summary generated -> $REPORT_FILE" >> "$FD_LOGS/diag_events.log"

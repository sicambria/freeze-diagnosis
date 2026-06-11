#!/bin/bash
# collector_dmesg.sh — continuous kernel + systemd log capture
# Runs dmesg -w and journalctl -f via sudo, merges into timestamped stream.
# This collector needs to be started with sudo privileges available.
# Usage: bash collector_dmesg.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

STREAM="dmesg"
PIDFILE="$FD_PID_DIR/freeze-diag-$STREAM.pid"
SEGMENT="${FD_DMESG_SEGMENT:-900}"

# Primary guard: flock (survives orphans)
flock_instance_guard "$FD_PID_DIR/freeze-diag-$STREAM.lock"

if is_running "$PIDFILE"; then
    echo "[$(ts_iso)] dmesg: already running" >&2
    exit 0
fi
write_pidfile "$PIDFILE"

cleanup_bg_jobs() {
    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null
}

trap "cleanup_pidfile '$PIDFILE'; trap_exit_handler '$STREAM'; cleanup_bg_jobs" EXIT TERM INT

# Set amdgpu debug_mask if configured
DMASK="${FD_AMDGPU_DEBUG_MASK:-1}"
if [ "$DMASK" -gt 0 ] 2>/dev/null; then
    echo "$DMASK" | eval "$FD_AMDGPU_DEBUG_MASK_CMD" > /dev/null 2>&1 || true
    echo "[$(ts_iso)] dmesg: amdgpu debug_mask set to $DMASK" >> "$FD_LOGS/diag_events.log"
fi

open_segment "$STREAM" "$SEGMENT"
# Record last line of Xorg log (detects clean shutdown vs crash)
record_xorg_status() {
    local xorg_log="/var/log/Xorg.0.log"
    if [ -r "$xorg_log" ]; then
        local xorg_last xorg_pid
        xorg_last=$(tail -1 "$xorg_log" 2>/dev/null || echo "unreadable")
        xorg_pid=$(pgrep -x Xorg 2>/dev/null || echo "dead")
        echo "X: xorg_exit_status=$xorg_last|xorg_pid=$xorg_pid" >> "$FD_CURRENT_SEGMENT" 2>/dev/null
    fi
    # Logind sessions
    if command -v loginctl &>/dev/null; then
        local sessions
        sessions=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{printf "%s:%s;", $1, $3}' | tr -d '\n')
        echo "L: sessions=$sessions" >> "$FD_CURRENT_SEGMENT" 2>/dev/null
    fi
}

sync_loop() {
    while true; do
        sleep 30
        echo "--- SYNCPOINT $(ts_iso) ---" >> "$FD_CURRENT_SEGMENT" 2>/dev/null
        record_xorg_status
        sync_file "$FD_CURRENT_SEGMENT"
        # Segment rollover
        if should_roll_segment "$SEGMENT"; then
            open_segment "$STREAM" "$SEGMENT"
        fi
        cleanup_old_segments "$STREAM" &
        size_check_and_prune &
    done
}

# Launch sync loop in background
sync_loop &
SYNC_PID=$!

# Check if sudo works (test with a quick dmesg read)
if ! sudo -n dmesg > /dev/null 2>&1; then
    echo "[$(ts_iso)] dmesg: sudo not available (passwordless sudo not configured)" >> "$FD_LOGS/diag_events.log"
    echo "[$(ts_iso)] dmesg: dmesg+journal capture DISABLED" >> "$FD_LOGS/diag_events.log"
    # Run sync loop only, then exit after a long sleep (keep PID alive so launcher doesn't restart)
    while true; do
        sleep 30
        if should_roll_segment "$SEGMENT"; then
            open_segment "$STREAM" "$SEGMENT"
        fi
        cleanup_old_segments "$STREAM" &
        size_check_and_prune &
    done
    exit 0
fi

# Capture dmesg (continuous). fsync per line: kernel messages are rare
# and the last ones before a panic are precisely the evidence we need —
# an unsynced page cache line dies with the kernel.
$FD_DMESG_CMD 2>/dev/null | while IFS= read -r line; do
    fsync_line "$FD_CURRENT_SEGMENT" "D: $line"
done &
DMESG_PID=$!

# Capture journal (continuous, warn-and-above only — low volume)
$FD_JOURNAL_CMD 2>/dev/null | while IFS= read -r line; do
    fsync_line "$FD_CURRENT_SEGMENT" "J: $line"
done &
JOURNAL_PID=$!

# Wait for any to die, then kill the rest
wait -n 2>/dev/null || true
kill $DMESG_PID $JOURNAL_PID $SYNC_PID 2>/dev/null || true
wait 2>/dev/null

#!/bin/bash
# collector_heartbeat.sh — 1-second durable heartbeat
# Source lib_common.sh first.
# Usage: bash collector_heartbeat.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

STREAM="heartbeat"
PIDFILE="$FD_PID_DIR/freeze-diag-$STREAM.pid"
INTERVAL="${FD_HEARTBEAT_INTERVAL:-1}"
SEGMENT="${FD_HEARTBEAT_SEGMENT:-600}"

# Primary guard: flock (survives orphans)
flock_instance_guard "$FD_PID_DIR/freeze-diag-$STREAM.lock"

# Secondary guard: PID file (for logging stale duplicates)
if is_running "$PIDFILE"; then
    echo "[$(ts_iso)] heartbeat: already running (pid=$(cat "$PIDFILE"))" >&2
    exit 0
fi
write_pidfile "$PIDFILE"
trap "cleanup_pidfile '$PIDFILE'; trap_exit_handler '$STREAM'" EXIT TERM INT

open_segment "$STREAM" "$SEGMENT"
COUNTER=0

while true; do
    NOW=$(ts_epochns)
    LINE="$NOW HEARTBEAT $COUNTER"

    # Check segment rollover
    if should_roll_segment "$SEGMENT"; then
        open_segment "$STREAM" "$SEGMENT"
    fi

    durable_line "$FD_CURRENT_SEGMENT" "$LINE"

    COUNTER=$((COUNTER + 1))

    # Periodic cleanup every 60 beats
    if [ $((COUNTER % 60)) -eq 0 ]; then
        cleanup_old_segments "$STREAM" &
        size_check_and_prune &
    fi

    sleep "$INTERVAL" 2>/dev/null || sleep 1
done

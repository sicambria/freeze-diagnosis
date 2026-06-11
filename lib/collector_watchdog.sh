#!/bin/bash
# collector_watchdog.sh — 10-second per-process monitoring
# Tracks opencode, kilo-cli and child processes
# Usage: bash collector_watchdog.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

STREAM="watchdog"
PIDFILE="$FD_PID_DIR/freeze-diag-$STREAM.pid"
INTERVAL="${FD_WATCHDOG_INTERVAL:-10}"
SEGMENT="${FD_WATCHDOG_SEGMENT:-600}"

# Primary guard: flock (survives orphans)
flock_instance_guard "$FD_PID_DIR/freeze-diag-$STREAM.lock"

if is_running "$PIDFILE"; then
    echo "[$(ts_iso)] watchdog: already running" >&2
    exit 0
fi
write_pidfile "$PIDFILE"
trap "cleanup_pidfile '$PIDFILE'; trap_exit_handler '$STREAM'" EXIT TERM INT

open_segment "$STREAM" "$SEGMENT"
COUNTER=0

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

    # Get children (single line, semicolon-separated, no leading comma)
    local children
    children=$(ps --ppid "$pid" -o pid=,comm= --no-headers 2>/dev/null | awk '{printf "%s,%s;", $1, $2}' | sed 's/;$/;/g')

    printf '%s|target=%s|pid=%s|st=%s|rss=%s|vsz=%s|cpu=%s|mem=%s|thr=%s|fd=%s|inot=%s|dri=%s|etime=%s|children=%s\n' \
        "$now" "$label" "$pid" "$state" "$rss_mb" "$vsz_mb" "$pcpu" "$pmem" "$threads" "$fds" "$inotify" "$dri" "$etime" "$children"
}

while true; do
    NOW=$(ts_epoch)

    if should_roll_segment "$SEGMENT"; then
        open_segment "$STREAM" "$SEGMENT"
    fi

    ANY_FOUND=0
    for TARGET in $FD_TARGETS; do
        PIDS=$(find_target_pids "$TARGET")
        if [ -z "$PIDS" ]; then
            echo "$NOW|target=$TARGET|status=NOT_FOUND" >> "$FD_CURRENT_SEGMENT"
        else
            for pid in $PIDS; do
                LINE=$(collect_for_pid "$pid" "$TARGET" "$NOW")
                if [ -n "$LINE" ]; then
                    echo "$LINE" >> "$FD_CURRENT_SEGMENT"
                    ANY_FOUND=1
                fi
            done
        fi
    done

    if [ "$ANY_FOUND" -eq 0 ]; then
        echo "$NOW|status=NO_TARGETS" >> "$FD_CURRENT_SEGMENT"
    fi

    # One fdatasync per cycle: an instant kernel death must not lose
    # the final samples — that window is exactly what the RCA needs.
    sync_file "$FD_CURRENT_SEGMENT"

    COUNTER=$((COUNTER + 1))
    if [ $((COUNTER % 12)) -eq 0 ]; then
        cleanup_old_segments "$STREAM" &
        size_check_and_prune &
    fi

    sleep "$INTERVAL" 2>/dev/null || sleep 10
done

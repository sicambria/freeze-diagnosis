#!/bin/bash
# collector_detailed.sh — 60-second full system snapshot
# Full meminfo, top processes, inotify owners, sockets, disk IO, D-state procs
# Usage: bash collector_detailed.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

STREAM="detailed"
PIDFILE="$FD_PID_DIR/freeze-diag-$STREAM.pid"
INTERVAL="${FD_DETAILED_INTERVAL:-60}"
SEGMENT="${FD_DETAILED_SEGMENT:-3600}"

# Primary guard: flock (survives orphans)
flock_instance_guard "$FD_PID_DIR/freeze-diag-$STREAM.lock"

if is_running "$PIDFILE"; then
    echo "[$(ts_iso)] detailed: already running" >&2
    exit 0
fi
write_pidfile "$PIDFILE"
trap "cleanup_pidfile '$PIDFILE'; trap_exit_handler '$STREAM'" EXIT TERM INT

open_segment "$STREAM" "$SEGMENT"
COUNTER=0

while true; do
    NOW=$(ts_epoch)
    NOW_ISO=$(ts_iso)

    if should_roll_segment "$SEGMENT"; then
        open_segment "$STREAM" "$SEGMENT"
    fi

    {
        echo "=== SNAPSHOT $NOW $NOW_ISO ==="

        # Full memory info
        echo "--- MEMINFO ---"
        cat /proc/meminfo 2>/dev/null || echo "N/A"

        echo "--- VMSTAT (key fields) ---"
        grep -E '^(oom_kill|pgpgin|pgpgout|pswpin|pswpout|nr_dirty|nr_writeback|nr_inactive_anon|nr_active_anon|nr_inactive_file|nr_active_file|nr_unevictable)' /proc/vmstat 2>/dev/null || echo "N/A"

        echo "--- BUDDYINFO ---"
        head -5 /proc/buddyinfo 2>/dev/null || echo "N/A"

        echo "--- SLABINFO (top 20) ---"
        sort -t: -k2 -rn /proc/slabinfo 2>/dev/null | head -22 || echo "N/A"

        echo "--- TOP PROCESSES (RSS) ---"
        ps -eo pid,ppid,state,rss,vsz,pcpu,pmem,etime,comm --no-headers --sort=-rss 2>/dev/null | head -30

        echo "--- INOTIFY OWNERS ---"
        if [ $((COUNTER % 5)) -eq 0 ]; then
            find /proc/[0-9]*/fd -lname 'anon_inode:inotify' 2>/dev/null | \
                awk -F/ '{print $3}' | sort | uniq -c | sort -rn | head -15 | \
                while read -r count pid; do
                    comm=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
                    echo "  $count watches: pid=$pid comm=$comm"
                done
        else
            echo "  (skipped, runs every 5 cycles)"
        fi

        echo "--- SOCKETS ---"
        ss -s 2>/dev/null || echo "N/A"

        echo "--- DISK IO ---"
        { echo "Device r/s w/s rkB/s wkB/s rrqm/s wrqm/s avgrq-sz avgqu-sz await svctm %util"
          awk '/[0-9]/{print $1,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13}' /proc/diskstats 2>/dev/null | head -10; } || echo "N/A"

        echo "--- DISK USAGE ---"
        df -h / /home 2>/dev/null || echo "N/A"

        echo "--- D-STATE PROCESSES ---"
        ps -eo pid,state,wchan:32,comm --no-headers 2>/dev/null | grep '^[0-9]* D' | head -10 || echo "none"

        echo "--- CPU INFO ---"
        grep -E '^cpu MHz|^model name|^processor' /proc/cpuinfo 2>/dev/null | head -3 || echo "N/A"

        echo "--- IRQ COUNTS (top 15) ---"
        grep -v '^ *0:' /proc/interrupts 2>/dev/null | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; if(sum>0) print sum, $0}' | sort -rn | head -15 || echo "N/A"

        echo "--- DISPLAY SERVER ---"
        XORG_PID=$(pgrep -x Xorg 2>/dev/null || echo "")
        if [ -n "$XORG_PID" ]; then
            XORG_INFO=$(proc_info "$XORG_PID" "rss,vsz,pcpu,pmem,etime" 2>/dev/null || echo "N/A")
            echo "  Xorg: pid=$XORG_PID info=$XORG_INFO"
            echo "  Xorg log tail: $(tail -1 /var/log/Xorg.0.log 2>/dev/null || echo 'N/A')"
        else
            echo "  Xorg: NOT_RUNNING"
            echo "  Xorg log tail: $(tail -1 /var/log/Xorg.0.log 2>/dev/null || echo 'N/A')"
        fi
        if command -v loginctl &>/dev/null; then
            echo "  Sessions:"
            loginctl list-sessions --no-legend 2>/dev/null | while read -r s uid user seat tty; do
                echo "    session=$s uid=$uid user=$user seat=$seat"
            done
        fi

        echo "=== END SNAPSHOT $NOW ==="
        echo ""
    } >> "$FD_CURRENT_SEGMENT"

    COUNTER=$((COUNTER + 1))
    if [ $((COUNTER % 5)) -eq 0 ]; then
        cleanup_old_segments "$STREAM" &
        size_check_and_prune &
    fi

    sleep "$INTERVAL" 2>/dev/null || sleep 60
done

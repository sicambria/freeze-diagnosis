#!/bin/bash
# collector_fast.sh — 5-second fast metrics
# PSI pressure, load, swap, temps, OOM count, top procs
# Usage: bash collector_fast.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

STREAM="fast"
PIDFILE="$FD_PID_DIR/freeze-diag-$STREAM.pid"
INTERVAL="${FD_FAST_INTERVAL:-5}"
SEGMENT="${FD_FAST_SEGMENT:-600}"

# Primary guard: flock (survives orphans)
flock_instance_guard "$FD_PID_DIR/freeze-diag-$STREAM.lock"

# Resolve hwmon paths by chip name (hwmonN numbering varies per boot)
fd_resolve_hwmons

if is_running "$PIDFILE"; then
    echo "[$(ts_iso)] fast: already running" >&2
    exit 0
fi
write_pidfile "$PIDFILE"
trap "cleanup_pidfile '$PIDFILE'; trap_exit_handler '$STREAM'" EXIT TERM INT

open_segment "$STREAM" "$SEGMENT"
COUNTER=0
LAST_OOM=0

read_pressure() {
    local f="$1" field="${2:-some}" result=0 part
    while IFS=' ' read -ra parts; do
        [[ ${parts[0]} == "$field" ]] || continue
        for part in "${parts[@]}"; do
            if [[ "$part" =~ ^avg10=([0-9.]+)$ ]]; then
                result="${BASH_REMATCH[1]}"
                break 2
            fi
        done
    done < "$f" 2>/dev/null
    echo "$result"
}

read_temp() {
    local path="$1" val tenths
    val=$(<"$path" 2>/dev/null) || { echo "0"; return; }
    val=${val//[[:space:]]/}
    [[ -n "$val" ]] || { echo "0"; return; }
    tenths=$(( (val + 50) / 100 ))
    printf "%d.%d\n" $((tenths / 10)) $((tenths % 10))
}

# Cache Xorg PID across iterations to avoid pgrep every cycle
CACHED_XORG_PID=""

while true; do
    NOW=$(ts_epoch)

    # Segment rollover
    if should_roll_segment "$SEGMENT"; then
        open_segment "$STREAM" "$SEGMENT"
    fi

    # PSI (bash builtin, no subprocesses)
    PSI_CPU=$(read_pressure /proc/pressure/cpu some)
    PSI_MEM_SOME=$(read_pressure /proc/pressure/memory some)
    PSI_MEM_FULL=$(read_pressure /proc/pressure/memory full)
    PSI_IO=$(read_pressure /proc/pressure/io some)

    # Load (single read, no awk)
    read -r L1 L5 L15 _ < /proc/loadavg 2>/dev/null || { L1=0; L5=0; L15=0; }

    # Memory (single pass through /proc/meminfo, zero subprocesses)
    MEM_AVAIL=0; SWAP_FREE=0; SWAP_CACHED=0; CACHED=0; ANON=0; SUNRECLAIM=0
    while IFS=':' read -r key val; do
        val="${val%%kB*}"
        val="${val## }"
        case "$key" in
            MemAvailable) MEM_AVAIL=$((val / 1024)) ;;
            SwapFree)     SWAP_FREE=$((val / 1024)) ;;
            SwapCached)   SWAP_CACHED=$((val / 1024)) ;;
            Cached)       CACHED=$((val / 1024)) ;;
            AnonPages)    ANON=$((val / 1024)) ;;
            SUnreclaim)   SUNRECLAIM=$((val / 1024)) ;;
        esac
    done < /proc/meminfo 2>/dev/null

    # OOM kills
    CUR_OOM=$(awk '/^oom_kill/{print $2}' /proc/vmstat 2>/dev/null || echo 0)
    OOM_DELTA=$((CUR_OOM - LAST_OOM))
    [ "$OOM_DELTA" -lt 0 ] && OOM_DELTA=0
    LAST_OOM=$CUR_OOM

    # Temps
    CPU_TEMP=$(read_temp "${FD_CPU_HWMON_PATH}/temp1_input")
    GPU_TEMP=$(read_temp "${FD_AMDGPU_HWMON_PATH}/temp1_input")
    NVME_TEMP=$(read_temp "${FD_NVME_HWMON_PATH}/temp1_input")

    # Top-3 processes by RSS
    TOP_PROCS=$(ps -eo pid,comm,rss --no-headers --sort=-rss 2>/dev/null | head -3 | \
        awk '{printf "%s,%s,%s;", $1,$2,$3}')

    # Running / blocked counts (single ps call, awk counts both)
    read -r R_COUNT D_COUNT < <(ps -eo state --no-headers 2>/dev/null | awk '/^R/{r++} /^D/{d++} END{print r+0, d+0}')
    R_COUNT=${R_COUNT:-0}; D_COUNT=${D_COUNT:-0}

    # Display server (cached PID to avoid pgrep every cycle)
    if [ -n "$CACHED_XORG_PID" ] && kill -0 "$CACHED_XORG_PID" 2>/dev/null; then
        XORG_PID="$CACHED_XORG_PID"
    else
        XORG_PID=$(pgrep -x Xorg 2>/dev/null || echo "")
        CACHED_XORG_PID="$XORG_PID"
    fi
    if [ -n "$XORG_PID" ]; then
        XORG_INFO=$(proc_info "$XORG_PID" "rss,pcpu,etime" 2>/dev/null || echo "0,0,0")
        read -r xrss xcpu xetime <<< "$XORG_INFO"
        XORG_UP="1"
    else
        XORG_UP="0"
        xrss=0; xcpu=0; xetime="0"
    fi

    # Sessions
    SESSION_COUNT=$(loginctl list-sessions --no-legend 2>/dev/null | wc -l || echo 0)

    LINE="$NOW|psic=$PSI_CPU|psim=$PSI_MEM_SOME|psimf=$PSI_MEM_FULL|psii=$PSI_IO|"
    LINE+="l1=$L1|l5=$L5|l15=$L15|"
    LINE+="mavail=$MEM_AVAIL|swapf=$SWAP_FREE|swapc=$SWAP_CACHED|cache=$CACHED|anon=$ANON|sunrec=$SUNRECLAIM|oomd=$OOM_DELTA|"
    LINE+="ctemp=$CPU_TEMP|gtemp=$GPU_TEMP|ntemp=$NVME_TEMP|"
    LINE+="rprocs=$R_COUNT|dprocs=$D_COUNT|"
    LINE+="xorg=$XORG_UP|xpss=$xrss|xpcpu=$xcpu|xetime=$xetime|nsess=$SESSION_COUNT|"
    LINE+="top3=$TOP_PROCS"

    fsync_line "$FD_CURRENT_SEGMENT" "$LINE"

    COUNTER=$((COUNTER + 1))
    if [ $((COUNTER % 24)) -eq 0 ]; then
        cleanup_old_segments "$STREAM" &
        size_check_and_prune &
    fi

    sleep "$INTERVAL" 2>/dev/null || sleep 5
done

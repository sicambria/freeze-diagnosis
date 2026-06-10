#!/bin/bash
# collector_gpu.sh — 5-second AMD GPU sysfs metrics
# GPU busy%, VRAM, GTT, temperature, power, voltage, runtime status
# Usage: bash collector_gpu.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

STREAM="gpu"
PIDFILE="$FD_PID_DIR/freeze-diag-$STREAM.pid"
INTERVAL="${FD_GPU_INTERVAL:-5}"
SEGMENT="${FD_GPU_SEGMENT:-600}"

# Primary guard: flock (survives orphans)
flock_instance_guard "$FD_PID_DIR/freeze-diag-$STREAM.lock"
CARD_PATH="${FD_AMDGPU_CARD_PATH:-/sys/class/drm/card1/device}"
HWMON_PATH="${FD_AMDGPU_HWMON_PATH:-/sys/class/hwmon/hwmon11}"

if is_running "$PIDFILE"; then
    echo "[$(ts_iso)] gpu: already running" >&2
    exit 0
fi
write_pidfile "$PIDFILE"
trap "cleanup_pidfile '$PIDFILE'; trap_exit_handler '$STREAM'" EXIT TERM INT

open_segment "$STREAM" "$SEGMENT"
COUNTER=0

read_gpu_val() {
    local f="$1" default="${2:-0}"
    [ -r "$f" ] && cat "$f" 2>/dev/null || echo "$default"
}

# Detect card path (card0 or card1)
detect_card_path() {
    if [ -r "$CARD_PATH/gpu_busy_percent" ]; then
        echo "$CARD_PATH"
    elif [ -r "/sys/class/drm/card0/device/gpu_busy_percent" ]; then
        echo "/sys/class/drm/card0/device"
    else
        echo ""
    fi
}

CARD_PATH=$(detect_card_path)

while true; do
    NOW=$(ts_epoch)

    if should_roll_segment "$SEGMENT"; then
        open_segment "$STREAM" "$SEGMENT"
    fi

    # GPU busy
    GPU_BUSY=$(read_gpu_val "$CARD_PATH/gpu_busy_percent")

    # VRAM
    VRAM_USED=$(read_gpu_val "$CARD_PATH/mem_info_vram_used" 0)
    VRAM_TOTAL=$(read_gpu_val "$CARD_PATH/mem_info_vram_total" 0)
    VRAM_MB=$((VRAM_USED / 1048576))

    # GTT
    GTT_USED=$(read_gpu_val "$CARD_PATH/mem_info_gtt_used" 0)
    GTT_TOTAL=$(read_gpu_val "$CARD_PATH/mem_info_gtt_total" 0)
    GTT_MB=$((GTT_USED / 1048576))

    # Temperature
    GPU_EDGE=$(sysfs_val "$HWMON_PATH/temp1_input" | awk '{printf "%.1f", $1/1000}')

    # Power (microwatts -> watts) and voltage (millivolts -> volts) from sysfs
    GPU_POWER=$(sysfs_val "$HWMON_PATH/power1_average" | awk '{printf "%.2f", $1/1000000}' 2>/dev/null || echo "0")
    GPU_VOLT=$(sysfs_val "$HWMON_PATH/in0_input" | awk '{printf "%.3f", $1/1000}' 2>/dev/null || echo "0")

    # Runtime power status
    GPU_RT_STATUS=$(read_gpu_val "$CARD_PATH/power/runtime_status" "unknown")

    # Connected display connectors
    CONNECTORS=""
    for c in /sys/class/drm/card*-*-*/status; do
        [ -r "$c" ] || continue
        st=$(cat "$c" 2>/dev/null)
        if [ "$st" = "connected" ]; then
            cname=$(basename "$(dirname "$c")")
            CONNECTORS="$CONNECTORS$cname:$st "
        fi
    done

    LINE="$NOW|busy=$GPU_BUSY|vram=$VRAM_MB|gtt=$GTT_MB|edge=$GPU_EDGE|power=$GPU_POWER|volt=$GPU_VOLT|rt=$GPU_RT_STATUS|conn=$CONNECTORS"

    fsync_line "$FD_CURRENT_SEGMENT" "$LINE"

    COUNTER=$((COUNTER + 1))
    if [ $((COUNTER % 24)) -eq 0 ]; then
        cleanup_old_segments "$STREAM" &
        size_check_and_prune &
    fi

    sleep "$INTERVAL" 2>/dev/null || sleep 5
done

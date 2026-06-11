#!/bin/bash
# collector_cpu.sh — 2-second CPU frequency / boost / taint sampler
#
# Purpose (born from the 2026-06 RCA): crashes correlated with bursty
# frequency/voltage transients (process-spawn storms). This stream records,
# at death-minus-seconds resolution:
#   - per-CPU scaling_cur_freq summarized as min/avg/max MHz + #cores >90% max
#   - turbo boost on/off (cpufreq/boost)
#   - /proc/sys/kernel/tainted — flips the moment an oops happens, so a
#     pre-panic oops is visible here even if nothing else got persisted
#   - amd_pstate status + policy0 governor (once per segment)
# Usage: bash collector_cpu.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

STREAM="cpu"
PIDFILE="$FD_PID_DIR/freeze-diag-$STREAM.pid"
INTERVAL="${FD_CPU_INTERVAL:-2}"
SEGMENT="${FD_CPU_SEGMENT:-600}"

# Primary guard: flock (survives orphans)
flock_instance_guard "$FD_PID_DIR/freeze-diag-$STREAM.lock"

if is_running "$PIDFILE"; then
    echo "[$(ts_iso)] cpu: already running" >&2
    exit 0
fi
write_pidfile "$PIDFILE"
trap "cleanup_pidfile '$PIDFILE'; trap_exit_handler '$STREAM'" EXIT TERM INT

open_segment "$STREAM" "$SEGMENT"
COUNTER=0

BOOST_PATH=/sys/devices/system/cpu/cpufreq/boost
PSTATE_PATH=/sys/devices/system/cpu/amd_pstate/status
GOV_PATH=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
HW_MAX=$(sysfs_val /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)
HW_MAX=${HW_MAX:-0}
HEADER_WRITTEN=0

write_header() {
    local gov pstate
    gov=$(sysfs_val "$GOV_PATH")
    pstate=$(sysfs_val "$PSTATE_PATH")
    fsync_line "$FD_CURRENT_SEGMENT" \
        "# governor=${gov:-?} amd_pstate=${pstate:-?} cpuinfo_max_khz=$HW_MAX"
}

while true; do
    NOW=$(ts_epoch)

    if should_roll_segment "$SEGMENT"; then
        open_segment "$STREAM" "$SEGMENT"
        HEADER_WRITTEN=0
    fi
    if [ "$HEADER_WRITTEN" -eq 0 ]; then
        write_header
        HEADER_WRITTEN=1
    fi

    # Per-CPU current frequency: min/avg/max + count near hardware max.
    # Pure-bash loop over sysfs, no subprocesses in the hot path.
    FMIN=99999999; FMAX=0; FSUM=0; N=0; NHI=0
    HI_THRESHOLD=$((HW_MAX * 9 / 10))
    for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq; do
        [ -r "$f" ] || continue
        read -r khz 2>/dev/null < "$f" || continue
        [ -n "$khz" ] || continue
        N=$((N + 1)); FSUM=$((FSUM + khz))
        [ "$khz" -lt "$FMIN" ] && FMIN=$khz
        [ "$khz" -gt "$FMAX" ] && FMAX=$khz
        [ "$HI_THRESHOLD" -gt 0 ] && [ "$khz" -ge "$HI_THRESHOLD" ] && NHI=$((NHI + 1))
    done
    if [ "$N" -gt 0 ]; then
        FAVG=$((FSUM / N / 1000)); FMIN=$((FMIN / 1000)); FMAX=$((FMAX / 1000))
    else
        FAVG=0; FMIN=0; FMAX=0
    fi

    BOOST=$(sysfs_val "$BOOST_PATH"); BOOST=${BOOST:-?}
    TAINT=$(sysfs_val /proc/sys/kernel/tainted); TAINT=${TAINT:-?}

    fsync_line "$FD_CURRENT_SEGMENT" \
        "$NOW|fmin=$FMIN|favg=$FAVG|fmax=$FMAX|ncpu=$N|nhi=$NHI|boost=$BOOST|taint=$TAINT"

    COUNTER=$((COUNTER + 1))
    if [ $((COUNTER % 150)) -eq 0 ]; then
        cleanup_old_segments "$STREAM" &
        size_check_and_prune &
    fi

    sleep "$INTERVAL" 2>/dev/null || sleep 2
done

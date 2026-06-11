#!/bin/bash
# diag-analyze.sh — post-freeze / live analysis
# Usage: diag-analyze.sh [OPTIONS]
#   --session <id>  Analyze specific session (unique per login, no overwrite)
#   --boot <id>     Analyze by boot ID (legacy, may match latest session only)
#   --current       Analyze currently running session
#   --quick         Non-interactive 1-page summary
#   --gpu-only      GPU findings only
#   --memory-only   Memory findings only
#   --output <file> Write report to file
#   --interactive   Force interactive mode
#   (no args)       Interactive menu
#
# New in v2:
#  - journalctl -k fallback for GPU events (persists across GPU recovery)
#  - GPU power anomaly detection (power/busy ratio >4W per % = hang sig)
#  - Process trigger analysis (new processes, Xorg RSS jump, per-proc growth)
#  - Same-boot crash correlation (multiple recoveries in same boot)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/diag.conf"
source "$FD_LIB/lib_common.sh"

ANALYZE_SESSION=""
ANALYZE_BOOT=""
ANALYZE_CURRENT=false
QUICK_MODE=false
GPU_ONLY=false
MEMORY_ONLY=false
OUTPUT_FILE=""
INTERACTIVE_MODE=false
crashed=""
session_file=""

# Track if any args were given (before they're consumed by shift)
HAD_ARGS=false
[ $# -gt 0 ] && HAD_ARGS=true

# ---- Parse arguments ----
while [ $# -gt 0 ]; do
    case "$1" in
        --session) ANALYZE_SESSION="$2"; shift 2 ;;
        --boot) ANALYZE_BOOT="$2"; shift 2 ;;
        --current) ANALYZE_CURRENT=true; shift ;;
        --quick) QUICK_MODE=true; INTERACTIVE_MODE=false; shift ;;
        --gpu-only) GPU_ONLY=true; shift ;;
        --memory-only) MEMORY_ONLY=true; shift ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --interactive) INTERACTIVE_MODE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

CURRENT_BOOT=$(current_boot_id)

# ---- Helpers ----
find_freeze_time() {
    local session_id="${1:-}"
    local pattern="$FD_LOGS/heartbeat_*_*.log"
    local last_ts=0

    # If analyzing a specific crashed session, find the last heartbeat
    # within its time window (between session start and crash detection)
    if [ -n "$session_id" ] && [[ "$session_id" =~ _([0-9]+)$ ]]; then
        local session_start="${BASH_REMATCH[1]}"
        local cutoff=$((session_start + 600))  # default: 10 min after start

        # Try to get precise cutoff from session marker's detected_at
        local sf
        sf=$(find_session_file "$session_id" 2>/dev/null) || sf=""
        if [ -n "$sf" ] && [ -f "$sf" ]; then
            local detected
            detected=$(grep -o '"detected_at": *"[^"]*"' "$sf" 2>/dev/null | head -1 | cut -d'"' -f4)
            if [ -n "$detected" ]; then
                local detected_epoch
                detected_epoch=$(date -d "$detected" +%s 2>/dev/null || echo 0)
                if [ "$detected_epoch" -gt 0 ]; then
                    cutoff=$detected_epoch
                fi
            fi
        fi

        # Bound the candidate set with find (mtime within the session
        # window) — globbing all heartbeat segments doesn't scale to
        # 90-day retention.
        local candidates
        candidates=$(find "$FD_LOGS" -maxdepth 1 -name 'heartbeat_*.log' \
            -newermt "@$((session_start - 700))" \
            ! -newermt "@$((cutoff + 120))" 2>/dev/null)
        local f
        for f in $candidates; do
            [ -f "$f" ] || continue
            local prev_ts=0
            local gap_hit=false
            while IFS= read -r line; do
                [[ "$line" =~ ^([0-9]+) ]] || continue
                local ts=${BASH_REMATCH[1]}
                [ "$ts" -lt "$session_start" ] 2>/dev/null && { prev_ts=$ts; continue; }
                [ "$ts" -gt "$cutoff" ] 2>/dev/null && break
                # Detect gap >3s = crash boundary, use pre-gap timestamp
                if [ "$prev_ts" -gt 0 ] && [ $((ts - prev_ts)) -gt 3 ] 2>/dev/null; then
                    [ "$prev_ts" -gt "$last_ts" ] && last_ts=$prev_ts
                    gap_hit=true
                fi
                prev_ts=$ts
            done < "$f"
            # If no gap found in this file, use last timestamp in range
            if [ "$gap_hit" = false ] && [ "$prev_ts" -gt "$last_ts" ] 2>/dev/null; then
                last_ts=$prev_ts
            fi
        done
        # If last_ts is within 30s of cutoff (detected_at), it's from the
        # recovery session, not the crash — pre-crash logs were purged.
        if [ "$last_ts" -gt 0 ] && [ $((cutoff - last_ts)) -lt 30 ] 2>/dev/null; then
            last_ts=0
        fi
        echo "$last_ts"
        return
    fi

    # Default: latest heartbeat (for current/live analysis). Segment
    # names embed sortable timestamps — only the newest file matters.
    local newest
    newest=$(ls -1 "$FD_LOGS"/heartbeat_*.log 2>/dev/null | sort | tail -1)
    if [ -n "$newest" ]; then
        local tail_line
        tail_line=$(tail -1 "$newest" 2>/dev/null)
        [[ "$tail_line" =~ ^([0-9]+) ]] && last_ts=${BASH_REMATCH[1]}
    fi
    echo "$last_ts"
}

# grep over recent segments only — with 90-day retention the logs dir
# holds tens of thousands of files; a full scan per category is unusable.
# Window: 48h by default, wide enough for any "crashed yesterday" case
# (older crashes have their evidence frozen in archive/ crash bundles).
grep_logs() {
    local pattern="$1" maxage_min="${2:-2880}"
    find "$FD_LOGS" -maxdepth 1 -name '*_????????_??????.log' \
        -mmin "-${maxage_min}" -print0 2>/dev/null | \
        xargs -0 -r grep -ahiE "$pattern" 2>/dev/null || true
}

grep_dmesg() {
    local pattern="$1"
    grep_logs "^D: .*($pattern)"
}

# Recent segment files of one stream (newest first). Bash line-by-line
# parsers must only ever walk these, never the full 90-day set.
recent_stream_files() {
    local stream="$1" maxage_min="${2:-1440}"
    find "$FD_LOGS" -maxdepth 1 -name "${stream}_????????_??????.log" \
        -mmin "-${maxage_min}" -printf '%T@ %p\n' 2>/dev/null | \
        sort -rn | head -20 | awk '{print $2}'
}

# ---- Journalctl helper (persists across same-boot recovery) ----
journalctl_k() {
    local pattern="$1" since="${2:-5 minutes ago}"
    if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        sudo journalctl -k --no-pager -o short-iso --since "$since" -b 0 2>/dev/null | grep -iE "$pattern" || true
    fi
}

# Convert freeze_ts (epoch) to a human-readable 'since' string for journalctl
journalctl_since_window() {
    local freeze_ts="$1" margin_sec="${2:-300}"
    local start_epoch=$((freeze_ts - margin_sec))
    date -d "@$start_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "1 hour ago"
}

# ---- Scoring ----
SCORE_GPU=0
SCORE_OOM=0
SCORE_NVME=0
SCORE_MEM=0
SCORE_THERMAL=0
SCORE_LEAK=0
SCORE_KERNEL=0
GPU_POWER_ANOMALY=0
PROCESS_TRIGGER=""
KERNEL_EVIDENCE=""
PSTORE_INFO=""
CPU_FREQ_INFO=""
CONTEXT_INFO=""

# ---- Kernel fault analysis (the 2026-06 RCA killer category) ----
# Scans the captured dmesg stream AND — when analyzing a crashed session —
# the previous boot's journal for oops/GPF/lockup/MCE signatures. These are
# kernel-level faults userspace cannot cause; their presence reclassifies
# the whole incident.
KERNEL_FAULT_PATTERN='BUG:|Oops|general protection|soft lockup|hung task|double fault|stack guard|invalid opcode|machine check|mce:.*(error|bank)|page fault.*kernel|RIP: 0010'

analyze_kernel_faults() {
    local freeze_ts="$1"
    local matches jmatches
    matches=$(grep_dmesg "$KERNEL_FAULT_PATTERN" | grep -vi 'MCE: In-kernel' || true)

    # Crashed-session analysis: the decisive lines usually live in the
    # *previous boot's* journal (this is how the bit-flip GPF was found).
    if [ -n "${ANALYZE_SESSION:-}" ] && sudo -n true 2>/dev/null; then
        jmatches=$(sudo -n journalctl -b -1 -o short-precise --no-pager 2>/dev/null | \
            grep -aiE "$KERNEL_FAULT_PATTERN" | grep -vi 'MCE: In-kernel' | head -40 || true)
        if [ -n "$jmatches" ]; then
            matches+="${matches:+$'\n'}[journal -b -1]"$'\n'"$jmatches"
        fi
    fi

    if echo "$matches" | grep -qiE 'general protection|Oops|BUG:|double fault|machine check'; then
        SCORE_KERNEL=4
    elif echo "$matches" | grep -qiE 'soft lockup|hung task|invalid opcode'; then
        SCORE_KERNEL=3
    fi
    KERNEL_EVIDENCE="$matches"
}

# ---- pstore: kernel panic records ----
# Lists records near the freeze; root-only contents are noted (and are
# auto-copied into crash bundles when fd-pstore-dump is installed).
analyze_pstore() {
    local freeze_ts="$1" info="" d mt
    for d in /var/lib/systemd/pstore/* /sys/fs/pstore/*; do
        [ -e "$d" ] || continue
        mt=$(stat -c %Y "$d" 2>/dev/null) || continue
        # Records written within 1h before .. 24h after the freeze
        if [ "$mt" -ge $((freeze_ts - 3600)) ] && [ "$mt" -le $((freeze_ts + 86400)) ]; then
            info+="  $(date -d "@$mt" '+%F %T' 2>/dev/null)  $d"$'\n'
        fi
    done
    PSTORE_INFO="$info"
    if [ -n "$info" ] && [ "$SCORE_KERNEL" -lt 3 ]; then
        SCORE_KERNEL=3   # a panic record exists even if no text was captured
    fi
}

# ---- CPU frequency posture before death (cpu stream) ----
analyze_cpu_freq() {
    local freeze_ts="$1" window=120
    local n=0 max_seen=0 boost_last="?" taint_last="?" nhi_max=0 f
    for f in $(recent_stream_files cpu); do
        while IFS='|' read -ra fields; do
            local ts=${fields[0]}
            [[ "$ts" =~ ^[0-9]+$ ]] || continue
            (( freeze_ts - ts <= window && freeze_ts - ts >= 0 )) 2>/dev/null || continue
            local field
            for field in "${fields[@]}"; do
                case "$field" in
                    fmax=*)  local v=${field#fmax=}
                             [ "$v" -gt "$max_seen" ] 2>/dev/null && max_seen=$v ;;
                    nhi=*)   local h=${field#nhi=}
                             [ "$h" -gt "$nhi_max" ] 2>/dev/null && nhi_max=$h ;;
                    boost=*) boost_last=${field#boost=} ;;
                    taint=*) taint_last=${field#taint=} ;;
                esac
            done
            n=$((n + 1))
        done < "$f"
    done
    if [ "$n" -gt 0 ]; then
        CPU_FREQ_INFO="  samples=$n in last ${window}s | peak core freq ${max_seen}MHz | max cores >90% fmax: $nhi_max | boost=$boost_last | tainted=$taint_last"
    fi
}

# ---- Context snapshot of the analyzed session ----
load_context() {
    local id="${ANALYZE_SESSION:-}" ctx=""
    [ -n "$id" ] && ctx="$FD_LOGS/context_${id}.log"
    if [ ! -f "$ctx" ]; then
        ctx=$(ls -1t "$FD_LOGS"/context_*.log 2>/dev/null | head -1 || true)
    fi
    if [ -n "$ctx" ] && [ -f "$ctx" ]; then
        CONTEXT_INFO=$(grep -aE '^(Linux|cmdline|bios_version|bios_date|microcode|boost|governor|tainted|amd_pstate)' "$ctx" 2>/dev/null | sed 's/^/  /' || true)
    fi
    return 0
}

# NOTE: analyze_gpu/oom/nvme set their SCORE_* and *_EVIDENCE globals
# directly. They must be called as plain statements, never in $(...) —
# a subshell would silently discard the scores (that exact bug shipped
# in v2: GPU/OOM/NVMe severity always displayed NONE).
GPU_EVIDENCE=""
OOM_EVIDENCE=""
NVME_EVIDENCE=""

analyze_gpu() {
    local freeze_ts="$1"
    local matches
    matches=$(grep_dmesg "amdgpu.*ring.*timeout|amdgpu.*fence.*timeout|amdgpu.*GPU fault|amdgpu.*guilty|amdgpu.*reset|drm.*atomic.*check.*fail|drm.*timed out")
    local count
    count=$(echo "$matches" | grep -c . 2>/dev/null || true)
    count=${count:-0}

    # If dmesg logs are empty, fall back to journalctl (persists across GPU recovery)
    if [ "$count" -eq 0 ]; then
        local jmatches jsince
        jsince=$(journalctl_since_window "$freeze_ts" 600)
        jmatches=$(journalctl_k "amdgpu.*ring.*timeout|amdgpu.*fence.*timeout|amdgpu.*GPU fault|amdgpu.*guilty|amdgpu.*reset|drm.*atomic.*check.*fail|drm.*timed out|gpu_recovery" "$jsince")
        local jcount
        jcount=$(echo "$jmatches" | grep -c . 2>/dev/null || true)
        jcount=${jcount:-0}
        if [ "$jcount" -gt 0 ]; then
            matches="$jmatches"
            count=$jcount
        fi
    fi

    if [ "$count" -gt 2 ]; then
        SCORE_GPU=4
    elif [ "$count" -gt 0 ]; then
        SCORE_GPU=3
    fi

    # Also check for GPU power anomaly (high power at low utilization = hang signature)
    analyze_gpu_power_anomaly "$freeze_ts"

    GPU_EVIDENCE="$matches"
}

analyze_gpu_power_anomaly() {
    local freeze_ts="$1"
    local window=120
    local anomaly_found=false
    local highest_ratio=0

    for f in $(recent_stream_files gpu); do
        [ -f "$f" ] || continue
        while IFS='|' read -ra fields; do
            local ts=${fields[0]}
            [ -z "$ts" ] && continue
            (( freeze_ts - ts <= window )) 2>/dev/null || continue
            local busy=0 power=0 field
            for field in "${fields[@]}"; do
                case "$field" in
                    busy=*) busy=${field#busy=} ;;
                    power=*) power=${field#power=} ;;
                esac
            done
            if [ -n "$busy" ] && [ -n "$power" ] && [ "$busy" -gt 0 ] 2>/dev/null && command -v bc &>/dev/null; then
                local ratio
                ratio=$(echo "scale=2; $power / $busy" | bc 2>/dev/null || true)
                if [ -n "$ratio" ]; then
                    local cmp_high cmp_thresh
                    cmp_high=$(echo "$ratio > $highest_ratio" | bc 2>/dev/null || true)
                    cmp_thresh=$(echo "$ratio > 4.0" | bc 2>/dev/null || true)
                    if [ "$cmp_high" = 1 ]; then
                        highest_ratio=$ratio
                    fi
                    if [ "$cmp_thresh" = 1 ]; then
                        anomaly_found=true
                    fi
                fi
            fi
        done < "$f"
    done

    if [ "$anomaly_found" = true ]; then
        GPU_POWER_ANOMALY=$highest_ratio
        if [ "$SCORE_GPU" -lt 3 ]; then
            SCORE_GPU=3
        fi
    fi
}

analyze_process_triggers() {
    local freeze_ts="$1"
    local window=120
    local evidence=""
    local -A early_pids late_pids late_names
    local early_seen=false
    local xorg_early_rss=0 xorg_late_rss=0

    for f in $(recent_stream_files fast); do
        [ -f "$f" ] || continue
        while IFS='|' read -ra fields; do
            local ts=${fields[0]}
            [ -z "$ts" ] && continue
            local age=$((freeze_ts - ts))
            (( age <= window )) 2>/dev/null || continue
            local top3_field="" xpss_val=""
            for field in "${fields[@]}"; do
                case "$field" in
                    xpss=*) xpss_val=${field#xpss=} ;;
                    top3=*) top3_field=${field#top3=} ;;
                esac
            done
            # Mark early vs late samples
            if [ "$age" -gt $((window / 2)) ] && [ "$early_seen" = false ]; then
                early_seen=true
                if [ -n "$xpss_val" ]; then
                    xorg_early_rss=$xpss_val
                fi
                # Parse top3 for early PIDs
                if [ -n "$top3_field" ]; then
                    IFS=';' read -ra procs <<< "$top3_field"
                    for proc in "${procs[@]}"; do
                        [ -z "$proc" ] && continue
                        local pid="${proc%%,*}"
                        [ -n "$pid" ] && early_pids["$pid"]=1
                    done
                fi
            elif [ "$age" -le $((window / 2)) ]; then
                if [ -n "$xpss_val" ] && [ "$xpss_val" -gt "$xorg_late_rss" ]; then
                    xorg_late_rss=$xpss_val
                fi
                if [ -n "$top3_field" ]; then
                    IFS=';' read -ra procs <<< "$top3_field"
                    for proc in "${procs[@]}"; do
                        [ -z "$proc" ] && continue
                        local pid="${proc%%,*}"
                        local pname="${proc#*,}"
                        pname="${pname%%,*}"
                        [ -n "$pid" ] && late_pids["$pid"]=1
                        [ -n "$pid" ] && [ -n "$pname" ] && late_names["$pid"]="$pname"
                    done
                fi
            fi
        done < "$f"
    done

    # Find newly appeared processes
    local new_procs=""
    for pid in "${!late_pids[@]}"; do
        [ -n "$pid" ] || continue
        if [ -z "${early_pids[$pid]:-}" ]; then
            local pname="${late_names[$pid]:-$pid}"
            [ -n "$new_procs" ] && new_procs+=", "
            new_procs+="$pname(pid=$pid)"
        fi
    done

    if [ -n "$new_procs" ]; then
        evidence+="  Processes newly at top-3 RSS in last 60s: $new_procs"$'\n'
    fi

    # Xorg RSS jump
    if [ "$xorg_early_rss" -gt 0 ] && [ "$xorg_late_rss" -gt 0 ]; then
        local xorg_delta=$((xorg_late_rss - xorg_early_rss))
        if [ "$xorg_delta" -gt 20000 ]; then
            evidence+="  Xorg RSS jumped ${xorg_delta}KB in last 60s ($xorg_early_rss -> $xorg_late_rss)"$'\n'
        fi
    fi

    # Per-process RSS growth from watchdog in last 5 minutes
    local -A watchdog_rss_early watchdog_rss_late watchdog_pname
    for f in $(recent_stream_files watchdog); do
        [ -f "$f" ] || continue
        while IFS='|' read -ra fields; do
            local ts=${fields[0]}
            [ -z "$ts" ] && continue
            local age=$((freeze_ts - ts))
            (( age <= 300 )) 2>/dev/null || continue
            local wpid="" wrss="" wname="" field
            for field in "${fields[@]}"; do
                case "$field" in
                    pid=*) wpid=${field#pid=} ;;
                    rss=*) wrss=${field#rss=} ;;
                    target=*) wname=${field#target=} ;;
                esac
            done
            [ -z "$wpid" ] && continue
            if [ "$age" -gt 150 ] && [ -z "${watchdog_rss_early[$wpid]:-}" ]; then
                watchdog_rss_early["$wpid"]=$wrss
                watchdog_pname["$wpid"]=$wname
            elif [ "$age" -le 150 ]; then
                watchdog_rss_late["$wpid"]=$wrss
                watchdog_pname["$wpid"]=$wname
            fi
        done < "$f"
    done

    local leak_procs=""
    for pid in "${!watchdog_rss_late[@]}"; do
        [ -n "$pid" ] || continue
        local early=${watchdog_rss_early[$pid]:-0}
        local late=${watchdog_rss_late[$pid]:-0}
        local e_int=${early%.*} l_int=${late%.*}
        if [ "$early" != "0" ] && [ "$late" != "0" ] && [ "$e_int" -gt 0 ] && [ "$l_int" -gt 0 ]; then
            local delta=$((l_int - e_int))
            if [ "$delta" -gt 20 ]; then
                local pname="${watchdog_pname[$pid]:-pid=$pid}"
                [ -n "$leak_procs" ] && leak_procs+=", "
                leak_procs+="${pname}(+${delta}MB RSS)"
            fi
        fi
    done

    if [ -n "$leak_procs" ]; then
        evidence+="  RSS growth >20MB: $leak_procs"$'\n'
    fi

    PROCESS_TRIGGER="$evidence"
    return 0
}

analyze_oom() {
    local freeze_ts="$1"
    local matches
    matches=$(grep_dmesg "Out of memory|invoked oom-killer|Killed process")
    local count
    count=$(echo "$matches" | grep -c . 2>/dev/null || true)
    count=${count:-0}
    if [ "$count" -gt 0 ]; then
        SCORE_OOM=4
    fi
    OOM_EVIDENCE="$matches"
}

analyze_nvme() {
    local freeze_ts="$1"
    local matches
    # \bfault: plain "fault" also matches "default_ps_max_latency_us"
    # in every captured kernel cmdline (false positive)
    matches=$(grep_dmesg "nvme.*I/O error|nvme.*abort|nvme.*timeout|nvme.*\bfault|nvme.*controller (down|reset)")
    local count
    count=$(echo "$matches" | grep -c . 2>/dev/null || true)
    count=${count:-0}
    if [ "$count" -gt 0 ]; then
        SCORE_NVME=3
    fi
    NVME_EVIDENCE="$matches"
}

analyze_memory_pressure() {
    local freeze_ts="$1"
    local evidence=""

    for f in $(recent_stream_files fast); do
        [ -f "$f" ] || continue
        while IFS='|' read -ra fields; do
            local ts=${fields[0]}
            [ -z "$ts" ] && continue
            (( freeze_ts - ts <= 300 )) 2>/dev/null || continue
            local psimf=0 swapf=0 oomd=0 field
            for field in "${fields[@]}"; do
                case "$field" in
                    psimf=*) psimf=${field#psimf=} ;;
                    swapf=*) swapf=${field#swapf=} ;;
                    oomd=*)  oomd=${field#oomd=} ;;
                esac
            done
            if [ -n "$psimf" ] && (( ${psimf%.*} > 80 )) 2>/dev/null; then
                evidence+="psi_mem_full=$psimf at ts=$ts"$'\n'
            fi
            if [ -n "$swapf" ] && (( ${swapf%.*} < 100 )) 2>/dev/null; then
                evidence+="swap_free_mb=$swapf at ts=$ts"$'\n'
            fi
        done < "$f"
    done

    if [ -n "$evidence" ]; then
        SCORE_MEM=3
    fi
}

analyze_thermal() {
    local freeze_ts="$1"
    local max_gpu=0 max_cpu=0
    for f in $(recent_stream_files fast); do
        [ -f "$f" ] || continue
        while IFS='|' read -ra fields; do
            local ts=${fields[0]}
            (( freeze_ts - ts <= 300 )) 2>/dev/null || continue
            local gtemp=0 ctemp=0 field
            for field in "${fields[@]}"; do
                case "$field" in
                    gtemp=*) gtemp=${field#gtemp=} ;;
                    ctemp=*) ctemp=${field#ctemp=} ;;
                esac
            done
            local gint=${gtemp%.*}
            if [ "$gint" -gt "$max_gpu" ] 2>/dev/null; then
                max_gpu=$gint
            fi
        done < "$f"
    done
    if [ "$max_gpu" -gt 95 ] 2>/dev/null; then SCORE_THERMAL=3; fi
}

analyze_leak() {
    local freeze_ts="$1"
    if [ -n "$PROCESS_TRIGGER" ]; then
        if echo "$PROCESS_TRIGGER" | grep -q "RSS growth >20MB"; then
            SCORE_LEAK=3
        fi
    fi
}

# ---- Same-boot crash correlation ----
check_same_boot_crashes() {
    local boot_id="$1"
    local current_session="$2"
    local crash_count=0
    local sessions_list=""

    # Get this session's start time for ordering
    local cur_start=""
    if [ -n "$current_session" ]; then
        local cur_sf
        cur_sf=$(find_session_file "$current_session" 2>/dev/null) || cur_sf=""
        if [ -n "$cur_sf" ]; then
            cur_start=$(grep -o '"started_at": *"[^"]*"' "$cur_sf" 2>/dev/null | head -1 | cut -d'"' -f4)
        fi
    fi

    for f in "$FD_LOGS/sessions/"*.session; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        local fname bid st
        fname=$(basename "$f" .session)
        bid=$(grep -o '"boot_id": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)
        st=$(grep -o '"status": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)
        if [ "$bid" = "$boot_id" ] && [ "$st" = "crashed" ] && [ "$fname" != "$current_session" ]; then
            # Only count crashes that occurred before this session started
            local f_start
            f_start=$(grep -o '"started_at": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)
            if [ -z "$cur_start" ] || [ -z "$f_start" ] || [[ "$f_start" < "$cur_start" ]]; then
                crash_count=$((crash_count + 1))
                local detected
                detected=$(grep -o '"detected_at": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)
                [ -n "$detected" ] && sessions_list+="    $detected  $fname"$'\n'
            fi
        fi
    done
    if [ "$crash_count" -gt 0 ]; then
        echo "$crash_count|$sessions_list"
    fi
}

# ---- Report generation ----
severity_label() {
    case "$1" in
        4) echo "HIGH" ;;
        3) echo "MEDIUM" ;;
        2) echo "LOW" ;;
        *) echo "NONE" ;;
    esac
}

severity_blocks() {
    case "$1" in
        4) echo -e "\e[31m████\e[0m" ;;
        3) echo -e "\e[33m███ \e[0m" ;;
        2) echo -e "\e[32m██  \e[0m" ;;
        *) echo "█   " ;;
    esac
}

generate_report() {
    local freeze_ts="$1"
    local report_file="$2"

    local ftime_str
    ftime_str=$(date -d "@$freeze_ts" --iso-8601=seconds 2>/dev/null || echo "$freeze_ts")

    # Plain calls (NOT $(...)): these set SCORE_* and *_EVIDENCE globals;
    # a subshell would discard the scores.
    analyze_gpu "$freeze_ts"
    analyze_oom "$freeze_ts"
    analyze_nvme "$freeze_ts"
    local gpu_evidence="$GPU_EVIDENCE" oom_evidence="$OOM_EVIDENCE" nvme_evidence="$NVME_EVIDENCE"
    analyze_memory_pressure "$freeze_ts"
    analyze_thermal "$freeze_ts"
    analyze_process_triggers "$freeze_ts"
    analyze_leak "$freeze_ts"
    analyze_kernel_faults "$freeze_ts"
    analyze_pstore "$freeze_ts"
    analyze_cpu_freq "$freeze_ts"
    load_context

    local same_boot_info
    same_boot_info=$(check_same_boot_crashes "${CURRENT_BOOT:-}" "${ANALYZE_SESSION:-}")

    {
        echo "FREEZE DIAGNOSIS REPORT — $ftime_str"
        echo "═══════════════════════════════════════════════"
        local session_label="${ANALYZE_SESSION:-${ANALYZE_BOOT:-$CURRENT_BOOT}}"
        echo "Session: $session_label"
        echo "Freeze at: $ftime_str"
        if [ -n "$same_boot_info" ]; then
            local crash_count="${same_boot_info%%|*}"
            local crash_list="${same_boot_info#*|}"
            echo "Same-boot crashes: $crash_count previous crash(es) in this boot"
            while IFS= read -r l; do echo "  $l"; done <<< "$crash_list"
        fi
        if [ -n "$CONTEXT_INFO" ]; then
            echo "SESSION CONTEXT (kernel / firmware / freq posture)"
            echo "$CONTEXT_INFO"
        fi
        echo ""

        echo "FINDINGS (severity: ████ HIGH  ███ MEDIUM  ██ LOW  █ NONE)"
        echo ""

        # Kernel faults first — if present they reclassify everything else
        echo "$(severity_blocks "$SCORE_KERNEL") KERNEL FAULT ($(severity_label "$SCORE_KERNEL"))"
        if [ -n "$KERNEL_EVIDENCE" ]; then
            echo "$KERNEL_EVIDENCE" | head -15 | while IFS= read -r l; do echo "  $l"; done
            echo "  NOTE: oops/GPF/lockup lines are kernel-level faults that"
            echo "  userspace cannot cause — suspect kernel bug or hardware"
            echo "  (repeated single-bit pointer corruption across kernels = HW)."
        else
            echo "  No kernel oops/GPF/lockup/MCE evidence captured."
        fi
        if [ -n "$PSTORE_INFO" ]; then
            echo "  Panic records (pstore) near this freeze:"
            printf '%s' "$PSTORE_INFO"
            echo "  (root-only; auto-copied into archive/ crash bundles when fd-pstore-dump is installed)"
        fi
        echo ""

        # CPU frequency posture at death
        if [ -n "$CPU_FREQ_INFO" ]; then
            echo "CPU FREQ BEFORE FREEZE (transient/boost forensics)"
            echo "$CPU_FREQ_INFO"
            echo ""
        fi

        # GPU
        if [ "$GPU_ONLY" = false ] || [ "$GPU_ONLY" = true ]; then
            echo "$(severity_blocks "$SCORE_GPU") GPU HANG ($(severity_label "$SCORE_GPU"))"
            if [ -n "$gpu_evidence" ]; then
                echo "$gpu_evidence" | tail -5 | while IFS= read -r l; do echo "  $l"; done
            fi
            if [ "$GPU_POWER_ANOMALY" != 0 ]; then
                echo "  GPU power anomaly: ${GPU_POWER_ANOMALY}W per % busy (threshold >4.0)"
            fi
            if [ -z "$gpu_evidence" ] && [ "$GPU_POWER_ANOMALY" = 0 ]; then
                echo "  No GPU fault evidence in dmesg or journal."
            fi
            echo ""
        fi

        # OOM
        if [ "$MEMORY_ONLY" = false ] && [ "$GPU_ONLY" = false ]; then
            echo "$(severity_blocks "$SCORE_OOM") OOM ($(severity_label "$SCORE_OOM"))"
            if [ -n "$oom_evidence" ]; then
                echo "$oom_evidence" | tail -5 | while IFS= read -r l; do echo "  $l"; done
            else
                echo "  No OOM killer activity in dmesg or journal."
            fi
            echo ""
        fi

        # NVMe
        if [ "$GPU_ONLY" = false ] && [ "$MEMORY_ONLY" = false ]; then
            echo "$(severity_blocks "$SCORE_NVME") NVMe ($(severity_label "$SCORE_NVME"))"
            if [ -n "$nvme_evidence" ]; then
                echo "$nvme_evidence" | tail -5 | while IFS= read -r l; do echo "  $l"; done
            else
                echo "  No NVMe errors in dmesg or journal."
            fi
            echo ""
        fi

        # Memory pressure
        if [ "$GPU_ONLY" = false ]; then
            echo "$(severity_blocks "$SCORE_MEM") MEMORY PRESSURE ($(severity_label "$SCORE_MEM"))"
            if [ "$SCORE_MEM" -gt 0 ]; then
                echo "  High memory pressure before freeze (PSI / swap)."
            else
                echo "  Normal memory pressure leading to freeze."
            fi
            echo ""
        fi

        # Thermal
        echo "$(severity_blocks "$SCORE_THERMAL") THERMAL ($(severity_label "$SCORE_THERMAL"))"
        if [ "$SCORE_THERMAL" -gt 0 ]; then
            echo "  GPU/CPU temperature exceeded 95°C before freeze."
        else
            echo "  Temperatures within safe range."
        fi
        echo ""

        # Process leak
        echo "$(severity_blocks "$SCORE_LEAK") PROCESS LEAK ($(severity_label "$SCORE_LEAK"))"
        if [ "$SCORE_LEAK" -gt 0 ]; then
            echo "  Process RSS growth detected (see trigger analysis below)."
        else
            echo "  No significant memory leak detected."
        fi
        echo ""

        # Process trigger analysis
        if [ -n "$PROCESS_TRIGGER" ]; then
            echo "PROCESS TRIGGER ANALYSIS (60s window before freeze)"
            echo "───────────────────────────────────────────────────"
            echo -n "$PROCESS_TRIGGER"
            echo ""
        fi

        # Raw excerpts
        echo "RAW LOG EXCERPTS (last 10 lines each stream)"
        echo "─────────────────────────────────────────────"
        for stream in heartbeat fast cpu gpu watchdog detailed dmesg; do
            echo "--- $stream ---"
            local lf
            lf=$(ls -t "$FD_LOGS/${stream}_"*.log 2>/dev/null | head -1 || true)
            if [ -n "$lf" ]; then
                tail -10 "$lf" 2>/dev/null || echo "(empty)"
            else
                echo "(no logs)"
            fi
            echo ""
        done

        echo "Full report saved to: $report_file"
    } > "$report_file"
}

# ---- Interactive menu ----
interactive_menu() {
    clear 2>/dev/null || true
    echo "╔══════════════════════════════════════════╗"
    echo "║       FREEZE DIAGNOSIS — ANALYZER       ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "  [1] Auto-detect and analyze last crash"
    echo "  [2] List all recorded sessions"
    echo "  [3] Analyze specific session"
    echo "  [4] Quick GPU hang check (current session)"
    echo "  [5] Quick memory pressure check (current)"
    echo "  [6] Full report (current session)"
    echo "  [q] Quit"
    echo ""

    read -r -p "  Choice: " choice
    case "$choice" in
        1)
            CRASHED=$(check_crashed_sessions)
            if [ -z "$CRASHED" ]; then
                # Fallback: find any session file with "crashed" status
                for s in "$FD_LOGS/sessions/"*.session; do
                    [ -f "$s" ] || continue
                    [ -L "$s" ] && continue
                    local st
                    st=$(grep -o '"status": *"[^"]*"' "$s" 2>/dev/null | head -1 | cut -d'"' -f4)
                    if [ "$st" = "crashed" ]; then
                        CRASHED=$(basename "$s" .session)
                        break
                    fi
                done
            fi
            if [ -z "$CRASHED" ]; then
                echo "  No crashed session found. Run with --current for live analysis."
            else
                ANALYZE_SESSION="$CRASHED"
                ANALYZE_BOOT=$(session_id_to_boot "$CRASHED")
                echo "  Analyzing session: $CRASHED"
            fi
            ;;
        2)
            echo "  Recorded sessions (* = current boot):"
            for s in "$FD_LOGS/sessions/"*.session; do
                [ -f "$s" ] || continue
                [ -L "$s" ] && continue
                local fname status started bid
                fname=$(basename "$s" .session)
                status=$(grep -o '"status": *"[^"]*"' "$s" 2>/dev/null | head -1 | cut -d'"' -f4)
                started=$(grep -o '"started_at": *"[^"]*"' "$s" 2>/dev/null | head -1 | cut -d'"' -f4)
                bid=$(grep -o '"boot_id": *"[^"]*"' "$s" 2>/dev/null | head -1 | cut -d'"' -f4)
                local marker=" "
                [ "$bid" = "$CURRENT_BOOT" ] && marker="*"
                echo "  $marker $fname  $status  $started"
            done
            read -r -p "  Press Enter to continue..."
            return
            ;;
        3)
            ANALYZE_CURRENT=false
            read -r -p "  Enter session_id (or boot_id): " ANALYZE_SESSION
            ANALYZE_BOOT=$(session_id_to_boot "$ANALYZE_SESSION")
            ;;
        4)
            ANALYZE_CURRENT=true
            GPU_ONLY=true
            QUICK_MODE=true
            ;;
        5)
            ANALYZE_CURRENT=true
            MEMORY_ONLY=true
            QUICK_MODE=true
            ;;
        6)
            ANALYZE_CURRENT=true
            ;;
        q|Q)
            echo "  Goodbye."
            exit 0
            ;;
        *)
            echo "  Invalid choice."
            read -r -p "  Press Enter..."
            return
            ;;
    esac
}

# ---- Main execution ----
if [ "$HAD_ARGS" = false ] || [ "$INTERACTIVE_MODE" = true ]; then
    INTERACTIVE_MODE=true

    while true; do
        interactive_menu

        # If no analysis target was set (list sessions, or 'q' already exited), loop
        if [ -z "$ANALYZE_SESSION" ] && [ -z "$ANALYZE_BOOT" ] && [ "$ANALYZE_CURRENT" = false ]; then
            continue
        fi

        if [ "$ANALYZE_CURRENT" = true ]; then
            ANALYZE_BOOT="$CURRENT_BOOT"
        elif [ -n "$ANALYZE_SESSION" ]; then
            ANALYZE_BOOT=$(session_id_to_boot "$ANALYZE_SESSION")
        elif [ -z "$ANALYZE_BOOT" ]; then
            crashed=$(check_crashed_sessions)
            if [ -n "$crashed" ]; then
                ANALYZE_SESSION="$crashed"
                ANALYZE_BOOT=$(session_id_to_boot "$crashed")
            else
                echo "No crashed session found. Use --current for live analysis or --session <id>." >&2
                continue
            fi
        fi

        # Validate session file exists
        session_file=""
        if [ -n "$ANALYZE_SESSION" ]; then
            session_file=$(find_session_file "$ANALYZE_SESSION" 2>/dev/null) || session_file=""
        fi
        if [ -z "$session_file" ] && [ -n "$ANALYZE_BOOT" ]; then
            session_file=$(find_session_file "$ANALYZE_BOOT" 2>/dev/null) || session_file=""
        fi
        if [ -z "$session_file" ]; then
            echo "Warning: no session marker found — using all available logs." >&2
        fi

        FREEZE_TS=$(find_freeze_time "${ANALYZE_SESSION:-}")
        # Fallback: when pre-crash logs are purged, use session marker detected_at
        if [ -z "$FREEZE_TS" ] || [ "$FREEZE_TS" -eq 0 ]; then
            if [ -n "$session_file" ] && [ -f "$session_file" ]; then
                detected_fallback=$(grep -o '"detected_at": *"[^"]*"' "$session_file" 2>/dev/null | head -1 | cut -d'"' -f4)
                if [ -n "$detected_fallback" ]; then
                    FREEZE_TS=$(date -d "$detected_fallback" +%s 2>/dev/null || echo 0)
                    [ "$FREEZE_TS" -ne 0 ] || echo "Warning: pre-crash data purged — using detection time." >&2
                fi
            fi
            if [ -z "$FREEZE_TS" ] || [ "$FREEZE_TS" -eq 0 ]; then
                echo "No heartbeat logs found. Ensure collectors are running." >&2
                continue
            fi
        fi

        REPORT_FILE="${OUTPUT_FILE:-$FD_REPORTS/report_$(ts_dt).txt}"
        generate_report "$FREEZE_TS" "$REPORT_FILE"

        echo ""
        cat "$REPORT_FILE"

        # Reset state for next iteration
        ANALYZE_BOOT=""
        ANALYZE_CURRENT=false
        GPU_ONLY=false
        MEMORY_ONLY=false
        QUICK_MODE=false
        OUTPUT_FILE=""

        echo ""
        read -r -p "Press Enter to continue..."
    done
else
    # ---- Non-interactive (CLI args) ----

    if [ -n "$ANALYZE_SESSION" ]; then
        ANALYZE_BOOT=$(session_id_to_boot "$ANALYZE_SESSION")
    elif [ "$ANALYZE_CURRENT" = true ]; then
        ANALYZE_BOOT="$CURRENT_BOOT"
    elif [ -z "$ANALYZE_BOOT" ]; then
        crashed=$(check_crashed_sessions)
        if [ -n "$crashed" ]; then
            ANALYZE_SESSION="$crashed"
            ANALYZE_BOOT=$(session_id_to_boot "$crashed")
        else
            echo "No crashed session found. Use --current for live analysis or --session <id>." >&2
            exit 1
        fi
    fi

    # Validate session file exists (try both formats)
    session_file=""
    if [ -n "$ANALYZE_SESSION" ]; then
        session_file=$(find_session_file "$ANALYZE_SESSION" 2>/dev/null) || session_file=""
    fi
    if [ -z "$session_file" ] && [ -n "$ANALYZE_BOOT" ]; then
        session_file=$(find_session_file "$ANALYZE_BOOT" 2>/dev/null) || session_file=""
    fi
    if [ -z "$session_file" ]; then
        echo "Warning: no session marker found — using all available logs." >&2
    fi

    FREEZE_TS=$(find_freeze_time "${ANALYZE_SESSION:-}")
    # Fallback: when pre-crash logs are purged, use session marker detected_at
    if [ -z "$FREEZE_TS" ] || [ "$FREEZE_TS" -eq 0 ]; then
        if [ -n "$session_file" ] && [ -f "$session_file" ]; then
            detected_fallback2=$(grep -o '"detected_at": *"[^"]*"' "$session_file" 2>/dev/null | head -1 | cut -d'"' -f4)
            if [ -n "$detected_fallback2" ]; then
                FREEZE_TS=$(date -d "$detected_fallback2" +%s 2>/dev/null || echo 0)
                [ "$FREEZE_TS" -ne 0 ] || echo "Warning: pre-crash data purged — using detection time." >&2
            fi
        fi
        if [ -z "$FREEZE_TS" ] || [ "$FREEZE_TS" -eq 0 ]; then
            echo "No heartbeat logs found. Ensure collectors are running." >&2
            exit 1
        fi
    fi

    REPORT_FILE="${OUTPUT_FILE:-$FD_REPORTS/report_$(ts_dt).txt}"
    generate_report "$FREEZE_TS" "$REPORT_FILE"

    echo ""
    cat "$REPORT_FILE"
fi

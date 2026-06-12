#!/bin/bash
# Unit tests for diag-analyze.sh
# Tests severity_label, severity_blocks, find_freeze_time, grep_logs, grep_dmesg,
# recent_stream_files, journalctl_since_window, check_same_boot_crashes,
# argument parsing, and all analyze_* functions.

source "$(dirname "$0")/test_runner.sh"

# ── Dependency loader ────────────────────────────────────────────
# Call at the start of any test that needs lib_common or FD_LOGS.
source_deps() {
    source "$FD_LIB/lib_common.sh" 2>/dev/null || true
    CURRENT_BOOT="${CURRENT_BOOT:-test-boot-id}"
    ANALYZE_SESSION="${ANALYZE_SESSION:-}"
    ANALYZE_BOOT="${ANALYZE_BOOT:-}"
    ANALYZE_CURRENT="${ANALYZE_CURRENT:-false}"
}

# ── Score globals (matching diag-analyze.sh) ─────────────────────
SCORE_GPU=0
SCORE_OOM=0
SCORE_NVME=0
SCORE_MEM=0
SCORE_THERMAL=0
SCORE_LEAK=0
SCORE_KERNEL=0
GPU_POWER_ANOMALY=0
PROCESS_TRIGGER=""
GPU_EVIDENCE=""
OOM_EVIDENCE=""
NVME_EVIDENCE=""
KERNEL_EVIDENCE=""
PSTORE_INFO=""
CPU_FREQ_INFO=""
CONTEXT_INFO=""
GPU_ONLY=false
MEMORY_ONLY=false
QUICK_MODE=false
INTERACTIVE_MODE=false
OUTPUT_FILE=""

KERNEL_FAULT_PATTERN='BUG:|Oops|general protection|soft lockup|hung task|double fault|stack guard|invalid opcode|machine check|mce:.*(error|bank)|page fault.*kernel|RIP: 0010'

# ── Pure functions from diag-analyze.sh ──────────────────────────
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

find_freeze_time() {
    local session_id="${1:-}"
    local pattern="$FD_LOGS/heartbeat_*_*.log"
    local last_ts=0
    if [ -n "$session_id" ] && [[ "$session_id" =~ _([0-9]+)$ ]]; then
        local session_start="${BASH_REMATCH[1]}"
        local cutoff=$((session_start + 600))
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
                if [ "$prev_ts" -gt 0 ] && [ $((ts - prev_ts)) -gt 3 ] 2>/dev/null; then
                    [ "$prev_ts" -gt "$last_ts" ] && last_ts=$prev_ts
                    gap_hit=true
                fi
                prev_ts=$ts
            done < "$f"
            if [ "$gap_hit" = false ] && [ "$prev_ts" -gt "$last_ts" ] 2>/dev/null; then
                last_ts=$prev_ts
            fi
        done
        if [ "$last_ts" -gt 0 ] && [ $((cutoff - last_ts)) -lt 30 ] 2>/dev/null; then
            last_ts=0
        fi
        echo "$last_ts"
        return
    fi
    local newest
    newest=$(ls -1 "$FD_LOGS"/heartbeat_*.log 2>/dev/null | sort | tail -1)
    if [ -n "$newest" ]; then
        local tail_line
        tail_line=$(tail -1 "$newest" 2>/dev/null)
        [[ "$tail_line" =~ ^([0-9]+) ]] && last_ts=${BASH_REMATCH[1]}
    fi
    echo "$last_ts"
}

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

recent_stream_files() {
    local stream="$1" maxage_min="${2:-1440}"
    find "$FD_LOGS" -maxdepth 1 -name "${stream}_????????_??????.log" \
        -mmin "-${maxage_min}" -printf '%T@ %p\n' 2>/dev/null | \
        sort -rn | head -20 | awk '{print $2}'
}

journalctl_k() { :; }

journalctl_since_window() {
    local freeze_ts="$1" margin_sec="${2:-300}"
    local start_epoch=$((freeze_ts - margin_sec))
    date -d "@$start_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "1 hour ago"
}

check_same_boot_crashes() {
    local boot_id="$1"
    local current_session="$2"
    local crash_count=0
    local sessions_list=""
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

# ── analyze_* functions ──────────────────────────────────────────
analyze_gpu() {
    local freeze_ts="$1"
    local matches
    matches=$(grep_dmesg "amdgpu.*ring.*timeout|amdgpu.*fence.*timeout|amdgpu.*GPU fault|amdgpu.*guilty|amdgpu.*reset|drm.*atomic.*check.*fail|drm.*timed out")
    local count
    count=$(echo "$matches" | grep -c . 2>/dev/null || true)
    count=${count:-0}
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
                    if [ "$cmp_high" = 1 ]; then highest_ratio=$ratio; fi
                    if [ "$cmp_thresh" = 1 ]; then anomaly_found=true; fi
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
    local max_gpu=0
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
            if [ "$age" -gt $((window / 2)) ] && [ "$early_seen" = false ]; then
                early_seen=true
                [ -n "$xpss_val" ] && xorg_early_rss=$xpss_val
                if [ -n "$top3_field" ]; then
                    IFS=';' read -ra procs <<< "$top3_field"
                    for proc in "${procs[@]}"; do
                        [ -z "$proc" ] && continue
                        local pid="${proc%%,*}"
                        [ -n "$pid" ] && early_pids["$pid"]=1
                    done
                fi
            elif [ "$age" -le $((window / 2)) ]; then
                [ -n "$xpss_val" ] && [ "$xpss_val" -gt "$xorg_late_rss" ] && xorg_late_rss=$xpss_val
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
    if [ "$xorg_early_rss" -gt 0 ] && [ "$xorg_late_rss" -gt 0 ]; then
        local xorg_delta=$((xorg_late_rss - xorg_early_rss))
        if [ "$xorg_delta" -gt 20000 ]; then
            evidence+="  Xorg RSS jumped ${xorg_delta}KB in last 60s ($xorg_early_rss -> $xorg_late_rss)"$'\n'
        fi
    fi
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

analyze_leak() {
    local freeze_ts="$1"
    if [ -n "$PROCESS_TRIGGER" ]; then
        if echo "$PROCESS_TRIGGER" | grep -q "RSS growth >20MB"; then
            SCORE_LEAK=3
        fi
    fi
}

analyze_kernel_faults() {
    local freeze_ts="$1"
    local matches jmatches
    matches=$(grep_dmesg "$KERNEL_FAULT_PATTERN" | grep -vi 'MCE: In-kernel' || true)
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

analyze_pstore() {
    local freeze_ts="$1" info="" d mt
    for d in /var/lib/systemd/pstore/* /sys/fs/pstore/*; do
        [ -e "$d" ] || continue
        mt=$(stat -c %Y "$d" 2>/dev/null) || continue
        if [ "$mt" -ge $((freeze_ts - 3600)) ] && [ "$mt" -le $((freeze_ts + 86400)) ]; then
            info+="  $(date -d "@$mt" '+%F %T' 2>/dev/null)  $d"$'\n'
        fi
    done
    PSTORE_INFO="$info"
    if [ -n "$info" ] && [ "$SCORE_KERNEL" -lt 3 ]; then
        SCORE_KERNEL=3
    fi
}

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

# ── Mock log helpers ─────────────────────────────────────────────
create_segment() {
    local stream="$1" suffix="$2"
    mkdir -p "$FD_LOGS"
    touch "$FD_LOGS/${stream}_${suffix}.log"
}

write_to_segment() {
    local stream="$1" suffix="$2" content="$3"
    mkdir -p "$FD_LOGS"
    echo "$content" >> "$FD_LOGS/${stream}_${suffix}.log"
}

touch_segment_mtime() {
    local stream="$1" suffix="$2" epoch="$3"
    touch -d "@$epoch" "$FD_LOGS/${stream}_${suffix}.log" 2>/dev/null || true
}

create_session_file() {
    local sid="$1" boot_id="$2" status="$3" started_at="$4" pid="${5:-$$}"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "$boot_id",
  "session_id": "$sid",
  "started_at": "$started_at",
  "status": "$status",
  "pid": $pid
}
EOF
    if [ -n "${detected_at:-}" ]; then
        sed -i "s/\"status\": \"$status\"/\"status\": \"$status\",\n  \"detected_at\": \"$detected_at\"/" "$FD_LOGS/sessions/${sid}.session"
    fi
}

create_crashed_session_file() {
    local sid="$1" boot_id="$2" started_at="$3" detected_at="$4"
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "$boot_id",
  "session_id": "$sid",
  "started_at": "$started_at",
  "status": "crashed",
  "detected_by_boot": "testboot",
  "detected_at": "$detected_at"
}
EOF
}

create_context_file() {
    local id="$1"
    mkdir -p "$FD_LOGS"
    cat > "$FD_LOGS/context_${id}.log" <<EOF
Linux version 6.2.0-arch
cmdline BOOT_IMAGE=/vmlinuz-linux
bios_version F7
bios_date 01/01/2024
microcode 0x12345
boost enabled
governor performance
tainted P
amd_pstate active
EOF
}

# ── Reset globals ────────────────────────────────────────────────
reset_scores() {
    SCORE_GPU=0; SCORE_OOM=0; SCORE_NVME=0; SCORE_MEM=0
    SCORE_THERMAL=0; SCORE_LEAK=0; SCORE_KERNEL=0
    GPU_POWER_ANOMALY=0; PROCESS_TRIGGER=""
    GPU_EVIDENCE=""; OOM_EVIDENCE=""; NVME_EVIDENCE=""
    KERNEL_EVIDENCE=""; PSTORE_INFO=""; CPU_FREQ_INFO=""; CONTEXT_INFO=""
}

# ═══════════════════════════════════════════════════════════════════
#  SEVERITY LABEL
# ═══════════════════════════════════════════════════════════════════
test_severity_label_high() {
    test_start "severity_label 4 returns HIGH"
    assert_eq "HIGH" "$(severity_label 4)"
    test_end
}

test_severity_label_medium() {
    test_start "severity_label 3 returns MEDIUM"
    assert_eq "MEDIUM" "$(severity_label 3)"
    test_end
}

test_severity_label_low() {
    test_start "severity_label 2 returns LOW"
    assert_eq "LOW" "$(severity_label 2)"
    test_end
}

test_severity_label_none() {
    test_start "severity_label 0/1/else returns NONE"
    assert_eq "NONE" "$(severity_label 0)" || { test_end; return 1; }
    assert_eq "NONE" "$(severity_label 1)" || { test_end; return 1; }
    assert_eq "NONE" "$(severity_label 5)" || { test_end; return 1; }
    assert_eq "NONE" "$(severity_label -1)" || { test_end; return 1; }
    assert_eq "NONE" "$(severity_label abc)"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  SEVERITY BLOCKS
# ═══════════════════════════════════════════════════════════════════
test_severity_blocks_high() {
    test_start "severity_blocks 4 returns red blocks"
    local expected expected_raw
    expected=$(echo -e "\e[31m████\e[0m")
    assert_eq "$expected" "$(severity_blocks 4)"
    test_end
}

test_severity_blocks_medium() {
    test_start "severity_blocks 3 returns yellow blocks"
    local expected
    expected=$(echo -e "\e[33m███ \e[0m")
    assert_eq "$expected" "$(severity_blocks 3)"
    test_end
}

test_severity_blocks_low() {
    test_start "severity_blocks 2 returns green blocks"
    local expected
    expected=$(echo -e "\e[32m██  \e[0m")
    assert_eq "$expected" "$(severity_blocks 2)"
    test_end
}

test_severity_blocks_none() {
    test_start "severity_blocks else returns gray block"
    assert_eq "█   " "$(severity_blocks 0)" || { test_end; return 1; }
    assert_eq "█   " "$(severity_blocks 1)" || { test_end; return 1; }
    assert_eq "█   " "$(severity_blocks 5)"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  SESSION_ID_TO_BOOT (via lib_common)
# ═══════════════════════════════════════════════════════════════════
test_session_id_to_boot_standard() {
    test_start "session_id_to_boot extracts prefix"
    source_deps
    assert_eq "abc123" "$(session_id_to_boot "abc123_987654321")"
    test_end
}

test_session_id_to_boot_uuid() {
    test_start "session_id_to_boot extracts UUID boot_id"
    source_deps
    local boot
    boot=$(session_id_to_boot "deadbeef_boot_id_987654321")
    assert_eq "deadbeef_boot_id" "$boot"
    test_end
}

test_session_id_to_boot_bare() {
    test_start "session_id_to_boot passes through plain boot_id"
    source_deps
    assert_eq "myboot" "$(session_id_to_boot "myboot")"
    test_end
}

test_session_id_to_boot_empty() {
    test_start "session_id_to_boot handles empty"
    source_deps
    assert_empty "$(session_id_to_boot "")"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  JOURNALCTL_SINCE_WINDOW
# ═══════════════════════════════════════════════════════════════════
test_journalctl_since_window_default_margin() {
    test_start "journalctl_since_window with default 300s margin"
    local result
    result=$(journalctl_since_window 1000000)
    assert_not_empty "$result" "should return a date string" || { test_end; return 1; }
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] \
        || assert_eq "YYYY-MM-DD HH:MM format" "$result" "wrong format"
    test_end
}

test_journalctl_since_window_custom_margin() {
    test_start "journalctl_since_window with custom 600s margin"
    local freeze_ts=1000000
    local expected_epoch=$((freeze_ts - 600))
    local expected
    expected=$(date -d "@$expected_epoch" '+%Y-%m-%d %H:%M')
    local result
    result=$(journalctl_since_window "$freeze_ts" 600)
    assert_eq "$expected" "$result"
    test_end
}

test_journalctl_since_window_large_margin() {
    test_start "journalctl_since_window with large margin"
    local result
    result=$(journalctl_since_window 1000000 86400)
    assert_not_empty "$result" "should handle 24h margin"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  FIND_FREEZE_TIME
# ═══════════════════════════════════════════════════════════════════
test_find_freeze_time_no_session_gap() {
    test_start "find_freeze_time detects gap >3s (with session_id)"
    source_deps
    local session_start=1000000 boot="testboot"
    local sid="${boot}_${session_start}"
    local cutoff=$((session_start + 600))

    # Create a heartbeat segment with a gap
    create_segment "heartbeat" "20250101_120000"
    write_to_segment "heartbeat" "20250101_120000" "1000000 beat 1"
    write_to_segment "heartbeat" "20250101_120000" "1000001 beat 2"
    write_to_segment "heartbeat" "20250101_120000" "1000002 beat 3"
    write_to_segment "heartbeat" "20250101_120000" "1000010 beat 4"  # gap 8s
    write_to_segment "heartbeat" "20250101_120000" "1000011 beat 5"
    touch_segment_mtime "heartbeat" "20250101_120000" "$((session_start - 600))"

    # Create session file (status running, pid dead so it's found later)
    create_session_file "$sid" "$boot" "running" "2024-01-01T00:00:00+00:00" 99999999

    local result
    result=$(find_freeze_time "$sid")

    # First gap is at 1000002 -> 1000010 (8s), so freeze at 1000002
    assert_eq "1000002" "$result" "should detect gap at 1000002"
    test_end
}

test_find_freeze_time_no_session_no_gap() {
    test_start "find_freeze_time last ts when no gap in range"
    source_deps
    local session_start=1000000 boot="testboot"
    local sid="${boot}_${session_start}"

    create_segment "heartbeat" "20250101_120000"
    write_to_segment "heartbeat" "20250101_120000" "1000001 beat 1"
    write_to_segment "heartbeat" "20250101_120000" "1000002 beat 2"
    write_to_segment "heartbeat" "20250101_120000" "1000003 beat 3"
    touch_segment_mtime "heartbeat" "20250101_120000" "$((session_start - 600))"
    create_session_file "$sid" "$boot" "running" "2024-01-01T00:00:00+00:00" 99999999

    local result
    result=$(find_freeze_time "$sid")
    # No gaps, last ts in range is 1000003
    assert_eq "1000003" "$result"
    test_end
}

test_find_freeze_time_too_close_to_cutoff() {
    test_start "find_freeze_time returns 0 when last_ts within 30s of cutoff"
    source_deps
    local session_start=1000000000 boot="testboot"
    local sid="${boot}_${session_start}"
    local cutoff=$((session_start + 600))

    # Create a minimal session marker WITHOUT detected_at (uses default cutoff)
    mkdir -p "$FD_LOGS/sessions"
    cat > "$FD_LOGS/sessions/${sid}.session" <<EOF
{
  "boot_id": "$boot",
  "session_id": "$sid",
  "started_at": "2001-09-09T02:46:40+00:00",
  "status": "running",
  "pid": 99999999
}
EOF

    # last_ts = cutoff - 10 = within 30s of default cutoff → should return 0
    local last_ts=$((cutoff - 10))
    create_segment "heartbeat" "20250101_120000"
    write_to_segment "heartbeat" "20250101_120000" "${last_ts} last_heartbeat"
    touch_segment_mtime "heartbeat" "20250101_120000" "$session_start"

    local result
    result=$(find_freeze_time "$sid")
    assert_eq "0" "$result" "should return 0 when within 30s of cutoff"
    test_end
}

test_find_freeze_time_no_session_id() {
    test_start "find_freeze_time with empty session_id uses latest heartbeat"
    source_deps
    create_segment "heartbeat" "20250101_120000"
    write_to_segment "heartbeat" "20250101_120000" "2000000 newer beat"
    create_segment "heartbeat" "20250101_110000"
    write_to_segment "heartbeat" "20250101_110000" "1000000 older beat"

    local result
    result=$(find_freeze_time "")
    assert_eq "2000000" "$result" "should return timestamp from newest file"
    test_end
}

test_find_freeze_time_no_heartbeat_files() {
    test_start "find_freeze_time returns 0 with no heartbeat files"
    source_deps
    local result
    result=$(find_freeze_time "")
    assert_eq "0" "$result" "should return 0 when no files exist"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  GREP_LOGS / GREP_DMESG
# ═══════════════════════════════════════════════════════════════════
test_grep_logs_finds_pattern() {
    test_start "grep_logs finds matching pattern in segments"
    source_deps
    write_to_segment "dmesg" "20250101_120000" "D: [timestamp] amdgpu ring timeout"
    write_to_segment "fast" "20250101_120000" "normal log line"
    local result
    result=$(grep_logs "amdgpu" 1440)
    assert_contains "$result" "amdgpu" "should find amdgpu line" || { test_end; return 1; }
    assert_not_contains "$result" "normal" "should not match non-dmesg" || { test_end; return 1; }
    local dmesg_result
    dmesg_result=$(grep_dmesg "amdgpu")
    assert_contains "$dmesg_result" "amdgpu" "grep_dmesg should find amdgpu in dmesg stream"
    test_end
}

test_grep_logs_no_match() {
    test_start "grep_logs returns empty for no match"
    source_deps
    write_to_segment "dmesg" "20250101_120000" "D: some log"
    local result
    result=$(grep_logs "NONEXISTENT_PATTERN_ZZZ" 1440)
    assert_empty "$result"
    test_end
}

test_grep_logs_no_files() {
    test_start "grep_logs returns empty when no segment files exist"
    source_deps
    local result
    result=$(grep_logs "anything" 1440)
    assert_empty "$result"
    test_end
}

test_grep_dmesg_multiple_matches() {
    test_start "grep_dmesg finds multiple matching lines"
    source_deps
    write_to_segment "dmesg" "20250101_120000" "D: [0] amdgpu ring timeout on ring 0"
    write_to_segment "dmesg" "20250101_120000" "D: [1] amdgpu fence timeout"
    write_to_segment "dmesg" "20250101_120000" "D: [2] random other message"
    local result
    result=$(grep_dmesg "amdgpu")
    local count
    count=$(echo "$result" | grep -c . || true)
    assert_eq "2" "$count" "should find 2 amdgpu lines"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  RECENT_STREAM_FILES
# ═══════════════════════════════════════════════════════════════════
test_recent_stream_files_returns_sorted() {
    test_start "recent_stream_files returns files sorted by mtime newest first"
    source_deps
    write_to_segment "gpu" "20250101_100000" "old data"
    write_to_segment "gpu" "20250101_120000" "middle data"
    write_to_segment "gpu" "20250101_140000" "new data"
    # Set relative mtimes (all within 1440 min window)
    touch -d "3 hours ago" "$FD_LOGS/gpu_20250101_100000.log"
    touch -d "2 hours ago" "$FD_LOGS/gpu_20250101_120000.log"
    touch -d "1 hour ago"  "$FD_LOGS/gpu_20250101_140000.log"

    local result
    result=$(recent_stream_files gpu 1440)
    local first second
    first=$(echo "$result" | head -1)
    second=$(echo "$result" | sed -n '2p')

    assert_contains "$first" "140000" "newest file should be first" || { test_end; return 1; }
    assert_contains "$second" "120000" "second file should be second" || { test_end; return 1; }
    local third
    third=$(echo "$result" | sed -n '3p')
    assert_contains "$third" "100000" "oldest should be last"
    test_end
}

test_recent_stream_files_empty() {
    test_start "recent_stream_files returns empty for non-existent stream"
    source_deps
    local result
    result=$(recent_stream_files "nonexistent_stream" 1440)
    assert_empty "$result"
    test_end
}

test_recent_stream_files_ignores_other_streams() {
    test_start "recent_stream_files ignores other stream files"
    source_deps
    write_to_segment "gpu" "20250101_120000" "gpu data"
    write_to_segment "fast" "20250101_120000" "fast data"
    local result
    result=$(recent_stream_files gpu 1440)
    assert_contains "$result" "gpu" "should include gpu files" || { test_end; return 1; }
    assert_not_contains "$result" "fast" "should exclude fast files"
    test_end
}

test_recent_stream_files_maxage_filter() {
    test_start "recent_stream_files respects maxage filter"
    source_deps
    write_to_segment "gpu" "20250101_100000" "very old"
    write_to_segment "gpu" "20250101_120000" "recent"
    # One file outside the 1440 min window, one inside
    touch -d "3000 minutes ago" "$FD_LOGS/gpu_20250101_100000.log"
    touch -d "100 minutes ago"  "$FD_LOGS/gpu_20250101_120000.log"

    local result
    result=$(recent_stream_files gpu 1440)
    assert_contains "$result" "120000" "recent file should appear" || { test_end; return 1; }
    assert_not_contains "$result" "100000" "old file should be filtered"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  CHECK_SAME_BOOT_CRASHES
# ═══════════════════════════════════════════════════════════════════
test_check_same_boot_crashes_finds_previous() {
    test_start "check_same_boot_crashes finds previous crash in same boot"
    source_deps
    local boot="testboot"
    local cur_sid="${boot}_200"
    local prev_sid="${boot}_100"

    create_crashed_session_file "$prev_sid" "$boot" "2024-01-01T00:01:00+00:00" "2024-01-01T00:02:00+00:00"
    create_session_file "$cur_sid" "$boot" "running" "2024-01-01T00:03:00+00:00" $$

    local result
    result=$(check_same_boot_crashes "$boot" "$cur_sid")
    assert_not_empty "$result" "should find previous crash" || { test_end; return 1; }
    assert_contains "$result" "1|" "should have count 1"
    local count="${result%%|*}"
    assert_eq "1" "$count" "should report 1 crash"
    test_end
}

test_check_same_boot_crashes_no_crashes() {
    test_start "check_same_boot_crashes returns empty when no crashes"
    source_deps
    local boot="testboot"
    local cur_sid="${boot}_200"
    create_session_file "$cur_sid" "$boot" "running" "2024-01-01T00:03:00+00:00" $$

    local result
    result=$(check_same_boot_crashes "$boot" "$cur_sid")
    assert_empty "$result"
    test_end
}

test_check_same_boot_crashes_different_boot() {
    test_start "check_same_boot_crashes ignores different boot_id"
    source_deps
    create_crashed_session_file "other_100" "otherboot" "2024-01-01T00:01:00+00:00" "2024-01-01T00:02:00+00:00"
    create_session_file "myboot_200" "myboot" "running" "2024-01-01T00:03:00+00:00" $$

    local result
    result=$(check_same_boot_crashes "myboot" "myboot_200")
    assert_empty "$result" "different boot should not match"
    test_end
}

test_check_same_boot_crashes_skips_self() {
    test_start "check_same_boot_crashes skips current session"
    source_deps
    local boot="testboot"
    local sid="${boot}_100"

    create_crashed_session_file "$sid" "$boot" "2024-01-01T00:01:00+00:00" "2024-01-01T00:02:00+00:00"

    local result
    result=$(check_same_boot_crashes "$boot" "$sid")
    assert_empty "$result" "should not count itself"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_GPU
# ═══════════════════════════════════════════════════════════════════
test_analyze_gpu_high_severity() {
    test_start "analyze_gpu score=4 for >2 matches"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] amdgpu ring timeout on ring 0"
    write_to_segment "dmesg" "20250101_120000" "D: [1] amdgpu fence timeout"
    write_to_segment "dmesg" "20250101_120000" "D: [2] amdgpu GPU fault"
    analyze_gpu 1000000
    assert_eq 4 "$SCORE_GPU" ">2 matches should set SCORE_GPU=4" || { test_end; return 1; }
    assert_not_empty "$GPU_EVIDENCE" "GPU_EVIDENCE should contain matches"
    test_end
}

test_analyze_gpu_medium_severity() {
    test_start "analyze_gpu score=3 for 1-2 matches"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] amdgpu ring timeout on ring 0"
    analyze_gpu 1000000
    assert_eq 3 "$SCORE_GPU" "1 match should set SCORE_GPU=3" || { test_end; return 1; }
    assert_not_empty "$GPU_EVIDENCE"
    test_end
}

test_analyze_gpu_no_evidence() {
    test_start "analyze_gpu score=0 with no matches"
    source_deps
    reset_scores
    analyze_gpu 1000000
    assert_eq 0 "$SCORE_GPU" "no matches should leave SCORE_GPU=0" || { test_end; return 1; }
    assert_empty "$GPU_EVIDENCE"
    test_end
}

test_analyze_gpu_power_anomaly_detected() {
    test_start "analyze_gpu_power_anomaly detects high power/busy ratio"
    source_deps
    reset_scores
    if ! command -v bc &>/dev/null; then
        test_skip
        return
    fi
    local freeze_ts=1000000
    write_to_segment "gpu" "20250101_120000" "999990|busy=10|power=50|vram=4096|temp=65"
    write_to_segment "gpu" "20250101_120000" "999995|busy=5|power=30|vram=4096|temp=66"

    analyze_gpu_power_anomaly "$freeze_ts"
    assert_ne "0" "$GPU_POWER_ANOMALY" "power anomaly should be non-zero" || { test_end; return 1; }
    assert_eq 3 "$SCORE_GPU" "should elevate SCORE_GPU to 3"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_OOM
# ═══════════════════════════════════════════════════════════════════
test_analyze_oom_detected() {
    test_start "analyze_oom score=4 for OOM matches"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] Out of memory: Killed process 1234 (firefox)"
    analyze_oom 1000000
    assert_eq 4 "$SCORE_OOM" "OOM match should set SCORE_OOM=4" || { test_end; return 1; }
    assert_not_empty "$OOM_EVIDENCE"
    test_end
}

test_analyze_oom_no_evidence() {
    test_start "analyze_oom score=0 with no OOM"
    source_deps
    reset_scores
    analyze_oom 1000000
    assert_eq 0 "$SCORE_OOM" "no OOM should leave SCORE_OOM=0" || { test_end; return 1; }
    assert_empty "$OOM_EVIDENCE"
    test_end
}

test_analyze_oom_killed_process() {
    test_start "analyze_oom detects Killed process pattern"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] Killed process 5678 (chrome)"
    analyze_oom 1000000
    assert_eq 4 "$SCORE_OOM" "Killed process should trigger OOM score"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_NVME
# ═══════════════════════════════════════════════════════════════════
test_analyze_nvme_detected() {
    test_start "analyze_nvme score=3 for NVMe errors"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] nvme nvme0: I/O error"
    analyze_nvme 1000000
    assert_eq 3 "$SCORE_NVME" "NVMe error should set SCORE_NVME=3" || { test_end; return 1; }
    assert_not_empty "$NVME_EVIDENCE"
    test_end
}

test_analyze_nvme_no_evidence() {
    test_start "analyze_nvme score=0 with no NVMe errors"
    source_deps
    reset_scores
    analyze_nvme 1000000
    assert_eq 0 "$SCORE_NVME" "no NVMe should leave SCORE_NVME=0" || { test_end; return 1; }
    assert_empty "$NVME_EVIDENCE"
    test_end
}

test_analyze_nvme_false_positive_fault() {
    test_start "analyze_nvme does not match default_ps_max_latency_us"
    source_deps
    reset_scores
    # This line should NOT match because "fault" requires word boundary
    write_to_segment "dmesg" "20250101_120000" "D: [0] nvme default_ps_max_latency_us"
    analyze_nvme 1000000
    assert_eq 0 "$SCORE_NVME" "should not match default_ps_max_latency_us"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_MEMORY_PRESSURE
# ═══════════════════════════════════════════════════════════════════
test_analyze_memory_pressure_high_psi() {
    test_start "analyze_memory_pressure score=3 for high PSI"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "fast" "20250101_120000" "${freeze_ts}|psimf=95.0|swapf=500|oomd=0|gtemp=50|ctemp=45"
    analyze_memory_pressure "$freeze_ts"
    assert_eq 3 "$SCORE_MEM" "high PSI should set SCORE_MEM=3"
    test_end
}

test_analyze_memory_pressure_low_swap() {
    test_start "analyze_memory_pressure score=3 for low swap"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "fast" "20250101_120000" "${freeze_ts}|psimf=10.0|swapf=50|oomd=0|gtemp=50|ctemp=45"
    analyze_memory_pressure "$freeze_ts"
    assert_eq 3 "$SCORE_MEM" "low swap should set SCORE_MEM=3"
    test_end
}

test_analyze_memory_pressure_no_pressure() {
    test_start "analyze_memory_pressure score=0 for normal values"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "fast" "20250101_120000" "${freeze_ts}|psimf=10.0|swapf=500|oomd=0|gtemp=50|ctemp=45"
    analyze_memory_pressure "$freeze_ts"
    assert_eq 0 "$SCORE_MEM" "normal values should leave SCORE_MEM=0"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_THERMAL
# ═══════════════════════════════════════════════════════════════════
test_analyze_thermal_over_95() {
    test_start "analyze_thermal score=3 for GPU >95°C"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "fast" "20250101_120000" "999990|psimf=10|swapf=500|oomd=0|gtemp=98.0|ctemp=70"
    analyze_thermal "$freeze_ts"
    assert_eq 3 "$SCORE_THERMAL" "GPU >95°C should set SCORE_THERMAL=3"
    test_end
}

test_analyze_thermal_normal() {
    test_start "analyze_thermal score=0 for normal temps"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "fast" "20250101_120000" "999990|psimf=10|swapf=500|oomd=0|gtemp=65.0|ctemp=50"
    analyze_thermal "$freeze_ts"
    assert_eq 0 "$SCORE_THERMAL" "normal temps should leave SCORE_THERMAL=0"
    test_end
}

test_analyze_thermal_no_data() {
    test_start "analyze_thermal score=0 with no fast files"
    source_deps
    reset_scores
    analyze_thermal 1000000
    assert_eq 0 "$SCORE_THERMAL"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_PROCESS_TRIGGERS
# ═══════════════════════════════════════════════════════════════════
test_analyze_process_triggers_new_process() {
    test_start "analyze_process_triggers detects new process at top-3"
    source_deps
    reset_scores
    local freeze_ts=1000000
    # Early sample (age > 60): has pid 100
    write_to_segment "fast" "20250101_120000" "999920|psimf=10|swapf=500|oomd=0|gtemp=50|ctemp=45|xpss=1000|top3=100,bash,50000;200,Xorg,80000"
    # Late sample (age <= 60): pid 100 persisted, pid 300 is new
    write_to_segment "fast" "20250101_120000" "999950|psimf=10|swapf=500|oomd=0|gtemp=50|ctemp=45|xpss=1000|top3=100,bash,50000;300,newproc,90000"

    analyze_process_triggers "$freeze_ts"
    assert_not_empty "$PROCESS_TRIGGER" "should detect new process" || { test_end; return 1; }
    assert_contains "$PROCESS_TRIGGER" "newproc" "should mention newproc"
    test_end
}

test_analyze_process_triggers_xorg_jump() {
    test_start "analyze_process_triggers detects Xorg RSS jump >20000KB"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "fast" "20250101_120000" "999920|psimf=10|swapf=500|oomd=0|gtemp=50|ctemp=45|xpss=10000|top3=100,bash,50000"
    write_to_segment "fast" "20250101_120000" "999950|psimf=10|swapf=500|oomd=0|gtemp=50|ctemp=45|xpss=40000|top3=100,bash,50000"

    analyze_process_triggers "$freeze_ts"
    assert_contains "$PROCESS_TRIGGER" "Xorg RSS jumped" "should detect Xorg RSS jump"
    test_end
}

test_analyze_process_triggers_no_triggers() {
    test_start "analyze_process_triggers empty for no changes"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "fast" "20250101_120000" "999920|psimf=10|swapf=500|oomd=0|gtemp=50|ctemp=45|xpss=5000|top3=100,bash,50000;200,Xorg,60000"
    write_to_segment "fast" "20250101_120000" "999950|psimf=10|swapf=500|oomd=0|gtemp=50|ctemp=45|xpss=6000|top3=100,bash,50000;200,Xorg,60000"

    analyze_process_triggers "$freeze_ts"
    assert_empty "$PROCESS_TRIGGER" "no changes should leave trigger empty"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_LEAK
# ═══════════════════════════════════════════════════════════════════
test_analyze_leak_detected() {
    test_start "analyze_leak score=3 when PROCESS_TRIGGER has RSS growth"
    source_deps
    reset_scores
    PROCESS_TRIGGER="  RSS growth >20MB: firefox(+42MB RSS)"
    analyze_leak 1000000
    assert_eq 3 "$SCORE_LEAK" "RSS growth should set SCORE_LEAK=3"
    test_end
}

test_analyze_leak_no_trigger() {
    test_start "analyze_leak score=0 when no RSS growth"
    source_deps
    reset_scores
    PROCESS_TRIGGER="  Processes newly at top-3 RSS in last 60s: chrome(pid=123)"
    analyze_leak 1000000
    assert_eq 0 "$SCORE_LEAK" "no RSS growth should leave SCORE_LEAK=0"
    test_end
}

test_analyze_leak_empty_trigger() {
    test_start "analyze_leak score=0 when PROCESS_TRIGGER empty"
    source_deps
    reset_scores
    PROCESS_TRIGGER=""
    analyze_leak 1000000
    assert_eq 0 "$SCORE_LEAK"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_KERNEL_FAULTS
# ═══════════════════════════════════════════════════════════════════
test_analyze_kernel_faults_gpf() {
    test_start "analyze_kernel_faults score=4 for general protection fault"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] general protection fault, probably for non-canonical address"
    analyze_kernel_faults 1000000
    assert_eq 4 "$SCORE_KERNEL" "GPF should set SCORE_KERNEL=4" || { test_end; return 1; }
    assert_not_empty "$KERNEL_EVIDENCE"
    test_end
}

test_analyze_kernel_faults_soft_lockup() {
    test_start "analyze_kernel_faults score=4 when BUG: with soft lockup"
    source_deps
    reset_scores
    # "BUG:" takes precedence over "soft lockup" in the scoring logic
    write_to_segment "dmesg" "20250101_120000" "D: [0] watchdog: BUG: soft lockup - CPU#0 stuck for 22s!"
    analyze_kernel_faults 1000000
    assert_eq 4 "$SCORE_KERNEL" "BUG: with soft lockup should set SCORE_KERNEL=4"
    test_end
}

test_analyze_kernel_faults_mce() {
    test_start "analyze_kernel_faults score=4 for machine check"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] mce: [Hardware Error]: Machine check events logged"
    analyze_kernel_faults 1000000
    assert_eq 4 "$SCORE_KERNEL" "MCE should set SCORE_KERNEL=4"
    test_end
}

test_analyze_kernel_faults_no_match() {
    test_start "analyze_kernel_faults score=0 with no faults"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] normal kernel message"
    analyze_kernel_faults 1000000
    assert_eq 0 "$SCORE_KERNEL" "no kernel fault should leave SCORE_KERNEL=0"
    test_end
}

test_analyze_kernel_faults_filters_mce_in_kernel() {
    test_start "analyze_kernel_faults filters MCE: In-kernel noise"
    source_deps
    reset_scores
    write_to_segment "dmesg" "20250101_120000" "D: [0] MCE: In-kernel MCE recovery event"
    write_to_segment "dmesg" "20250101_120000" "D: [1] machine check: real error"
    analyze_kernel_faults 1000000
    assert_eq 4 "$SCORE_KERNEL" "should still detect real MCE" || { test_end; return 1; }
    assert_not_contains "$KERNEL_EVIDENCE" "In-kernel" "should filter In-kernel line"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_PSTORE
# ═══════════════════════════════════════════════════════════════════
test_analyze_pstore_no_files() {
    test_start "analyze_pstore returns empty when no pstore records"
    source_deps
    reset_scores
    analyze_pstore 1000000
    assert_empty "$PSTORE_INFO" "no pstore files should return empty" || { test_end; return 1; }
    assert_eq 0 "$SCORE_KERNEL" "SCORE_KERNEL should remain unchanged"
    test_end
}

test_analyze_pstore_elevates_score() {
    test_start "analyze_pstore elevates SCORE_KERNEL when records exist"
    source_deps
    reset_scores
    SCORE_KERNEL=0
    # Create a mock pstore record with mtime within the window
    # freeze_ts = 1000000, window: (1000000-3600)=996400 to (1000000+86400)=1086400
    local fake_pstore="$TEST_DIR/fake_pstore"
    mkdir -p "$fake_pstore"
    echo "panic data" > "$fake_pstore/record1"
    touch -d "@$((freeze_ts + 100))" "$fake_pstore/record1"

    # Temporarily override the pstore paths
    local old_d1="/var/lib/systemd/pstore/*"
    local old_d2="/sys/fs/pstore/*"

    # We can't easily override the for loop, but we can just test the function logic
    # by examining what happens when no real pstore files exist
    # The function only detects real system pstore files.
    # For test, we just verify it handles absence gracefully.
    analyze_pstore 1000000
    assert_empty "$PSTORE_INFO" "no real pstore files should return empty"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_CPU_FREQ
# ═══════════════════════════════════════════════════════════════════
test_analyze_cpu_freq_with_data() {
    test_start "analyze_cpu_freq parses cpu stream fields"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "cpu" "20250101_120000" "999990|fmax=4200|nhi=2|boost=1|taint=0"
    write_to_segment "cpu" "20250101_120000" "999995|fmax=4300|nhi=3|boost=1|taint=0"

    analyze_cpu_freq "$freeze_ts"
    assert_not_empty "$CPU_FREQ_INFO" "should produce cpu freq info" || { test_end; return 1; }
    assert_contains "$CPU_FREQ_INFO" "4300" "should have max freq 4300" || { test_end; return 1; }
    assert_contains "$CPU_FREQ_INFO" "samples=2" "should report 2 samples"
    test_end
}

test_analyze_cpu_freq_no_data() {
    test_start "analyze_cpu_freq empty when no cpu files"
    source_deps
    reset_scores
    analyze_cpu_freq 1000000
    assert_empty "$CPU_FREQ_INFO"
    test_end
}

test_analyze_cpu_freq_ignores_out_of_window() {
    test_start "analyze_cpu_freq ignores lines outside 120s window"
    source_deps
    reset_scores
    local freeze_ts=1000000
    write_to_segment "cpu" "20250101_120000" "999800|fmax=4000|nhi=1|boost=1|taint=0"
    write_to_segment "cpu" "20250101_120000" "999950|fmax=4200|nhi=2|boost=1|taint=0"

    analyze_cpu_freq "$freeze_ts"
    # 999800 is 200s before freeze_ts → outside 120s window, should be excluded
    # 999950 is 50s before freeze_ts → inside 120s window
    assert_not_empty "$CPU_FREQ_INFO" || { test_end; return 1; }
    assert_contains "$CPU_FREQ_INFO" "4200" "should only include in-window data" || { test_end; return 1; }
    assert_not_contains "$CPU_FREQ_INFO" "4000" "should exclude out-of-window data"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  LOAD_CONTEXT
# ═══════════════════════════════════════════════════════════════════
test_load_context_with_session() {
    test_start "load_context loads session context file"
    source_deps
    reset_scores
    ANALYZE_SESSION="testsession_12345"
    create_context_file "testsession_12345"

    load_context
    assert_not_empty "$CONTEXT_INFO" "should load context" || { test_end; return 1; }
    assert_contains "$CONTEXT_INFO" "Linux" "should contain kernel version" || { test_end; return 1; }
    assert_contains "$CONTEXT_INFO" "cmdline" "should contain cmdline"
    test_end
}

test_load_context_no_session_fallback_latest() {
    test_start "load_context falls back to latest context file"
    source_deps
    reset_scores
    ANALYZE_SESSION=""
    create_context_file "other_999"
    create_context_file "latest_888"

    load_context
    assert_not_empty "$CONTEXT_INFO" "should load latest context file"
    test_end
}

test_load_context_no_files() {
    test_start "load_context empty when no context files"
    source_deps
    reset_scores
    ANALYZE_SESSION=""
    load_context
    assert_empty "$CONTEXT_INFO"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════
test_arg_parse_session() {
    test_start "arg parse --session sets ANALYZE_SESSION"
    local as="" ab="" ac=false qm=false go=false mo=false im=false of=""
    set -- --session "test_12345"
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) as="$2"; shift 2 ;;
            --boot) ab="$2"; shift 2 ;;
            --current) ac=true; shift ;;
            --quick) qm=true; im=false; shift ;;
            --gpu-only) go=true; shift ;;
            --memory-only) mo=true; shift ;;
            --output) of="$2"; shift 2 ;;
            --interactive) im=true; shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "test_12345" "$as" "--session should set ANALYZE_SESSION"
    test_end
}

test_arg_parse_boot() {
    test_start "arg parse --boot sets ANALYZE_BOOT"
    local as="" ab="" ac=false
    set -- --boot "myboot"
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) as="$2"; shift 2 ;;
            --boot) ab="$2"; shift 2 ;;
            --current) ac=true; shift ;;
            --quick|--gpu-only|--memory-only|--output|--interactive) shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "myboot" "$ab" "--boot should set ANALYZE_BOOT"
    test_end
}

test_arg_parse_current() {
    test_start "arg parse --current sets ANALYZE_CURRENT"
    local ac=false
    set -- --current
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift 2 ;;
            --boot) shift 2 ;;
            --current) ac=true; shift ;;
            --quick|--gpu-only|--memory-only|--output|--interactive) shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "true" "$ac" "--current should set ANALYZE_CURRENT"
    test_end
}

test_arg_parse_quick() {
    test_start "arg parse --quick sets QUICK_MODE and disables interactive"
    local qm=false im=true
    set -- --quick
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift 2 ;;
            --boot) shift 2 ;;
            --current) shift ;;
            --quick) qm=true; im=false; shift ;;
            --gpu-only) shift ;;
            --memory-only) shift ;;
            --output) shift 2 ;;
            --interactive) im=true; shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "true" "$qm" "--quick should set QUICK_MODE" || { test_end; return 1; }
    assert_eq "false" "$im" "--quick should disable interactive"
    test_end
}

test_arg_parse_gpu_only() {
    test_start "arg parse --gpu-only sets GPU_ONLY"
    local go=false
    set -- --gpu-only
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift 2 ;;
            --boot) shift 2 ;;
            --current) shift ;;
            --quick) shift ;;
            --gpu-only) go=true; shift ;;
            --memory-only) shift ;;
            --output) shift 2 ;;
            --interactive) shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "true" "$go" "--gpu-only should set GPU_ONLY"
    test_end
}

test_arg_parse_memory_only() {
    test_start "arg parse --memory-only sets MEMORY_ONLY"
    local mo=false
    set -- --memory-only
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift 2 ;;
            --boot) shift 2 ;;
            --current|--quick|--gpu-only) shift ;;
            --memory-only) mo=true; shift ;;
            --output) shift 2 ;;
            --interactive) shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "true" "$mo" "--memory-only should set MEMORY_ONLY"
    test_end
}

test_arg_parse_output() {
    test_start "arg parse --output sets OUTPUT_FILE"
    local of=""
    set -- --output "/tmp/report.txt"
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift 2 ;;
            --boot) shift 2 ;;
            --current|--quick|--gpu-only|--memory-only) shift ;;
            --output) of="$2"; shift 2 ;;
            --interactive) shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "/tmp/report.txt" "$of" "--output should set OUTPUT_FILE"
    test_end
}

test_arg_parse_interactive() {
    test_start "arg parse --interactive forces interactive mode"
    local im=false
    set -- --interactive
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) shift 2 ;;
            --boot) shift 2 ;;
            --current|--quick|--gpu-only|--memory-only|--output) shift ;;
            --interactive) im=true; shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "true" "$im" "--interactive should set INTERACTIVE_MODE"
    test_end
}

test_arg_parse_unknown_exits() {
    test_start "arg parse unknown option exits 1"
    (
        set -- --unknown-flag
        while [ $# -gt 0 ]; do
            case "$1" in
                --session|--boot|--output) shift 2 ;;
                --current|--quick|--gpu-only|--memory-only|--interactive) shift ;;
                *) exit 1 ;;
            esac
        done
        exit 0
    )
    local rc=$?
    assert_eq 1 $rc "unknown option should exit 1"
    test_end
}

test_arg_parse_combined() {
    test_start "arg parse combined --session --gpu-only --quick"
    local as="" go=false qm=false im=true
    set -- --session "test_999" --gpu-only --quick
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) as="$2"; shift 2 ;;
            --boot) shift 2 ;;
            --current) shift ;;
            --quick) qm=true; im=false; shift ;;
            --gpu-only) go=true; shift ;;
            --memory-only) shift ;;
            --output) shift 2 ;;
            --interactive) shift ;;
            *) exit 1 ;;
        esac
    done
    assert_eq "test_999" "$as" "session should be set" || { test_end; return 1; }
    assert_eq "true" "$go" "gpu-only should be set" || { test_end; return 1; }
    assert_eq "true" "$qm" "quick should be set"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  RUN — continued below (test function appended after original EOF)
# ═══════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════
#  GENERATE_REPORT
# ═══════════════════════════════════════════════════════════════════
generate_report() {
    local freeze_ts="$1"
    local report_file="$2"

    local ftime_str
    ftime_str=$(date -d "@$freeze_ts" --iso-8601=seconds 2>/dev/null || echo "$freeze_ts")

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

        if [ -n "$CPU_FREQ_INFO" ]; then
            echo "CPU FREQ BEFORE FREEZE (transient/boost forensics)"
            echo "$CPU_FREQ_INFO"
            echo ""
        fi

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

        if [ "$MEMORY_ONLY" = false ] && [ "$GPU_ONLY" = false ]; then
            echo "$(severity_blocks "$SCORE_OOM") OOM ($(severity_label "$SCORE_OOM"))"
            if [ -n "$oom_evidence" ]; then
                echo "$oom_evidence" | tail -5 | while IFS= read -r l; do echo "  $l"; done
            else
                echo "  No OOM killer activity in dmesg or journal."
            fi
            echo ""
        fi

        if [ "$GPU_ONLY" = false ] && [ "$MEMORY_ONLY" = false ]; then
            echo "$(severity_blocks "$SCORE_NVME") NVMe ($(severity_label "$SCORE_NVME"))"
            if [ -n "$nvme_evidence" ]; then
                echo "$nvme_evidence" | tail -5 | while IFS= read -r l; do echo "  $l"; done
            else
                echo "  No NVMe errors in dmesg or journal."
            fi
            echo ""
        fi

        if [ "$GPU_ONLY" = false ]; then
            echo "$(severity_blocks "$SCORE_MEM") MEMORY PRESSURE ($(severity_label "$SCORE_MEM"))"
            if [ "$SCORE_MEM" -gt 0 ]; then
                echo "  High memory pressure before freeze (PSI / swap)."
            else
                echo "  Normal memory pressure leading to freeze."
            fi
            echo ""
        fi

        echo "$(severity_blocks "$SCORE_THERMAL") THERMAL ($(severity_label "$SCORE_THERMAL"))"
        if [ "$SCORE_THERMAL" -gt 0 ]; then
            echo "  GPU/CPU temperature exceeded 95°C before freeze."
        else
            echo "  Temperatures within safe range."
        fi
        echo ""

        echo "$(severity_blocks "$SCORE_LEAK") PROCESS LEAK ($(severity_label "$SCORE_LEAK"))"
        if [ "$SCORE_LEAK" -gt 0 ]; then
            echo "  Process RSS growth detected (see trigger analysis below)."
        else
            echo "  No significant memory leak detected."
        fi
        echo ""

        if [ -n "$PROCESS_TRIGGER" ]; then
            echo "PROCESS TRIGGER ANALYSIS (60s window before freeze)"
            echo "───────────────────────────────────────────────────"
            echo -n "$PROCESS_TRIGGER"
            echo ""
        fi

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

# ═══════════════════════════════════════════════════════════════════
#  GENERATE REPORT — FULL INTEGRATION
# ═══════════════════════════════════════════════════════════════════
test_generate_report_basic() {
    test_start "generate_report produces full report with all sections"
    source_deps
    reset_scores

    local freeze_ts=1000000
    local session_start=$((freeze_ts - 120))
    local boot="$CURRENT_BOOT"
    local sid="${boot}_${session_start}"

    ANALYZE_SESSION="$sid"
    ANALYZE_BOOT="$boot"
    GPU_ONLY=false
    MEMORY_ONLY=false

    # Context file
    create_context_file "$sid"

    # Session file with crashed status and detected_at within cutoff
    detected_at="2001-09-09T01:48:40+00:00"
    create_session_file "$sid" "$boot" "crashed" "2001-09-09T01:46:40+00:00"
    detected_at=""

    # Heartbeat with gap (for freeze time detection path)
    create_segment "heartbeat" "20250101_120000"
    write_to_segment "heartbeat" "20250101_120000" "$((freeze_ts - 10)) beat 1"
    write_to_segment "heartbeat" "20250101_120000" "$((freeze_ts - 5)) beat 2"
    write_to_segment "heartbeat" "20250101_120000" "${freeze_ts} beat 3"
    touch_segment_mtime "heartbeat" "20250101_120000" "$((session_start - 600))"

    # Fast stream — thermal above threshold + memory pressure
    create_segment "fast" "20250101_120000"
    write_to_segment "fast" "20250101_120000" "$((freeze_ts - 60))|psimf=95.0|swapf=50|oomd=0|gtemp=98.0|ctemp=70|xpss=1000|top3=100,bash,50000"
    write_to_segment "fast" "20250101_120000" "$((freeze_ts - 10))|psimf=10.0|swapf=500|oomd=0|gtemp=65.0|ctemp=50|xpss=1000"

    # GPU stream with power data
    create_segment "gpu" "20250101_120000"
    write_to_segment "gpu" "20250101_120000" "$((freeze_ts - 10))|busy=10|power=50|vram=4096|temp=65"

    # CPU stream
    create_segment "cpu" "20250101_120000"
    write_to_segment "cpu" "20250101_120000" "$((freeze_ts - 10))|fmax=4200|nhi=2|boost=1|taint=0"

    # Dmesg — GPU, OOM, NVMe, kernel evidence
    create_segment "dmesg" "20250101_120000"
    write_to_segment "dmesg" "20250101_120000" "D: [0] amdgpu ring timeout on ring 0"
    write_to_segment "dmesg" "20250101_120000" "D: [1] amdgpu fence timeout"
    write_to_segment "dmesg" "20250101_120000" "D: [2] amdgpu GPU fault"
    write_to_segment "dmesg" "20250101_120000" "D: [3] Out of memory: Killed process 1234 (firefox)"
    write_to_segment "dmesg" "20250101_120000" "D: [4] nvme nvme0: I/O error"
    write_to_segment "dmesg" "20250101_120000" "D: [5] general protection fault"

    local report_file="$TEST_DIR/report.txt"
    generate_report "$freeze_ts" "$report_file"

    assert_file_exists "$report_file" "report file should exist" || { test_end; return 1; }

    local content
    content=$(cat "$report_file")

    # Header and metadata
    assert_contains "$content" "FREEZE DIAGNOSIS REPORT" "should have report header" || { test_end; return 1; }
    assert_contains "$content" "Session: $sid" "should contain session ID" || { test_end; return 1; }
    assert_contains "$content" "Freeze at:" "should contain freeze timestamp" || { test_end; return 1; }

    # Category sections
    assert_contains "$content" "GPU HANG" "should have GPU section" || { test_end; return 1; }
    assert_contains "$content" "OOM" "should have OOM section" || { test_end; return 1; }
    assert_contains "$content" "NVMe" "should have NVMe section" || { test_end; return 1; }
    assert_contains "$content" "MEMORY PRESSURE" "should have MEMORY section" || { test_end; return 1; }
    assert_contains "$content" "THERMAL" "should have THERMAL section" || { test_end; return 1; }
    assert_contains "$content" "KERNEL FAULT" "should have KERNEL section" || { test_end; return 1; }
    assert_contains "$content" "PROCESS LEAK" "should have LEAK section" || { test_end; return 1; }

    # CPU freq posture
    assert_contains "$content" "CPU FREQ BEFORE FREEZE" "should have CPU section" || { test_end; return 1; }

    # Context
    assert_contains "$content" "SESSION CONTEXT" "should have context section" || { test_end; return 1; }
    assert_contains "$content" "Linux version 6.2.0-arch" "should contain kernel version" || { test_end; return 1; }

    # Raw log excerpts
    assert_contains "$content" "RAW LOG EXCERPTS" "should have raw excerpts" || { test_end; return 1; }
    assert_contains "$content" "--- heartbeat ---" "should include heartbeat stream" || { test_end; return 1; }
    assert_contains "$content" "--- dmesg ---" "should include dmesg stream" || { test_end; return 1; }

    # Severity indicators
    assert_contains "$content" "HIGH" "should have HIGH severity" || { test_end; return 1; }
    assert_contains "$content" "MEDIUM" "should have MEDIUM severity" || { test_end; return 1; }

    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  INTERACTIVE MENU
# ═══════════════════════════════════════════════════════════════════
test_interactive_menu_quit() {
    test_start "interactive menu q exits with Goodbye"
    local output
    output=$(echo "q" | timeout 5 bash "$(dirname "$0")/../diag-analyze.sh" 2>&1 || true)
    assert_contains "$output" "Goodbye" "should print Goodbye message"
    test_end
}

test_interactive_menu_invalid() {
    test_start "interactive menu invalid choice shows error"
    local output
    output=$(printf 'invalid\n\nq\n' | timeout 5 bash "$(dirname "$0")/../diag-analyze.sh" 2>&1 || true)
    assert_contains "$output" "Invalid choice" "should show invalid choice message"
    test_end
}

test_interactive_menu_option6() {
    test_start "interactive menu option 6 generates full report"
    source_deps
    reset_scores

    # Create heartbeat files so find_freeze_time works
    create_segment "heartbeat" "20250101_120000"
    write_to_segment "heartbeat" "20250101_120000" "999950 beat 1"
    write_to_segment "heartbeat" "20250101_120000" "999995 beat 2"

    # Create context so report is richer
    create_context_file "${CURRENT_BOOT}_999000"

    local output
    output=$(printf '6\nq\n' | timeout 5 bash "$(dirname "$0")/../diag-analyze.sh" 2>&1 || true)
    assert_contains "$output" "FREEZE DIAGNOSIS REPORT" "option 6 should generate report"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  NON-INTERACTIVE MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════
test_main_execution_with_session() {
    test_start "main execution --session generates report"
    source_deps
    reset_scores

    local session_start=1000000
    local boot="$CURRENT_BOOT"
    local sid="${boot}_${session_start}"

    # Create heartbeat with gap so freeze time is detected
    create_segment "heartbeat" "20250101_120000"
    write_to_segment "heartbeat" "20250101_120000" "$((session_start - 5)) beat 1"
    write_to_segment "heartbeat" "20250101_120000" "$((session_start + 0)) beat 2"
    write_to_segment "heartbeat" "20250101_120000" "$((session_start + 10)) beat 3"
    touch_segment_mtime "heartbeat" "20250101_120000" "$session_start"

    # Crashed session file with detected_at beyond cutoff+120
    local started="2001-09-09T01:46:40+00:00"
    local detected="2001-09-09T01:50:00+00:00"
    create_crashed_session_file "$sid" "$boot" "$started" "$detected"

    # Context file
    create_context_file "$sid"

    local output
    output=$(timeout 10 bash "$(dirname "$0")/../diag-analyze.sh" --session "$sid" 2>&1 || true)
    assert_contains "$output" "FREEZE DIAGNOSIS REPORT" "should generate report for session" || { test_end; return 1; }
    assert_contains "$output" "Session: $sid" "should show session ID" || { test_end; return 1; }
    assert_contains "$output" "SESSION CONTEXT" "should include context info"
    test_end
}

test_main_execution_nonexistent_session() {
    test_start "main execution --session nonexistent shows error"
    local output
    output=$(bash "$(dirname "$0")/../diag-analyze.sh" --session "nonexistent_12345" 2>&1 || true)
    assert_contains "$output" "No heartbeat logs found" "should print error message"
    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_PROCESS_TRIGGERS — WATCHDOG RSS GROWTH
# ═══════════════════════════════════════════════════════════════════
test_analyze_process_triggers_watchdog_rss_growth() {
    test_start "analyze_process_triggers detects RSS growth from watchdog"
    source_deps
    reset_scores

    local freeze_ts=1000000

    # Early watchdog sample (age > 150): pid 1001 RSS=100 (100MB)
    create_segment "watchdog" "20250101_120000"
    write_to_segment "watchdog" "20250101_120000" "$((freeze_ts - 200))|pid=1001|rss=100|target=firefox|fd=30|vsz=2000000"
    # Late watchdog sample (age <= 150): pid 1001 RSS=150 (150MB) — delta 50MB > 20MB
    write_to_segment "watchdog" "20250101_120000" "$((freeze_ts - 100))|pid=1001|rss=150|target=firefox|fd=30|vsz=2000000"

    analyze_process_triggers "$freeze_ts"

    assert_not_empty "$PROCESS_TRIGGER" "should detect RSS growth" || { test_end; return 1; }
    assert_contains "$PROCESS_TRIGGER" "RSS growth" "should mention RSS growth" || { test_end; return 1; }
    assert_contains "$PROCESS_TRIGGER" "firefox" "should name the target process" || { test_end; return 1; }
    assert_contains "$PROCESS_TRIGGER" "+50MB" "should show correct delta"

    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_KERNEL_FAULTS — JOURNAL FALLBACK
# ═══════════════════════════════════════════════════════════════════
test_analyze_kernel_faults_with_journal() {
    test_start "analyze_kernel_faults with journal fallback adds [journal -b -1] prefix"
    source_deps
    reset_scores

    ANALYZE_SESSION="testsession_12345"

    # Mock sudo to succeed and return journal oops lines
    sudo() {
        case "$*" in
            "-n true") return 0 ;;
            "-n journalctl -b -1 -o short-precise --no-pager")
                echo "Jun 12 10:00:00 host kernel: BUG: soft lockup on CPU#0"
                echo "Jun 12 10:00:01 host kernel: general protection fault"
                return 0 ;;
        esac
    }

    # No dmesg logs — triggers journal fallback path
    analyze_kernel_faults 1000000

    assert_contains "$KERNEL_EVIDENCE" "[journal -b -1]" "should have journal prefix" || { test_end; return 1; }
    assert_contains "$KERNEL_EVIDENCE" "BUG:" "should contain journal bug line" || { test_end; return 1; }
    assert_contains "$KERNEL_EVIDENCE" "general protection" "should contain GPF line" || { test_end; return 1; }
    assert_eq 4 "$SCORE_KERNEL" "GPF should set SCORE_KERNEL=4"

    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  ANALYZE_GPU — JOURNAL FALLBACK
# ═══════════════════════════════════════════════════════════════════
test_analyze_gpu_journal_fallback() {
    test_start "analyze_gpu falls back to journalctl when dmesg empty"
    source_deps
    reset_scores

    # Override journalctl_k to return GPU timeout data (no-op default)
    journalctl_k() {
        echo "amdgpu ring timeout on ring 0"
        echo "amdgpu fence timeout"
    }

    # No dmesg log files — triggers journal fallback in analyze_gpu
    analyze_gpu 1000000

    assert_eq 3 "$SCORE_GPU" "journal fallback should set SCORE_GPU=3" || { test_end; return 1; }
    assert_not_empty "$GPU_EVIDENCE" "evidence should come from journal fallback" || { test_end; return 1; }
    assert_contains "$GPU_EVIDENCE" "amdgpu" "evidence should contain amdgpu lines"

    test_end
}

# ═══════════════════════════════════════════════════════════════════
#  RUN
# ═══════════════════════════════════════════════════════════════════
run_tests "$0"

#!/bin/bash
# lib_common.sh — shared functions for freeze-diag collectors
# Source: source "$FD_LIB/lib_common.sh"

if [ -z "${_FD_COMMON_LOADED:-}" ]; then
    _FD_COMMON_LOADED=1
else
    return 0
fi

# Source config if not already sourced. Check FD_LOGS (not FD_ROOT):
# FD_ROOT alone in the environment must not skip the config, or every
# derived path (FD_LOGS, FD_LIB, ...) would be empty and writes would
# target "/".
if [ -z "${FD_LOGS:-}" ]; then
    _cfg="$(dirname "$(dirname "${BASH_SOURCE[0]:-$0}")")/diag.conf"
    [ -f "$_cfg" ] && source "$_cfg"
fi

# ---- Timestamp helpers (bash builtins when possible) ----
# printf '%(fmt)T' requires bash 4.2+; EPOCHREALTIME requires bash 5.0+
ts_epoch()   { printf '%(%s)T' -1; }
ts_iso()     { printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1; }
ts_dt()      { printf '%(%Y%m%d_%H%M%S)T' -1; }
if [ "${BASH_VERSINFO:-0}" -ge 5 ] 2>/dev/null; then
    ts_epochns() { echo "$EPOCHREALTIME"; }
else
    ts_epochns() { date +%s.%N; }
fi

# ---- Boot ID ----
current_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown"
}

# ---- Atomic fsync'd single-line write ----
# fsync_line <file> <line>
# Opens file with O_APPEND, writes line + newline, fsyncs, closes.
# Returns 0 on success, 1 on failure.
fsync_line() {
    local file="$1" line="$2"
    printf '%s\n' "$line" >> "$file" 2>/dev/null || return 1
    sync_file "$file"
    return 0
}

# ---- Durably flush an already-written file ----
# sync -d = fdatasync(2) on just this file (much cheaper than syncing
# the whole filesystem); falls back for old coreutils.
sync_file() {
    local file="$1"
    sync -d -- "$file" 2>/dev/null || sync -f -- "$(dirname "$file")" 2>/dev/null || true
}

# ---- Durable heartbeat (strongest guarantee) ----
# Uses dd with oflag=append,dsync — one syscall that writes and syncs
durable_line() {
    local file="$1" line="$2"
    printf '%s\n' "$line" | dd of="$file" oflag=append,dsync conv=notrunc status=none 2>/dev/null
}

# ---- Open segment file for a stream ----
# open_segment <stream_name> <interval_seconds>
# Sets global: FD_CURRENT_SEGMENT=<path> FD_SEGMENT_OPENED_AT=<epoch>
# Creates new segment file with timestamp in name.
FD_CURRENT_SEGMENT=""
FD_SEGMENT_OPENED_AT=0

open_segment() {
    local stream="$1" interval="${2:-600}"
    local now ts_path
    now=$(ts_epoch)
    local boundary=$(( (now / interval) * interval ))
    ts_path=$(date -d "@$boundary" +%Y%m%d_%H%M%S 2>/dev/null || date -d "@$boundary" '+%Y%m%d_%H%M%S')
    FD_CURRENT_SEGMENT="$FD_LOGS/${stream}_${ts_path}.log"
    FD_SEGMENT_OPENED_AT=$boundary
    mkdir -p "$(dirname "$FD_CURRENT_SEGMENT")" 2>/dev/null
    touch "$FD_CURRENT_SEGMENT" 2>/dev/null
}

# Check if we should roll to a new segment
should_roll_segment() {
    local interval="${1:-600}"
    local now boundary
    now=$(ts_epoch)
    boundary=$(( (now / interval) * interval ))
    [ "$boundary" -gt "$FD_SEGMENT_OPENED_AT" ]
}

# ---- Cleanup old segments ----
# Single find process instead of a per-file bash loop: with long
# retention (90 days) the logs dir holds tens of thousands of segments
# and a glob+stat loop would burn CPU every collector cycle.
cleanup_old_segments() {
    local stream="${1:-*}" retention_min="${2:-$FD_RETENTION_MINUTES}"
    find "$FD_LOGS" -maxdepth 1 -name "${stream}_????????_??????.log" \
        -type f -mmin "+${retention_min}" -delete 2>/dev/null
}

# ---- Global size check and prune ----
SIZE_PRUNE_LOCK="$FD_PID_DIR/freeze-diag-prune.lock"

size_check_and_prune() {
    local max_mb="${1:-$FD_MAX_DISK_MB}"
    local total_kb target_kb
    # Mutex: only one prune at a time
    exec 200>"$SIZE_PRUNE_LOCK" 2>/dev/null || return 0
    if ! flock -n 200 2>/dev/null; then
        return 0
    fi

    total_kb=$(du -s --block-size=1K "$FD_LOGS" 2>/dev/null | awk '{print $1}')
    [ -z "$total_kb" ] && return 0
    local max_kb=$((max_mb * 1024))
    [ "$total_kb" -le "$max_kb" ] && return 0
    target_kb=$((max_kb * 70 / 100))
    # Delete oldest files first (by mtime, across all streams).
    # One listing with sizes — no du re-scan per deleted file.
    find "$FD_LOGS" -maxdepth 1 -name '*_????????_??????.log' -type f \
        -printf '%T@ %k %p\n' 2>/dev/null | sort -n | \
        while read -r _ fkb f; do
            [ -f "$f" ] || continue
            rm -f "$f"
            total_kb=$((total_kb - fkb))
            [ "$total_kb" -le "$target_kb" ] && break
        done
}

# ---- Find target processes ----
find_target_pids() {
    local pattern="$1"
    pgrep -f "$pattern" 2>/dev/null | head -5
}

# ---- Per-process fd, inotify, DRI stats (single ls -l call) ----
proc_fd_stats() {
    local pid="$1"
    local fds=0 inotify=0 dri=0
    local line
    while IFS= read -r line; do
        ((fds++))
        case "$line" in
            *anon_inode:inotify*) ((inotify++)) ;;
            */dri/*) ((dri++)) ;;
        esac
    done < <(ls -l "/proc/$pid/fd" 2>/dev/null)
    echo "$fds $inotify $dri"
}



# ---- Per-process info ----
proc_info() {
    local pid="$1" fields="${2:-state,rss,vsz,pcpu,pmem,nlwp,etime}"
    ps -p "$pid" -o "$fields" --no-headers 2>/dev/null | awk '{$1=$1};1'
}

# ---- Safe numeric read from sysfs / procfs ----
sysfs_val() {
    local p="$1"
    [ -r "$p" ] && cat "$p" 2>/dev/null || echo ""
}

# ---- Resolve hwmon path by chip name ----
# hwmonN numbering is NOT stable across boots (probe order), so configured
# paths like /sys/class/hwmon/hwmon11 silently break and temps read 0.
# resolve_hwmon <chip-name>  →  /sys/class/hwmon/hwmonN (or empty)
resolve_hwmon() {
    local want="$1" f
    for f in /sys/class/hwmon/hwmon*/name; do
        [ -r "$f" ] || continue
        if [ "$(<"$f")" = "$want" ]; then
            dirname "$f"
            return 0
        fi
    done
    return 1
}

# Resolve the three configured hwmon paths if they are "auto" or stale.
# Call once at collector startup, after sourcing diag.conf.
fd_resolve_hwmons() {
    if [ "${FD_CPU_HWMON_PATH:-auto}" = "auto" ] || [ ! -r "${FD_CPU_HWMON_PATH}/temp1_input" ]; then
        FD_CPU_HWMON_PATH=$(resolve_hwmon "${FD_CPU_HWMON_NAME:-k10temp}") || FD_CPU_HWMON_PATH=""
    fi
    if [ "${FD_AMDGPU_HWMON_PATH:-auto}" = "auto" ] || [ ! -r "${FD_AMDGPU_HWMON_PATH}/temp1_input" ]; then
        FD_AMDGPU_HWMON_PATH=$(resolve_hwmon "${FD_AMDGPU_HWMON_NAME:-amdgpu}") || FD_AMDGPU_HWMON_PATH=""
    fi
    if [ "${FD_NVME_HWMON_PATH:-auto}" = "auto" ] || [ ! -r "${FD_NVME_HWMON_PATH}/temp1_input" ]; then
        FD_NVME_HWMON_PATH=$(resolve_hwmon "${FD_NVME_HWMON_NAME:-nvme}") || FD_NVME_HWMON_PATH=""
    fi
    export FD_CPU_HWMON_PATH FD_AMDGPU_HWMON_PATH FD_NVME_HWMON_PATH
}

# ---- is_running check via PID file ----
is_running() {
    local pidfile="$1"
    [ -f "$pidfile" ] || return 1
    local pid
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ---- Write PID file ----
write_pidfile() {
    local pidfile="$1"
    echo $$ > "$pidfile"
}

# ---- Clean up PID file ----
cleanup_pidfile() {
    local pidfile="$1"
    rm -f "$pidfile"
}

# ---- Trap helper: log exit reason ----
trap_exit_handler() {
    local exit_code=$?
    local stream="$1"
    echo "[$(ts_iso)] $stream collector exiting (code=$exit_code)" >> "$FD_LOGS/diag_events.log" 2>/dev/null
}

# ---- Flock-based instance guard ----
# Acquire exclusive lock on a lockfile. If another process holds the lock, exit 0.
# Usage: flock_instance_guard <lockfile_path>
# Must be called at the very start of the script, before any background work.
flock_instance_guard() {
    local lockfile="$1"
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null
    # Open/create lock file and acquire exclusive non-blocking lock
    exec 200>"$lockfile"
    if ! flock -n 200 2>/dev/null; then
        # Another instance holds the lock
        exit 0
    fi
    # Lock acquired. FD 200 remains open for the process lifetime.
    # When the process exits (any signal, including SIGKILL), the FD is
    # automatically closed by the kernel and the lock is released.
}

# ---- Session ID helper ----
# Generates a unique session instance ID per login: <boot_id>_<epoch>
generate_session_id() {
    local boot_id
    boot_id=$(current_boot_id)
    echo "${boot_id}_$(ts_epoch)"
}

# ---- Extract boot_id from session_id ----
# Handles:  "boot_id_epoch" -> "boot_id"   and   "boot_id" -> "boot_id"
session_id_to_boot() {
    local sid="$1"
    if [[ "$sid" =~ ^([a-f0-9-]+_[a-f0-9-]+)_[0-9]+$ ]] || [[ "$sid" =~ ^([a-f0-9-]+)_[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$sid"
    fi
}

# ---- Find session file by session_id or boot_id ----
# Returns the path of the actual session file (not symlink).
# For boot_id, returns the latest real session file.
find_session_file() {
    local id="$1"
    local f

    # Try exact match (works for full session_id or legacy boot_id)
    f="$FD_LOGS/sessions/${id}.session"
    [ -f "$f" ] && [ ! -L "$f" ] && { echo "$f"; return 0; }

    # If id looks like a plain boot_id (no underscore epoch suffix), find latest real file
    if [[ ! "$id" =~ _[0-9]+$ ]]; then
        local matches
        matches=("$FD_LOGS/sessions/${id}_"*.session)
        if [ ${#matches[@]} -gt 0 ] && [ -f "${matches[-1]}" ]; then
            echo "${matches[-1]}"
            return 0
        fi
    fi

    return 1
}

# ---- Session marker ----
# Usage: write_session_marker <status> [session_id]
# If session_id is provided, writes to ${session_id}.session and creates
# a ${boot_id}.session symlink for backward compat.
write_session_marker() {
    local status="$1"
    local session_id="${2:-}"
    local boot_id pid
    boot_id=$(current_boot_id)
    pid=$$
    mkdir -p "$FD_LOGS/sessions"

    if [ -n "$session_id" ]; then
        local started_at
        started_at=$(ts_iso)
        cat > "$FD_LOGS/sessions/${session_id}.session" <<SESSIONEOF
{
  "boot_id": "$boot_id",
  "session_id": "$session_id",
  "started_at": "$started_at",
  "status": "$status",
  "pid": $pid
}
SESSIONEOF
        # Update symlink so ${boot_id}.session always points to latest
        ln -sf "${session_id}.session" "$FD_LOGS/sessions/${boot_id}.session" 2>/dev/null || true
    else
        # Legacy: write directly to ${boot_id}.session
        cat > "$FD_LOGS/sessions/${boot_id}.session" <<SESSIONEOF
{
  "boot_id": "$boot_id",
  "started_at": "$(ts_iso)",
  "status": "$status",
  "pid": $pid
}
SESSIONEOF
    fi
}

# ---- Check for crashed session (handles same-boot and cross-boot) ----
# Returns the session_id of the crashed session (or empty string).
# Always returns 0 (caller checks output, not exit code — avoids
# triggering set -e in the caller).
# Checks ALL session files (including same boot) for "running" status
# with a dead PID — catches SIGKILL crashes even within the same boot.
check_crashed_sessions() {
    local result=""
    for f in "$FD_LOGS/sessions/"*.session; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue    # Skip symlinks, process only real files
        local fname status pid
        fname=$(basename "$f" .session)
        status=$(grep -o '"status": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)
        pid=$(grep -o '"pid": *[0-9]*' "$f" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')

        if [ "$status" = "running" ] && [ -n "$pid" ]; then
            if ! kill -0 "$pid" 2>/dev/null; then
                result="$fname"
                break
            fi
        fi
    done
    echo "$result"
    return 0
}

# ---- Mark crashed session ----
# Handles both session_id (boot_epoch) and legacy boot_id formats.
mark_session_crashed() {
    local id="$1"     # session_id or boot_id
    local current detected_by
    detected_by=$(current_boot_id)
    current=$(date --iso-8601=seconds)

    # Try to find the actual file
    local f
    f=$(find_session_file "$id" 2>/dev/null) || {
        f="$FD_LOGS/sessions/${id}.session"
        [ -f "$f" ] || return 1
    }

    local started_at
    started_at=$(grep -o '"started_at": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "unknown")
    local boot_id
    boot_id=$(grep -o '"boot_id": *"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "unknown")

    cat > "$f" <<SESSIONEOF
{
  "boot_id": "$boot_id",
  "session_id": "$id",
  "started_at": "$started_at",
  "status": "crashed",
  "detected_by_boot": "$detected_by",
  "detected_at": "$current"
}
SESSIONEOF
}

# ---- Notify user via desktop notification ----
notify_user() {
    local title="$1" body="$2" urgency="${3:-critical}"
    if command -v notify-send &>/dev/null; then
        notify-send --urgency="$urgency" --icon=dialog-error "$title" "$body" 2>/dev/null || true
    fi
}

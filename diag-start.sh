#!/bin/bash
# diag-start.sh — freeze-diag launcher / installer
# Usage:
#   diag-start.sh                Launch collectors (called by systemd or manually)
#   diag-start.sh --install      One-time setup: sudoers, systemd enable, start
#   diag-start.sh --help         Show usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/diag.conf"

# ---- Handle --install before sourcing lib_common (avoids PID lock conflict) ----
if [ "${1:-}" = "--install" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║      FREEZE DIAGNOSIS — ONE-TIME INSTALLER      ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    SUDOERS_SRC="$SCRIPT_DIR/sudoers-freeze-diag"
    SUDOERS_DST="/etc/sudoers.d/freeze-diag"
    SERVICE_SRC="$SCRIPT_DIR/freeze-diag.service"
    SERVICE_DST="$SYSTEMD_DIR/freeze-diag.service"

    # ---- Step 1: Install sudoers ----
    echo "── Step 1/4: sudoers drop-in ──"
    if [ -f "$SUDOERS_DST" ]; then
        echo "  [SKIP] Already installed: $SUDOERS_DST"
    else
        if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
            echo "  Installing $SUDOERS_DST ..."
            if [ "$(id -u)" -eq 0 ]; then
                cp "$SUDOERS_SRC" "$SUDOERS_DST"
            else
                sudo cp "$SUDOERS_SRC" "$SUDOERS_DST"
            fi
            sudo chmod 0440 "$SUDOERS_DST"
            echo "  [OK] Installed. Allows passwordless: dmesg, journalctl, tee debug_mask"
        else
            echo "  [WARN] sudo required but not available."
            echo "         Run manually as root:"
            echo "         cp $SUDOERS_SRC $SUDOERS_DST"
            echo "         chmod 0440 $SUDOERS_DST"
        fi
    fi

    # Verify sudoers works
    if sudo -n dmesg > /dev/null 2>&1; then
        echo "  [OK] sudo dmesg works — kernel log capture enabled"
    else
        echo "  [INFO] sudo dmesg not available — kernel capture will be disabled"
        echo "         (collectors still run fine without it)"
    fi

    # ---- Install pstore dump helper (root-owned) ----
    PSTORE_SRC="$SCRIPT_DIR/bin/fd-pstore-dump"
    PSTORE_DST="${FD_PSTORE_DUMP_BIN:-/usr/local/bin/fd-pstore-dump}"
    if [ -f "$PSTORE_SRC" ]; then
        if cmp -s "$PSTORE_SRC" "$PSTORE_DST" 2>/dev/null; then
            echo "  [SKIP] pstore helper up-to-date: $PSTORE_DST"
        elif sudo -n true 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
            sudo cp "$PSTORE_SRC" "$PSTORE_DST"
            sudo chown root:root "$PSTORE_DST"
            sudo chmod 0755 "$PSTORE_DST"
            echo "  [OK] Installed $PSTORE_DST (panic records become harvestable)"
        else
            echo "  [WARN] Could not install $PSTORE_DST (needs sudo). Run manually:"
            echo "         sudo cp $PSTORE_SRC $PSTORE_DST && sudo chmod 0755 $PSTORE_DST"
        fi
    fi
    echo ""

    # ---- Step 2: Install systemd user service ----
    echo "── Step 2/4: systemd user service ──"
    mkdir -p "$SYSTEMD_DIR"

    if [ -f "$SERVICE_DST" ]; then
        if cmp -s "$SERVICE_SRC" "$SERVICE_DST" 2>/dev/null; then
            echo "  [SKIP] Already installed and up-to-date: $SERVICE_DST"
        else
            echo "  Updating $SERVICE_DST ..."
            cp "$SERVICE_SRC" "$SERVICE_DST"
            echo "  [OK] Updated"
        fi
    else
        echo "  Installing $SERVICE_DST ..."
        cp "$SERVICE_SRC" "$SERVICE_DST"
        echo "  [OK] Installed"
    fi
    echo ""

    # ---- Step 3: Reload and enable ----
    echo "── Step 3/4: enable and start ──"
    systemctl --user daemon-reload

    if systemctl --user is-enabled freeze-diag.service > /dev/null 2>&1; then
        echo "  [SKIP] Service already enabled"
    else
        systemctl --user enable freeze-diag.service
        echo "  [OK] Service enabled — auto-starts at login"
    fi

    if systemctl --user is-active freeze-diag.service > /dev/null 2>&1; then
        echo "  [SKIP] Service already running"
    else
        systemctl --user start freeze-diag.service
        echo "  [OK] Service started — collectors are now running"
    fi
    echo ""

    # ---- Step 4: Verification ----
    echo "── Step 4/4: verify ──"
    sleep 2
    if systemctl --user is-active freeze-diag.service > /dev/null 2>&1; then
        echo "  [OK] freeze-diag.service is ACTIVE"
        echo ""
        echo "  Log files: $FD_LOGS"
        echo "  Live view: tail -f $FD_LOGS/diag_events.log"
        echo "  Analysis:  $SCRIPT_DIR/diag-analyze.sh"
    else
        echo "  [FAIL] Service did not start. Check:"
        echo "         journalctl --user -u freeze-diag.service -n 30"
    fi
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "Install complete. System is now monitoring."
    echo "══════════════════════════════════════════════════"
    echo ""
    exit 0
fi

# ---- Handle --uninstall ----
if [ "${1:-}" = "--uninstall" ]; then
    PURGE_LOGS=false
    [ "${2:-}" = "--purge" ] && PURGE_LOGS=true

    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║       FREEZE DIAGNOSIS — UNINSTALLER           ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    SUDOERS_DST="/etc/sudoers.d/freeze-diag"
    SERVICE_DST="$SYSTEMD_DIR/freeze-diag.service"
    SERVICE_NAME="freeze-diag.service"

    # ---- Step 1: Stop service ----
    echo "── Step 1/4: stop service ──"
    if systemctl --user is-active "$SERVICE_NAME" > /dev/null 2>&1; then
        systemctl --user stop "$SERVICE_NAME"
        echo "  [OK] Service stopped"
    else
        echo "  [SKIP] Service not running"
    fi

    # ---- Step 2: Disable and remove service ----
    echo "── Step 2/4: disable and remove systemd unit ──"
    if systemctl --user is-enabled "$SERVICE_NAME" > /dev/null 2>&1; then
        systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
        echo "  [OK] Service disabled"
    else
        echo "  [SKIP] Service not enabled"
    fi
    systemctl --user daemon-reload 2>/dev/null || true

    if [ -f "$SERVICE_DST" ]; then
        rm -f "$SERVICE_DST"
        echo "  [OK] Removed $SERVICE_DST"
    else
        echo "  [SKIP] Service file not found"
    fi
    echo ""

    # ---- Step 3: Remove sudoers ----
    echo "── Step 3/4: remove sudoers drop-in ──"
    if [ -f "$SUDOERS_DST" ]; then
        if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
            if [ "$(id -u)" -eq 0 ]; then
                rm -f "$SUDOERS_DST"
            else
                sudo rm -f "$SUDOERS_DST"
            fi
            echo "  [OK] Removed $SUDOERS_DST"
        else
            echo "  [WARN] sudo required but not available."
            echo "         Run manually as root:"
            echo "         rm -f $SUDOERS_DST"
        fi
    else
        echo "  [SKIP] sudoers file not installed"
    fi
    echo ""

    # ---- Step 4: Optional log purge ----
    echo "── Step 4/4: log files ──"
    if [ "$PURGE_LOGS" = true ]; then
        echo "  Removing logs, sessions, archives, and reports ..."
        rm -rf "$FD_LOGS" "$FD_ARCHIVE" "$FD_REPORTS" 2>/dev/null || true
        mkdir -p "$FD_LOGS/sessions" "$FD_ARCHIVE" "$FD_REPORTS"
        echo "  [OK] Logs purged"
    else
        if [ -d "$FD_LOGS" ] && ls "$FD_LOGS"/*.log > /dev/null 2>&1; then
            echo "  [SKIP] Logs preserved at $FD_LOGS"
            echo "         To remove them: $0 --uninstall --purge"
        else
            echo "  [SKIP] No logs to remove"
        fi
    fi

    # Clean PID files
    rm -f "$FD_PID_DIR"/freeze-diag-*.pid "$FD_PID_DIR"/freeze-diag-restart-*.count 2>/dev/null || true
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "Uninstall complete."
    if [ "$PURGE_LOGS" = false ]; then
        echo ""
        echo "The install directory remains at:"
        echo "  $SCRIPT_DIR"
        echo "Remove it manually when ready:"
        echo "  rm -rf $SCRIPT_DIR"
    fi
    echo "══════════════════════════════════════════════════"
    echo ""
    exit 0
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: diag-start.sh [--install | --uninstall | --help | (no args)]"
    echo ""
    echo "  (no args)     Launch all collectors (called by systemd)"
    echo "  --install     One-time setup: sudoers, systemd enable, start"
    echo "  --uninstall   Stop service, remove sudoers + systemd unit"
    echo "  --uninstall --purge  Also delete all logs and reports"
    echo "  --help        Show this message"
    echo ""
    echo "After install, manages itself via systemd:"
    echo "  systemctl --user status freeze-diag"
    echo "  systemctl --user stop   freeze-diag"
    echo "  systemctl --user start  freeze-diag"
    echo ""
    echo "Manual analysis after a freeze:"
    echo "  $SCRIPT_DIR/diag-analyze.sh            (interactive)"
    echo "  $SCRIPT_DIR/diag-analyze.sh --current --quick"
    exit 0
fi

source "$FD_LIB/lib_common.sh"

# ---- Unique session identifier (preserved across SIGKILL detection) ----
SESSION_ID=$(generate_session_id)
export SESSION_ID

mkdir -p "$FD_LOGS/sessions" "$FD_ARCHIVE" "$FD_REPORTS"

# ---- Prevent duplicate instances (flock, survives orphans) ----
MAIN_LOCKFILE="$FD_PID_DIR/freeze-diag-main.lock"
flock_instance_guard "$MAIN_LOCKFILE"
MAIN_PIDFILE="$FD_PID_DIR/freeze-diag-main.pid"
write_pidfile "$MAIN_PIDFILE"
# Persist SESSION_ID so diag-stop.sh can read it
echo "$SESSION_ID" > "$FD_PID_DIR/freeze-diag-session.id" 2>/dev/null || true

trap_cleanup() {
    echo "[$(date --iso-8601=seconds)] diag-start: shutting down" >> "$FD_LOGS/diag_events.log"
    # Stop all child collectors
    for pidf in "$FD_PID_DIR"/freeze-diag-*.pid; do
        [ -f "$pidf" ] || continue
        [ "$pidf" = "$MAIN_PIDFILE" ] && continue
        pid=$(cat "$pidf" 2>/dev/null) || continue
        kill "$pid" 2>/dev/null || true
        rm -f "$pidf"
    done
    # Mark this session as stopped so crash detection doesn't false-fire
    local sf
    sf=$(find_session_file "${SESSION_ID:-$CURRENT_BOOT}" 2>/dev/null) || sf="$FD_LOGS/sessions/${CURRENT_BOOT}.session"
    if [ -f "$sf" ]; then
        local started
        started=$(grep '"started_at"' "$sf" 2>/dev/null | sed 's/.*"started_at": *"\([^"]*\)".*/\1/' || echo "unknown")
        local bid
        bid=$(grep '"boot_id"' "$sf" 2>/dev/null | sed 's/.*"boot_id": *"\([^"]*\)".*/\1/' || echo "$CURRENT_BOOT")
        local sid
        sid=$(grep '"session_id"' "$sf" 2>/dev/null | sed 's/.*"session_id": *"\([^"]*\)".*/\1/' || echo "${SESSION_ID:-}")
        cat > "$sf" <<SESSIONEOF
{
  "boot_id": "$bid",
  "session_id": "$sid",
  "started_at": "$started",
  "status": "stopped",
  "stopped_at": "$(date --iso-8601=seconds)"
}
SESSIONEOF
    fi
    rm -f "$MAIN_PIDFILE"
    exit 0
}
trap trap_cleanup EXIT TERM INT

# ---- Session housekeeping ----
CURRENT_BOOT=$(current_boot_id)
echo "[$(ts_iso)] diag-start: boot=$CURRENT_BOOT session=$SESSION_ID pid=$$" >> "$FD_LOGS/diag_events.log"

# Write unique session marker (never overwrites previous crash data)
write_session_marker "running" "$SESSION_ID"

# ---- Boot context snapshot (once per session) ----
# Captures the platform state every post-crash RCA needs but no periodic
# collector records: kernel, cmdline, BIOS/microcode, boost, panic posture.
write_context_snapshot() {
    local ctx="$FD_LOGS/context_${SESSION_ID}.log"
    {
        echo "=== CONTEXT $(ts_iso) session=$SESSION_ID boot=$CURRENT_BOOT ==="
        echo "--- KERNEL ---"
        uname -a
        echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
        echo "tainted: $(cat /proc/sys/kernel/tainted 2>/dev/null)"
        echo "--- PLATFORM ---"
        for k in product_name board_name bios_version bios_date; do
            echo "$k: $(cat "/sys/class/dmi/id/$k" 2>/dev/null)"
        done
        echo "model: $(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
        echo "microcode: $(grep -m1 '^microcode' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
        echo "memtotal: $(grep -m1 MemTotal /proc/meminfo 2>/dev/null)"
        echo "--- CPU FREQ POSTURE ---"
        echo "boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
        echo "amd_pstate: $(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)"
        echo "governor: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"
        echo "max_khz: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)"
        echo "--- PANIC POSTURE (sysctl) ---"
        sysctl kernel.panic kernel.panic_on_oops kernel.softlockup_panic \
               kernel.hardlockup_panic kernel.hung_task_panic 2>/dev/null
        echo "--- AMDGPU MODULE PARAMS ---"
        for p in gpu_recovery lockup_timeout; do
            echo "$p: $(cat "/sys/module/amdgpu/parameters/$p" 2>/dev/null)"
        done
        echo "--- MODULES ---"
        lsmod 2>/dev/null | head -40
        echo "=== END CONTEXT ==="
    } > "$ctx" 2>/dev/null
    sync_file "$ctx"
}
write_context_snapshot

# Check for crashed previous session (handles same-boot and cross-boot)
CRASHED_SESSION=$(check_crashed_sessions)
if [ -n "$CRASHED_SESSION" ]; then
    echo "[$(ts_iso)] diag-start: CRASHED session detected: $CRASHED_SESSION" >> "$FD_LOGS/diag_events.log"
    # Run diag-report.sh in background (don't block startup)
    (
        bash "$SCRIPT_DIR/diag-report.sh" --session "$CRASHED_SESSION" 2>&1 >> "$FD_LOGS/diag_events.log"
    ) &
fi

# ---- Launch collectors ----
COLLECTORS=(
    "heartbeat:$FD_LIB/collector_heartbeat.sh"
    "fast:$FD_LIB/collector_fast.sh"
    "gpu:$FD_LIB/collector_gpu.sh"
    "cpu:$FD_LIB/collector_cpu.sh"
    "watchdog:$FD_LIB/collector_watchdog.sh"
    "detailed:$FD_LIB/collector_detailed.sh"
    "dmesg:$FD_LIB/collector_dmesg.sh"
)

COLLECTOR_PIDS=()
for entry in "${COLLECTORS[@]}"; do
    name="${entry%%:*}"
    script="${entry##*:}"
    if [ -x "$script" ] || [ -f "$script" ]; then
        bash "$script" &
        cpid=$!
        COLLECTOR_PIDS+=("$cpid")
        echo "[$(ts_iso)] diag-start: launched $name (pid=$cpid)" >> "$FD_LOGS/diag_events.log"
    else
        echo "[$(ts_iso)] diag-start: SKIP $name - script not found: $script" >> "$FD_LOGS/diag_events.log"
    fi
done

echo "[$(ts_iso)] diag-start: all collectors launched (${#COLLECTOR_PIDS[@]} total)" >> "$FD_LOGS/diag_events.log"

# ---- Monitor children, restart if they die ----
# Per-collector restart counters, stored as /tmp/freeze-diag-restart-<name>.count

while true; do
    sleep 10

    # Check if we should still be running
    if [ ! -f "$MAIN_PIDFILE" ]; then
        echo "[$(ts_iso)] diag-start: PID file removed, exiting" >> "$FD_LOGS/diag_events.log"
        break
    fi

    # Check each collector
    for entry in "${COLLECTORS[@]}"; do
        name="${entry%%:*}"
        script="${entry##*:}"
        pidf="$FD_PID_DIR/freeze-diag-$name.pid"

        if [ -f "$pidf" ]; then
            cpid=$(cat "$pidf" 2>/dev/null || echo "")
            if [ -n "$cpid" ] && ! kill -0 "$cpid" 2>/dev/null; then
                # Collector died — per-collector restart counter
                restart_file="$FD_PID_DIR/freeze-diag-restart-$name.count"
                RC=$(cat "$restart_file" 2>/dev/null || echo 0)
                RC=$((RC + 1))
                echo "[$(ts_iso)] diag-start: $name died (pid=$cpid), restart #$RC" >> "$FD_LOGS/diag_events.log"
                if [ "$RC" -le 5 ]; then
                    echo "$RC" > "$restart_file"
                    rm -f "$pidf"
                    bash "$script" &
                else
                    echo "[$(ts_iso)] diag-start: $name exceeded restart limit ($RC), stopping" >> "$FD_LOGS/diag_events.log"
                fi
            fi
        fi
    done
done

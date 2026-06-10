#!/bin/bash
# diag-stop.sh — clean shutdown for freeze-diag
# Sends SIGTERM to all running collectors and main process.
# Updates session marker to "stopped".

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/diag.conf"
source "$FD_LIB/lib_common.sh"

echo "[$(date --iso-8601=seconds)] diag-stop: stopping all collectors" >> "$FD_LOGS/diag_events.log"

# Kill all collector PIDs
for pidf in "$FD_PID_DIR"/freeze-diag-*.pid; do
    [ -f "$pidf" ] || continue
    pid=$(cat "$pidf" 2>/dev/null) || continue
    kill "$pid" 2>/dev/null || true
    rm -f "$pidf"
done

# Read session_id from file (written by diag-start.sh)
SESSION_ID=$(cat "$FD_PID_DIR/freeze-diag-session.id" 2>/dev/null || echo "")
CURRENT_BOOT=$(current_boot_id)
SESSION_FILE=$(find_session_file "${SESSION_ID:-$CURRENT_BOOT}" 2>/dev/null) || SESSION_FILE="$FD_LOGS/sessions/${CURRENT_BOOT}.session"
if [ -f "$SESSION_FILE" ]; then
    STARTED_AT=$(grep '"started_at"' "$SESSION_FILE" 2>/dev/null | sed 's/.*"started_at": *"\([^"]*\)".*/\1/' || echo "unknown")
    BOOT_ID=$(grep '"boot_id"' "$SESSION_FILE" 2>/dev/null | sed 's/.*"boot_id": *"\([^"]*\)".*/\1/' || echo "$CURRENT_BOOT")
    SID=$(grep '"session_id"' "$SESSION_FILE" 2>/dev/null | sed 's/.*"session_id": *"\([^"]*\)".*/\1/' || echo "${SESSION_ID:-}")
    cat > "$SESSION_FILE" <<SESSIONEOF
{
  "boot_id": "$BOOT_ID",
  "session_id": "$SID",
  "started_at": "$STARTED_AT",
  "status": "stopped",
  "stopped_at": "$(date --iso-8601=seconds)"
}
SESSIONEOF
fi

# Small wait for processes to die gracefully
sleep 2

# Force kill any remaining
for pidf in "$FD_PID_DIR"/freeze-diag-*.pid; do
    [ -f "$pidf" ] || continue
    pid=$(cat "$pidf" 2>/dev/null) || continue
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$pidf"
done

echo "[$(date --iso-8601=seconds)] diag-stop: done" >> "$FD_LOGS/diag_events.log"

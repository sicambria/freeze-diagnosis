# Duplicate collector instances caused by PID file race on service restart

**Date:** 2026-06-09  
**Area:** tooling  
**Severity:** high — causes duplicate log writes, potential data corruption
**Fix commit:** `825ce34`

## Summary

When systemd restarts the freeze-diag service (e.g. during package update, crash, or manual restart), orphaned collector processes from the old instance could survive and continue writing to log files alongside the new instance's collectors. This produced duplicate heartbeat sequences (two counter streams interleaved in the same file) and corrupted log file endings (null bytes).

## Evidence

The `heartbeat_20260609_193000.log` file contained 1138 lines — exactly **double** the expected ~569 for a 574-second segment. Two distinct counter sequences ran in parallel:

| Sequence | Counter Range | Entries |
|----------|--------------|---------|
| A | 9569 → 10137 | 568 |
| B | 10180 → 10748 | 568 |
| Both | same 574s window | 1138 total |

GPU and watchdog logs had null bytes (`\x00`) at their ends — evidence of concurrent writes colliding.

## Timeline

- `16:48:23` — Boot `<BOOT-A>` starts, collectors launch  
- `16:48:33` — First service restart: trap_cleanup kills children by PID, orphans survive  
- `16:48:43` — Second startup (same boot ID): new collectors launch, orphans still present  
- `19:39:34` — System freezes

The duplicate processes ran for **~2h51m** before the freeze.

## Root Cause

The PID-file-based instance guard was insufficient:

1. `trap_cleanup` sends SIGTERM to child PIDs listed in PID files
2. A child stuck in D-state (uninterruptible I/O sleep) can't respond to SIGTERM
3. The main process exits, cleaning up the PID file
4. The new main process starts — PID file doesn't exist → no guard → starts new collectors
5. Old orphan exits D-state and continues writing alongside the new instance

## Fix

Replaced PID file checks with `flock(2)`-based instance guards:

```bash
flock_instance_guard() {
    local lockfile="$1"
    exec 200>"$lockfile"          # open/create lock file
    flock -n 200 || exit 0        # non-blocking exclusive lock
    # FD 200 stays open for process lifetime.
    # On process exit (any signal, any cause), kernel closes FD 200,
    # releasing the lock atomically. No race, no orphan survivability.
}
```

Every collector and the main launcher now uses `flock_instance_guard()` as the **primary** instance guard before reaching PID file logic.

## Files affected

- `lib/lib_common.sh` — added `flock_instance_guard()`
- `diag-start.sh` — replaced PID file check with `flock_instance_guard`
- `lib/collector_*.sh` (all 6) — added `flock_instance_guard()` at startup

## Prevention

- Never rely solely on PID files for instance guards — `flock` is kernel-enforced and survives process crashes
- All collector locks are now file-descriptor-based; the kernel releases them on process death regardless of exit path

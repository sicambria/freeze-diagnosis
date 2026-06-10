# freeze-diag — Linux System Freeze Diagnosis Toolkit

Zero-dependency Bash toolkit that continuously records system state to disk. After a hard freeze and reboot, pinpoints root cause (GPU hang, OOM, NVMe failure, thermal throttle, process leak) down to the second.

## Tech Stack

- **Language:** Pure Bash (no Python, JS, or compiled deps)
- **Runtime:** Linux `/proc`, `/sys`, `systemctl --user`, `sudo`
- **Target:** AMD Phoenix / Radeon 780M laptops, but works on any Linux

## Architecture

- **6 collectors** running as background processes under `diag-start.sh`:
  - `heartbeat` (1s) — durable O_DSYNC tick
  - `fast` (5s) — PSI, load, swap, temps, OOM, top processes
  - `gpu` (5s) — AMD GPU sysfs metrics
  - `watchdog` (10s) — per-process RSS, FD, inotify
  - `detailed` (60s) — full system snapshot
  - `dmesg` (continuous) — kernel log + journalctl via sudo
- **Session lifecycle:** `diag-start.sh` → all collectors → `diag-stop.sh` clean kill
- **Segment rotation:** log files split every 10–60 min windows
- **Post-mortem:** `diag-analyze.sh` scores 6 severity categories (GPU/OOM/NVMe/thermal/leak/memory), generates formatted reports

## Coding Conventions

- **Shebang:** `#!/bin/bash`
- **Strict mode:** `set -euo pipefail` at top of every main script
- **Indent:** 4 spaces (no tabs)
- **Variables:** `UPPER_CASE` for config/exports, `snake_case` for locals
- **Functions:** `snake_case`
- **Guards (every collector):**
  1. `flock_instance_guard` (survives orphan processes)
  2. PID file check (`is_running`)
  3. `trap "cleanup_pidfile; trap_exit_handler" EXIT TERM INT`
- **I/O:** `durable_line()` (dd+dsync) for heartbeat, `fsync_line()` for others
- **Subprocess minimization:** prefer reading `/proc` directly over `grep`/`awk`/`sed` subprocesses
- **Comments:** header block on every file, `# ---- Section ----` separators for large files

## File Map

| Path | Purpose |
|------|---------|
| `diag.conf` | Config sourced by every script. Never edit while collectors run. |
| `lib/lib_common.sh` | Shared library (guard-loaded, idempotent) |
| `lib/collector_*.sh` | 6 independent collectors |
| `diag-start.sh` | Entry point: launcher, installer, supervisor |
| `diag-stop.sh` | Clean shutdown of all collectors |
| `diag-analyze.sh` | Analysis CLI + interactive TUI |
| `diag-report.sh` | Auto-run crash summary + desktop notification |
| `diag-harden.sh` | Kernel parameter hardening (GRUB + sysctl) |
| `tests/check-sensitive.sh` | Pre-commit sensitive data scanner |
| `sudoers-freeze-diag` | sudoers template (`<USERNAME>` placeholder) |

## Commands

```bash
bash diag-start.sh --install     # One-time setup (sudoers + systemd)
bash diag-start.sh               # Launch collectors
bash diag-stop.sh                # Stop collectors
bash diag-analyze.sh --interactive  # Interactive post-mortem
bash diag-analyze.sh --session <id> # Analyze specific session
bash diag-harden.sh --status     # Check kernel hardening status
bash diag-harden.sh --fix-all    # Apply all hardening
bash tests/check-sensitive.sh <files...>  # Scan for secrets
systemctl --user start freeze-diag   # Via systemd
systemctl --user stop freeze-diag
```

## Critical Rules

- **NEVER** commit `logs/`, `reports/`, or `archive/` directories
- **NEVER** hardcode usernames, MAC addresses, IPs, UUIDs, SSH keys, or API tokens
- **ALWAYS** run `tests/check-sensitive.sh` on new or modified files
- **ALWAYS** source `diag.conf` before any collector or library code
- `sudoers-freeze-diag` contains `<USERNAME>` — substitute with the actual username before deploying
- New collectors must follow the established pattern: source lib, define `STREAM`, flock guard, PID file, trap, `open_segment` loop with `should_roll_segment` + `cleanup_old_segments`

## Patterns to Follow

- **New collector:** copy `lib/collector_fast.sh` as template — it has the canonical guard/loop structure
- **New library function:** add to `lib/lib_common.sh` inside the guard-load block
- **New analysis:** follow `diag-analyze.sh` scoring pattern (evidence collection → category scoring → report formatting)
- **Error handling:** `|| true` on expected failures, `|| return 1` in functions called without `set -e`

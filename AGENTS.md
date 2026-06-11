# freeze-diag

Zero-dependency Bash toolkit for diagnosing Linux system freezes. Records system state continuously to disk with `O_DSYNC`/`fsync`; after a hard freeze and reboot, pinpoints root cause (GPU hang, OOM, NVMe, thermal, leak) ±1 second.

## Tech Stack

- **Language:** Pure Bash, no deps
- **Runtime:** Linux `/proc`, `/sys`, `systemctl --user`, `sudo`
- **License:** AGPL-3.0

## Architecture

- **`diag-start.sh`** is both launcher and **supervisor** — it monitors child collectors and restarts them if they die (up to 5 times each). Writes a per-session **context snapshot** (`logs/context_<session>.log`: kernel, cmdline, BIOS/microcode, boost/governor, panic sysctls, amdgpu params) and launches 7 background collectors:
  - `heartbeat` (1s) — `durable_line()` via `dd oflag=append,dsync`
  - `fast` (5s) — PSI, load, swap, temps, OOM, top-3 procs
  - `gpu` (5s) — AMD GPU sysfs: busy%, VRAM, temp, power, runtime
  - `cpu` (2s) — per-CPU freq min/avg/max, cores near fmax, boost flag, kernel taint (flips on first oops — pre-panic signal)
  - `watchdog` (10s) — per-target RSS/VSZ/fd/inotify/DRI
  - `detailed` (60s) — full `/proc` snapshot, D-state, iostat, IRQ
  - `dmesg` (continuous) — `dmesg -w` + `journalctl -f` via sudo, fsync per line
- **Session lifecycle:** each boot creates `<boot_id>_<epoch>.session` marker. Clean stop → `stopped`. Next boot sees `running` with dead PID → marks `crashed`, auto-runs `diag-report.sh`, which also freezes a **crash bundle** in `archive/crash_<session>_<ts>/` (pre-crash segments, context, previous-boot journal tail + kernel-fault lines, pstore records via `fd-pstore-dump`) — bundles are never pruned.
- **hwmon resolution:** `fd_resolve_hwmons()` resolves sensor paths by chip name (`k10temp`/`amdgpu`/`nvme`) at collector start; `hwmonN` numbering is not stable across boots.
- **Segment rotation:** log files split every 10–60 min windows (configurable per stream in `diag.conf`). Oldest pruned past `FD_RETENTION_MINUTES` (default 90 days) and `FD_MAX_DISK_MB` (5 GB) — both via single `find` calls, never bash loops over the segment set.
- **Post-mortem:** `diag-analyze.sh` scores 7 categories (KERNEL FAULT first — oops/GPF/lockup/MCE from the dmesg stream + previous-boot journal, plus pstore record detection — then GPU/OOM/NVMe/memory/thermal/leak), shows session context and pre-freeze CPU-frequency posture. Category analyzers set `SCORE_*`/`*_EVIDENCE` globals and must be called as plain statements, never `$(...)` (subshells discard scores).
- **`bin/fd-pstore-dump`** — root-owned helper (installed to `/usr/local/bin` by `--install`, sudoers-allowed) that copies root-only pstore panic records into user-owned crash bundles; validates the destination is owned by the invoking user.
- **`diag-harden.sh`** — blanket hardening via `--fix-all` plus targeted single-variable experiments: `--disable-cpu-boost`/`--enable-cpu-boost`, `--enable-iommu-strict`, `--relax-panic` (inverse of `--panic-on-lockup`, for after the system is proven stable).

## Coding Conventions

- `set -euo pipefail` on every main script (not in library file)
- 4-space indent, no tabs
- `UPPER_CASE` for exported config, `snake_case` for locals and functions
- Every collector: `flock_instance_guard` → PID file check → `trap "cleanup_pidfile; trap_exit_handler" EXIT TERM INT`
- I/O: `durable_line()` (dd+dsync) for heartbeat, `fsync_line()` (sync -f) for others
- Minimize subprocesses: read `/proc` directly, avoid `grep`/`awk`/`sed` in hot loops
- `|| true` on expected failures, `|| return 1` in functions called without `set -e`
- Library is idempotent: `if [ -z "${_FD_COMMON_LOADED:-}" ]; then _FD_COMMON_LOADED=1` guard
- `lib_common.sh` auto-sources `diag.conf` if `FD_ROOT` is unset (path: two dirs up from lib/)

## Commands

```bash
# Setup and lifecycle
bash diag-start.sh --install            # One-time: sudoers + systemd enable + start
bash diag-start.sh --uninstall          # Stop, remove sudoers and systemd unit
bash diag-start.sh --uninstall --purge  # Also delete all logs, reports, archives
bash diag-start.sh                      # Launch collectors directly (no systemd)
bash diag-stop.sh                       # Clean kill of all collectors
systemctl --user start|stop|status freeze-diag

# Post-freeze analysis
bash diag-analyze.sh                        # Interactive TUI (no args)
bash diag-analyze.sh --session <id>         # Analyze specific session
bash diag-analyze.sh --boot <boot_id>       # Analyze by boot ID
bash diag-analyze.sh --current              # Live analysis of running session
bash diag-analyze.sh --current --quick      # Non-interactive 1-page summary
bash diag-analyze.sh --current --gpu-only   # GPU findings only
bash diag-analyze.sh --current --memory-only
bash diag-analyze.sh --current --output <file>

# Auto-run crash notification (called by diag-start.sh)
bash diag-report.sh --session <id>

# Kernel hardening
bash diag-harden.sh --status                    # Show current kernel params
bash diag-harden.sh --dry-run                   # Preview changes
bash diag-harden.sh --enable-amdgpu-recovery    # lockup_timeout + gpu_recovery
bash diag-harden.sh --disable-nvme-power-save   # NVMe APST fix
bash diag-harden.sh --disable-deep-cstates       # Ryzen C-state fix
bash diag-harden.sh --panic-on-lockup           # sysctl + GRUB panic settings
bash diag-harden.sh --fix-all                   # Apply all four above

# Pre-commit hook (activate once):
git config core.hooksPath githooks

# Manual sensitive data scan (run before every commit):
bash tests/check-sensitive.sh              # All tracked files
bash tests/check-sensitive.sh path/to/file # Specific files
```

## Critical Rules

- **NEVER** commit `logs/`, `reports/`, or `archive/` directories (in `.gitignore`)
- **NEVER** hardcode usernames, MACs, IPs, UUIDs, SSH keys, or API tokens
- **ALWAYS** run `tests/check-sensitive.sh` on new or modified files before committing
- `sudoers-freeze-diag` contains literal `<USERNAME>` — substitute before deploying
- New collectors: copy `lib/collector_fast.sh` (canonical guard/loop structure); add entry to `COLLECTORS` array in `diag-start.sh`
- New lib functions: add to `lib/lib_common.sh` inside the guard block
- diag-start.sh sources `diag.conf` explicitly before `lib_common.sh`; collectors source only `lib_common.sh` (which auto-sources `diag.conf`)

## File Map

| Path | Purpose |
|------|---------|
| `diag.conf` | All tunables. Never edit while collectors run. Vars exported for child processes. |
| `lib/lib_common.sh` | Shared library: segment mgmt, fsync, pidfile, flock, session markers |
| `lib/collector_*.sh` | 6 independent collectors |
| `diag-start.sh` | Launcher + installer + supervisor (restarts dead collectors) |
| `diag-stop.sh` | Clean kill of all collectors + session marker |
| `diag-analyze.sh` | Post-freeze / live analysis (CLI + interactive TUI) |
| `diag-report.sh` | Auto-run crash summary + desktop notification via `notify-send` |
| `diag-harden.sh` | Kernel param hardening: GRUB + sysctl |
| `tests/check-sensitive.sh` | Pre-commit sensitive data scanner |
| `githooks/pre-commit` | Git hook that runs check-sensitive.sh on staged files |
| `sudoers-freeze-diag` | sudoers template (`<USERNAME>` placeholder) |
| `freeze-diag.service` | systemd --user unit (type=simple, restart=no) |

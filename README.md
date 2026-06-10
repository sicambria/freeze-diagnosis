# freeze-diag — Linux System Freeze Diagnosis Toolkit

[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-linux-blue)](https://kernel.org)
[![GPU](https://img.shields.io/badge/gpu-amdgpu-red)](https://docs.kernel.org/gpu/amdgpu/)

A lightweight, zero-dependency shell-based logger that continuously records system state to disk. After an unexplained system freeze and hard reboot, it pinpoints the root cause — GPU hang, OOM, NVMe failure, memory pressure, thermal throttle, or process leak — down to the second.

```
FREEZE DIAGNOSIS REPORT — 2026-06-09 14:32:05
═══════════════════════════════════════════════════

████ GPU HANG (HIGH)
  dmesg: [14:31:58] amdgpu: ring gfx_0.0.0 timeout
  Action: amdgpu.lockup_timeout=10000 amdgpu.gpu_recovery=1

██ MEMORY PRESSURE (MEDIUM)
  PSI memory full avg10 hit 85% 1 min before freeze
  opencode RSS grew 1.2G → 3.8G in 45 min (+57 MB/min)

█ NVMe / THERMAL / LEAK (NONE)
```

---

## Table of Contents

1. [Why This Exists](#why-this-exists)
2. [How It Works](#how-it-works)
3. [What It Detects](#what-it-detects)
4. [Installation](#installation)
5. [Usage](#usage)
6. [Report Reference](#report-reference)
7. [Configuration](#configuration)
8. [File Layout](#file-layout)
9. [Troubleshooting Common Findings](#troubleshooting-common-findings)
10. [Prerequisites & Compatibility](#prerequisites--compatibility)
11. [Limitations](#limitations)
12. [License](#license)

---

## Why This Exists

You are programming. After 30–60 minutes, the entire machine freezes — no mouse, no keyboard, no SSH, not even the magic SysRq keys respond. You hard-reset, losing all state. There's nothing in `journalctl -b -1` because the kernel had already stopped writing.

Freeze-diag solves this by writing to disk with `O_DSYNC` — every write is a kernel-level flush that survives a sudden power-off better than buffered I/O. After reboot, it tells you:

- **When** the freeze happened (±1 second)
- **What** the system looked like in the seconds before
- **Which** subsystem failed (GPU, OOM, NVMe, …)
- **What** to do about it

---

## How It Works

### Architecture

```
┌──────────────────────────────────────────────────────┐
│                    diag-start.sh                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│  │heartbeat │  │  fast    │  │   gpu    │  …  6 total│
│  │  (1s)    │  │  (5s)    │  │  (5s)    │           │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘           │
│       │              │              │                 │
│       ▼              ▼              ▼                 │
│  ┌─────────────────────────────────────────┐         │
│  │        ~/.local/share/freeze-diag/logs/ │         │
│  │  heartbeat_20260609_143000.log          │         │
│  │  fast_20260609_143000.log               │         │
│  │  gpu_20260609_143000.log                │         │
│  │  watchdog_20260609_143000.log           │         │
│  │  detailed_20260609_150000.log           │         │
│  │  dmesg_20260609_144500.log              │         │
│  └─────────────────────────────────────────┘         │
│                                                       │
│  ┌─────────────────────────────────────────┐         │
│  │           diag-analyze.sh                │         │
│  │  Post-reboot: scan logs, score causes   │         │
│  └─────────────────────────────────────────┘         │
└──────────────────────────────────────────────────────┘
```

### Collectors

Six independent background processes, each writing to its own timestamped segment file:

| Collector | Interval | What It Records |
|-----------|----------|-----------------|
| **heartbeat** | 1 s | Epoch timestamp + counter, written with `O_DSYNC`. Last line before the freeze is the freeze timestamp (±1s). |
| **fast** | 5 s | PSI pressure (CPU/memory/IO), load average, MemAvailable, SwapFree, OOM kill delta, CPU/GPU/NVMe temperatures, top-3 processes by RSS |
| **gpu** | 5 s | AMD GPU: busy%, VRAM/GTT usage, edge temperature, power draw (W), voltage, runtime power status, connected display connectors |
| **watchdog** | 10 s | Per-target process monitoring: RSS, VSZ, CPU%, thread count, FD count, inotify watches, DRI FDs, child processes. Targets: `opencode`, `kilo` |
| **detailed** | 60 s | Full `/proc/meminfo`, `/proc/vmstat`, `/proc/buddyinfo`, `/proc/slabinfo`, top-30 processes by RSS, inotify owners, socket summary, `iostat`, D-state processes, IRQ counts |
| **dmesg+journal** | continuous | `dmesg -w` (kernel ring buffer) + `journalctl -f -p warn`. Every line prefixed `D:` or `J:`. Syncpoints every 30s. Requires passwordless sudo. |

### Session Lifecycle

Each boot creates a session marker at `logs/sessions/<boot_id>.session`:

```json
{
  "boot_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "started_at": "2026-06-09T14:30:00+02:00",
  "status": "running",
  "pid": 12345
}
```

On clean shutdown (`diag-stop.sh`): `status` → `stopped`.
On next boot, if the previous session is still `running`: `status` → `crashed`, and `diag-report.sh` auto-generates a summary notification.

### Rotation & Space

- Each collector writes to timestamped segment files (10–60 minute segments).
- Segments older than 2 hours are auto-deleted.
- Total `logs/` directory hard-capped at **100 MB** — well under your 500 MB/hr budget (actual usage: ~7 MB/hr).
- Before any write, space is checked; oldest files are pruned if the cap is exceeded.

---

## What It Detects

| Freeze Cause | Detected By | Signal in Logs |
|-------------|-------------|----------------|
| **amdgpu GPU hang** | dmesg collector | `amdgpu: ring gfx_0.0.0 timeout`, `GPU fault`, `guilty job`, `GPU reset begin` |
| **amdgpu power mgmt bug** | GPU collector + dmesg | `runtime_status` flip-flopping, `dmesg`: DC/DMUB messages |
| **Memory leak → OOM** | fast + watchdog collectors | PSI memory pressure spike, RSS monotonic growth, `oom-killer` in dmesg |
| **Inotify exhaustion** | watchdog collector | inotify watch count exceeding `max_user_watches` (252,763 default) |
| **NVMe APST hang** | dmesg collector + fast | `nvme: I/O timeout`, `nvme: abort`, NVMe temp spike |
| **Thermal throttle** | fast + GPU collectors | GPU edge > 95°C, CPU Tctl > 95°C, frequency scaling drop |
| **Kernel soft/hard lockup** | dmesg collector | `rcu_sched stall`, `soft lockup`, `NMI watchdog: BUG` |
| **Swap thrash** | fast collector | SwapFree → near-zero, PSI IO pressure spike |
| **AMD fTPM stutter** | dmesg collector | `ftpm`/`hwrng`/`amdtee` messages in kernel log |
| **Filesystem hang (D-state)** | detailed collector | Processes stuck in `D` (uninterruptible sleep) with kernel `wchan` |
| **RAM bit-flip (marginal DIMM)** | indirect across all collectors | Random OOM kills, random GPU faults at low temperature, unexplained pressure spikes |

---

## Installation

### Quick Install (one command)

```bash
~/.local/share/freeze-diag/diag-start.sh --install
```

This runs a 4-step interactive installer:

1. **sudoers drop-in** — copies `sudoers-freeze-diag` to `/etc/sudoers.d/`, enabling passwordless `dmesg` and `journalctl` for kernel log capture
2. **systemd user service** — installs `freeze-diag.service` to `~/.config/systemd/user/`
3. **enable & start** — `systemctl --user enable --now freeze-diag.service`
4. **verification** — confirms the service is active and collectors are running

### Manual Install

```bash
# 1. Sudoers (requires root)
sudo cp sudoers-freeze-diag /etc/sudoers.d/freeze-diag
sudo chmod 0440 /etc/sudoers.d/freeze-diag

# 2. Systemd service
mkdir -p ~/.config/systemd/user
cp freeze-diag.service ~/.config/systemd/user/

# 3. Enable and start
systemctl --user daemon-reload
systemctl --user enable --now freeze-diag.service
```

### Verify

```bash
systemctl --user status freeze-diag
tail -f ~/.local/share/freeze-diag/logs/diag_events.log
```

### Uninstall

```bash
# Stop service, remove sudoers and systemd unit, preserve logs
~/.local/share/freeze-diag/diag-start.sh --uninstall

# Also delete all collected logs and reports
~/.local/share/freeze-diag/diag-start.sh --uninstall --purge
```

---

## Usage

### After a Freeze

**Automatic**: On next login, a desktop notification appears with a quick summary. Full report at `~/.local/share/freeze-diag/reports/crash_<timestamp>.txt`.

**Manual**: Run the analyzer:

```bash
# Interactive menu (no arguments)
~/.local/share/freeze-diag/diag-analyze.sh

# Quick 1-page summary (non-interactive)
~/.local/share/freeze-diag/diag-analyze.sh --quick

# Analyze a specific session
~/.local/share/freeze-diag/diag-analyze.sh --boot <boot_id>

# GPU findings only
~/.local/share/freeze-diag/diag-analyze.sh --current --gpu-only
```

### Interactive Menu

```
╔══════════════════════════════════════════╗
║       FREEZE DIAGNOSIS — ANALYZER       ║
╚══════════════════════════════════════════╝

  [1] Auto-detect and analyze last crash
  [2] List all recorded sessions
  [3] Analyze specific session
  [4] Quick GPU hang check (current session)
  [5] Quick memory pressure check (current)
  [6] Full report (current session)
  [q] Quit
```

### Live Monitoring

```bash
# Watch all collectors in real time
tail -f ~/.local/share/freeze-diag/logs/heartbeat_*.log
tail -f ~/.local/share/freeze-diag/logs/fast_*.log
tail -f ~/.local/share/freeze-diag/logs/dmesg_*.log

# Check current session status
cat ~/.local/share/freeze-diag/logs/sessions/*.session

# GPU stats right now
tail -1 ~/.local/share/freeze-diag/logs/gpu_*.log
```

### Manual Start / Stop

```bash
systemctl --user start   freeze-diag   # Start now
systemctl --user stop    freeze-diag   # Stop now
systemctl --user restart freeze-diag   # Restart (e.g. after sudoers change)
systemctl --user status  freeze-diag   # Check status
```

---

## Report Reference

Each analysis report has 6 scored categories:

### Scoring

| Score | Label | Meaning |
|-------|-------|---------|
| 0 | NONE | No evidence found |
| 1–2 | LOW | Weak or inconclusive signal |
| 3 | MEDIUM | Significant evidence, likely contributor |
| 4 | HIGH | Definitive evidence, root cause |

### Categories

#### GPU HANG
Evidence from dmesg: `amdgpu` ring timeout, fence timeout, GPU fault, guilty job, GPU reset, DRM atomic check failure.

If HIGH:
```bash
# Add to kernel cmdline (in /etc/default/grub):
amdgpu.lockup_timeout=10000 amdgpu.gpu_recovery=1

# Or: disable GPU acceleration in the problematic Electron app
opencode --disable-gpu
```

#### OOM
Evidence from dmesg: `Out of memory`, `invoked oom-killer`, `Killed process`.

If HIGH:
```bash
# Increase swap (if OOM is from leak, not runaway)
sudo swapoff -a
sudo fallocate -l 8G /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Or: increase vm.overcommit tuning
sudo sysctl vm.overcommit_memory=2
sudo sysctl vm.overcommit_ratio=80
```

#### NVMe
Evidence from dmesg: `nvme I/O timeout`, `nvme abort`, `nvme controller failure`.

If HIGH:
```bash
# Disable Autonomous Power State Transition (APST)
# Add to kernel cmdline:
nvme_core.default_ps_max_latency_us=0

# Or runtime:
echo 0 | sudo tee /sys/module/nvme_core/parameters/default_ps_max_latency_us
```

#### Memory Pressure
Evidence from fast metrics: PSI memory `full avg10` approaching 100% within 5 minutes of the freeze, SwapFree dropping to near-zero.

#### Thermal
Evidence from fast + GPU metrics: GPU edge or CPU Tctl exceeding 95°C.

If HIGH:
```bash
# Reduce max frequency / increase fan curve
# For AMD:
echo manual | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level
echo 2 | sudo tee /sys/class/drm/card1/device/pp_dpm_sclk  # low/mid clock
```

#### Process Leak
Evidence from watchdog metrics: monotonic RSS growth > 500 MB over the monitoring window, or FD count monotonic increase.

### Raw Log Excerpts

Every report includes the last ~10 lines from each collector stream, giving you the exact system state in the moments before the freeze.

---

## Configuration

All tunables in `diag.conf`:

| Variable | Default | Description |
|----------|---------|-------------|
| `FD_ROOT` | `~/.local/share/freeze-diag` | Install directory |
| `FD_HEARTBEAT_INTERVAL` | 1 | Heartbeat interval (seconds) |
| `FD_FAST_INTERVAL` | 5 | Fast metrics interval |
| `FD_GPU_INTERVAL` | 5 | GPU metrics interval |
| `FD_WATCHDOG_INTERVAL` | 10 | Process watchdog interval |
| `FD_DETAILED_INTERVAL` | 60 | Detailed snapshot interval |
| `FD_RETENTION_MINUTES` | 120 | Keep log segments for 2 hours |
| `FD_MAX_DISK_MB` | 100 | Hard cap on `logs/` directory |
| `FD_AMDGPU_DEBUG_MASK` | 1 | amdgpu debug verbosity (0=off, 1=INFO, 4=VM, 0x10=RING) |
| `FD_TARGETS` | `"opencode kilo"` | Space-separated pgrep patterns for process watchdog |

To increase dmesg verbosity for GPU hang diagnosis:

```bash
# Runtime (takes effect immediately):
echo 16 | sudo tee /sys/module/amdgpu/parameters/debug_mask    # 0x10 = RING

# Permanent (add to kernel cmdline in /etc/default/grub):
amdgpu.debug_mask=0x10
```

---

## File Layout

```
~/.local/share/freeze-diag/
├── diag.conf                         # All tunables
├── diag-start.sh                     # Entry point: --install, --uninstall, or launch
├── diag-stop.sh                      # Clean shutdown
├── diag-analyze.sh                   # Post-freeze / live analysis (CLI + interactive)
├── diag-report.sh                    # Auto-run crash notification at login
├── freeze-diag.service               # systemd user unit
├── sudoers-freeze-diag               # /etc/sudoers.d/ drop-in template
├── lib/
│   ├── lib_common.sh                 # Shared: fsync, segment mgmt, boot_id, pruning
│   ├── collector_heartbeat.sh        # 1s O_DSYNC heartbeat
│   ├── collector_fast.sh             # 5s PSI/load/swap/temps/OOM
│   ├── collector_gpu.sh              # 5s GPU sysfs: busy, VRAM, temp, power, runtime
│   ├── collector_watchdog.sh         # 10s per-process RSS/VSZ/fd/inotify/DRI
│   ├── collector_detailed.sh         # 60s full system snapshot
│   └── collector_dmesg.sh            # continuous dmesg -w + journalctl -f
├── logs/                             # Runtime — timestamped segment files
│   ├── sessions/                     # One .session file per boot
│   ├── heartbeat_<ts>.log
│   ├── fast_<ts>.log
│   ├── gpu_<ts>.log
│   ├── watchdog_<ts>.log
│   ├── detailed_<ts>.log
│   ├── dmesg_<ts>.log
│   └── diag_events.log              # Collector lifecycle events
├── archive/                          # Older segments
└── reports/                          # Analysis output
    └── crash_<ts>.txt | report_<ts>.txt
```

### Log Formats

**Heartbeat**: `1717953601.234567 HEARTBEAT 42`
→ Epoch nanoseconds, counter.

**Fast**: Pipe-delimited key=value:
```
1780991732|psic=0.00|psim=0.00|...|mavail=27666|swapf=1952|oomd=0|ctemp=41.1|gtemp=39.0|ntemp=30.9|top3=20268,firefox-bin,503072;...
```

**GPU**: Similar pipe-delimited:
```
1780991731|busy=8|vram=434|gtt=134|edge=39.0|power=22.00|volt=1.290|rt=active|conn=card1-eDP-1:connected
```

**Watchdog**: Per-PID single-line:
```
1780991727|target=opencode|pid=3357|st=S|rss=200.2|vsz=1425627.8|cpu=0.0|mem=0.6|thr=36|fd=115|inot=0|dri=0|etime=01:06:26|children=3361,@opencode-aides;3362,@opencode-aides;
```

**Dmesg**: Line-prefixed: `D: <kernel message>` or `J: <journal message>`. Syncpoints at 30s intervals: `--- SYNCPOINT 2026-06-09T09:55:26+02:00 ---`

---

## Troubleshooting Common Findings

### amdgpu ring timeout / GPU hang

The most common cause on AMD laptops with integrated Radeon graphics and Electron/Chromium apps (VS Code, Cursor, opencode, Slack, Discord).

**Immediate mitigation** — try launching the app with `--disable-gpu`:

```bash
opencode --disable-gpu
code --disable-gpu
```

**Kernel parameters** (add to `GRUB_CMDLINE_LINUX` in `/etc/default/grub`, then `sudo update-grub`):

```
amdgpu.lockup_timeout=10000 amdgpu.gpu_recovery=1 amdgpu.dpm=0
```

- `lockup_timeout=10000` — kernel gives GPU 10 seconds before declaring a hang (default: unset, infinitely waits)
- `gpu_recovery=1` — attempt GPU reset on hang (default: auto)
- `dpm=0` — disable dynamic power management (if power transitions are the trigger)

### OOM / Memory Leak

If the watchdog shows RSS monotonic growth (e.g. opencode growing 57 MB/min):

1. Check if it's a known Electron leak — try `--disable-gpu` first (GPU rendering holds large buffers)
2. Increase swap: `sudo fallocate -l 8G /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`
3. Set memory limit on the process: `systemd-run --user --scope -p MemoryMax=8G opencode`

### NVMe APST Hang

Very common on AMD laptops. The NVMe drive enters a low-power state and can't wake up.

```bash
# Check current APST state:
sudo nvme get-feature /dev/nvme0 -f 0x0c -H

# If APST is enabled, add to kernel cmdline:
nvme_core.default_ps_max_latency_us=0

# Runtime workaround (temporary):
echo 0 | sudo tee /sys/module/nvme_core/parameters/default_ps_max_latency_us
```

### Soft Lockup / RCU Stall

If dmesg shows `rcu_sched detected stalls` or `soft lockup`:

```bash
# Increase the lockup detection threshold (or enable panic so it reboots instead of hanging):
echo 1 | sudo tee /proc/sys/kernel/softlockup_panic
echo 1 | sudo tee /proc/sys/kernel/hardlockup_panic
echo 1 | sudo tee /proc/sys/kernel/hung_task_panic

# Permanent: add to /etc/sysctl.d/99-freeze.conf:
kernel.softlockup_panic = 1
kernel.hardlockup_panic = 1
kernel.hung_task_panic = 1
```

> Warning: this makes a soft lockup cause an instant reboot instead of a freeze. You lose unsaved work but can recover without a hard reset.

### RAM (Even If BIOS Memtest Passed)

BIOS memtest is rudimentary (cold, single-pass, simple patterns). Marginal DIMMs can fail only when warm under combined CPU+IO+GPU load.

**Userspace test** (while the system is hot, after 30+ min of load):

```bash
# Test 2 GB for 5 passes (takes ~30 min)
sudo memtester 2G 5
```

Or use `stress-ng` to test under load:

```bash
stress-ng --vm 4 --vm-bytes 80% --timeout 3600s
```

### Inotify Watch Exhaustion

If the detailed collector shows a process with >50,000 inotify watches:

```bash
# Check current limits:
cat /proc/sys/fs/inotify/max_user_watches   # default: 252,763

# Increase if needed:
echo 524288 | sudo tee /proc/sys/fs/inotify/max_user_watches

# Permanent: add to /etc/sysctl.d/99-inotify.conf:
fs.inotify.max_user_watches = 524288
```

---

## Prerequisites & Compatibility

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| **OS** | Linux kernel 5.x+ | Tested on 7.0.0-14-generic (Ubuntu 24.04/Mint 22) |
| **Shell** | Bash 4.0+ | Uses `read -r ... <<<` (here-string), `[[` |
| **GPU** | AMD with amdgpu driver | GPU collector uses `/sys/class/drm/card*/device/` sysfs. Works with NVIDIA via minor config changes |
| **systemd** | User services (`systemctl --user`) | Required for auto-start. Can still run manually without it |
| **sudo** | Passwordless `dmesg`, `journalctl` | Only needed for kernel log capture. Collectors run fine without it |
| **Disk** | ext4 (or any non-CoW FS) | `fsync` and `O_DSYNC` are safe on ext4. btrfs/zfs untested |
| **Memory** | < 10 MB RSS when idle | 16 bash processes, ~8 MB total. Negligible overhead |

---

## Limitations

- **Kernel log capture requires root** — the `dmesg -w` and `journalctl -f` collectors need passwordless sudo. Without it, the kernel log stream is empty. All other collectors work unprivileged.
- **Can't log through a full kernel lockup** — if the kernel itself deadlocks (spinlock, IRQ storm), no userspace process can write. The dmesg log preserves messages from *before* the lockup, which is usually sufficient for root-cause analysis.
- **Can't log through NVMe failure** — if the NVMe drive is the cause of the freeze, the last few writes may not reach disk. The heartbeat interval is 1 second; worst case you lose < 1 second of data.
- **ext4 only tested** — behavior on btrfs (CoW), zfs, or NFS is unknown.
- **AMD GPU primarily** — the GPU collector targets AMD's sysfs layout. NVIDIA and Intel GPUs have different paths (minor config changes needed).
- **No long-term analytics** — this is a diagnostic tool, not a monitoring dashboard. Logs are kept for 2 hours by default.

---

---

## Contributing

### Pre-commit hook

A pre-commit hook scans staged files for sensitive data (UUIDs, MACs, IPs, usernames, keys).
To activate:

```bash
git config core.hooksPath githooks
```

The hook runs `tests/check-sensitive.sh` on every commit. To run manually:

```bash
tests/check-sensitive.sh
```

### Sensitive data policy

Never commit runtime logs, boot IDs, usernames, or system telemetry. The `.gitignore` excludes `logs/`, `reports/`, and `archive/` — these directories only contain runtime output.

---

## License

GNU Affero General Public License v3.0 or later.

See [LICENSE](LICENSE) for the full text.

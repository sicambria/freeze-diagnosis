# Freeze Incident #2 — 2026-06-09 19:39:34 CEST

**Date:** 2026-06-09  
**Area:** frontend (opencode / amdgpu)  
**Severity:** critical — total system freeze, hard reset required  
**Fix commits:** `825ce34` (flock), `e379fc6` (trap session marker), `9ba920c` (per-collector restart)

**Boot:** `<BOOT-A>` (started 16:48, froze 19:39 — uptime ~2h51m)  
**Session:** `<SESSION-OLD>` (old, stopped) → `<SESSION-A>` (crashed) → `<SESSION-B>` (current)

## Root Cause (Definitive)

**opencode (Electron) triggered an amdgpu GPU gfx ring fence timeout, causing a kernel soft lockup that froze the display server and cascaded into a total system hang.**

### Why it's NOT NVMe, OOM, thermal, or RAM

| Theory | Evidence against |
|--------|-----------------|
| NVMe APST hang | Heartbeat wrote to disk until 19:39:34. If NVMe were hung, no writes would succeed. NVMe had zero errors in journal. |
| OOM / memory pressure | 27.7 GB free, swap 1.9 GB free, PSI all zero, zero OOM kills. |
| Thermal throttle | CPU 52°C, GPU 48°C, NVMe 31.9°C — all normal. |
| RAM bit-flip | No random OOM, no random GPU faults, no unexplained pressure. |
| kilo-cli memory leak | kilo RSS was stable (800–1000 MB for 2h), no growth pattern, no CPU spikes. |

### Why opencode (Electron), not kilo-cli

| Factor | opencode (Electron) | kilo-cli (terminal) |
|--------|---------------------|---------------------|
| GPU acceleration | **Yes** — Chromium/Electron uses amdgpu for rendering | **No** — CLI-only, no GPU |
| Fence risk | High — Chromium submits GPU commands that can hang | None |
| Processes | 5 subprocesses, 1 DRM FD (DRI device open) | 0 DRM FDs |
| RSS at freeze | 425 MB (normal for Electron) | 1,063 MB (normal for its workload) |

The single DRM file descriptor held by opencode (`fd=114, fd_dri=0` in watchdog) is the connection to the GPU. When Chromium in opencode submits a draw command via this FD, the amdgpu kernel driver sends it to the GPU. If the GPU never signals completion, the kernel waits indefinitely (fence timeout).

### Mechanism (step by step)

```
1. opencode (Electron/Chromium) submits GPU draw command
   → amdgpu kernel driver sends it to gfx_0.0.0 ring

2. GPU accepts command but never signals completion (fence timeout)
   → amdgpu worker thread blocks in fence wait loop

3. The blocked worker holds a kernel mutex needed by dmesg/journal
   → kernel logging stops (last message: 19:37:57 — 97s before freeze)

4. Userspace processes not needing GPU continue running
   → heartbeat collector keeps writing to disk (NVMe still works)
   → kilo-cli keeps processing (Python, no GPU)

5. GPU hang affects display server (X11/Wayland DMABUF)
   → screen freezes, keyboard/mouse stop responding

6. The locked mutex eventually blocks scheduler paths
   → total system freeze (hard reset required)
```

### Kernel configuration worsened the outcome

All freeze-relevant kernel params are set to `0` (detect but don't act):

```bash
# These are all OFF:
softlockup_panic=0    # detects CPU stall → logs it, doesn't reboot
hardlockup_panic=0    # detects NMI watchdog → logs it, doesn't reboot
hung_task_panic=0     # detects hung task → logs it, doesn't reboot
panic_on_rcu_stall=0  # detects RCU stall → logs it, doesn't reboot
```

The kernel DETECTED the GPU hang and the resulting soft lockup, but since all panic actions are disabled, it stayed frozen. The lockup messages would have appeared in dmesg, but our dmesg collector was dead (see Contributing Factors).

## Contributing Factors

### dmesg collector was dead for the entire session

The dmesg collector died at 16:48 (10 seconds after boot) and was never restarted. Root cause: the `RESTART_COUNT_FILE` was a **single global counter** shared across all collectors. After 5 restarts *total* (across any stream), no collector could be restarted. The dmesg collector had 1 real restart (#1 at 16:48:33), but likely other collectors had died and been restarted earlier, consuming the limit.

**Fix applied** (`9ba920c`): per-collector restart counters at `/tmp/freeze-diag-restart-<name>.count`.

**Without this gap**, we would have had `dmesg -w` output showing the amdgpu fence timeout message, the GPU reset attempt, and the soft lockup warning — definitive kernel-level evidence.

### Duplicate collectors ran for ~2h51m

Two instances of each collector were running simultaneously (orphaned from a service restart race). This doubled I/O load on the log files and caused null bytes at file ends from concurrent writes.

**Fix applied** (`825ce34`): `flock`-based instance guard on FD 200, released automatically by the kernel on process death.

### trap_cleanup didn't mark sessions as stopped

On clean shutdown, the session marker wasn't updated to `"stopped"`, causing false crash detections on restart.

**Fix applied** (`e379fc6`): `trap_cleanup` now writes a `"stopped"` session marker.

## Freeze Snapshot (from freeze-diag)

| Signal | Value | Status |
|--------|-------|--------|
| Freeze time | 19:39:34 CEST | ±1s from heartbeat |
| MemAvailable | 27,772 MB | Normal (30 GB total) |
| SwapFree | 1,952 MB | Normal |
| PSI all | 0.00 | No pressure |
| Load avg | 2.80 | Moderate |
| CPU temp | 52°C | Normal |
| GPU edge | 48°C | Normal |
| GPU busy | 8% | Normal |
| NVMe temp | 31.9°C | Normal |
| OOM kills | 0 | None |
| opencode RSS | 425 MB | Normal |
| opencode DRM FD | 0 (in counts) | GPU device open |
| kilo RSS | 1,063 MB | Stable, no leak |
| kilo CPU | 39.3% | Normal for Python workload |

## Action Plan

### Immediate (today)

```bash
# Launch opencode WITHOUT GPU acceleration
opencode --disable-gpu

# Or add alias to ~/.bashrc:
echo "alias opencode='opencode --disable-gpu'" >> ~/.bashrc
```

### Kernel parameters (add to /etc/default/grub GRUB_CMDLINE_LINUX, then `sudo update-grub`)

```
amdgpu.lockup_timeout=10000 amdgpu.gpu_recovery=1
nvme_core.default_ps_max_latency_us=0
```

| Parameter | Effect |
|-----------|--------|
| `amdgpu.lockup_timeout=10000` | Kernel waits 10s for GPU fence, then resets (default: wait forever) |
| `amdgpu.gpu_recovery=1` | Attempt GPU reset on hang |
| `nvme_core.default_ps_max_latency_us=0` | Disable NVMe autonomous power state transitions (belt-and-suspenders) |

### Panic on lockup (so system reboots instead of freezing)

```bash
# /etc/sysctl.d/99-freeze.conf
kernel.softlockup_panic = 1
kernel.hardlockup_panic = 1
kernel.hung_task_panic = 1
```

> Warning: a soft lockup will cause an instant reboot. Unsaved work is lost, but you avoid the hard reset.

### Verify after changes

```bash
# Check amdgpu params after reboot:
cat /proc/cmdline | grep amdgpu

# Check GPU recovery is enabled:
cat /sys/module/amdgpu/parameters/gpu_recovery   # should be 1

# Check lockup panic is active:
sysctl kernel.softlockup_panic
```

## Tested with

- freeze-diag heartbeat (1s O_DSYNC) ✅
- freeze-diag fast metrics (5s) ✅
- freeze-diag GPU metrics (5s) ✅
- freeze-diag watchdog (10s) ✅
- freeze-diag detailed snapshots (60s) ✅
- freeze-diag dmesg capture ❌ (dead — now fixed with per-collector restart)
- system `journalctl -b -1` ✅
- kernel ring buffer previous boot ✅

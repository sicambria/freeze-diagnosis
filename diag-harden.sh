#!/bin/bash
# diag-harden.sh — kernel parameter hardening for freeze-prone systems
# Applies amdgpu, NVMe, and kernel panic settings that prevent hanging
# during GPU lockups on AMD Phoenix (Radeon 780M) laptops.
#
# Usage:
#   diag-harden.sh --status                          Show current kernel params
#   diag-harden.sh --enable-amdgpu-recovery          Fix GPU lockup timeout + recovery
#   diag-harden.sh --disable-nvme-power-save          Fix NVMe latency on power transitions
#   diag-harden.sh --panic-on-lockup                  Kernel panics instead of hanging
#   diag-harden.sh --disable-deep-cstates              Fix Ryzen deep C-state/SMM lockups
#   diag-harden.sh --fix-all                          Apply all four above
#   diag-harden.sh --dry-run                          Show what --fix-all would do, no changes
#
# Targeted experiments (NOT part of --fix-all; apply one at a time):
#   diag-harden.sh --disable-cpu-boost                 Turbo boost off now + persist (HW marginality mitigation)
#   diag-harden.sh --enable-cpu-boost                  Re-enable turbo boost, remove persistence
#   diag-harden.sh --enable-iommu-strict               GRUB iommu.strict=1 (rogue-DMA corruption becomes visible IO_PAGE_FAULTs)
#   diag-harden.sh --relax-panic                       Revert panic-on-lockup posture (after system proven stable)
#
#   diag-harden.sh --help                             Show this message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/diag.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}$*${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
info() { echo -e "  ${YELLOW}[INFO]${NC} $*"; }
warn() { echo -e "  ${RED}[WARN]${NC} $*"; }
cmd()  { echo -e "  ${BOLD}\$${NC} $*"; }

check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        warn "This command requires passwordless sudo."
        info "Try: sudo $0"
        exit 1
    fi
}

# ---- GRUB helpers ----

GRUB_FILE="/etc/default/grub"

read_grub_cmdline() {
    local which="${1:-DEFAULT}"  # DEFAULT or LINUX
    local var
    case "$which" in
        DEFAULT) var="GRUB_CMDLINE_LINUX_DEFAULT" ;;
        LINUX)   var="GRUB_CMDLINE_LINUX" ;;
        *)       var="GRUB_CMDLINE_LINUX_${which}" ;;
    esac
    grep "^${var}=" "$GRUB_FILE" 2>/dev/null | sed 's/^[^=]*=//; s/"//g' || echo ""
}

has_grub_param() {
    local which="$1" param="$2"
    local line
    line=$(read_grub_cmdline "$which")
    # Disable pathname expansion to prevent globbing on param values
    local _had_noglob; shopt -qo noglob && _had_noglob=true || _had_noglob=false
    set -f
    local w
    for w in $line; do
        [ "$w" = "$param" ] && { $_had_noglob || set +f; return 0; }
    done
    $_had_noglob || set +f
    return 1
}

has_grub_key_with_value() {
    local which="$1" key="$2"
    local line
    line=$(read_grub_cmdline "$which")
    local _had_noglob; shopt -qo noglob && _had_noglob=true || _had_noglob=false
    set -f
    local w
    for w in $line; do
        case "$w" in
            "$key="*) { $_had_noglob || set +f; return 0; } ;;
        esac
    done
    $_had_noglob || set +f
    return 1
}

grub_key_value() {
    local which="$1" key="$2"
    local line
    line=$(read_grub_cmdline "$which")
    local _had_noglob; shopt -qo noglob && _had_noglob=true || _had_noglob=false
    set -f
    local w
    for w in $line; do
        case "$w" in
            "$key="*) echo "${w#*=}"; $_had_noglob || set +f; return 0 ;;
        esac
    done
    $_had_noglob || set +f
    return 1
}

add_grub_params() {
    local which="$1" desc="$2"
    shift 2
    local params=("$@")
    local current
    current=$(read_grub_cmdline "$which")
    local changed=false

    info "Adding to ${BOLD}GRUB_CMDLINE_LINUX_${which}${NC}: ${desc}"

    local new_line="$current"
    for p in "${params[@]}"; do
        if has_grub_param "$which" "$p"; then
            ok "Already present: ${BOLD}$p${NC}"
        else
            info "Adding: ${BOLD}$p${NC}"
            new_line="$new_line $p"
            changed=true
        fi
    done

    if [ "$changed" = false ]; then
        ok "All params already present in GRUB_CMDLINE_LINUX_${which}"
        return 0
    fi

    # Trim leading spaces
    new_line="${new_line# }"

    local var="GRUB_CMDLINE_LINUX_${which}"
    sudo sed -i "s/^${var}=.*/${var}=\"${new_line}\"/" "$GRUB_FILE"
    ok "Updated ${BOLD}${var}=\"${new_line}\"${NC}"
    GRUB_UPDATED=true
}

# ---- Sysctl helpers ----

SYSCTL_FILE="/etc/sysctl.d/99-freeze.conf"

read_sysctl_val() {
    local key="$1"
    sysctl -n "$key" 2>/dev/null || echo ""
}

set_sysctl_key() {
    local key="$1" expected="$2" desc="$3"
    local current
    current=$(read_sysctl_val "$key")
    info "${desc}"
    cmd "sysctl -w ${key}=${expected}"
    if [ "$current" = "$expected" ]; then
        ok "${BOLD}${key}${NC} already = ${expected}"
    else
        echo -e "    Current: ${YELLOW}${current}${NC} → ${GREEN}${expected}${NC}"
        sudo sysctl -w "${key}=${expected}" > /dev/null
        ok "${BOLD}${key}${NC} set to ${expected}"
    fi
    SYSCTL_ENTRIES="${SYSCTL_ENTRIES}${key}=${expected}\n"
}

install_sysctl_file() {
    if [ -n "${SYSCTL_ENTRIES:-}" ]; then
        local persisted
        persisted=$(cat "$SYSCTL_FILE" 2>/dev/null || echo "")
        local needs_update=false
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Whole-line exact match to avoid substring false-positives
            # (e.g. "kernel.softlockup_panic=1" must not match "kernel.softlockup_panic=10")
            if ! printf '%s\n' "$persisted" | grep -qxF "$line"; then
                needs_update=true
            fi
        done < <(printf '%b\n' "$SYSCTL_ENTRIES")

        if [ "$needs_update" = true ]; then
            printf '%b\n' "$SYSCTL_ENTRIES" | sudo tee -a "$SYSCTL_FILE" > /dev/null
            ok "Persisted to ${BOLD}$SYSCTL_FILE${NC}"
        else
            ok "All sysctl entries already persisted in ${BOLD}$SYSCTL_FILE${NC}"
        fi
    fi
}

# ---- Status display ----

cmdline_status() {
    local which="$1" label="$2"
    local line
    line=$(read_grub_cmdline "$which")
    if [ -n "$line" ]; then
        echo -e "  ${CYAN}${label}${NC}: ${BOLD}${line}${NC}"
    else
        echo -e "  ${CYAN}${label}${NC}: (empty)"
    fi
}

show_status() {
    header "System Hardening Status"

    echo -e "${BOLD}Boot parameters (GRUB):${NC}"
    cmdline_status "DEFAULT" "GRUB_CMDLINE_LINUX_DEFAULT"
    cmdline_status "LINUX"   "GRUB_CMDLINE_LINUX"

    local -a grub_params=(
        "amdgpu.lockup_timeout"
        "amdgpu.gpu_recovery"
        "nvme_core.default_ps_max_latency_us"
        "panic"
        "processor.max_cstate"
        "idle"
    )

    for grp in "${grub_params[@]}"; do
        local found_which="" found_val=""
        for which in DEFAULT LINUX; do
            if has_grub_key_with_value "$which" "$grp"; then
                found_which="$which"
                found_val=$(grub_key_value "$which" "$grp")
                break
            fi
        done
        if [ -n "$found_val" ]; then
            local found_label
            case "$found_which" in
                DEFAULT) found_label="GRUB_CMDLINE_LINUX_DEFAULT" ;;
                LINUX)   found_label="GRUB_CMDLINE_LINUX" ;;
                *)       found_label="GRUB_CMDLINE_LINUX_${found_which}" ;;
            esac
            ok "${BOLD}${grp}${NC} → ${GREEN}${grp}=${found_val}${NC} (${found_label})"
        else
            warn "${BOLD}${grp}${NC} → not set"
        fi
    done

    echo ""
    echo -e "${BOLD}Runtime sysctl settings:${NC}"

    local -a sysctl_keys=(
        "kernel.softlockup_panic"
        "kernel.hardlockup_panic"
        "kernel.hung_task_panic"
        "kernel.panic_on_oops"
    )

    for key in "${sysctl_keys[@]}"; do
        local val
        val=$(read_sysctl_val "$key")
        if [ "$val" = "1" ]; then
            ok "${BOLD}${key}${NC} = ${GREEN}${val}${NC}"
        elif [ -n "$val" ]; then
            warn "${BOLD}${key}${NC} = ${RED}${val}${NC}  (should be 1)"
        else
            warn "${BOLD}${key}${NC} = (unreadable)"
        fi
    done

    echo ""
    echo -e "${BOLD}Runtime hardware posture:${NC}"
    local boost taint
    boost=$(cat "$BOOST_PATH" 2>/dev/null || echo "n/a")
    taint=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo "n/a")
    if [ "$boost" = "0" ]; then
        ok "${BOLD}CPU turbo boost${NC} = ${GREEN}disabled${NC} (marginality mitigation active)"
    else
        info "${BOLD}CPU turbo boost${NC} = ${boost} (1 = enabled)"
    fi
    if systemctl is-enabled disable-cpu-boost.service > /dev/null 2>&1; then
        ok "boost-off persistence: ${GREEN}enabled${NC} (disable-cpu-boost.service)"
    fi
    if grep -qw 'iommu.strict=1' /proc/cmdline 2>/dev/null; then
        ok "${BOLD}iommu.strict=1${NC} active this boot (DMA faults visible)"
    fi
    if [ "$taint" = "0" ] || [ "$taint" = "n/a" ]; then
        ok "${BOLD}kernel tainted${NC} = ${taint}"
    elif [ "$taint" = "64" ]; then
        ok "${BOLD}kernel tainted${NC} = 64 (TAINT_USER only — expected with amdgpu.gpu_recovery=1)"
    else
        warn "${BOLD}kernel tainted${NC} = ${taint} (decode: bit 7=DIE/oops fired, bit 9=warn fired, bit 6=user)"
    fi

    echo ""
    echo -e "${BOLD}Persistence files:${NC}"
    if [ -f "$SYSCTL_FILE" ]; then
        echo -e "  ${CYAN}$SYSCTL_FILE${NC}:"
        while IFS= read -r line; do
            echo "    $line"
        done < "$SYSCTL_FILE"
    else
        info "$SYSCTL_FILE: not present"
    fi

    if [ -f "$GRUB_FILE" ]; then
        echo ""
        echo -e "${BOLD}Note:${NC} GRUB changes require ${YELLOW}sudo update-grub${NC} + reboot to take effect."
        echo -e "      Sysctl changes are live immediately but require reboot to persist."

        # Detect GRUB modified but update-grub never run
        local grub_has_params=false
        for grp in "${grub_params[@]}"; do
            if has_grub_key_with_value "DEFAULT" "$grp" || has_grub_key_with_value "LINUX" "$grp"; then
                grub_has_params=true
                break
            fi
        done
        if [ "$grub_has_params" = true ]; then
            local cmdline
            cmdline=$(cat /proc/cmdline 2>/dev/null)
            if ! echo "$cmdline" | grep -q "amdgpu.lockup_timeout\|amdgpu.gpu_recovery\|nvme_core.default_ps_max_latency_us\|panic=10"; then
                echo ""
                warn "GRUB has hardening params BUT they are NOT active this boot."
                info "update-grub was not run after the last GRUB edit."
                info "Run: ${BOLD}sudo update-grub && sudo reboot${NC}"
            fi
        fi
    fi
}

# ---- Apply functions ----

apply_amdgpu_recovery() {
    header "Fix: AMD GPU Lockup Recovery"
    echo -e "  Prevents total system freeze when amdgpu encounters a"
    echo -e "  GPU ring fence timeout on Radeon 780M (Phoenix)."
    echo -e ""
    echo -e "  ${BOLD}amdgpu.lockup_timeout=10000${NC} — wait 10s before declaring lockup"
    echo -e "  ${BOLD}amdgpu.gpu_recovery=1${NC}         — attempt GPU reset on lockup"
    echo ""

    # Skip if params already set in either DEFAULT or LINUX
    local all_present=true
    for p in "amdgpu.lockup_timeout=10000" "amdgpu.gpu_recovery=1"; do
        if ! has_grub_param "DEFAULT" "$p" && ! has_grub_param "LINUX" "$p"; then
            all_present=false
            break
        fi
    done
    if [ "$all_present" = true ]; then
        ok "Both amdgpu params already present in GRUB"
        return 0
    fi

    add_grub_params "DEFAULT" "AMD GPU lockup detection + recovery" \
        "amdgpu.lockup_timeout=10000" "amdgpu.gpu_recovery=1"
}

apply_nvme_power_save() {
    header "Fix: NVMe Power State Latency"
    echo -e "  Prevents NVMe drive from entering deep power states"
    echo -e "  that cause I/O latency spikes and potential controller hangs."
    echo -e ""
    echo -e "  ${BOLD}nvme_core.default_ps_max_latency_us=0${NC} — disable NVMe power saving"
    echo ""

    if has_grub_param "DEFAULT" "nvme_core.default_ps_max_latency_us=0" || has_grub_param "LINUX" "nvme_core.default_ps_max_latency_us=0"; then
        ok "NVMe power save fix already present in GRUB"
        return 0
    fi

    add_grub_params "DEFAULT" "NVMe power state latency fix" \
        "nvme_core.default_ps_max_latency_us=0"
}

apply_disable_deep_cstates() {
    header "Fix: Ryzen Deep C-State / SMM Lockup"
    echo -e "  Prevents total system freeze from deep CPU C-states on Ryzen."
    echo -e "  NMI watchdog can't fire if CPU is stuck in SMM or deep C-state."
    echo -e ""
    echo -e "  ${BOLD}processor.max_cstate=1${NC}  — limit to C1, no deep sleep"
    echo -e "  ${BOLD}idle=nomwait${NC}              — use HLT instead of buggy MWAIT"
    echo ""

    if has_grub_param "DEFAULT" "idle=nomwait" && has_grub_param "LINUX" "idle=nomwait"; then
        if has_grub_key_with_value "DEFAULT" "processor.max_cstate" || has_grub_key_with_value "LINUX" "processor.max_cstate"; then
            ok "Both C-state params already present in GRUB"
            return 0
        fi
    fi

    local target="LINUX"
    add_grub_params "$target" "Ryzen deep C-state lockup fix" \
        "processor.max_cstate=1" "idle=nomwait"
}

BOOST_PATH=/sys/devices/system/cpu/cpufreq/boost
BOOST_UNIT=/etc/systemd/system/disable-cpu-boost.service

apply_disable_cpu_boost() {
    header "Experiment: Disable CPU Turbo Boost"
    echo -e "  Mitigation for suspected hardware marginality under boost-clock"
    echo -e "  transients (random single-bit corruption, memtest-clean RAM)."
    echo -e "  Applies immediately (no reboot) and persists via a systemd unit."
    echo -e "  Cost: peak single-core clock drops to base; sustained multicore"
    echo -e "  throughput barely changes."
    echo ""

    [ -w "$BOOST_PATH" ] || [ -e "$BOOST_PATH" ] || { warn "$BOOST_PATH not present on this system"; return 1; }

    echo 0 | sudo tee "$BOOST_PATH" > /dev/null
    ok "boost = $(cat "$BOOST_PATH" 2>/dev/null) (0 = disabled)"

    sudo tee "$BOOST_UNIT" > /dev/null <<'UNITEOF'
[Unit]
Description=Disable CPU turbo boost (stability mitigation, freeze-diag harden)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'

[Install]
WantedBy=multi-user.target
UNITEOF
    sudo systemctl daemon-reload
    sudo systemctl enable disable-cpu-boost.service > /dev/null 2>&1
    ok "Persisted across reboots (disable-cpu-boost.service enabled)"
    info "Rollback: $0 --enable-cpu-boost"
}

apply_enable_cpu_boost() {
    header "Re-enable CPU Turbo Boost"
    sudo systemctl disable disable-cpu-boost.service > /dev/null 2>&1 || true
    sudo rm -f "$BOOST_UNIT"
    sudo systemctl daemon-reload
    echo 1 | sudo tee "$BOOST_PATH" > /dev/null 2>&1 || true
    ok "boost = $(cat "$BOOST_PATH" 2>/dev/null) (1 = enabled); persistence removed"
}

apply_iommu_strict() {
    header "Experiment: Strict IOMMU (DMA fault visibility)"
    echo -e "  With lazy IOMMU, a misbehaving device (GPU, WiFi, NVMe) can DMA"
    echo -e "  into freed/foreign memory and silently corrupt the kernel —"
    echo -e "  indistinguishable from RAM bit flips. ${BOLD}iommu.strict=1${NC} makes"
    echo -e "  every such access an immediate, attributable AMD-Vi IO_PAGE_FAULT."
    echo -e "  Cost: a few % I/O overhead. Diagnostic posture, revert when done."
    echo ""

    if has_grub_param "DEFAULT" "iommu.strict=1" || has_grub_param "LINUX" "iommu.strict=1"; then
        ok "iommu.strict=1 already present in GRUB"
        return 0
    fi
    add_grub_params "LINUX" "strict IOMMU TLB invalidation (DMA fault visibility)" \
        "iommu.strict=1"
}

apply_relax_panic() {
    header "Relax: panic-on-lockup posture → recover instead of reboot"
    echo -e "  The inverse of --panic-on-lockup. Once the system has proven"
    echo -e "  stable, panicking on every oops/lockup turns survivable events"
    echo -e "  into reboots. This restores recover-in-place behavior."
    echo -e "  (amdgpu recovery params and panic=10 GRUB fallback are kept.)"
    echo ""

    echo -e "${BOLD}Runtime sysctl settings (live immediately):${NC}"
    SYSCTL_ENTRIES=""
    set_sysctl_key "kernel.softlockup_panic" "0" "Recover from soft lockup (no panic)"
    set_sysctl_key "kernel.hardlockup_panic" "0" "Recover from hard lockup (no panic)"
    set_sysctl_key "kernel.hung_task_panic" "0"  "Log hung tasks without panicking"
    set_sysctl_key "kernel.panic_on_oops"  "0"  "Contain oops without panicking"

    # Rewrite (not append) the persisted file so =1 entries don't linger
    if [ -f "$SYSCTL_FILE" ]; then
        sudo sed -i \
            -e 's/^kernel\.softlockup_panic=.*/kernel.softlockup_panic=0/' \
            -e 's/^kernel\.hardlockup_panic=.*/kernel.hardlockup_panic=0/' \
            -e 's/^kernel\.hung_task_panic=.*/kernel.hung_task_panic=0/' \
            -e 's/^kernel\.panic_on_oops=.*/kernel.panic_on_oops=0/' \
            "$SYSCTL_FILE"
        ok "Rewrote persisted entries in ${BOLD}$SYSCTL_FILE${NC}"
    else
        install_sysctl_file
    fi
    info "Re-arm diagnostics anytime with: $0 --panic-on-lockup"
}

apply_panic_on_lockup() {
    header "Fix: Kernel Panic on Lockup"
    echo -e  "  Makes the kernel panic (then reboot via panic=10) instead of"
    echo -e  "  hanging frozen when a lockup is detected."
    echo -e  ""
    echo -e  "  ${BOLD}kernel.softlockup_panic=1${NC}  — panic on soft lockup"
    echo -e  "  ${BOLD}kernel.hardlockup_panic=1${NC}  — panic on hard lockup"
    echo -e  "  ${BOLD}kernel.hung_task_panic=1${NC}   — panic on hung task"
    echo -e  "  ${BOLD}kernel.panic_on_oops=1${NC}    — panic on kernel oops"
    echo -e  "  ${BOLD}panic=10${NC}                   — reboot 10s after panic"
    echo ""

    echo -e "${BOLD}Runtime sysctl settings (live immediately):${NC}"
    SYSCTL_ENTRIES=""
    set_sysctl_key "kernel.softlockup_panic" "1" "Panic on soft lockup"
    set_sysctl_key "kernel.hardlockup_panic" "1" "Panic on hard lockup (NMI watchdog)"
    set_sysctl_key "kernel.hung_task_panic" "1"  "Panic on hung task (D-state stuck)"
    set_sysctl_key "kernel.panic_on_oops"  "1"  "Panic on kernel oops"
    install_sysctl_file

    echo ""
    echo -e "${BOLD}Boot parameter (GRUB, requires reboot):${NC}"
    add_grub_params "LINUX" "panic=10 (reboot after kernel panic)" \
        "panic=10"
}

apply_fix_all() {
    header "Applying ALL hardening fixes"
    echo -e "  This will modify both GRUB boot parameters and"
    echo -e "  runtime sysctl settings for maximum freeze resilience."
    echo ""

    # Ask for confirmation (only if stdin is a terminal)
    if [ -t 0 ]; then
        echo -e "${YELLOW}WARNING:${NC} GRUB will be updated and will need ${BOLD}sudo update-grub${NC} + reboot."
        echo ""
        echo -ne "${BOLD}Proceed? [y/N]${NC} "
        read -r confirm
        case "$confirm" in
            y|Y|yes|YES) echo "" ;;
            *) echo ""; info "Aborted."; exit 0 ;;
        esac
    else
        echo -e "${YELLOW}WARNING:${NC} Non-interactive mode — applying fixes without confirmation."
        echo ""
    fi

    GRUB_UPDATED=false
    apply_amdgpu_recovery
    apply_nvme_power_save
    apply_disable_deep_cstates
    apply_panic_on_lockup

    echo ""
    if [ "$GRUB_UPDATED" = true ]; then
        header "Next Steps"
        echo -e  "  ${BOLD}1.${NC} Update GRUB bootloader:"
        cmd "sudo update-grub"
        echo ""
        echo -e  "  ${BOLD}2.${NC} Reboot to apply GRUB params:"
        cmd "sudo reboot"
        echo ""
        echo -e  "  ${BOLD}3.${NC} After reboot, verify with:"
        cmd "cat /proc/cmdline"
        cmd "sysctl kernel.softlockup_panic kernel.hardlockup_panic kernel.hung_task_panic"
    else
        info "No GRUB changes needed — all params already present."
        echo ""
        echo -e "  Sysctl changes are live now. They persist across reboot via:"
        echo -e "  ${BOLD}${SYSCTL_FILE}${NC}"
    fi
}

dry_run() {
    header "Dry Run — what ${BOLD}--fix-all${NC} would change"
    echo -e "  Checking current state without making changes..."
    echo ""

    local has_changes=false

    # Check amdgpu
    echo -e "${BOLD}1. amdgpu recovery${NC}"
    for p in "amdgpu.lockup_timeout=10000" "amdgpu.gpu_recovery=1"; do
        if has_grub_param "DEFAULT" "$p" || has_grub_param "LINUX" "$p"; then
            ok "${BOLD}${p}${NC} already set"
        else
            warn "${BOLD}${p}${NC} would be added"
            has_changes=true
        fi
    done
    echo ""

    # Check C-states
    echo -e "${BOLD}2. Ryzen deep C-state fix${NC}"
    if has_grub_key_with_value "DEFAULT" "processor.max_cstate" || has_grub_key_with_value "LINUX" "processor.max_cstate"; then
        ok "${BOLD}processor.max_cstate${NC} already set"
    else
        warn "${BOLD}processor.max_cstate=1${NC} would be added"
        has_changes=true
    fi
    if has_grub_param "DEFAULT" "idle=nomwait" || has_grub_param "LINUX" "idle=nomwait"; then
        ok "${BOLD}idle=nomwait${NC} already set"
    else
        warn "${BOLD}idle=nomwait${NC} would be added"
        has_changes=true
    fi
    echo ""

    # Check NVMe
    echo -e "${BOLD}3. NVMe power save fix${NC}"
    if has_grub_param "DEFAULT" "nvme_core.default_ps_max_latency_us=0" || has_grub_param "LINUX" "nvme_core.default_ps_max_latency_us=0"; then
        ok "${BOLD}nvme_core.default_ps_max_latency_us=0${NC} already set"
    else
        warn "${BOLD}nvme_core.default_ps_max_latency_us=0${NC} would be added"
        has_changes=true
    fi
    echo ""

    # Check panic settings
    echo -e "${BOLD}4. panic behavior${NC}"
    for key in "kernel.softlockup_panic=1" "kernel.hardlockup_panic=1" "kernel.hung_task_panic=1" "kernel.panic_on_oops=1"; do
        local k="${key%=*}"
        local v="${key#*=}"
        local cur
        cur=$(read_sysctl_val "$k")
        if [ "$cur" = "$v" ]; then
            ok "${BOLD}${k}${NC} = ${v} (already set)"
        else
            warn "${BOLD}${k}${NC} = ${cur:-unreadable} → would set to ${v}"
            has_changes=true
        fi
    done

    if has_grub_param "LINUX" "panic=10"; then
        ok "${BOLD}panic=10${NC} already in GRUB_CMDLINE_LINUX"
    else
        warn "${BOLD}panic=10${NC} would be added to GRUB_CMDLINE_LINUX"
        has_changes=true
    fi
    echo ""

    if [ "$has_changes" = true ]; then
        echo -e "  ${YELLOW}Changes needed. Run with --fix-all to apply.${NC}"
    else
        echo -e "  ${GREEN}System already fully hardened. No changes needed.${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}Note:${NC} Use ${CYAN}--status${NC} for full current state."
}

show_help() {
    echo "Usage: diag-harden.sh [OPTION]"
    echo ""
    echo "Kernel parameter hardening for freeze-prone AMD Phoenix laptops."
    echo "Applies settings based on root-cause analysis of GPU lockup freezes."
    echo ""
    echo "Modes:"
    echo "  --status                  Show current kernel and sysctl parameter values"
    echo "  --enable-amdgpu-recovery  Set amdgpu.lockup_timeout=10000 + amdgpu.gpu_recovery=1"
    echo "  --disable-nvme-power-save Set nvme_core.default_ps_max_latency_us=0"
    echo "  --disable-deep-cstates    Add processor.max_cstate=1 + idle=nomwait (Ryzen)"
    echo "  --panic-on-lockup         Set softlockup_panic=1, hardlockup_panic=1,"
    echo "                            hung_task_panic=1 (sysctl live + persisted),"
    echo "                            panic=10 (GRUB)"
    echo "  --fix-all                 Apply all four above (with confirmation prompt)"
    echo "  --dry-run                 Show what --fix-all would do without changing anything"
    echo ""
    echo "Targeted experiments (one variable at a time, NOT in --fix-all):"
    echo "  --disable-cpu-boost       Turbo boost off now + persist via systemd unit"
    echo "                            (mitigation/test for HW marginality under boost transients)"
    echo "  --enable-cpu-boost        Re-enable turbo boost, remove persistence"
    echo "  --enable-iommu-strict     GRUB iommu.strict=1 — rogue device DMA becomes"
    echo "                            visible AMD-Vi IO_PAGE_FAULTs instead of silent corruption"
    echo "  --relax-panic             Revert panic-on-lockup posture once the system is"
    echo "                            proven stable (recover in place instead of rebooting)"
    echo ""
    echo "  --help                    Show this message"
    echo ""
    echo "Example:"
    echo "  diag-harden.sh --status"
    echo "  diag-harden.sh --dry-run"
    echo "  diag-harden.sh --fix-all"
    echo ""
    echo "After --fix-all, run:"
    echo "  sudo update-grub && sudo reboot"
}

# ---- Main ----

case "${1:-}" in
    --status)
        show_status
        ;;
    --enable-amdgpu-recovery)
        check_sudo
        GRUB_UPDATED=false
        apply_amdgpu_recovery
        if [ "$GRUB_UPDATED" = true ]; then
            echo ""
            echo -e "  ${YELLOW}Run${NC} sudo update-grub ${YELLOW}then reboot to apply.${NC}"
        fi
        ;;
    --disable-nvme-power-save)
        check_sudo
        GRUB_UPDATED=false
        apply_nvme_power_save
        if [ "$GRUB_UPDATED" = true ]; then
            echo ""
            echo -e "  ${YELLOW}Run${NC} sudo update-grub ${YELLOW}then reboot to apply.${NC}"
        fi
        ;;
    --panic-on-lockup)
        check_sudo
        GRUB_UPDATED=false
        apply_panic_on_lockup
        if [ "$GRUB_UPDATED" = true ]; then
            echo ""
            echo -e "  ${YELLOW}Run${NC} sudo update-grub ${YELLOW}then reboot to apply.${NC}"
        fi
        ;;
    --disable-deep-cstates)
        check_sudo
        GRUB_UPDATED=false
        apply_disable_deep_cstates
        if [ "$GRUB_UPDATED" = true ]; then
            echo ""
            echo -e "  ${YELLOW}Run${NC} sudo update-grub ${YELLOW}then reboot to apply.${NC}"
        fi
        ;;
    --disable-cpu-boost)
        check_sudo
        apply_disable_cpu_boost
        ;;
    --enable-cpu-boost)
        check_sudo
        apply_enable_cpu_boost
        ;;
    --enable-iommu-strict)
        check_sudo
        GRUB_UPDATED=false
        apply_iommu_strict
        if [ "$GRUB_UPDATED" = true ]; then
            echo ""
            echo -e "  ${YELLOW}Run${NC} sudo update-grub ${YELLOW}then reboot to apply.${NC}"
        fi
        ;;
    --relax-panic)
        check_sudo
        apply_relax_panic
        ;;
    --fix-all)
        check_sudo
        apply_fix_all
        ;;
    --dry-run)
        dry_run
        ;;
    --help|-h)
        show_help
        ;;
    *)
        echo "Usage: $0 [--status | --dry-run | --fix-all | --enable-amdgpu-recovery | --disable-nvme-power-save | --disable-deep-cstates | --panic-on-lockup | --disable-cpu-boost | --enable-cpu-boost | --enable-iommu-strict | --relax-panic]"
        echo "Try: $0 --help"
        exit 1
        ;;
esac

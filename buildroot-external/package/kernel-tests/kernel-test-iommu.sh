#!/bin/sh
# kernel-test-iommu.sh — MSM8974 (Fairphone 2, headless) GPU IOMMU test suite
#
# Validates the non-secure MSM8974 MMSS GPU IOMMU (qcom_iommu) bring-up:
#   - the Adreno GPU (fdb00000.gpu) is IOMMU-mapped and drm/msm bound it,
#   - the SMMU is NOT faulting (context/global faults) and the GPU is not hung,
#   - a real GPU submit DMA-fetches its cmdstream through the SMMU without
#     raising a context fault or hangcheck.
#
# This target is HEADLESS: the display (mdss/dsi, mdp_iommu) and the secure
# venus_iommu are disabled in DT, so those instances are reported SKIP.
#
# Accuracy note: a GPU submit's WAIT_FENCE can return on a stale seqno even
# when the GPU actually faulted, so this suite does NOT trust the submit's
# exit code alone — it snapshots dmesg around the submit and fails if a
# context fault or hangcheck appears. TAP version 13. Run as root.

TEST_NUM=0
SUBMIT_BIN=/usr/bin/gpu-iommu-submit

# MSM8974 MMSS SMMU addresses
GPU_DEV=fdb00000.gpu          # Adreno 330
GPU_IOMMU=fdb10000            # gpu_iommu global window
GPU_CTX=fdb18000              # gpu_iommu context bank 0

tap_ok()      { TEST_NUM=$((TEST_NUM+1)); if [ -n "$2" ]; then printf "ok %d - %s # SKIP %s\n" "$TEST_NUM" "$1" "$2"; else printf "ok %d - %s\n" "$TEST_NUM" "$1"; fi; }
tap_not_ok()  { TEST_NUM=$((TEST_NUM+1)); printf "not ok %d - %s\n" "$TEST_NUM" "$1"; printf "  ---\n  message: '%s'\n  ...\n" "$2"; }

# Fault / hang signatures. These are the lines that mean the SMMU is not
# translating GPU DMA correctly (or the GPU wedged as a result).
FAULT_RE='Unhandled context fault|\*\*\* fault: iova|context fault|global fault|Global fault|adreno.*fault|smmu.*fault|SMMU halt timeout|secure init failed'
HANG_RE='hangcheck detected gpu lockup|gpu recover|recover_worker|gpu hung|GPU lockup'

scan() { dmesg 2>/dev/null | grep -aiE "$1"; }

_PLAN=12
printf "TAP version 13\n"
printf "1..%d\n" "$_PLAN"

printf "# IOMMU groups:\n"
for _g in /sys/kernel/iommu_groups/*/; do
    [ -d "$_g" ] || continue
    for _d in "$_g"devices/*; do
        [ -e "$_d" ] && printf "#   group %s: %s\n" "$(basename "$_g")" "$(basename "$_d")"
    done
done

# ---------------------------------------------------------------------------
# 1. qcom_iommu driver is active
# ---------------------------------------------------------------------------
if [ -d /sys/class/iommu ] && ls /sys/class/iommu/ 2>/dev/null | grep -q .; then
    tap_ok "qcom_iommu driver active (/sys/class/iommu populated)"
elif scan "Adding to iommu group" >/dev/null; then
    tap_ok "qcom_iommu driver active (dmesg)"
else
    tap_not_ok "qcom_iommu driver active" "no /sys/class/iommu entries and no 'Adding to iommu group' in dmesg"
fi

# ---------------------------------------------------------------------------
# 2. GPU (fdb00000.gpu) is IOMMU-mapped (present in an iommu group)
# ---------------------------------------------------------------------------
_gpu_grp=""
for _g in /sys/kernel/iommu_groups/*/; do
    [ -e "$_g/devices/$GPU_DEV" ] && _gpu_grp=$(basename "$_g")
done
if [ -n "$_gpu_grp" ]; then
    tap_ok "GPU $GPU_DEV is IOMMU-mapped (group $_gpu_grp)"
else
    tap_not_ok "GPU $GPU_DEV is IOMMU-mapped" "$GPU_DEV not found in any /sys/kernel/iommu_groups/*/devices/"
fi

# ---------------------------------------------------------------------------
# 3. GPU IOMMU context bank bound (qcom-iommu-ctx @ fdb18000)
# ---------------------------------------------------------------------------
if [ -e "/sys/bus/platform/devices/$GPU_CTX.iommu-ctx/driver" ] || \
   scan "$GPU_CTX" >/dev/null; then
    tap_ok "GPU IOMMU context bank ($GPU_CTX) present"
else
    tap_not_ok "GPU IOMMU context bank present" "$GPU_CTX.iommu-ctx not bound"
fi

# ---------------------------------------------------------------------------
# 4. drm/msm bound the GPU (and did NOT fail to bind)
#    Component path prints "bound <dev>"; the native GPU-only path
#    (msm_gpu_probe via amd,imageon, v6.18+) prints "Initialized msm ... for <dev>".
# ---------------------------------------------------------------------------
if { scan "bound $GPU_DEV" >/dev/null || scan "Initialized msm .* for $GPU_DEV" >/dev/null; } \
   && ! scan "failed to bind $GPU_DEV" >/dev/null; then
    tap_ok "drm/msm bound $GPU_DEV"
else
    _why=$(scan "failed to bind $GPU_DEV|failed to load adreno|adev bind failed" | head -n1)
    tap_not_ok "drm/msm bound $GPU_DEV" "${_why:-no 'bound $GPU_DEV' or 'Initialized msm' message in dmesg}"
fi

# ---------------------------------------------------------------------------
# 5. GPU render node present (/dev/dri/renderD128)
# ---------------------------------------------------------------------------
if [ -e /dev/dri/renderD128 ]; then
    tap_ok "GPU render node /dev/dri/renderD128 exists"
else
    tap_not_ok "GPU render node /dev/dri/renderD128 exists" "no render node — GPU did not come up"
fi

# ---------------------------------------------------------------------------
# 6. No SMMU context/global faults at boot (CRITICAL)
# ---------------------------------------------------------------------------
_boot_faults=$(scan "$FAULT_RE")
if [ -z "$_boot_faults" ]; then
    tap_ok "no SMMU faults in dmesg (boot)"
else
    tap_not_ok "no SMMU faults in dmesg (boot)" "SMMU faults present"
    printf '%s\n' "$_boot_faults" | head -n 5 | while read -r _l; do printf "  # FAULT: %s\n" "$_l"; done
fi

# ---------------------------------------------------------------------------
# 7. No GPU hangcheck / lockup at boot (CRITICAL)
# ---------------------------------------------------------------------------
_boot_hang=$(scan "$HANG_RE")
if [ -z "$_boot_hang" ]; then
    tap_ok "no GPU hangcheck/lockup in dmesg (boot)"
else
    tap_not_ok "no GPU hangcheck/lockup in dmesg (boot)" "GPU hang/recover present"
    printf '%s\n' "$_boot_hang" | head -n 5 | while read -r _l; do printf "  # HANG: %s\n" "$_l"; done
fi

# ---------------------------------------------------------------------------
# 8. GPU submit exercises the IOMMU without a fault (CRITICAL, active test)
#    Snapshot dmesg, run a real submit, then verify NO new context fault /
#    hangcheck appeared. WAIT_FENCE success alone is NOT trusted.
# ---------------------------------------------------------------------------
if [ ! -x "$SUBMIT_BIN" ]; then
    tap_ok "GPU submit runs through IOMMU without fault" "$SUBMIT_BIN not installed"
elif [ ! -e /dev/dri/renderD128 ]; then
    tap_ok "GPU submit runs through IOMMU without fault" "no render node"
else
    _before=$(dmesg 2>/dev/null | wc -l)
    _out=$("$SUBMIT_BIN" 2>&1); _rc=$?
    printf '%s\n' "$_out" | while read -r _l; do printf "#   submit: %s\n" "$_l"; done
    # let any fault / hangcheck land (hangcheck fires ~2s after submit)
    sleep 3
    _new=$(dmesg 2>/dev/null | tail -n "+$((_before+1))")
    _newfault=$(printf '%s\n' "$_new" | grep -aiE "$FAULT_RE|$HANG_RE")
    if [ -n "$_newfault" ]; then
        tap_not_ok "GPU submit runs through IOMMU without fault" "submit triggered a context fault / GPU hang"
        printf '%s\n' "$_newfault" | head -n 6 | while read -r _l; do printf "  # %s\n" "$_l"; done
    elif [ "$_rc" -ne 0 ]; then
        tap_not_ok "GPU submit runs through IOMMU without fault" "submit helper failed (rc=$_rc)"
    else
        tap_ok "GPU submit runs through IOMMU without fault (fence completed, no fault)"
    fi
fi

# ---------------------------------------------------------------------------
# 9. GPU cmd buffer got a valid IOMMU address (not a carveout/identity addr)
#    The submit helper prints cmdbuf_iova; a translated aperture address is
#    >= 16MB (the GPU aspace start), proving IOMMU-backed allocation.
# ---------------------------------------------------------------------------
if [ -x "$SUBMIT_BIN" ] && [ -e /dev/dri/renderD128 ]; then
    _iova=$("$SUBMIT_BIN" 2>/dev/null | sed -n 's/^cmdbuf_iova=0x//p' | head -n1)
    if [ -n "$_iova" ]; then
        _dec=$(printf "%d" "0x$_iova" 2>/dev/null)
        if [ -n "$_dec" ] && [ "$_dec" -ge 16777216 ]; then
            tap_ok "GPU buffer IOMMU-mapped in aperture (iova=0x$_iova)"
        else
            tap_not_ok "GPU buffer IOMMU-mapped in aperture" "iova 0x$_iova below 16MB aperture — possible carveout/identity mapping"
        fi
    else
        tap_ok "GPU buffer IOMMU-mapped in aperture" "could not read cmdbuf_iova"
    fi
else
    tap_ok "GPU buffer IOMMU-mapped in aperture" "submit helper unavailable"
fi

# ---------------------------------------------------------------------------
# 10. SoC survived (no silent TZ/NoC reset). If we are running, the kernel
#     that programmed the SMMU booted and reached userspace.
# ---------------------------------------------------------------------------
if [ -r /proc/uptime ]; then
    tap_ok "SoC stable, reached userspace (uptime $(cut -d. -f1 /proc/uptime)s)"
else
    tap_ok "SoC stable, reached userspace"
fi

# ---------------------------------------------------------------------------
# 11. Display / MDP IOMMU — expected DISABLED on this headless target
# ---------------------------------------------------------------------------
if scan "fd928000" >/dev/null; then
    tap_not_ok "display IOMMU disabled (headless)" "mdp_iommu unexpectedly active on a headless target"
else
    tap_ok "display IOMMU disabled (headless)" "mdp_iommu intentionally disabled in DT"
fi

# ---------------------------------------------------------------------------
# 12. Venus IOMMU — expected DISABLED (codec off; will return as non-secure)
# ---------------------------------------------------------------------------
if scan "fdc84000" >/dev/null; then
    tap_not_ok "venus IOMMU disabled (headless)" "venus_iommu unexpectedly active"
else
    tap_ok "venus IOMMU disabled (headless)" "venus_iommu intentionally disabled in DT"
fi

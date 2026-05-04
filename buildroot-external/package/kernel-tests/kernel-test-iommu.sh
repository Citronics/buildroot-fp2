#!/bin/sh
# kernel-test-iommu.sh — IOMMU TAP v13 test suite
# Platform: Fairphone 2, Qualcomm MSM8974 Pro (Snapdragon 801)
# IOMMU driver: qcom-iommu / qcom_iommu (CONFIG_QCOM_IOMMU=y)
# IOMMU instances: mdp_iommu, gpu_iommu, venus_iommu
#
# TAP version 13 — https://testanything.org/tap-version-13-specification.html
# Usage: sh kernel-test-iommu.sh
# Run as root for full dmesg access.

# ---------------------------------------------------------------------------
# Test counter
# ---------------------------------------------------------------------------
TEST_NUM=0

# ---------------------------------------------------------------------------
# TAP helpers
# ---------------------------------------------------------------------------
tap_ok() {
    # tap_ok <description> [skip_reason]
    TEST_NUM=$(( TEST_NUM + 1 ))
    if [ -n "$2" ]; then
        printf "ok %d - %s # SKIP %s\n" "$TEST_NUM" "$1" "$2"
    else
        printf "ok %d - %s\n" "$TEST_NUM" "$1"
    fi
}

tap_not_ok() {
    # tap_not_ok <description> <message>
    TEST_NUM=$(( TEST_NUM + 1 ))
    printf "not ok %d - %s\n" "$TEST_NUM" "$1"
    printf "  ---\n"
    printf "  message: '%s'\n" "$2"
    printf "  ...\n"
}

# ---------------------------------------------------------------------------
# Static plan — 11 tests always emitted (some may be SKIP)
#   1  /sys/kernel/iommu_groups/ exists and is readable
#   2  /sys/class/iommu/ exists
#   3  IOMMU groups count > 0
#   4  dmesg shows qcom-iommu probe messages (driver active)
#   5  MDP/display device found in an IOMMU group
#   6  GPU/Adreno device found in an IOMMU group
#   7  Venus/video device found in an IOMMU group
#   8  No IOMMU faults in dmesg
#   9  IOMMU context banks registered in dmesg
#  10  No unexpected IOMMU bypass in dmesg
#  11  No new IOMMU warnings during test run
# ---------------------------------------------------------------------------
_PLAN=11

# ---------------------------------------------------------------------------
# Output TAP header
# ---------------------------------------------------------------------------
printf "TAP version 13\n"
printf "1..%d\n" "$_PLAN"

# ---------------------------------------------------------------------------
# Diagnostic: enumerate IOMMU groups (informational, not TAP tests)
# ---------------------------------------------------------------------------
printf "# IOMMU group enumeration:\n"
for _grp in /sys/kernel/iommu_groups/*/; do
    [ -d "$_grp" ] || continue
    _gidx=$(basename "$_grp")
    printf "# Group %s:\n" "$_gidx"
    for _dev in "$_grp"devices/*; do
        [ -e "$_dev" ] && printf "#   device: %s\n" "$(basename "$_dev")"
    done
done

# ---------------------------------------------------------------------------
# Baseline dmesg line count (used by test 11)
# ---------------------------------------------------------------------------
_dmesg_before_count=$(dmesg 2>/dev/null | wc -l)

# ---------------------------------------------------------------------------
# Test 1: /sys/kernel/iommu_groups/ exists and is readable
# ---------------------------------------------------------------------------
if [ ! -d /sys/kernel/iommu_groups ]; then
    tap_ok "iommu_groups directory exists" "IOMMU not available"
    _i=2
    while [ "$_i" -le 11 ]; do
        TEST_NUM=$(( TEST_NUM + 1 ))
        printf "ok %d - skipped # SKIP IOMMU not available\n" "$TEST_NUM"
        _i=$(( _i + 1 ))
    done
    exit 0
fi
tap_ok "iommu_groups directory exists"

# ---------------------------------------------------------------------------
# Test 2: /sys/class/iommu/ exists
# ---------------------------------------------------------------------------
if [ -d /sys/class/iommu ]; then
    tap_ok "sys/class/iommu directory exists"
else
    tap_not_ok "sys/class/iommu directory exists" "/sys/class/iommu not found"
fi

# ---------------------------------------------------------------------------
# Test 3: IOMMU groups count > 0
# ---------------------------------------------------------------------------
_count=0
for _d in /sys/kernel/iommu_groups/*/; do
    [ -d "$_d" ] && _count=$(( _count + 1 ))
done
printf "# IOMMU group count: %d\n" "$_count"
if [ "$_count" -gt 0 ]; then
    tap_ok "IOMMU groups count > 0 (found ${_count})"
else
    tap_not_ok "IOMMU groups count > 0" "no IOMMU groups found under /sys/kernel/iommu_groups/"
fi

# ---------------------------------------------------------------------------
# Test 4: dmesg shows qcom-iommu probe messages (driver active)
# ---------------------------------------------------------------------------
_probe=$(dmesg 2>/dev/null | grep -i "qcom.iommu\|qcom_iommu" | grep -i "probe\|init\|attach\|add" | head -n 3)
if [ -n "$_probe" ]; then
    tap_ok "qcom-iommu driver active in dmesg"
else
    tap_not_ok "qcom-iommu driver active in dmesg" "no qcom-iommu probe messages in dmesg"
fi
printf "# driver messages:\n"
dmesg 2>/dev/null | grep -i "qcom.iommu\|qcom_iommu" | head -n 5 | while read -r _line; do
    printf "#   %s\n" "$_line"
done

# ---------------------------------------------------------------------------
# Test 5: MDP/display device found in an IOMMU group
# ---------------------------------------------------------------------------
_mdp_found=0
for _grp in /sys/kernel/iommu_groups/*/; do
    for _dev in "$_grp"devices/*; do
        _devpath=$(readlink -f "$_dev" 2>/dev/null)
        case "$_devpath" in
            *fd928000*|*fd900000*)
                _mdp_found=1
                printf "#   MDP device: %s\n" "$_devpath"
                ;;
        esac
    done
done
if [ "$_mdp_found" -eq 1 ]; then
    tap_ok "MDP/display device found in IOMMU group"
else
    tap_ok "MDP/display device found in IOMMU group" "display device not found in any IOMMU group"
fi

# ---------------------------------------------------------------------------
# Test 6: GPU/Adreno device found in an IOMMU group
# ---------------------------------------------------------------------------
_gpu_found=0
for _grp in /sys/kernel/iommu_groups/*/; do
    for _dev in "$_grp"devices/*; do
        _devpath=$(readlink -f "$_dev" 2>/dev/null)
        case "$_devpath" in
            *fdb10000*|*fdb00000*)
                _gpu_found=1
                printf "#   GPU device: %s\n" "$_devpath"
                ;;
        esac
    done
done
if [ "$_gpu_found" -eq 1 ]; then
    tap_ok "GPU/Adreno device found in IOMMU group"
else
    tap_ok "GPU/Adreno device found in IOMMU group" "GPU device not found in any IOMMU group"
fi

# ---------------------------------------------------------------------------
# Test 7: Venus/video device found in an IOMMU group (may not be probed)
# ---------------------------------------------------------------------------
_venus_found=0
for _grp in /sys/kernel/iommu_groups/*/; do
    for _dev in "$_grp"devices/*; do
        _devpath=$(readlink -f "$_dev" 2>/dev/null)
        case "$_devpath" in
            *fdc84000*|*fdc00000*)
                _venus_found=1
                printf "#   Venus device: %s\n" "$_devpath"
                ;;
        esac
    done
done
if [ "$_venus_found" -eq 1 ]; then
    tap_ok "Venus/video device found in IOMMU group"
else
    tap_ok "Venus/video device found in IOMMU group" "venus device not probed or not in IOMMU group"
fi

# ---------------------------------------------------------------------------
# Test 8: No IOMMU faults in dmesg (CRITICAL)
# ---------------------------------------------------------------------------
_faults=$(dmesg 2>/dev/null | grep -iE "iommu.*(fault|error|stall|exception)|translation.*(error|fault)|context.*(fault|stall)|Unhandled.*context")
if [ -n "$_faults" ]; then
    tap_not_ok "no IOMMU faults in dmesg" "faults detected"
    printf '%s\n' "$_faults" | head -n 5 | while read -r _line; do
        printf "  # FAULT: %s\n" "$_line"
    done
else
    tap_ok "no IOMMU faults in dmesg"
fi

# ---------------------------------------------------------------------------
# Test 9: Context bank registration in dmesg
# ---------------------------------------------------------------------------
_bank_count=0
for _bank in "mdp_0" "GFX3D" "venus_ns"; do
    dmesg 2>/dev/null | grep -qi "$_bank" && _bank_count=$(( _bank_count + 1 ))
done
printf "# known context banks seen: %d/3\n" "$_bank_count"
dmesg 2>/dev/null | grep -iE "mdp_0|GFX3D|venus_ns|context bank" | head -n 10 | while read -r _line; do
    printf "#   %s\n" "$_line"
done
if [ "$_bank_count" -gt 0 ]; then
    tap_ok "IOMMU context banks registered in dmesg (found ${_bank_count}/3)"
else
    tap_not_ok "IOMMU context banks registered in dmesg" "no known context bank names found (mdp_0, GFX3D, venus_ns)"
fi

# ---------------------------------------------------------------------------
# Test 10: DMA bypass check — no unexpected passthrough/bypass warnings
# ---------------------------------------------------------------------------
_bypass=$(dmesg 2>/dev/null | grep -iE "iommu.*(bypass|passthrough|direct)" | grep -iv "disable.*bypass")
if [ -n "$_bypass" ]; then
    tap_not_ok "no unexpected IOMMU bypass" "bypass detected for IOMMU device"
    printf '%s\n' "$_bypass" | head -n 3 | while read -r _line; do
        printf "#   %s\n" "$_line"
    done
else
    tap_ok "no unexpected IOMMU bypass in dmesg"
fi

# ---------------------------------------------------------------------------
# Test 11: No new IOMMU warnings during test run (dmesg side-effect)
# ---------------------------------------------------------------------------
_new_lines=$(dmesg 2>/dev/null | tail -n "+${_dmesg_before_count}" 2>/dev/null)
_new_warn=$(printf '%s\n' "$_new_lines" | grep -iE "iommu.*(warning|error|fault)" 2>/dev/null)
if [ -z "$_new_warn" ]; then
    tap_ok "no new IOMMU warnings during test run"
else
    tap_not_ok "no new IOMMU warnings during test run" "new warnings appeared"
    printf '%s\n' "$_new_warn" | head -n 3 | while read -r _line; do
        printf "#   %s\n" "$_line"
    done
fi

#!/bin/sh
# kernel-tests-run.sh — Master test runner for kernel-tests package
# Executes all kernel test scripts and aggregates results.
# TAP version 13 output wrapping sub-test suites.

# ---------------------------------------------------------------------------
# Temp file cleanup
# ---------------------------------------------------------------------------
TMPDIR_RUN="/tmp/kernel-tests-$$"
mkdir -p "$TMPDIR_RUN"

runner_cleanup() {
    rm -rf "$TMPDIR_RUN"
}
trap runner_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# TAP header (wraps 3 sub-tests)
# ---------------------------------------------------------------------------
printf "TAP version 13\n"
printf "1..3\n"

# ---------------------------------------------------------------------------
# Print device/kernel info header
# ---------------------------------------------------------------------------
printf "# Kernel Test Suite\n"
printf "# Host: %s\n" "$(uname -n 2>/dev/null)"
printf "# Kernel: %s\n" "$(uname -r 2>/dev/null)"
printf "# Date: %s\n" "$(date 2>/dev/null)"

# ---------------------------------------------------------------------------
# run_test <name> <test_num>
# Runs the named test script, saves output, parses TAP, returns pass/fail/skip counts
# ---------------------------------------------------------------------------
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
DVFS_PASS=0;  DVFS_FAIL=0;  DVFS_SKIP=0
THERM_PASS=0; THERM_FAIL=0; THERM_SKIP=0
IOMMU_PASS=0; IOMMU_FAIL=0; IOMMU_SKIP=0

run_test() {
    _name="$1"
    _num="$2"
    _script="/usr/bin/${_name}"
    _outfile="${TMPDIR_RUN}/${_name}.tap"

    printf "# --- Running: %s ---\n" "$_name"

    # Check script exists and is executable
    if [ ! -x "$_script" ]; then
        printf "not ok %d - %s\n" "$_num" "$_name"
        printf "  ---\n"
        printf "  message: '%s not found or not executable'\n" "$_script"
        printf "  ...\n"
        TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
        return 1
    fi

    # Run script, capture output to temp file AND forward to stdout
    "$_script" | tee "$_outfile"

    # Parse TAP output — SKIP lines are "ok N - ... # SKIP ...", count separately
    _pass=$(grep -c '^ok ' "$_outfile" 2>/dev/null); _pass=${_pass:-0}
    _fail=$(grep -c '^not ok ' "$_outfile" 2>/dev/null); _fail=${_fail:-0}
    _skip=$(grep -c '# SKIP' "$_outfile" 2>/dev/null); _skip=${_skip:-0}
    _pass=$(( _pass - _skip ))

    printf "# %s: %d pass, %d fail, %d skip\n" "$_name" "$_pass" "$_fail" "$_skip"

    TOTAL_PASS=$(( TOTAL_PASS + _pass ))
    TOTAL_FAIL=$(( TOTAL_FAIL + _fail ))
    TOTAL_SKIP=$(( TOTAL_SKIP + _skip ))

    # Emit wrapper TAP result
    if [ "$_fail" -eq 0 ]; then
        printf "ok %d - %s (%d pass, %d fail, %d skip)\n" \
            "$_num" "$_name" "$_pass" "$_fail" "$_skip"
    else
        printf "not ok %d - %s (%d pass, %d fail, %d skip)\n" \
            "$_num" "$_name" "$_pass" "$_fail" "$_skip"
    fi
}

run_test "kernel-test-dvfs" 1
DVFS_PASS=$_pass; DVFS_FAIL=$_fail; DVFS_SKIP=$_skip

run_test "kernel-test-thermal" 2
THERM_PASS=$_pass; THERM_FAIL=$_fail; THERM_SKIP=$_skip

run_test "kernel-test-iommu" 3
IOMMU_PASS=$_pass; IOMMU_FAIL=$_fail; IOMMU_SKIP=$_skip

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
printf "\n"
printf "=== Kernel Test Results ===\n"
printf "%-12s %d pass, %d fail, %d skip\n" "DVFS:"    "$DVFS_PASS"  "$DVFS_FAIL"  "$DVFS_SKIP"
printf "%-12s %d pass, %d fail, %d skip\n" "Thermal:"  "$THERM_PASS" "$THERM_FAIL" "$THERM_SKIP"
printf "%-12s %d pass, %d fail, %d skip\n" "IOMMU:"   "$IOMMU_PASS" "$IOMMU_FAIL" "$IOMMU_SKIP"
printf -- "---\n"
printf "%-12s %d pass, %d fail, %d skip\n" \
    "TOTAL:" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"

# ---------------------------------------------------------------------------
# Exit code: 0 if no failures, 1 if any
# ---------------------------------------------------------------------------
if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

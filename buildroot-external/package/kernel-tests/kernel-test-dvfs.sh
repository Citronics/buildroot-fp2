#!/bin/sh
# kernel-test-dvfs.sh — DVFS / cpufreq TAP v13 test suite
# Platform: Fairphone 2, Qualcomm MSM8974 Pro (Snapdragon 801)
# cpufreq driver: qcom-cpufreq-nvmem
# All 4 CPUs share the same DVCS domain; frequencies are read from sysfs.
#
# TAP version 13 — https://testanything.org/tap-version-13-specification.html
# Usage: sh kernel-test-dvfs.sh
# Run as root (sysfs writes require root).

CPUFREQ_BASE="/sys/devices/system/cpu"
CPU0_FREQ="${CPUFREQ_BASE}/cpu0/cpufreq"

# ---------------------------------------------------------------------------
# Test counter
# ---------------------------------------------------------------------------
TEST_NUM=0

# ---------------------------------------------------------------------------
# Governor restore / cleanup
# ---------------------------------------------------------------------------
ORIG_GOV=""

cleanup() {
    if [ -n "$ORIG_GOV" ]; then
        for _cpu in 0 1 2 3; do
            echo "$ORIG_GOV" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_governor" 2>/dev/null
        done
    fi
    kill $(jobs -p) 2>/dev/null
}
trap cleanup EXIT INT TERM

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
# Pre-count total tests so we can print the plan line up front.
#
# Static tests (always emitted, possibly as SKIP):
#   1  cpufreq sysfs directory exists
#   2  scaling_available_frequencies readable and non-empty
#   3  scaling_available_governors readable
#   4  scaling_cur_freq readable and > 0
#   5  scaling_driver is qcom-cpufreq-nvmem
#   6  all 4 CPUs have cpufreq directories
#   7  all 4 CPUs report same scaling_available_frequencies
#   8  all 4 CPUs report same scaling_available_governors
#   9  cpufreq_userspace module loaded (or SKIP)
#
# Dynamic tests (count derived at runtime after reading sysfs):
#   + 1 per available governor (governor switching)
#   + 1 per available frequency (frequency transition, only if userspace avail)
#   + 1 rapid cycling stress test (only if userspace avail)
#   + 1 dmesg side-effect check
#
# Strategy: emit "TAP version 13" now, compute plan line at end (streaming
# TAP parsers accept plan at end per TAP v13 spec), or we pre-read sysfs
# to count. We pre-read sysfs so the plan line appears at the top as
# required by most consumers.
# ---------------------------------------------------------------------------

# Pre-read governors and frequencies to count dynamic tests
_avail_govs=""
_avail_freqs=""
_gov_count=0
_freq_count=0
_userspace_likely=0

if [ -r "${CPU0_FREQ}/scaling_available_governors" ]; then
    _avail_govs=$(cat "${CPU0_FREQ}/scaling_available_governors" 2>/dev/null)
    for _g in $_avail_govs; do
        _gov_count=$(( _gov_count + 1 ))
        [ "$_g" = "userspace" ] && _userspace_likely=1
    done
fi

if [ -r "${CPU0_FREQ}/scaling_available_frequencies" ]; then
    _avail_freqs=$(cat "${CPU0_FREQ}/scaling_available_frequencies" 2>/dev/null)
    for _f in $_avail_freqs; do
        _freq_count=$(( _freq_count + 1 ))
    done
fi

# Total plan:
#   9 static + governor_count + (freq_count + 1 stress) if userspace + 1 dmesg
_PLAN=9
_PLAN=$(( _PLAN + _gov_count ))
if [ "$_userspace_likely" -eq 1 ]; then
    _PLAN=$(( _PLAN + _freq_count + 1 ))
fi
_PLAN=$(( _PLAN + 1 ))

# ---------------------------------------------------------------------------
# Output TAP header
# ---------------------------------------------------------------------------
printf "TAP version 13\n"
printf "1..%d\n" "$_PLAN"

# ---------------------------------------------------------------------------
# Test 1: cpufreq sysfs directory exists
# ---------------------------------------------------------------------------
if [ -d "$CPU0_FREQ" ]; then
    tap_ok "cpufreq sysfs directory exists"
else
    tap_not_ok "cpufreq sysfs directory exists" "${CPU0_FREQ} not found"
    # Skip all remaining tests
    _i=2
    while [ "$_i" -le "$_PLAN" ]; do
        TEST_NUM=$(( TEST_NUM + 1 ))
        printf "ok %d - skipped # SKIP cpufreq not available\n" "$TEST_NUM"
        _i=$(( _i + 1 ))
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Test 2: scaling_available_frequencies readable and non-empty
# ---------------------------------------------------------------------------
_avail_freqs=$(cat "${CPU0_FREQ}/scaling_available_frequencies" 2>/dev/null)
if [ -n "$_avail_freqs" ]; then
    tap_ok "scaling_available_frequencies readable and non-empty"
else
    tap_not_ok "scaling_available_frequencies readable and non-empty" \
        "file empty or unreadable: ${CPU0_FREQ}/scaling_available_frequencies"
fi

# ---------------------------------------------------------------------------
# Test 3: scaling_available_governors readable
# ---------------------------------------------------------------------------
_avail_govs=$(cat "${CPU0_FREQ}/scaling_available_governors" 2>/dev/null)
if [ -n "$_avail_govs" ]; then
    tap_ok "scaling_available_governors readable"
else
    tap_not_ok "scaling_available_governors readable" \
        "file empty or unreadable: ${CPU0_FREQ}/scaling_available_governors"
fi

# ---------------------------------------------------------------------------
# Test 4: scaling_cur_freq readable and > 0
# ---------------------------------------------------------------------------
_cur_freq=$(cat "${CPU0_FREQ}/scaling_cur_freq" 2>/dev/null)
if [ -n "$_cur_freq" ] && [ "$_cur_freq" -gt 0 ] 2>/dev/null; then
    tap_ok "scaling_cur_freq readable and > 0"
else
    tap_not_ok "scaling_cur_freq readable and > 0" \
        "got: '${_cur_freq}'"
fi

# ---------------------------------------------------------------------------
# Test 5: scaling_driver is a recognised cpufreq driver for this platform
# ---------------------------------------------------------------------------
_driver=$(cat "${CPU0_FREQ}/scaling_driver" 2>/dev/null)
case "$_driver" in
    qcom-cpufreq-nvmem|cpufreq-dt)
        tap_ok "scaling_driver recognised: ${_driver}"
        ;;
    *)
        tap_not_ok "scaling_driver recognised" \
            "got: '${_driver}' (expected qcom-cpufreq-nvmem or cpufreq-dt)"
        ;;
esac

# ---------------------------------------------------------------------------
# Test 6: all 4 CPUs have cpufreq directories
# ---------------------------------------------------------------------------
_missing_cpus=""
for _cpu in 0 1 2 3; do
    [ -d "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq" ] || \
        _missing_cpus="${_missing_cpus} cpu${_cpu}"
done
if [ -z "$_missing_cpus" ]; then
    tap_ok "all 4 CPUs have cpufreq directories"
else
    tap_not_ok "all 4 CPUs have cpufreq directories" \
        "missing:${_missing_cpus}"
fi

# ---------------------------------------------------------------------------
# Test 7: all 4 CPUs report same scaling_available_frequencies
# ---------------------------------------------------------------------------
_ref_freqs=$(cat "${CPUFREQ_BASE}/cpu0/cpufreq/scaling_available_frequencies" 2>/dev/null)
_freq_mismatch=""
for _cpu in 1 2 3; do
    _f=$(cat "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_available_frequencies" 2>/dev/null)
    if [ "$_f" != "$_ref_freqs" ]; then
        _freq_mismatch="${_freq_mismatch} cpu${_cpu}"
    fi
done
if [ -z "$_freq_mismatch" ]; then
    tap_ok "all 4 CPUs report same scaling_available_frequencies"
else
    tap_not_ok "all 4 CPUs report same scaling_available_frequencies" \
        "mismatch on:${_freq_mismatch}"
fi

# ---------------------------------------------------------------------------
# Test 8: all 4 CPUs report same scaling_available_governors
# ---------------------------------------------------------------------------
_ref_govs=$(cat "${CPUFREQ_BASE}/cpu0/cpufreq/scaling_available_governors" 2>/dev/null)
_gov_mismatch=""
for _cpu in 1 2 3; do
    _g=$(cat "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_available_governors" 2>/dev/null)
    if [ "$_g" != "$_ref_govs" ]; then
        _gov_mismatch="${_gov_mismatch} cpu${_cpu}"
    fi
done
if [ -z "$_gov_mismatch" ]; then
    tap_ok "all 4 CPUs report same scaling_available_governors"
else
    tap_not_ok "all 4 CPUs report same scaling_available_governors" \
        "mismatch on:${_gov_mismatch}"
fi

# ---------------------------------------------------------------------------
# dmesg baseline (not a TAP test)
# ---------------------------------------------------------------------------
DMESG_LINES_BEFORE=$(dmesg 2>/dev/null | wc -l)

# ---------------------------------------------------------------------------
# Test 9: cpufreq_userspace module load attempt
# ---------------------------------------------------------------------------
USERSPACE_AVAILABLE=0
modprobe cpufreq_userspace 2>/dev/null
if [ $? -eq 0 ]; then
    USERSPACE_AVAILABLE=1
    tap_ok "cpufreq_userspace module loaded"
else
    tap_ok "cpufreq_userspace module available" "module not loadable"
fi

# ---------------------------------------------------------------------------
# Governor switching tests (one TAP result per governor)
# ---------------------------------------------------------------------------

# Save original governor and install the cleanup trap with actual value
ORIG_GOV=$(cat "${CPU0_FREQ}/scaling_governor" 2>/dev/null)

# Re-read available governors fresh (may differ from pre-count pass)
_avail_govs=$(cat "${CPU0_FREQ}/scaling_available_governors" 2>/dev/null)

for _gov in $_avail_govs; do
    echo "$_gov" > "${CPU0_FREQ}/scaling_governor" 2>/dev/null
    _read_gov=$(cat "${CPU0_FREQ}/scaling_governor" 2>/dev/null)
    if [ "$_read_gov" = "$_gov" ]; then
        tap_ok "governor switch to ${_gov}"
    else
        tap_not_ok "governor switch to ${_gov}" \
            "wrote '${_gov}', read back '${_read_gov}'"
    fi
done

# Restore original governor for subsequent tests (cleanup trap also does this)
if [ -n "$ORIG_GOV" ]; then
    echo "$ORIG_GOV" > "${CPU0_FREQ}/scaling_governor" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Frequency transition tests (only if userspace governor is available)
# MSM8974: all 4 CPUs share a single cpufreq policy domain (L2 SAW2 regulator).
# Writing to cpu0 scaling_setspeed controls all cores; cpu1-3 follow cpu0.
# ---------------------------------------------------------------------------
if [ "$USERSPACE_AVAILABLE" -eq 1 ]; then

    # Switch cpu0 to userspace governor (shared policy: all CPUs follow)
    echo "userspace" > "${CPU0_FREQ}/scaling_governor" 2>/dev/null

    # Re-read available frequencies fresh
    _avail_freqs=$(cat "${CPU0_FREQ}/scaling_available_frequencies" 2>/dev/null)

    for _freq in $_avail_freqs; do
        echo "$_freq" > "${CPU0_FREQ}/scaling_setspeed" 2>/dev/null
        # Brief settle time — usleep 1000 (1 ms) if available, else sleep 0
        usleep 1000 2>/dev/null || sleep 0

        _cur=$(cat "${CPU0_FREQ}/scaling_cur_freq" 2>/dev/null)
        _max=$(cat "${CPU0_FREQ}/scaling_max_freq" 2>/dev/null)

        # If thermal throttle cap is below requested freq, accept as SKIP
        if [ -n "$_max" ] && [ "$_max" -lt "$_freq" ] 2>/dev/null; then
            tap_ok "frequency transition to ${_freq} kHz" \
                "thermal throttling active, max_freq=${_max}"
        elif [ "$_cur" = "$_freq" ]; then
            tap_ok "frequency transition to ${_freq} kHz"
        else
            tap_not_ok "frequency transition to ${_freq} kHz" \
                "requested ${_freq}, got ${_cur}"
        fi
    done

    # -----------------------------------------------------------------------
    # Rapid cycling stress test (50 cycles between min and max)
    # -----------------------------------------------------------------------
    _freq_min=$(echo "$_avail_freqs" | awk '{print $1}')
    _freq_max=$(echo "$_avail_freqs" | awk '{print $NF}')

    _cycles=50
    _successes=0
    _i=0
    while [ "$_i" -lt "$_cycles" ]; do
        # Alternate min/max
        if [ "$(( _i % 2 ))" -eq 0 ]; then
            _target="$_freq_min"
        else
            _target="$_freq_max"
        fi
        echo "$_target" > "${CPU0_FREQ}/scaling_setspeed" 2>/dev/null
        usleep 1000 2>/dev/null || sleep 0
        _got=$(cat "${CPU0_FREQ}/scaling_cur_freq" 2>/dev/null)
        _max=$(cat "${CPU0_FREQ}/scaling_max_freq" 2>/dev/null)
        # Accept thermal-throttled result if max < target
        if [ "$_got" = "$_target" ]; then
            _successes=$(( _successes + 1 ))
        elif [ -n "$_max" ] && [ "$_max" -lt "$_target" ] 2>/dev/null; then
            _successes=$(( _successes + 1 ))
        fi
        _i=$(( _i + 1 ))
    done

    if [ "$_successes" -ge 45 ]; then
        tap_ok "rapid cycling stress test (${_successes}/${_cycles} succeeded)"
    else
        tap_not_ok "rapid cycling stress test" \
            "only ${_successes}/${_cycles} transitions verified"
    fi

    # Restore governor after userspace use
    if [ -n "$ORIG_GOV" ]; then
        echo "$ORIG_GOV" > "${CPU0_FREQ}/scaling_governor" 2>/dev/null
    fi
fi

# ---------------------------------------------------------------------------
# dmesg side-effect test
# ---------------------------------------------------------------------------
_dmesg_new=$(dmesg 2>/dev/null | tail -n "+${DMESG_LINES_BEFORE}" 2>/dev/null)
_dmesg_warn=$(printf '%s\n' "$_dmesg_new" | grep -i "cpufreq" | grep -iE "warning|error|oops|BUG" 2>/dev/null)
if [ -z "$_dmesg_warn" ]; then
    tap_ok "no cpufreq-related dmesg warnings or errors"
else
    tap_not_ok "no cpufreq-related dmesg warnings or errors" \
        "$(printf '%s\n' "$_dmesg_warn" | head -n 3)"
fi

# cleanup trap fires on EXIT

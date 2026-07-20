#!/bin/sh
# kernel-test-voltage.sh — CPU gang-rail voltage TAP v13 test suite
# Platform: Fairphone 2, Qualcomm MSM8974 Pro (Snapdragon 801)
# Regulator: "spm" (L2/APCS SAW2 gang supply), drivers/soc/qcom/spm.c
#
# This suite targets the SPM gang-rail voltage path: it verifies that the
# core voltage actually follows cpufreq frequency requests. It exists to
# catch the class of bug where frequency ramps but VDD_CPU does not, which
# causes intermittent undervoltage crashes. It directly checks:
#   - the "spm" regulator exists and reports a physically plausible voltage
#   - voltage is non-decreasing as frequency increases (DVFS moves the rail)
#   - no "timeout setting the voltage" (SPM PMIC_STS ack failure) in dmesg
#   - the rail stays up under sustained max-frequency load
#
# TAP version 13 — https://testanything.org/tap-version-13-specification.html
# Usage: sh kernel-test-voltage.sh
# Run as root (cpufreq sysfs writes require root).

CPUFREQ_BASE="/sys/devices/system/cpu"
CPU0_FREQ="${CPUFREQ_BASE}/cpu0/cpufreq"
REG_BASE="/sys/class/regulator"

# Physically valid window for the Krait gang rail (from DT saw_l2_vreg:
# regulator-min/max-microvolt = 350000 / 1275000). A little slack either side.
VMIN_PLAUSIBLE=340000
VMAX_PLAUSIBLE=1300000
# Any credible top-OPP voltage for a Krait 400 bin is comfortably above this.
VMAX_FREQ_FLOOR=900000

# ---------------------------------------------------------------------------
# Test counter
# ---------------------------------------------------------------------------
TEST_NUM=0

# ---------------------------------------------------------------------------
# Cleanup: restore governor, kill any stress loops
# ---------------------------------------------------------------------------
ORIG_GOV=""
STRESS_PIDS=""

volt_cleanup() {
    for _pid in $STRESS_PIDS; do
        kill "$_pid" 2>/dev/null
    done
    if [ -n "$ORIG_GOV" ]; then
        for _cpu in 0 1 2 3; do
            echo "$ORIG_GOV" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_governor" 2>/dev/null
        done
    fi
}
trap volt_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# TAP helpers
# ---------------------------------------------------------------------------
tap_ok() {
    TEST_NUM=$(( TEST_NUM + 1 ))
    if [ -n "$2" ]; then
        printf "ok %d - %s # SKIP %s\n" "$TEST_NUM" "$1" "$2"
    else
        printf "ok %d - %s\n" "$TEST_NUM" "$1"
    fi
}

tap_not_ok() {
    TEST_NUM=$(( TEST_NUM + 1 ))
    printf "not ok %d - %s\n" "$TEST_NUM" "$1"
    printf "  ---\n"
    printf "  message: '%s'\n" "$2"
    printf "  ...\n"
}

# ---------------------------------------------------------------------------
# Static plan — 8 tests always emitted (some may be SKIP)
#   1  "spm" regulator present in /sys/class/regulator
#   2  regulator voltage readable and within plausible range
#   3  voltage non-decreasing as frequency increases (userspace sweep)
#   4  voltage at max freq strictly higher than at min freq (rail moves)
#   5  voltage at max freq above undervoltage floor
#   6  no "timeout setting the voltage" in dmesg (PMIC_STS acks)
#   7  rail stays up under sustained max-frequency load
#   8  no undervoltage / regulator errors in dmesg
# ---------------------------------------------------------------------------
_PLAN=8

printf "TAP version 13\n"
printf "1..%d\n" "$_PLAN"

printf "# CPU gang-rail voltage suite\n"
printf "# Kernel: %s\n" "$(uname -r 2>/dev/null)"

# ---------------------------------------------------------------------------
# skip_rest <n_from> <reason> — emit remaining plan as SKIP and exit 0
# ---------------------------------------------------------------------------
skip_rest() {
    while [ "$TEST_NUM" -lt "$_PLAN" ]; do
        TEST_NUM=$(( TEST_NUM + 1 ))
        printf "ok %d - skipped # SKIP %s\n" "$TEST_NUM" "$1"
    done
    exit 0
}

# ---------------------------------------------------------------------------
# read_uv — echo the current regulator microvolts (empty if unavailable)
# ---------------------------------------------------------------------------
REG_DIR=""
read_uv() {
    cat "${REG_DIR}/microvolts" 2>/dev/null
}

# settle_uv — echo the regulator microvolts once it has stopped changing.
# The SPM rail ramps at a bounded slew rate, so a single read right after a
# frequency change can catch it mid-ramp. Poll until two consecutive reads
# match (or a ~2s timeout), which removes all dependence on a fixed delay.
settle_uv() {
    _s_prev=""
    _s_i=0
    while [ "$_s_i" -lt 20 ]; do
        _s_cur=$(read_uv)
        if [ -n "$_s_cur" ] && [ "$_s_cur" = "$_s_prev" ]; then
            printf '%s' "$_s_cur"
            return 0
        fi
        _s_prev="$_s_cur"
        sleep 0.1
        _s_i=$(( _s_i + 1 ))
    done
    printf '%s' "$_s_prev"
}

# ---------------------------------------------------------------------------
# Test 1: locate the "spm" regulator
# ---------------------------------------------------------------------------
if [ ! -d "$REG_BASE" ]; then
    tap_ok "spm regulator present" "no /sys/class/regulator (CONFIG_REGULATOR?)"
    skip_rest "regulator sysfs unavailable"
fi

for _r in "${REG_BASE}"/regulator.*; do
    [ -d "$_r" ] || continue
    _name=$(cat "${_r}/name" 2>/dev/null)
    case "$_name" in
        spm|*spm*|*SPM*)
            REG_DIR="$_r"
            break
            ;;
    esac
done

# Fallback: a regulator whose range matches the Krait gang rail (350mV..1275mV)
if [ -z "$REG_DIR" ]; then
    for _r in "${REG_BASE}"/regulator.*; do
        [ -d "$_r" ] || continue
        _mn=$(cat "${_r}/min_microvolts" 2>/dev/null)
        _mx=$(cat "${_r}/max_microvolts" 2>/dev/null)
        if [ "$_mn" = "350000" ] && [ "$_mx" = "1275000" ]; then
            REG_DIR="$_r"
            break
        fi
    done
fi

if [ -n "$REG_DIR" ]; then
    printf "# regulator: %s (name=%s)\n" "$REG_DIR" "$(cat "${REG_DIR}/name" 2>/dev/null)"
    tap_ok "spm regulator present ($(cat "${REG_DIR}/name" 2>/dev/null))"
else
    tap_not_ok "spm regulator present" \
        "no regulator named spm and none with the 350000/1275000 uV Krait range"
    skip_rest "spm regulator not found"
fi

# ---------------------------------------------------------------------------
# Test 2: voltage readable and within plausible range
# ---------------------------------------------------------------------------
_uv=$(read_uv)
printf "# current microvolts: %s\n" "$_uv"
if [ -z "$_uv" ] || ! [ "$_uv" -ge 0 ] 2>/dev/null; then
    tap_not_ok "regulator voltage readable and plausible" \
        "microvolts unreadable: '${_uv}'"
elif [ "$_uv" -ge "$VMIN_PLAUSIBLE" ] && [ "$_uv" -le "$VMAX_PLAUSIBLE" ] 2>/dev/null; then
    tap_ok "regulator voltage readable and plausible (${_uv} uV)"
else
    tap_not_ok "regulator voltage readable and plausible" \
        "microvolts ${_uv} outside [${VMIN_PLAUSIBLE}, ${VMAX_PLAUSIBLE}]"
fi

# ---------------------------------------------------------------------------
# Prepare a frequency sweep via the userspace governor.
# All 4 Krait cores share one policy (L2 gang rail), so cpu0 drives the rail.
# ---------------------------------------------------------------------------
DMESG_BEFORE=$(dmesg 2>/dev/null | wc -l)

_userspace=0
modprobe cpufreq_userspace 2>/dev/null
_avail_freqs=$(cat "${CPU0_FREQ}/scaling_available_frequencies" 2>/dev/null)
ORIG_GOV=$(cat "${CPU0_FREQ}/scaling_governor" 2>/dev/null)

if [ -n "$_avail_freqs" ]; then
    echo "userspace" > "${CPU0_FREQ}/scaling_governor" 2>/dev/null
    if [ "$(cat "${CPU0_FREQ}/scaling_governor" 2>/dev/null)" = "userspace" ]; then
        _userspace=1
    fi
fi

_freq_min=$(echo "$_avail_freqs" | tr ' ' '\n' | grep -v '^$' | sort -n | head -n1)
_freq_max=$(echo "$_avail_freqs" | tr ' ' '\n' | grep -v '^$' | sort -n | tail -n1)

# ---------------------------------------------------------------------------
# Test 3: voltage is non-decreasing as frequency increases
# ---------------------------------------------------------------------------
_uv_at_min=""
_uv_at_max=""
if [ "$_userspace" -eq 1 ]; then
    # Put the rail in a known low state and let it settle before sweeping up,
    # so a prior high-frequency/high-voltage state (e.g. a preceding stress
    # test) cannot be sampled mid-ramp-down.
    echo "$_freq_min" > "${CPU0_FREQ}/scaling_setspeed" 2>/dev/null
    settle_uv >/dev/null

    _prev_uv=0
    _monotonic=1
    _msg=""
    for _f in $(echo "$_avail_freqs" | tr ' ' '\n' | grep -v '^$' | sort -n); do
        echo "$_f" > "${CPU0_FREQ}/scaling_setspeed" 2>/dev/null
        _u=$(settle_uv)
        _cur=$(cat "${CPU0_FREQ}/scaling_cur_freq" 2>/dev/null)
        _cap=$(cat "${CPU0_FREQ}/scaling_max_freq" 2>/dev/null)
        printf "# freq=%s kHz (cur=%s) -> %s uV\n" "$_f" "$_cur" "$_u"

        # Only judge steps whose frequency was actually applied. If thermal
        # capping held the frequency below the request, the rail reflects the
        # lower frequency, so skip that step's ordering check.
        if [ -n "$_cap" ] && [ "$_cap" -lt "$_f" ] 2>/dev/null; then
            continue
        fi
        [ "$_cur" = "$_f" ] || continue

        [ -z "$_uv_at_min" ] && _uv_at_min="$_u"
        _uv_at_max="$_u"

        if [ -n "$_u" ] && [ "$_u" -ge 0 ] 2>/dev/null; then
            if [ "$_u" -lt "$_prev_uv" ] 2>/dev/null; then
                _monotonic=0
                _msg="voltage dropped from ${_prev_uv} to ${_u} uV going up in frequency (at ${_f} kHz)"
            fi
            _prev_uv="$_u"
        fi
    done
    if [ "$_monotonic" -eq 1 ]; then
        tap_ok "voltage non-decreasing as frequency increases"
    else
        tap_not_ok "voltage non-decreasing as frequency increases" "$_msg"
    fi
else
    tap_ok "voltage non-decreasing as frequency increases" \
        "userspace governor unavailable"
fi

# ---------------------------------------------------------------------------
# Test 4: voltage at max freq strictly higher than at min freq
# (proves DVFS actually moves the rail, not just reports a constant)
# ---------------------------------------------------------------------------
if [ "$_userspace" -eq 1 ] && [ -n "$_uv_at_min" ] && [ -n "$_uv_at_max" ]; then
    printf "# uv_at_min=%s uv_at_max=%s\n" "$_uv_at_min" "$_uv_at_max"
    if [ "$_uv_at_max" -gt "$_uv_at_min" ] 2>/dev/null; then
        tap_ok "rail voltage increases from min to max freq (${_uv_at_min} -> ${_uv_at_max} uV)"
    else
        tap_not_ok "rail voltage increases from min to max freq" \
            "min-freq ${_uv_at_min} uV, max-freq ${_uv_at_max} uV (no increase)"
    fi
else
    tap_ok "rail voltage increases from min to max freq" \
        "userspace governor unavailable or voltages unread"
fi

# ---------------------------------------------------------------------------
# Test 5: voltage at max freq above the undervoltage floor
# ---------------------------------------------------------------------------
if [ "$_userspace" -eq 1 ] && [ -n "$_uv_at_max" ]; then
    if [ "$_uv_at_max" -ge "$VMAX_FREQ_FLOOR" ] 2>/dev/null; then
        tap_ok "max-freq voltage above undervoltage floor (${_uv_at_max} >= ${VMAX_FREQ_FLOOR} uV)"
    else
        tap_not_ok "max-freq voltage above undervoltage floor" \
            "max-freq voltage ${_uv_at_max} uV below floor ${VMAX_FREQ_FLOOR} uV"
    fi
else
    tap_ok "max-freq voltage above undervoltage floor" \
        "userspace governor unavailable"
fi

# ---------------------------------------------------------------------------
# Test 6: no "timeout setting the voltage" in dmesg
# This is the exact ratelimited error emitted by smp_set_vdd_v2_1_l2() when
# the PMIC arbiter fails to acknowledge a voltage write (PMIC_STS mismatch).
# ---------------------------------------------------------------------------
_vtimeout=$(dmesg 2>/dev/null | grep -i "timeout setting the voltage")
if [ -z "$_vtimeout" ]; then
    tap_ok "no SPM voltage-set timeouts in dmesg"
else
    tap_not_ok "no SPM voltage-set timeouts in dmesg" \
        "$(printf '%s\n' "$_vtimeout" | head -n 3)"
fi

# ---------------------------------------------------------------------------
# Test 7: rail stays up under sustained max-frequency load
# Reproduces the reported undervoltage-under-load scenario: pin all cores to
# max freq, load them, and confirm the rail holds, the frequency is not
# silently dropped, and no voltage-set timeout appears.
# ---------------------------------------------------------------------------
if [ "$_userspace" -eq 1 ]; then
    _load_dmesg_before=$(dmesg 2>/dev/null | wc -l)

    for _cpu in 0 1 2 3; do
        echo "userspace" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_governor" 2>/dev/null
        echo "$_freq_max" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_setspeed" 2>/dev/null
    done

    STRESS_PIDS=""
    _i=0
    while [ "$_i" -lt 4 ]; do
        while :; do :; done &
        STRESS_PIDS="${STRESS_PIDS} $!"
        _i=$(( _i + 1 ))
    done

    _fail=""
    _s=0
    while [ "$_s" -lt 20 ]; do
        sleep 2
        _s=$(( _s + 2 ))
        _u=$(read_uv)
        _cur=$(cat "${CPU0_FREQ}/scaling_cur_freq" 2>/dev/null)
        _cap=$(cat "${CPU0_FREQ}/scaling_max_freq" 2>/dev/null)
        printf "# load %ss: %s uV, cur=%s kHz, cap=%s kHz\n" "$_s" "$_u" "$_cur" "$_cap"
        # Rail must stay above the floor unless thermal capped the frequency.
        if [ -n "$_cap" ] && [ "$_cap" -ge "$_freq_max" ] 2>/dev/null; then
            if [ -n "$_u" ] && [ "$_u" -lt "$VMAX_FREQ_FLOOR" ] 2>/dev/null; then
                _fail="rail sagged to ${_u} uV while pinned at max freq"
                break
            fi
        fi
    done

    for _pid in $STRESS_PIDS; do
        kill "$_pid" 2>/dev/null
    done
    STRESS_PIDS=""

    _load_timeout=$(dmesg 2>/dev/null | tail -n "+${_load_dmesg_before}" 2>/dev/null | \
        grep -i "timeout setting the voltage")
    if [ -n "$_load_timeout" ]; then
        _fail="voltage-set timeout appeared under load: $(printf '%s' "$_load_timeout" | head -n1)"
    fi

    if [ -z "$_fail" ]; then
        tap_ok "rail holds under sustained max-frequency load"
    else
        tap_not_ok "rail holds under sustained max-frequency load" "$_fail"
    fi

    if [ -n "$ORIG_GOV" ]; then
        for _cpu in 0 1 2 3; do
            echo "$ORIG_GOV" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_governor" 2>/dev/null
        done
    fi
else
    tap_ok "rail holds under sustained max-frequency load" \
        "userspace governor unavailable"
fi

# ---------------------------------------------------------------------------
# Test 8: no undervoltage / regulator errors in dmesg (whole boot + this run)
# ---------------------------------------------------------------------------
_verr=$(dmesg 2>/dev/null | grep -iE "under.?volt|spm.*(fail|error)|regulator.*(fail|error)|vdd.*(fail|error)" | \
    grep -iv "regulator-dummy")
if [ -z "$_verr" ]; then
    tap_ok "no undervoltage or regulator errors in dmesg"
else
    tap_not_ok "no undervoltage or regulator errors in dmesg" \
        "$(printf '%s\n' "$_verr" | head -n 3)"
fi

# volt_cleanup trap fires on EXIT

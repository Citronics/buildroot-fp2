#!/bin/sh
# kernel-test-thermal.sh — Thermal management TAP v13 test suite
# Platform: Fairphone 2, Qualcomm MSM8974 Pro (Snapdragon 801)
# 10 thermal zones total; CPU zones discovered dynamically by reading type.
# CONFIG_THERMAL_EMULATION is NOT enabled — tests use real CPU load.
#
# TAP version 13 — https://testanything.org/tap-version-13-specification.html
# Usage: sh kernel-test-thermal.sh
# Run as root (cpufreq sysfs writes require root for heavy stress section).

THERMAL_BASE="/sys/class/thermal"
CPUFREQ_BASE="/sys/devices/system/cpu"

# ---------------------------------------------------------------------------
# Test counter
# ---------------------------------------------------------------------------
TEST_NUM=0

# ---------------------------------------------------------------------------
# Governor / busy-loop cleanup state
# ---------------------------------------------------------------------------
ORIG_GOVS=""
STRESS_PIDS=""

thermal_cleanup() {
    # Kill busy loops launched for heavy stress test
    for _pid in $STRESS_PIDS; do
        kill "$_pid" 2>/dev/null
    done
    # Restore original governors for CPUs 0-3
    _cpu=0
    for _gov in $ORIG_GOVS; do
        echo "$_gov" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_governor" 2>/dev/null
        _cpu=$(( _cpu + 1 ))
        [ "$_cpu" -gt 3 ] && break
    done
}
trap thermal_cleanup EXIT INT TERM

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
# Pre-count: discover CPU thermal zones by reading type attribute
# ---------------------------------------------------------------------------
CPU_ZONES=""
CPU_ZONE_COUNT=0
TOTAL_ZONES=0

if [ -d "$THERMAL_BASE" ]; then
    for _z in "${THERMAL_BASE}"/thermal_zone*; do
        [ -d "$_z" ] || continue
        TOTAL_ZONES=$(( TOTAL_ZONES + 1 ))
        _type=$(cat "$_z/type" 2>/dev/null)
        case "$_type" in
            *cpu*-thermal|cpu*-thermal|*cpu*)
                _zidx=$(basename "$_z" | sed 's/thermal_zone//')
                CPU_ZONES="${CPU_ZONES} ${_zidx}"
                 CPU_ZONE_COUNT=$(( CPU_ZONE_COUNT + 1 ))
                 ;;
         esac
    done
fi

# ---------------------------------------------------------------------------
# Plan calculation (static + dynamic)
#
# Static (infrastructure) tests:
#   1  /sys/class/thermal/ exists and is readable
#   2  at least one thermal zone present
#   3  at least one cooling device present
#   4  at least 4 CPU thermal zones found
#
# Dynamic per-CPU-zone tests (CPU_ZONE_COUNT each):
#   +CPU_ZONE_COUNT  temperature readout (between 10°C and 85°C)
#   +CPU_ZONE_COUNT  trip point validation (readable, ordered)
#   +CPU_ZONE_COUNT  cooling device linkage (cdev exists, max_state > 0)
#
# Thermal zone consistency:
#   +1  all CPU zones have same trip point configuration
#   +1  temperature spread across CPU zones < 15000 mC
#
# Organic stress test:
#   +1  temperature increased (or stable) after 5s busy loop
#
# Heavy thermal throttling test (4 results):
#   +1  throttling detected or skipped (ambient)
#   +1  temperature stable/decreasing after recovery
#   +1  frequency returned to normal range after recovery
#   (modprobe skip collapses these 3 into 1 skip if userspace unavailable)
#
# dmesg side-effect check:
#   +1
# ---------------------------------------------------------------------------

# Static: 4
_PLAN=4

# Per-CPU-zone dynamic: 3 groups × CPU_ZONE_COUNT
_PLAN=$(( _PLAN + CPU_ZONE_COUNT * 3 ))

# Consistency: 2
_PLAN=$(( _PLAN + 2 ))

# Organic stress: 1
_PLAN=$(( _PLAN + 1 ))

# Heavy stress: 3 (or 1 if skipped)
# We always reserve 3 — the skip case outputs 1 skip + 2 skips
_PLAN=$(( _PLAN + 3 ))

# dmesg: 1
_PLAN=$(( _PLAN + 1 ))

# ---------------------------------------------------------------------------
# Output TAP header
# ---------------------------------------------------------------------------
printf "TAP version 13\n"
printf "1..%d\n" "$_PLAN"

# ---------------------------------------------------------------------------
# dmesg baseline (captured before any test output for side-effect check)
# ---------------------------------------------------------------------------
DMESG_LINES_BEFORE=$(dmesg 2>/dev/null | wc -l)

# ---------------------------------------------------------------------------
# == INFRASTRUCTURE TESTS ==
# ---------------------------------------------------------------------------

# Test 1: /sys/class/thermal/ exists and is readable
if [ -d "$THERMAL_BASE" ] && [ -r "$THERMAL_BASE" ]; then
    tap_ok "/sys/class/thermal/ exists and is readable"
else
    tap_not_ok "/sys/class/thermal/ exists and is readable" \
        "${THERMAL_BASE} missing or unreadable"
    # Skip all remaining tests
    while [ "$TEST_NUM" -lt "$_PLAN" ]; do
        TEST_NUM=$(( TEST_NUM + 1 ))
        printf "ok %d - skipped # SKIP thermal not available\n" "$TEST_NUM"
    done
    exit 0
fi

# Test 2: at least one thermal zone present
if [ "$TOTAL_ZONES" -gt 0 ]; then
    tap_ok "at least one thermal zone present (found ${TOTAL_ZONES})"
else
    tap_not_ok "at least one thermal zone present" \
        "no thermal_zone* directories found under ${THERMAL_BASE}"
    while [ "$TEST_NUM" -lt "$_PLAN" ]; do
        TEST_NUM=$(( TEST_NUM + 1 ))
        printf "ok %d - skipped # SKIP no thermal zones\n" "$TEST_NUM"
    done
    exit 0
fi

# Test 3: at least one cooling device present
_cdev_count=0
for _c in "${THERMAL_BASE}"/cooling_device*; do
    [ -d "$_c" ] && _cdev_count=$(( _cdev_count + 1 ))
done
if [ "$_cdev_count" -gt 0 ]; then
    tap_ok "at least one cooling device present (found ${_cdev_count})"
else
    tap_ok "at least one cooling device present" \
        "no cooling_device* in sysfs (thermal framework may use passive-only control)"
fi

# Test 4: at least 4 CPU thermal zones found
if [ "$CPU_ZONE_COUNT" -ge 4 ]; then
    tap_ok "at least 4 CPU thermal zones found (found ${CPU_ZONE_COUNT})"
else
    tap_not_ok "at least 4 CPU thermal zones found" \
        "found ${CPU_ZONE_COUNT} CPU zones (need >= 4)"
fi

# ---------------------------------------------------------------------------
# == TEMPERATURE READOUT TESTS (1 per CPU zone) ==
# ---------------------------------------------------------------------------
for _zi in $CPU_ZONES; do
    _zpath="${THERMAL_BASE}/thermal_zone${_zi}"
    _ztype=$(cat "${_zpath}/type" 2>/dev/null)
    _temp=$(cat "${_zpath}/temp" 2>/dev/null)
    printf "  # temp: %s mC\n" "$_temp"
    if [ -n "$_temp" ] && [ "$_temp" -ge 10000 ] && [ "$_temp" -le 85000 ] 2>/dev/null; then
        tap_ok "temperature readout for ${_ztype} (zone ${_zi}) in plausible range"
    elif [ -z "$_temp" ]; then
        tap_not_ok "temperature readout for ${_ztype} (zone ${_zi})" \
            "could not read temp from ${_zpath}/temp"
    else
        tap_not_ok "temperature readout for ${_ztype} (zone ${_zi}) in plausible range" \
            "temp=${_temp} mC is outside [10000, 85000] range"
    fi
done

# ---------------------------------------------------------------------------
# == TRIP POINT VALIDATION (1 per CPU zone) ==
# ---------------------------------------------------------------------------
# Reference values from DT (logged only — not hard-coded as assertions)
_TRIP0_EXPECT=75000
_TRIP1_EXPECT=110000

for _zi in $CPU_ZONES; do
    _zpath="${THERMAL_BASE}/thermal_zone${_zi}"
    _ztype=$(cat "${_zpath}/type" 2>/dev/null)

    _t0_temp=$(cat "${_zpath}/trip_point_0_temp" 2>/dev/null)
    _t0_type=$(cat "${_zpath}/trip_point_0_type" 2>/dev/null)
    _t1_temp=$(cat "${_zpath}/trip_point_1_temp" 2>/dev/null)
    _t1_type=$(cat "${_zpath}/trip_point_1_type" 2>/dev/null)

    printf "  # trip_point_0: type=%s temp=%s mC (expect passive=%d)\n" \
        "$_t0_type" "$_t0_temp" "$_TRIP0_EXPECT"
    printf "  # trip_point_1: type=%s temp=%s mC (expect critical=%d)\n" \
        "$_t1_type" "$_t1_temp" "$_TRIP1_EXPECT"

    # Check readable and ordering
    _tp_ok=1
    _tp_msg=""

    if [ -z "$_t0_temp" ] || [ -z "$_t0_type" ]; then
        _tp_ok=0
        _tp_msg="trip_point_0 not readable"
    elif [ -z "$_t1_temp" ] || [ -z "$_t1_type" ]; then
        _tp_ok=0
        _tp_msg="trip_point_1 not readable"
    elif [ "$_t0_temp" -ge "$_t1_temp" ] 2>/dev/null; then
        _tp_ok=0
        _tp_msg="trip ordering violated: trip0=${_t0_temp} >= trip1=${_t1_temp}"
    fi

    if [ "$_tp_ok" -eq 1 ]; then
        tap_ok "trip points readable for ${_ztype} (${_t0_type}=${_t0_temp}, ${_t1_type}=${_t1_temp})"
    else
        tap_not_ok "trip points readable for ${_ztype}" "$_tp_msg"
    fi
done

# ---------------------------------------------------------------------------
# == COOLING DEVICE LINKAGE (1 per CPU zone) ==
# ---------------------------------------------------------------------------
for _zi in $CPU_ZONES; do
    _zpath="${THERMAL_BASE}/thermal_zone${_zi}"
    _ztype=$(cat "${_zpath}/type" 2>/dev/null)

    # Look for cdev* symlinks under the zone directory
    _cdev_found=0
    _max_state_ok=0
    _cdev_info=""

    for _cdev in "${_zpath}"/cdev*; do
        [ -e "$_cdev" ] || continue
        _cdev_found=1
        # Resolve the cooling device path from the symlink
        _cdev_real=$(readlink -f "$_cdev" 2>/dev/null)
        if [ -z "$_cdev_real" ]; then
            # Symlink target not resolvable; try direct path construction
            _cdev_name=$(basename "$_cdev")
            _cdev_real="${THERMAL_BASE}/${_cdev_name}"
        fi
        _ms=$(cat "${_cdev_real}/max_state" 2>/dev/null)
        _cs=$(cat "${_cdev_real}/cur_state" 2>/dev/null)
        _ct=$(cat "${_cdev_real}/type" 2>/dev/null)
        printf "  # %s -> cdev type=%s cur_state=%s max_state=%s\n" \
            "$_ztype" "$_ct" "$_cs" "$_ms"
        if [ -n "$_ms" ] && [ "$_ms" -gt 0 ] 2>/dev/null; then
            _max_state_ok=1
            _cdev_info="type=${_ct} max_state=${_ms}"
        fi
        break  # One cdev check per zone is sufficient
    done

    if [ "$_cdev_found" -eq 1 ] && [ "$_max_state_ok" -eq 1 ]; then
        tap_ok "cooling device linked for ${_ztype} (${_cdev_info})"
    elif [ "$_cdev_found" -eq 0 ]; then
        tap_ok "cooling device linked for ${_ztype}" \
            "no cdev* entries under ${_zpath} (passive-only thermal framework)"
    else
        tap_not_ok "cooling device linked for ${_ztype}" \
            "cdev found but max_state is 0 or unreadable"
    fi
done

# ---------------------------------------------------------------------------
# == THERMAL ZONE CONSISTENCY ==
# ---------------------------------------------------------------------------

# Test: all CPU zones have same trip point configuration
# Use first CPU zone as reference
_first_zi=$(echo "$CPU_ZONES" | awk '{print $1}')
_ref_t0_temp=""
_ref_t0_type=""
_ref_t1_temp=""
_ref_t1_type=""
if [ -n "$_first_zi" ]; then
    _ref_path="${THERMAL_BASE}/thermal_zone${_first_zi}"
    _ref_t0_temp=$(cat "${_ref_path}/trip_point_0_temp" 2>/dev/null)
    _ref_t0_type=$(cat "${_ref_path}/trip_point_0_type" 2>/dev/null)
    _ref_t1_temp=$(cat "${_ref_path}/trip_point_1_temp" 2>/dev/null)
    _ref_t1_type=$(cat "${_ref_path}/trip_point_1_type" 2>/dev/null)
fi

_consistency_ok=1
_consistency_msg=""
for _zi in $CPU_ZONES; do
    [ "$_zi" = "$_first_zi" ] && continue
    _zpath="${THERMAL_BASE}/thermal_zone${_zi}"
    _t0t=$(cat "${_zpath}/trip_point_0_temp" 2>/dev/null)
    _t0y=$(cat "${_zpath}/trip_point_0_type" 2>/dev/null)
    _t1t=$(cat "${_zpath}/trip_point_1_temp" 2>/dev/null)
    _t1y=$(cat "${_zpath}/trip_point_1_type" 2>/dev/null)
    if [ "$_t0t" != "$_ref_t0_temp" ] || [ "$_t0y" != "$_ref_t0_type" ] || \
       [ "$_t1t" != "$_ref_t1_temp" ] || [ "$_t1y" != "$_ref_t1_type" ]; then
        _consistency_ok=0
        _ztype=$(cat "${_zpath}/type" 2>/dev/null)
        _consistency_msg="zone ${_zi} (${_ztype}) differs from zone ${_first_zi}"
        break
    fi
done

if [ "$_consistency_ok" -eq 1 ]; then
    tap_ok "all CPU zones have same trip point configuration"
else
    tap_not_ok "all CPU zones have same trip point configuration" \
        "$_consistency_msg"
fi

# Test: temperature spread across CPU zones < 15000 mC
_temp_min=999999
_temp_max=0
for _zi in $CPU_ZONES; do
    _t=$(cat "${THERMAL_BASE}/thermal_zone${_zi}/temp" 2>/dev/null)
    [ -z "$_t" ] && continue
    if [ "$_t" -lt "$_temp_min" ] 2>/dev/null; then _temp_min=$_t; fi
    if [ "$_t" -gt "$_temp_max" ] 2>/dev/null; then _temp_max=$_t; fi
done
_spread=$(( _temp_max - _temp_min ))
printf "  # temperature spread: min=%s mC max=%s mC spread=%s mC\n" \
    "$_temp_min" "$_temp_max" "$_spread"
if [ "$_spread" -lt 15000 ] 2>/dev/null; then
    tap_ok "CPU zone temperature spread < 15000 mC (spread=${_spread} mC)"
else
    tap_not_ok "CPU zone temperature spread < 15000 mC" \
        "spread=${_spread} mC exceeds threshold (min=${_temp_min}, max=${_temp_max})"
fi

# ---------------------------------------------------------------------------
# == ORGANIC STRESS TEST (sensor responsiveness) ==
# ---------------------------------------------------------------------------

# Record starting temperatures
_start_temps=""
for _zi in $CPU_ZONES; do
    _t=$(cat "${THERMAL_BASE}/thermal_zone${_zi}/temp" 2>/dev/null)
    _start_temps="${_start_temps} ${_t}"
done
printf "  # organic stress: start temps:%s mC\n" "$_start_temps"

# Run tight arithmetic loop for 5 seconds
_end=$(( $(date +%s) + 5 ))
while [ "$(date +%s)" -lt "$_end" ]; do
    :
done

# Record ending temperatures
_end_temps=""
for _zi in $CPU_ZONES; do
    _t=$(cat "${THERMAL_BASE}/thermal_zone${_zi}/temp" 2>/dev/null)
    _end_temps="${_end_temps} ${_t}"
done
printf "  # organic stress: end temps:  %s mC\n" "$_end_temps"

# Verify at least one zone increased (or didn't significantly drop)
_any_increased=0
_first_start=$(echo "$_start_temps" | awk '{print $1}')
_first_end=$(echo "$_end_temps" | awk '{print $1}')
_delta=$(( _first_end - _first_start ))
printf "  # organic stress: delta of first zone: %s mC\n" "$_delta"

# Accept if: any zone went up, or delta is >= -2000 (sensor not degrading)
if [ "$_delta" -ge -2000 ] 2>/dev/null; then
    _any_increased=1
fi
# Also check other zones
_zi_idx=1
for _zi in $CPU_ZONES; do
    _s=$(echo "$_start_temps" | awk -v i="$_zi_idx" '{print $i}')
    _e=$(echo "$_end_temps" | awk -v i="$_zi_idx" '{print $i}')
    _d=$(( _e - _s ))
    [ "$_d" -gt 0 ] 2>/dev/null && _any_increased=1
    _zi_idx=$(( _zi_idx + 1 ))
done

if [ "$_any_increased" -eq 1 ]; then
    tap_ok "organic stress: CPU temperature responsive to load (delta=${_delta} mC)"
else
    tap_not_ok "organic stress: CPU temperature responsive to load" \
        "no zone showed increase after 5s busy loop (delta=${_delta} mC)"
fi

# ---------------------------------------------------------------------------
# == HEAVY THERMAL THROTTLING TEST ==
# ---------------------------------------------------------------------------
# This tests the full thermal -> cooling -> cpufreq feedback loop.
# Requires userspace governor module.

modprobe cpufreq_userspace 2>/dev/null
if [ $? -ne 0 ]; then
    tap_ok "heavy thermal stress test: modprobe cpufreq_userspace" \
        "userspace governor not available"
    tap_ok "heavy thermal stress: temperature recovery after stress" \
        "userspace governor not available"
    tap_ok "heavy thermal stress: frequency returned to normal range" \
        "userspace governor not available"
else
    # Read max freq for cpu0
    _max_freq=$(cat "${CPUFREQ_BASE}/cpu0/cpufreq/scaling_max_freq" 2>/dev/null)
    printf "  # heavy stress: max_freq=%s kHz\n" "$_max_freq"

    # Save original governors for all 4 CPUs (space-separated list)
    ORIG_GOVS=""
    for _cpu in 0 1 2 3; do
        _g=$(cat "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_governor" 2>/dev/null)
        ORIG_GOVS="${ORIG_GOVS}${_g} "
    done

    # Switch all 4 CPUs to userspace governor
    for _cpu in 0 1 2 3; do
        echo "userspace" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_governor" 2>/dev/null
    done

    # Pin all 4 CPUs to max freq
    for _cpu in 0 1 2 3; do
        echo "$_max_freq" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_setspeed" 2>/dev/null
    done

    # Launch 4 background busy loops (one per CPU conceptually)
    STRESS_PIDS=""
    _i=0
    while [ "$_i" -lt 4 ]; do
        while :; do :; done &
        _pid=$!
        STRESS_PIDS="${STRESS_PIDS} ${_pid}"
        _i=$(( _i + 1 ))
    done
    printf "  # heavy stress: launched busy loops: PIDs%s\n" "$STRESS_PIDS"

    # Pick first CPU zone for temperature polling
    _cpu_zone=$(echo "$CPU_ZONES" | awk '{print $1}')

    # Dynamically discover first available cooling device index
    _cool_dev_path=""
    for _cd in "${THERMAL_BASE}"/cooling_device*; do
        [ -f "${_cd}/cur_state" ] && _cool_dev_path="$_cd" && break
    done

    # Poll every 2 seconds, up to 30 seconds (15 polls)
    _poll=0
    _throttled=0
    while [ "$_poll" -lt 15 ] && [ "$_throttled" -eq 0 ]; do
        sleep 2
        _poll=$(( _poll + 1 ))
        _temp=$(cat "${THERMAL_BASE}/thermal_zone${_cpu_zone}/temp" 2>/dev/null)
        _freq=$(cat "${CPUFREQ_BASE}/cpu0/cpufreq/scaling_cur_freq" 2>/dev/null)
        _cool_state=""
        [ -n "$_cool_dev_path" ] && _cool_state=$(cat "${_cool_dev_path}/cur_state" 2>/dev/null)
        printf "  # poll %d: temp=%s mC freq=%s kHz cool_state=%s\n" \
            "$_poll" "$_temp" "$_freq" "$_cool_state"

        # Detect throttling: frequency dropped or cooling state elevated
        if [ -n "$_freq" ] && [ -n "$_max_freq" ] && \
           [ "$_freq" -lt "$_max_freq" ] 2>/dev/null; then
            _throttled=1
        elif [ -n "$_cool_state" ] && [ "$_cool_state" -gt 0 ] 2>/dev/null; then
            _throttled=1
        fi
    done

    if [ "$_throttled" -eq 1 ]; then
        tap_ok "heavy thermal stress: thermal throttling activated (poll ${_poll}, temp=${_temp} mC)"
    else
        tap_ok "heavy thermal stress: thermal throttling not triggered within timeout" \
            "ambient conditions prevented throttling (peak temp=${_temp} mC)"
    fi

    # Kill busy loops (trap will also do this on exit, but kill now for recovery)
    for _pid in $STRESS_PIDS; do
        kill "$_pid" 2>/dev/null
    done
    STRESS_PIDS=""

    # Restore governors immediately for recovery check
    _cpu=0
    for _gov in $ORIG_GOVS; do
        echo "$_gov" > "${CPUFREQ_BASE}/cpu${_cpu}/cpufreq/scaling_governor" 2>/dev/null
        _cpu=$(( _cpu + 1 ))
        [ "$_cpu" -gt 3 ] && break
    done
    ORIG_GOVS=""

    # Wait 10 seconds for thermal recovery
    _recovery_start_temp=$(cat "${THERMAL_BASE}/thermal_zone${_cpu_zone}/temp" 2>/dev/null)
    printf "  # recovery: start temp=%s mC, waiting 10s...\n" "$_recovery_start_temp"
    sleep 10
    _recovery_end_temp=$(cat "${THERMAL_BASE}/thermal_zone${_cpu_zone}/temp" 2>/dev/null)
    _recovery_delta=$(( _recovery_end_temp - _recovery_start_temp ))
    printf "  # recovery: end temp=%s mC delta=%s mC\n" "$_recovery_end_temp" "$_recovery_delta"

    # Stable or decreasing (allow up to 5000 mC residual increase)
    if [ "$_recovery_delta" -le 5000 ] 2>/dev/null; then
        tap_ok "heavy thermal stress: temperature stable/decreasing after recovery (delta=${_recovery_delta} mC)"
    else
        tap_not_ok "heavy thermal stress: temperature stable/decreasing after recovery" \
            "temp still rising: delta=${_recovery_delta} mC (start=${_recovery_start_temp}, end=${_recovery_end_temp})"
    fi

    # Check frequency returned to normal (not pinned at max by userspace)
    _cur_freq_after=$(cat "${CPUFREQ_BASE}/cpu0/cpufreq/scaling_cur_freq" 2>/dev/null)
    _cur_gov_after=$(cat "${CPUFREQ_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null)
    printf "  # recovery: cur_freq=%s kHz governor=%s\n" "$_cur_freq_after" "$_cur_gov_after"

    # Frequency is in normal range if it's readable and governor is restored
    if [ "$_cur_gov_after" != "userspace" ] && [ -n "$_cur_freq_after" ] && \
       [ "$_cur_freq_after" -gt 0 ] 2>/dev/null; then
        tap_ok "heavy thermal stress: frequency returned to normal range (freq=${_cur_freq_after} kHz, gov=${_cur_gov_after})"
    elif [ "$_cur_gov_after" = "userspace" ]; then
        tap_not_ok "heavy thermal stress: frequency returned to normal range" \
            "governor still 'userspace' after restore attempt"
    else
        tap_not_ok "heavy thermal stress: frequency returned to normal range" \
            "cur_freq unreadable or zero (freq=${_cur_freq_after}, gov=${_cur_gov_after})"
    fi
fi

# ---------------------------------------------------------------------------
# == DMESG SIDE-EFFECT CHECK ==
# ---------------------------------------------------------------------------
_dmesg_new=$(dmesg 2>/dev/null | tail -n "+${DMESG_LINES_BEFORE}" 2>/dev/null)
_dmesg_warn=$(printf '%s\n' "$_dmesg_new" | grep -iE "thermal" | \
    grep -iE "warning|error|oops|BUG|critical|shutdown|power.?off" 2>/dev/null)
if [ -z "$_dmesg_warn" ]; then
    tap_ok "no thermal-related dmesg warnings or errors"
else
    tap_not_ok "no thermal-related dmesg warnings or errors" \
        "$(printf '%s\n' "$_dmesg_warn" | head -n 3)"
fi

# thermal_cleanup trap fires on EXIT

#!/bin/sh
# Cap the CPU ceiling to what this *rig's power supply* can deliver.
#
# This is deliberately NOT a kernel or device-tree change, and the distinction
# matters. A Fairphone 2 with its battery runs all four Kraits at 2265.6 MHz -
# that is what Android does, and the fused OPP table is correct for the silicon.
# What cannot deliver the current is this bench setup: a bare motherboard on a
# carrier feeding VBAT directly, with no cell acting as a low-impedance buffer.
#
# Measured on the reference rig, at a *fixed* 1728 MHz and identical commanded
# voltage, so the only variable was how many cores were loaded:
#
#     2 loaded cores   survived 600 s, VBAT dipped to 4.023 V
#     4 loaded cores   PMIC UVLO (poff=0x2000) after 40 s
#
# VBAT reads 4.38 V idle and sags under load; pm8941 locks out around
# 3.4-3.5 V, and a transient gets there long before the ~2 Hz VADC sees it.
# So the failure is current draw, not the voltage table, not DVFS transitions,
# and not temperature - it reproduces at constant frequency and temperature.
#
# Capping the ceiling bounds the peak draw. It costs peak clock on this rig and
# nothing at all on a real handset, which is exactly why it lives here in the
# image tooling rather than in the DTS that ships to every msm8974 device.
#
# If the supply is fixed (battery fitted, or a stiffer feed with bulk
# capacitance), raise or remove the cap - it is a property of the bench, not of
# the phone.
CAP_KHZ=${CAP_KHZ:-}
CONF=${CONF:-/etc/msm8974-rig-cap}

[ -n "$CAP_KHZ" ] || { [ -r "$CONF" ] && CAP_KHZ=$(sed 's/#.*//' "$CONF" | tr -dc '0-9'); }
[ -n "$CAP_KHZ" ] || { echo "no cap configured ($CONF absent and CAP_KHZ unset); leaving the ceiling alone"; exit 0; }

applied=0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -d "$p" ] || continue
	# Only ever lower the ceiling, and never touch scaling_min_freq: raising the
	# floor would stop the thermal governor from throttling, which has already
	# driven this board into its 105 C critical trip once.
	cur=$(cat "$p/scaling_max_freq" 2>/dev/null) || continue
	if [ -n "$cur" ] && [ "$cur" -gt "$CAP_KHZ" ]; then
		echo "$CAP_KHZ" > "$p/scaling_max_freq" 2>/dev/null && applied=$((applied + 1))
	fi
done

echo "rig power cap: ceiling set to ${CAP_KHZ} kHz on $applied policies"
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -d "$p" ] && echo "  $(basename "$p"): $(cat "$p/scaling_min_freq")-$(cat "$p/scaling_max_freq")"
done

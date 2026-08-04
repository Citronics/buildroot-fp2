#!/bin/sh
# soak-logger - fsync'd telemetry sampler (ACU O3), THE single device-side
# recorder. One line per sample, synced to storage: a silent reset must leave
# evidence up to the last sample. Judge device state from these logs plus the
# BOOTS registry below, never from "it looked fine" and never from wall time
# (no RTC, and no NTP reference on the host-only gadget network).
#
# Experiment scripts must NOT run their own samplers. They only generate load
# and write their current phase name to $LOG_DIR/.phase (see exp-run); the
# phase shows up in every sample here.

# NOT /var/log: buildroot puts it on tmpfs, and the 2026-07-30 CP1 reset
# proved the previous boot's samples evaporate with it. /root is on the
# rootfs and survives.
LOG_DIR=/root/soak
INTERVAL=30
CPUFREQ=/sys/devices/system/cpu/cpufreq

mkdir -p "$LOG_DIR"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
LOG="$LOG_DIR/soak-boot-${BOOT_ID:-unknown}.log"

# Boot registry: exactly one line per boot, appended before anything else.
# `wc -l BOOTS` = boot count; the PON reason says why the previous boot died
# (poff=0x0002 + warm_reset=0x0002 = the silent PS_HOLD reset signature).
# The phase marker lives on the rootfs and therefore SURVIVES a reset.
# Clear it at boot: otherwise samples on a boot where no experiment is
# running inherit the previous boot's label, which mislabelled two idle
# deaths as load deaths in the 2026-08-03 night post-mortem.
echo "-" > "$LOG_DIR/.phase"

PON=$(dmesg | grep -m1 -oE "pon=0x[0-9a-f]+ warm_reset=0x[0-9a-f]+ poff=0x[0-9a-f]+")
echo "$(date +%s) boot_id=${BOOT_ID:-unknown} kernel=$(uname -r) ${PON:-pon=unknown}" >> "$LOG_DIR/BOOTS"
sync "$LOG_DIR/BOOTS" 2>/dev/null || sync

# VADC path for VBAT (may be absent early; re-probed lazily below)
vadc_dir() {
	dirname "$(grep -l "adc@3100" /sys/bus/iio/devices/iio:device*/name 2>/dev/null)" 2>/dev/null
}
D=$(vadc_dir)

{
	echo "# soak-logger start: boot_id=$BOOT_ID kernel=$(uname -r) epoch=$(date +%s)"
	echo "# fields: epoch uptime_s load1 ph=phase cpufreq_khz(csv|nofreq) trans(csv|-) vbat_uV chg pwrirq=N chgirq=fast/gone/uvalid tzone_temps_mC(csv)"
} >> "$LOG"

while :; do
	up=$(cut -d' ' -f1 /proc/uptime)
	load=$(cut -d' ' -f1 /proc/loadavg)
	ph=$(cat "$LOG_DIR/.phase" 2>/dev/null)
	freqs=$(cat $CPUFREQ/policy*/scaling_cur_freq 2>/dev/null | tr '\n' ',')
	[ -n "$freqs" ] || freqs=nofreq
	trans=$(cat $CPUFREQ/policy*/stats/total_trans 2>/dev/null | tr '\n' ',')
	[ -n "$trans" ] || trans=-
	[ -d "$D" ] || D=$(vadc_dir)
	vbat=$(cat "$D/in_voltage6_input" 2>/dev/null)
	chg=$(cat /sys/class/power_supply/smbb-bif/status 2>/dev/null)
	temps=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr '\n' ',')
	# pwr_irq timeouts: canary for the persistent PMIC/power-path degradation
	# that precedes the silent reset (see 2026-08-03 EXP-2 post-mortem)
	pwrirq=$(dmesg | grep -c "pwr_irq for req" 2>/dev/null)
	# charger-transition discriminator: counter movement in the final samples
	# before a battery-signature (poff=0x2000) death implicates the charger
	# state machine; static counters implicate physical battery contact
	fast=$(awk '/chg-fast/  {print $2+$3+$4+$5}' /proc/interrupts 2>/dev/null)
	gone=$(awk '/chg-gone/  {print $2+$3+$4+$5}' /proc/interrupts 2>/dev/null)
	uval=$(awk '/usb-valid/ {print $2+$3+$4+$5}' /proc/interrupts 2>/dev/null)
	chgirq="${fast:-?}/${gone:-?}/${uval:-?}"
	echo "$(date +%s) $up $load ph=${ph:--} $freqs $trans ${vbat:--} ${chg:--} pwrirq=${pwrirq:-0} chgirq=${chgirq:--} $temps" >> "$LOG"
	# busybox sync may lack per-file support; fall back to full sync
	sync "$LOG" 2>/dev/null || sync
	sleep $INTERVAL
done

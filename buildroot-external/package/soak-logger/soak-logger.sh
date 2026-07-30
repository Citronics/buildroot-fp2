#!/bin/sh
# soak-logger - fsync'd telemetry sampler (ACU O3).
# One line per sample, synced to storage: a silent reset must leave evidence
# up to the last sample. Judge device state from these logs plus the next
# boot's PON reason, never from "it looked fine".

# NOT /var/log: buildroot puts it on tmpfs, and the 2026-07-30 CP1 reset
# proved the previous boot's samples evaporate with it. /root is on the
# rootfs and survives.
LOG_DIR=/root/soak
INTERVAL=30

mkdir -p "$LOG_DIR"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
LOG="$LOG_DIR/soak-boot-${BOOT_ID:-unknown}.log"

{
	echo "# soak-logger start: boot_id=$BOOT_ID kernel=$(uname -r) epoch=$(date +%s)"
	echo "# fields: epoch uptime_s load1 cpufreq_khz(csv|nofreq) tzone_temps_mC(csv)"
} >> "$LOG"

while :; do
	up=$(cut -d' ' -f1 /proc/uptime)
	load=$(cut -d' ' -f1 /proc/loadavg)
	freqs=$(cat /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq 2>/dev/null | tr '\n' ',')
	[ -n "$freqs" ] || freqs=nofreq
	temps=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr '\n' ',')
	echo "$(date +%s) $up $load $freqs $temps" >> "$LOG"
	# busybox sync may lack per-file support; fall back to full sync
	sync "$LOG" 2>/dev/null || sync
	sleep $INTERVAL
done

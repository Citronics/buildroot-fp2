#!/bin/sh
# Trace the PMIC's VADC voltage channels through a brownout.
#
# Written after a reset finally reported the PMIC's own UVLO bit
# (poff=0x2000) instead of the usual PS_HOLD: raising the commanded CPU rail
# from 930 mV to 1030 mV at the same frequency made the board die *sooner*
# (334 s -> 39 s), which is what a supply that cannot deliver the current
# looks like - more voltage at equal frequency is simply more power.
#
# On this rig (FP2 motherboard on a carrier, no battery) VBAT is fed directly,
# so there is no cell impedance to hold the rail up during a load transient.
# in_voltage6_raw read ~4.43 V idle and ~3.94 V under four-core load, and
# pm8941 locks out somewhere around 3.4-3.5 V.
#
# Every sample is fsync'd: a brownout must not be able to erase the evidence
# of itself. Channels are logged raw and unlabelled on purpose - whichever one
# collapses is the one that matters, and guessing the VADC channel map is how
# you end up measuring the wrong node.
DIAG=${DIAG_DIR:-/var/log/msm8974-diag}
LOG=$DIAG/vbat-trace.log
PERIOD=${PERIOD:-0.5}
MAXBYTES=${MAXBYTES:-8000000}
ADC=$(dirname "$(ls /sys/bus/iio/devices/iio:device*/in_voltage6_raw 2>/dev/null | head -1)")
mkdir -p "$DIAG"

[ -n "$ADC" ] || { echo "no VADC channel found" >&2; exit 1; }
CHANS=$(ls "$ADC"/in_voltage*_raw 2>/dev/null | sort)

{
  printf '# uptime'
  for c in $CHANS; do printf ' %s' "$(basename "$c" _raw)"; done
  printf ' freq_khz loadavg tmax_mC\n'
} >> $LOG

while true; do
  line="$(cut -d' ' -f1 /proc/uptime)"
  for c in $CHANS; do
    line="$line $(cat "$c" 2>/dev/null || echo -1)"
  done
  line="$line $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)"
  line="$line $(cut -d' ' -f1 /proc/loadavg)"
  line="$line $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)"
  echo "$line" >> $LOG
  # fsync, not just flush: the point is to survive an unannounced reset.
  sync -d $LOG 2>/dev/null || sync
  if [ "$(stat -c%s $LOG 2>/dev/null || echo 0)" -gt "$MAXBYTES" ]; then
    mv $LOG $LOG.prev
    : > $LOG
  fi
  sleep $PERIOD
done

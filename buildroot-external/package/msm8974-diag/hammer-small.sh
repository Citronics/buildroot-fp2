#!/bin/sh
# Small-swing transition hammer: 729.6 <-> 1497.6 MHz, i.e. the same stressor as
# hammer-full.sh but without visiting the top OPPs. Used to separate "any DVFS
# transition is dangerous" from "only the high operating points are".
#
# Reference measurements on the reference FP2 (6.18 fork kernel):
#   hammer-full  (729.6 <-> 2265.6)  killed the board at 352, 507 and 2405 flips
#   hammer-small (729.6 <-> 1497.6)  survived 1671 flips
DIAG=${DIAG_DIR:-/var/log/msm8974-diag}
LOG=$DIAG/hammer-small.log
mkdir -p "$DIAG"
n=0
while true; do
  for f in 1497600 729600; do
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$p" ] || continue
      echo $f > "$p/scaling_max_freq" 2>/dev/null
      echo $f > "$p/scaling_min_freq" 2>/dev/null
    done
    n=$((n + 1))
    echo "$(cut -d' ' -f1 /proc/uptime) flip=$n want=$f cur=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null) tmax=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)" >> $LOG
    sync -d $LOG 2>/dev/null
    sleep 1
  done
done

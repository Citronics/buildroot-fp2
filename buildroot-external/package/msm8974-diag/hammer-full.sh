#!/bin/sh
# Full-swing transition hammer: the exact stressor that killed the pre-fix
# kernels at 352 and 2405 flips. Logs fsync'd so a death leaves its count.
LOG=${DIAG_DIR:-/var/log/msm8974-diag}/hammer-full.log
n=0
while true; do
  for f in 2265600 729600; do
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      echo $f > $p/scaling_max_freq; echo $f > $p/scaling_min_freq
    done
    n=$((n+1))
    echo "$(cut -d' ' -f1 /proc/uptime) flip=$n want=$f cur=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq) trans=$(cat /sys/devices/system/cpu/cpufreq/policy0/stats/total_trans) tmax=$(cat /sys/class/thermal/thermal_zone*/temp | sort -n | tail -1)" >> $LOG
    sync -d $LOG 2>/dev/null
    sleep 1
  done
done

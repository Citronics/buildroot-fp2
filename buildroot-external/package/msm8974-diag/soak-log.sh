#!/bin/sh
# Device-side soak logger: one fsync'd line every 15 s so a silent reset
# always leaves evidence of the state just before it.
LOG=${DIAG_DIR:-/var/log/msm8974-diag}/soak2.log
mount -t debugfs none /sys/kernel/debug 2>/dev/null
P=/sys/devices/system/cpu/cpufreq/policy0
while true; do
  up=$(cut -d' ' -f1 /proc/uptime)
  f=$(cat $P/scaling_cur_freq 2>/dev/null)
  tr=$(cat $P/stats/total_trans 2>/dev/null)
  cx=$(grep -m1 '^cx ' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | awk '{print $NF}')
  tmax=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
  ph=$(cat /run/soak-phase 2>/dev/null || echo none)
  la=$(cut -d' ' -f1 /proc/loadavg)
  echo "$up f=$f trans=$tr cx=$cx tmax=$tmax load=$la phase=$ph" >> $LOG
  sync -d $LOG 2>/dev/null
  sleep 15
done

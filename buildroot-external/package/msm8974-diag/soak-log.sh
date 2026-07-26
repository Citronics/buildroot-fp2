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
  # Read cx_ao as well as cx. The CPUs vote the active-only domain, so a
  # kernel that votes correctly shows cx_ao "on" at a nonzero performance state
  # while plain cx stays off-0 - logging only the latter reported cx=0 and
  # looked exactly like a vote that never arrived.
  cx=$(awk '$1=="cx"    {print $NF; exit}' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null)
  cxao=$(awk '$1=="cx_ao" {print $NF; exit}' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null)
  tmax=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
  ph=$(cat /run/soak-phase 2>/dev/null || echo none)
  la=$(cut -d' ' -f1 /proc/loadavg)
  echo "$up f=$f trans=$tr cx=$cx cx_ao=$cxao tmax=$tmax load=$la phase=$ph" >> $LOG
  sync -d $LOG 2>/dev/null
  sleep 15
done

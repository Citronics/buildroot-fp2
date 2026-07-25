#!/bin/sh
# Independent thermal guard. Runs as its own service so it cannot be orphaned
# by whatever is generating load.
#
# This exists because the opposite arrangement failed: a load test held its own
# guard, the supervisor was killed, its stress-ng child survived, and on a
# kernel with no cpufreq - where the thermal governor has no cooling device and
# literally cannot throttle - the board climbed to its 105 C critical trip and
# powered off.
#
# The guard only ever removes load. It never touches frequency, so it cannot
# invalidate a soak result by silently throttling it.
HOT=${HOT:-95000}
COOL=${COOL:-85000}
DIAG=${DIAG_DIR:-/var/log/msm8974-diag}
LOG=$DIAG/thermal-guard.log
mkdir -p "$DIAG"

tmax() { cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1; }

say() {
  echo "$(cut -d' ' -f1 /proc/uptime) $*" >> $LOG
  sync -d $LOG 2>/dev/null
}

say "guard up: kill load above ${HOT} mC, note recovery below ${COOL} mC"
tripped=0
while true; do
  t=$(tmax)
  [ -n "$t" ] || { sleep 5; continue; }
  if [ "$t" -gt "$HOT" ]; then
    # Kill every load source we know about, whoever started it.
    pkill -x stress-ng 2>/dev/null
    pkill -f "hammer-full" 2>/dev/null
    pkill -f "hammer-small" 2>/dev/null
    command -v boinccmd >/dev/null 2>&1 && boinccmd --set_run_mode never >/dev/null 2>&1
    if [ "$tripped" = "0" ]; then
      say "TRIPPED at ${t} mC: killed stress-ng/hammers, suspended BOINC"
      tripped=1
    fi
  elif [ "$tripped" = "1" ] && [ "$t" -lt "$COOL" ]; then
    say "recovered to ${t} mC (load stays off; restart the experiment deliberately)"
    tripped=0
  fi
  sleep 5
done

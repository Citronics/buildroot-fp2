#!/bin/sh
# Duty-cycled REAL load for the overnight soak.
#
# Why duty-cycled: saturating all cores pins the governor at the ceiling and
# then almost no DVFS transitions happen - and the transitions are what the
# remaining silent-reset bug is linked to. Alternating load/idle gives both
# sustained top-OPP + thermal stress AND organic full-range governor swings.
#
# Prefers BOINC (real project work) when a project is attached; otherwise
# falls back to stress-ng, then to a plain shell burner.
ON=${ON:-180}
OFF=${OFF:-180}
PHASE=/run/soak-phase

have_boinc_project() {
  # Only treat BOINC as the load source when a project is attached AND it
  # actually has tasks: on armhf many projects have no applications, so an
  # attached-but-idle client would leave the soak running with no load.
  command -v boinccmd >/dev/null 2>&1 || return 1
  boinccmd --get_project_status 2>/dev/null | grep -q 'master URL' || return 1
  boinccmd --get_tasks 2>/dev/null | grep -qE 'name:|active_task_state'
}

start_load() {
  if have_boinc_project; then
    boinccmd --set_run_mode auto >/dev/null 2>&1
    echo "load-on:boinc" > $PHASE
  elif command -v stress-ng >/dev/null 2>&1; then
    stress-ng --cpu 4 --cpu-method matrixprod --timeout "${ON}s" >/dev/null 2>&1 &
    echo "load-on:stress-ng" > $PHASE
  else
    for _ in 1 2 3 4; do
      nice -n 0 sh -c 'while :; do i=0; while [ $i -lt 100000 ]; do i=$((i+1)); done; done' &
      echo $! >> /run/soak-burners
    done
    echo "load-on:shell" > $PHASE
  fi
}

stop_load() {
  if have_boinc_project; then
    boinccmd --set_run_mode never >/dev/null 2>&1
  fi
  pkill -x stress-ng 2>/dev/null
  if [ -f /run/soak-burners ]; then
    while read -r p; do kill "$p" 2>/dev/null; done < /run/soak-burners
    rm -f /run/soak-burners
  fi
  echo "idle" > $PHASE
}

trap 'stop_load; exit 0' TERM INT
echo "idle" > $PHASE
while true; do
  start_load
  sleep "$ON"
  stop_load
  sleep "$OFF"
done

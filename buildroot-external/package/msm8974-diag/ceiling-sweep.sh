#!/bin/sh
# Ascending frequency-ceiling ladder under real load, resumable across resets.
#
# Hypothesis under test (ONE variable: scaling_max_freq): the silent resets are
# caused by insufficient headroom at the higher OPPs, so time-to-death should
# fall as the ceiling rises, and a low enough ceiling should be stable.
#
# Policy: start at the lowest rung, hold each rung for HOLD seconds under
# continuous BOINC load, then climb. A reset is detected on the next boot by
# comparing the persisted rung against the freshly booted uptime; the same rung
# is then retried once. Two deaths on one rung = confirmed limit: the sweep
# stops and parks the ceiling one rung lower so the board stays alive for
# inspection.
#
# Safety: only scaling_max_freq is ever constrained. scaling_min_freq stays at
# the floor so the thermal governor can always throttle (a pinned min once
# caused a 105 C thermal shutdown that looked like a reset).

# Rung 1 is the CONTROL: ceiling == floor, so min == max and no DVFS
# transition can happen at all. It is the only configuration never observed to
# die (61 min clean), while an idle board at the same 729.6 MHz *with*
# transitions enabled died after 25 min at 54 C. If rung 1 survives its hold
# under load, transitions are necessary for the failure; if it dies, they are
# not, and the cause is time-based rather than DVFS-linked.
RUNGS="729600 1036800 1190400 1344000 1497600 1651200 1804800 2035200 2265600"
HOLD=${HOLD:-3600}
FLOOR=729600
STATE=${DIAG_DIR:-/var/log/msm8974-diag}/sweep-state
LOG=${DIAG_DIR:-/var/log/msm8974-diag}/sweep.log

log() {
  echo "$(cut -d' ' -f1 /proc/uptime) $*" >> $LOG
  sync -d $LOG 2>/dev/null
}

set_ceiling() {
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    echo "$FLOOR" > "$p/scaling_min_freq" 2>/dev/null
    echo "$1"     > "$p/scaling_max_freq" 2>/dev/null
  done
}

nth_rung() { echo "$RUNGS" | cut -d' ' -f"$1"; }
n_rungs()  { echo "$RUNGS" | wc -w; }

# Why did the previous boot end? Logged first thing, every boot, so a reset
# always carries its own PMIC verdict (UVLO vs watchdog vs thermal vs PS_HOLD).
[ -x ${DIAG_DIR:-/var/log/msm8974-diag}/pon-reason.sh ] && log "PMIC: $(${DIAG_DIR:-/var/log/msm8974-diag}/pon-reason.sh 2>&1)"

# ---- resume logic -------------------------------------------------------
idx=1; retry=0; done_sweep=0
if [ -f $STATE ]; then
  . $STATE
  # We are running again while a rung was marked in-flight => that rung reset
  # the board.
  if [ "${inflight:-0}" = "1" ]; then
    log "RESET detected: rung $idx ($(nth_rung $idx) kHz) died after ${elapsed:-?}s of ${HOLD}s (retry=$retry)"
    if [ "$retry" -ge 1 ]; then
      prev=$((idx - 1))
      if [ "$prev" -lt 1 ]; then
        # Even the lowest rung dies: park at the OPP floor, which is the only
        # configuration ever observed to survive (61 min pinned at 729.6 MHz).
        log "CONFIRMED LIMIT at the LOWEST rung $(nth_rung $idx) kHz (died twice) -> top-OPP-headroom hypothesis is WRONG. Parking at the floor ${FLOOR} kHz."
        set_ceiling "$FLOOR"
        printf 'idx=1\nretry=0\ninflight=0\nelapsed=0\ndone_sweep=1\n' > $STATE
        sync -d $STATE 2>/dev/null
        while true; do log "parked at floor ${FLOOR} kHz (sweep finished)"; sleep 300; done
      fi
      log "CONFIRMED LIMIT at $(nth_rung $idx) kHz (died twice). Parking at $(nth_rung $prev) kHz and stopping the sweep."
      set_ceiling "$(nth_rung $prev)"
      printf 'idx=%s\nretry=0\ninflight=0\nelapsed=0\ndone_sweep=1\n' "$prev" > $STATE
      sync -d $STATE 2>/dev/null
      # keep load running at the parked ceiling, but stop climbing
      while true; do log "parked at $(nth_rung $prev) kHz (sweep finished)"; sleep 300; done
    fi
    retry=$((retry + 1))
  fi
fi
[ "${done_sweep:-0}" = "1" ] && { set_ceiling "$(nth_rung $idx)"; while true; do log "parked at $(nth_rung $idx) kHz (sweep finished)"; sleep 300; done; }

# ---- make sure the real load is running ---------------------------------
boinccmd --set_run_mode auto >/dev/null 2>&1
log "sweep start/resume: rung $idx = $(nth_rung $idx) kHz, hold ${HOLD}s, retry=$retry, kernel=$(uname -r)"

# ---- the ladder --------------------------------------------------------
total=$(n_rungs)
while [ "$idx" -le "$total" ]; do
  ceil=$(nth_rung $idx)
  set_ceiling "$ceil"
  printf 'idx=%s\nretry=%s\ninflight=1\nelapsed=0\ndone_sweep=0\n' "$idx" "$retry" > $STATE
  sync -d $STATE 2>/dev/null
  log "RUNG $idx: ceiling=$ceil kHz for ${HOLD}s"
  t=0
  while [ "$t" -lt "$HOLD" ]; do
    sleep 30
    t=$((t + 30))
    printf 'idx=%s\nretry=%s\ninflight=1\nelapsed=%s\ndone_sweep=0\n' "$idx" "$retry" "$t" > $STATE
    sync -d $STATE 2>/dev/null
    cur=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
    tr=$(cat /sys/devices/system/cpu/cpufreq/policy0/stats/total_trans 2>/dev/null)
    tmax=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
    la=$(cut -d' ' -f1 /proc/loadavg)
    src=boinc
    # If BOINC runs dry (no tasks left for armhf), the rung would silently
    # become an idle test. Keep the cores busy with stress-ng as a backstop.
    if [ "${la%.*}" -lt 2 ]; then
      if ! pgrep -x stress-ng >/dev/null 2>&1; then
        stress-ng --cpu 4 --cpu-method matrixprod >/dev/null 2>&1 &
        log "load too low (${la}): started stress-ng backstop"
      fi
      src=stress-ng
    fi
    log "rung=$idx ceil=$ceil t=${t}s cur=$cur trans=$tr tmax=$tmax load=$la src=$src"
  done
  log "RUNG $idx SURVIVED ${HOLD}s at $ceil kHz"
  idx=$((idx + 1))
  retry=0
done
log "ALL RUNGS SURVIVED up to $(nth_rung $total) kHz"
printf 'idx=%s\nretry=0\ninflight=0\nelapsed=0\ndone_sweep=1\n' "$total" > $STATE
sync -d $STATE 2>/dev/null
while true; do log "sweep complete, full range in use"; sleep 300; done

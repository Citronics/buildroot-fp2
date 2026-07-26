#!/bin/bash
# Survival-vs-current ladder on the phone (10.0.42.1).
#
# Ascends fixed-frequency rungs under a 4-worker load. Survival time falling
# with rising current/voltage points at the electrical hypothesis (S1, FTS
# mode); survival independent of the rung points at a logical bug. The device
# side is load-soak.py, which verifies its own pin, watches the SAW setpoint
# every second, and pauses load above 85 C.
#
# The host owns reset detection: on an uptime drop it collects the PMIC's
# account (pon/poff), the watchdog bootstatus, and the device log tail, then
# stops the ladder - one death is a data point, and repeating it is a decision,
# not an automatism.
set -u
PHONE=citro@10.0.42.1
SSH="ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no"
OUT=${LADDER_LOG:-./ladder.log}
RUNGS=(300000 883200 1190400 1497600)
RUNG_SECS=1800

log() { echo "$(date +%H:%M:%S) $*" >> $OUT; }

up() { timeout 20 $SSH $PHONE 'cut -d" " -f1 /proc/uptime' 2>/dev/null | cut -d. -f1; }

forensics() {
    log "collecting forensics after reset"
    timeout 40 $SSH $PHONE 'echo citro | sudo -S -p "" dmesg 2>/dev/null | grep -E "pon=|previous power-off|power-on"' 2>/dev/null | sed 's/^/    /' >> $OUT
    timeout 20 $SSH $PHONE 'cat /sys/class/watchdog/watchdog0/bootstatus 2>/dev/null' 2>/dev/null | sed 's/^/    bootstatus=/' >> $OUT
    timeout 30 $SSH $PHONE 'echo citro | sudo -S -p "" tail -8 /var/log/msm8974-diag/load-soak.log' 2>/dev/null | sed 's/^/    /' >> $OUT
}

wait_back() {  # wait (up to 5 min) for the phone to boot back
    for i in $(seq 1 30); do
        sleep 10
        u=$(up); [ -n "$u" ] && { log "phone back, uptime $u"; return 0; }
    done
    log "phone did NOT come back within 5 min - ladder aborted"; return 1
}

cool_down() {  # wait until the hottest zone is below 55 C
    for i in $(seq 1 30); do
        t=$(timeout 20 $SSH $PHONE 'cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1' 2>/dev/null)
        [ -n "$t" ] && [ "$t" -lt 55000 ] && { log "cool: tmax=$t"; return 0; }
        log "cooling: tmax=${t:-?}"; sleep 20
    done
    return 0
}

log "=== ladder start: rungs ${RUNGS[*]}, ${RUNG_SECS}s each"
for rung in "${RUNGS[@]}"; do
    cool_down
    u0=$(up)
    [ -z "$u0" ] && { log "phone unreachable before rung $rung - abort"; exit 1; }
    log "--- rung $rung kHz: starting soak (uptime $u0)"
    # rotate the device log so pin/SURVIVED greps only ever see THIS rung
    timeout 30 $SSH $PHONE 'echo citro | sudo -S -p "" sh -c "mv /var/log/msm8974-diag/load-soak.log /var/log/msm8974-diag/load-soak.$(date +%s).old 2>/dev/null; true"' >/dev/null 2>&1
    timeout 40 $SSH $PHONE "echo citro | sudo -S -p '' systemd-run --unit=ladder-$rung \
        --setenv=FREQ=$rung --setenv=WORKERS=4 --setenv=DURATION=$RUNG_SECS \
        python3 -u /home/citro/load-soak.py" >/dev/null 2>&1
    sleep 10
    # confirm the pin took (the harness aborts loudly if not)
    pin=$(timeout 30 $SSH $PHONE 'echo citro | sudo -S -p "" grep -cE "pin verified" /var/log/msm8974-diag/load-soak.log' 2>/dev/null)
    log "pin-verified lines so far: ${pin:-?}"
    start=$SECONDS last=$u0
    while [ $((SECONDS - start)) -lt $((RUNG_SECS + 120)) ]; do
        sleep 30
        u=$(up)
        if [ -z "$u" ]; then
            log "rung $rung: unreachable at t=$((SECONDS-start))s"
            continue
        fi
        if [ "$u" -lt "$last" ]; then
            log "*** rung $rung: RESET after ~$((last - u0))s of uptime (t=$((SECONDS-start))s)"
            forensics
            log "=== ladder stopped at first death: rung $rung"
            exit 0
        fi
        last=$u
        if timeout 30 $SSH $PHONE 'echo citro | sudo -S -p "" grep -q "SURVIVED" /var/log/msm8974-diag/load-soak.log' 2>/dev/null; then
            if [ $((SECONDS - start)) -ge $RUNG_SECS ]; then
                log "rung $rung: SURVIVED ${RUNG_SECS}s"
                break
            fi
        fi
    done
    timeout 30 $SSH $PHONE 'echo citro | sudo -S -p "" systemctl stop "ladder-*" 2>/dev/null' >/dev/null 2>&1
done
log "=== ladder complete: all rungs survived"

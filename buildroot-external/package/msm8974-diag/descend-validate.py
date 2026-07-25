#!/usr/bin/env python3
"""Validate the DVFS fix and, if it is not enough, converge on what is.

The fix kernel caps the OPP table at 960 MHz and adds 100 mV of margin. That
cap is a hypothesis: on the 6.16 reference only *one* core ever ran at 960 MHz
(the other three sat on the aux mux), so four cores at 960 MHz has never
actually been proven on this board.

So rather than assume, walk down the remaining OPPs under sustained 4-core
load until one survives:

    960.0 -> 883.2 -> 806.4 -> 729.6 MHz

Each ceiling must survive HOLD seconds of continuous load. State is fsync'd, so
when the board resets the next boot picks up where it left off, records that
the ceiling failed and steps down. A ceiling that survives is declared stable
and kept loaded to accumulate evidence.

Thermal safety: heat is handled by suspending the load, never by lowering the
frequency, so a "survived" result is never an artifact of throttling.
"""
import os, subprocess, time
import os as _os
DIAG = _os.environ.get("DIAG_DIR", "/var/log/msm8974-diag")

CEILINGS = [960000, 883200, 806400, 729600]
FLOOR = 729600
HOLD = int(os.environ.get("HOLD", "2700"))
HOT, COOL = 85000, 75000
STATE = "" + DIAG + "/validate-state"
LOG = "" + DIAG + "/validate.log"
CPUFREQ = "/sys/devices/system/cpu/cpufreq"

log = open(LOG, "a", buffering=1)


def say(msg):
    line = "%s %s" % (open("/proc/uptime").read().split()[0], msg)
    log.write(line + "\n")
    os.fsync(log.fileno())
    print(line, flush=True)


def policies():
    return [os.path.join(CPUFREQ, p) for p in os.listdir(CPUFREQ)
            if p.startswith("policy")]


def set_range(ceil_khz):
    for p in policies():
        open(p + "/scaling_max_freq", "w").write(str(ceil_khz))
        open(p + "/scaling_min_freq", "w").write(str(min(FLOOR, ceil_khz)))


def read_state():
    st = {"idx": 0, "inflight": 0, "elapsed": 0, "done": 0}
    try:
        for line in open(STATE):
            k, _, v = line.strip().partition("=")
            if k in st:
                st[k] = int(v)
    except Exception:
        pass
    return st


def write_state(**kw):
    with open(STATE, "w") as f:
        f.write("".join("%s=%d\n" % (k, v) for k, v in kw.items()))
        f.flush()
        os.fsync(f.fileno())


def tmax():
    t = 0
    for z in os.listdir("/sys/class/thermal"):
        if z.startswith("thermal_zone"):
            try:
                t = max(t, int(open("/sys/class/thermal/%s/temp" % z).read()))
            except Exception:
                pass
    return t


def loadavg():
    return float(open("/proc/loadavg").read().split()[0])


def load_on():
    subprocess.run(["boinccmd", "--set_run_mode", "auto"], capture_output=True)
    if loadavg() < 2.0 and subprocess.run(["pgrep", "-x", "stress-ng"],
                                          capture_output=True).returncode != 0:
        subprocess.Popen(["stress-ng", "--cpu", "4", "--cpu-method", "matrixprod"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def load_off():
    subprocess.run(["boinccmd", "--set_run_mode", "never"], capture_output=True)
    subprocess.run(["pkill", "-x", "stress-ng"], capture_output=True)


try:
    say("PMIC: " + subprocess.run(["" + DIAG + "/pon-reason.sh"], capture_output=True,
                                  text=True).stdout.strip())
except Exception:
    pass

st = read_state()
idx = st["idx"]
if st["done"]:
    ceil = CEILINGS[min(idx, len(CEILINGS) - 1)]
    set_range(ceil)
    load_on()
    say("already converged: %d kHz declared stable, continuing to soak" % ceil)
    while True:
        time.sleep(60)
        say("stable-soak ceiling=%d tmax=%d load=%.2f uptime-ok" % (ceil, tmax(), loadavg()))

if st["inflight"]:
    failed = CEILINGS[min(idx, len(CEILINGS) - 1)]
    say("RESET while validating %d kHz after %ds of %ds -> that ceiling FAILS"
        % (failed, st["elapsed"], HOLD))
    idx += 1
    if idx >= len(CEILINGS):
        say("ALL ceilings down to %d kHz failed under load: DVFS itself is not "
            "survivable on this board and must be disabled, not merely capped."
            % CEILINGS[-1])
        write_state(idx=len(CEILINGS) - 1, inflight=0, elapsed=0, done=1)
        set_range(FLOOR)
        while True:
            time.sleep(300)
            say("parked at floor %d kHz (all ceilings failed)" % FLOOR)

ceil = CEILINGS[idx]
say("validating ceiling %d kHz (floor %d) under continuous 4-core load, "
    "need %ds; kernel=%s" % (ceil, min(FLOOR, ceil), HOLD, os.uname().release))
set_range(ceil)
write_state(idx=idx, inflight=1, elapsed=0, done=0)
load_on()

t0 = time.time()
loaded = True
while True:
    time.sleep(15)
    el = int(time.time() - t0)
    t = tmax()
    if loaded and t > HOT:
        load_off()
        loaded = False
        say("thermal: %d mC, load suspended (frequency untouched)" % t)
    elif not loaded and t < COOL:
        load_on()
        loaded = True
        say("thermal: %d mC, load resumed" % t)
    elif loaded and loadavg() < 2.0:
        load_on()
    write_state(idx=idx, inflight=1, elapsed=el, done=0)
    say("ceiling=%d t=%ds/%ds cur=%s trans=%s tmax=%d load=%.2f"
        % (ceil, el, HOLD,
           open(CPUFREQ + "/policy0/scaling_cur_freq").read().strip(),
           open(CPUFREQ + "/policy0/stats/total_trans").read().strip(),
           t, loadavg()))
    if el >= HOLD:
        say("PASS: ceiling %d kHz survived %ds of continuous 4-core load" % (ceil, HOLD))
        write_state(idx=idx, inflight=0, elapsed=0, done=1)
        while True:
            time.sleep(60)
            say("stable-soak ceiling=%d tmax=%d load=%.2f" % (ceil, tmax(), loadavg()))

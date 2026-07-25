#!/usr/bin/env python3
"""Does time-to-reset scale with how much current the CPUs draw?

This is the software half of the power-delivery question, and it is built to be
decisive without any hardware instrumentation. Frequency and voltage are held
fixed (scaling_min == scaling_max), so the *only* thing that changes between
phases is how many cores are loaded, i.e. how much current the rail must
supply. If a board that dies in minutes under four-core load runs for hours
under one- or two-core load at the identical operating point, current draw is
implicated. If every phase dies alike, current is exonerated and the cause lies
elsewhere.

Why this experiment and not more voltage: the measured series showed resets at
*every* frequency including the 729.6 MHz floor (42 s to 396 s, no relation to
frequency), and raising the commanded rail from 930 to 1030 mV did not extend
survival while adding roughly 20% more heat. Voltage magnitude is therefore not
the lever; total power is the remaining suspect.

Every phase also records the calibrated battery voltage. The VADC exposes
625 mV, 1250 mV and GND reference channels, so raw codes convert honestly
instead of by a guessed scale factor - an earlier reading of "3.94 V" was a raw
code divided by 10000, and the true value was 4.30 V. Note the ADC samples at a
couple of Hz: it can show a steady-state sag but it can NOT see a microsecond
transient, so a healthy average here does not disprove a fast droop.

State is fsync'd per sample, so a reset is the measurement: the next boot
records which phase died and how long it lasted, then moves on.
"""
import os
import signal
import subprocess
import time

DIAG = os.environ.get("DIAG_DIR", "/var/log/msm8974-diag")
CPUFREQ = "/sys/devices/system/cpu/cpufreq"
STATE = DIAG + "/load-scale-state"
LOG = DIAG + "/load-scale.log"

FREQ = int(os.environ.get("FREQ", "1036800"))     # pinned, min == max
HOLD = int(os.environ.get("HOLD", "1800"))        # seconds a phase must survive
METHOD = os.environ.get("METHOD", "matrixprod")   # keep constant across phases
WORKERS = [int(w) for w in os.environ.get("WORKERS", "1,2,4").split(",")]
HOT = int(os.environ.get("HOT", "88000"))
COOL = int(os.environ.get("COOL", "78000"))

log = open(LOG, "a", buffering=1)


def say(msg):
    line = "%s %s" % (open("/proc/uptime").read().split()[0], msg)
    log.write(line + "\n")
    os.fsync(log.fileno())
    print(line, flush=True)


def adc_dir():
    import glob
    hits = glob.glob("/sys/bus/iio/devices/iio:device*/in_voltage6_raw")
    return os.path.dirname(hits[0]) if hits else None


ADC = adc_dir()


def vbat_mv():
    """Battery voltage in mV, calibrated against the ADC's own references.

    channel 6 = VBAT_SNS (1/3 prescale), 9 = 625 mV ref, 10 = 1250 mV ref,
    14 = GND ref. Returns None if the references are missing or saturated.
    """
    if not ADC:
        return None
    try:
        def raw(ch):
            return int(open("%s/in_voltage%d_raw" % (ADC, ch)).read())
        gnd, r625, r1250, vb = raw(14), raw(9), raw(10), raw(6)
        counts_per_mv = (r1250 - r625) / 625.0
        if counts_per_mv <= 0:
            return None
        return (vb - gnd) / counts_per_mv * 3.0
    except Exception:
        return None


def tmax():
    t = 0
    for z in os.listdir("/sys/class/thermal"):
        if z.startswith("thermal_zone"):
            try:
                t = max(t, int(open("/sys/class/thermal/%s/temp" % z).read()))
            except Exception:
                pass
    return t


def pin(freq):
    for p in os.listdir(CPUFREQ):
        if not p.startswith("policy"):
            continue
        d = os.path.join(CPUFREQ, p)
        # max first, then min: never leave min above max mid-write
        open(d + "/scaling_max_freq", "w").write(str(freq))
        open(d + "/scaling_min_freq", "w").write(str(freq))


def load_on(workers):
    if subprocess.run(["pgrep", "-x", "stress-ng"], capture_output=True).returncode == 0:
        return
    subprocess.Popen(["stress-ng", "--cpu", str(workers), "--cpu-method", METHOD],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def load_off():
    subprocess.run(["pkill", "-x", "stress-ng"], capture_output=True)


def bootnum():
    try:
        raw = open("/proc/sys/kernel/random/boot_id").read().strip().replace("-", "")
        return int(raw[:8], 16)
    except Exception:
        return 0


DEFAULTS = {"phase": 0, "inflight": 0, "elapsed": 0, "boot": 0, "fresh": 1}


def read_state():
    st = dict(DEFAULTS)
    try:
        for line in open(STATE):
            k, _, v = line.strip().partition("=")
            if k in st:
                st[k] = int(v)
        st["fresh"] = 0
    except Exception:
        pass
    return st


def write_state(**kw):
    kw.setdefault("boot", bootnum())
    with open(STATE, "w") as f:
        f.write("".join("%s=%d\n" % (k, v) for k, v in kw.items()))
        f.flush()
        os.fsync(f.fileno())


st = read_state()


def bail(signum, _frame):
    load_off()
    write_state(phase=st["phase"], inflight=0, elapsed=0)
    say("stopped by signal %d: load off, phase left unjudged" % signum)
    raise SystemExit(0)


signal.signal(signal.SIGTERM, bail)
signal.signal(signal.SIGINT, bail)

say("=== start: kernel=%s pinned=%d kHz method=%s workers=%s HOLD=%ds"
    % (os.uname().release, FREQ, METHOD, WORKERS, HOLD))

if not st["fresh"]:
    w = WORKERS[st["phase"]] if st["phase"] < len(WORKERS) else -1
    if st["inflight"] and st["boot"] != bootnum():
        say("RESET during the %d-worker phase after %ds of %ds -> that load level FAILS"
            % (w, st["elapsed"], HOLD))
        st["phase"] += 1
    elif st["inflight"]:
        say("restarted within the same boot (not a board reset): redoing the "
            "%d-worker phase from zero" % w)

if st["phase"] >= len(WORKERS):
    say("all load levels done; nothing left to test. Parking with no load.")
    load_off()
    while True:
        time.sleep
        break

pin(FREQ)
workers = WORKERS[st["phase"]]
v = vbat_mv()
say("phase %d/%d: %d worker(s) at %d kHz, need %ds; VBAT idle %s"
    % (st["phase"] + 1, len(WORKERS), workers, FREQ, HOLD,
       "%.2f V" % (v / 1000) if v else "unavailable"))
write_state(phase=st["phase"], inflight=1, elapsed=0)
load_on(workers)

t0 = time.time()
loaded = True
vmin = None
while True:
    time.sleep(10)
    el = int(time.time() - t0)
    t = tmax()
    v = vbat_mv()
    if v:
        vmin = v if vmin is None else min(vmin, v)
    if loaded and t > HOT:
        load_off()
        loaded = False
        say("thermal %d mC: load suspended (frequency untouched)" % t)
    elif not loaded and t < COOL:
        load_on(workers)
        loaded = True
        say("thermal %d mC: load resumed" % t)
    elif loaded:
        load_on(workers)
    write_state(phase=st["phase"], inflight=1, elapsed=el)
    say("workers=%d t=%ds/%ds cur=%s tmax=%d load=%.2f VBAT=%s min=%s"
        % (workers, el, HOLD,
           open(CPUFREQ + "/policy0/scaling_cur_freq").read().strip(), t,
           float(open("/proc/loadavg").read().split()[0]),
           "%.3fV" % (v / 1000) if v else "n/a",
           "%.3fV" % (vmin / 1000) if vmin else "n/a"))
    if el >= HOLD:
        break

say("PASS: %d worker(s) at %d kHz survived %ds; VBAT min %s"
    % (workers, FREQ, HOLD, "%.3f V" % (vmin / 1000) if vmin else "n/a"))
load_off()
write_state(phase=st["phase"] + 1, inflight=0, elapsed=0)
say("next phase starts on the next service start (load is off now)")

#!/usr/bin/env python3
"""Load a board and record, every interval, proof of what was actually running.

Written after two shell-heredoc versions of this silently lost their load: the
sampler died on a quoting error, systemd tore down the cgroup with the busy
loops in it, and the board then reset while effectively idle - which produced a
reset that could not be attributed to anything. A reset you cannot attribute is
worse than no measurement, so this file exists as a file, spawns its own load,
and logs the evidence that the load is alive (worker count and loadavg) next to
every sample.

Everything is fsync'd, because the interesting outcome is the board vanishing.

  DIAG_DIR   where to write (default /var/log/msm8974-diag)
  WORKERS    how many busy loops (default 4)
  DURATION   seconds to run (default 1800)
  FREQ       pin every policy to this kHz, or "range" to leave DVFS alone
  HOT/COOL   pause the load above HOT mC, resume below COOL (default 85000/75000)

The thermal guard is checked every second, not every sample interval: sustained
four-core load at a high operating point reaches the 90 C passive trip in well
under a minute on this SoC, and once the thermal governor starts clamping
scaling_max_freq a pinned test silently stops being pinned - which invalidates
the experiment - besides risking the 105 C critical trip. Pausing the load keeps
temperature out of the result; the frequency is never touched, so a "survived"
verdict is never a throttling artifact.
"""
import os
import signal
import subprocess
import sys
import time

DIAG = os.environ.get("DIAG_DIR", "/var/log/msm8974-diag")
WORKERS = int(os.environ.get("WORKERS", "4"))
DURATION = int(os.environ.get("DURATION", "1800"))
FREQ = os.environ.get("FREQ", "range")
HOT = int(os.environ.get("HOT", "85000"))
COOL = int(os.environ.get("COOL", "75000"))
CPUFREQ = "/sys/devices/system/cpu/cpufreq"
LOG = os.path.join(DIAG, "load-soak.log")

os.makedirs(DIAG, exist_ok=True)


def say(msg):
    line = "%s %s" % (open("/proc/uptime").read().split()[0], msg)
    with open(LOG, "a") as f:
        f.write(line + "\n")
        f.flush()
        os.fsync(f.fileno())
    print(line, flush=True)


def adc_dir():
    import glob
    hits = glob.glob("/sys/bus/iio/devices/iio:device*/in_voltage6_raw")
    return os.path.dirname(hits[0]) if hits else None


ADC = adc_dir()
_cal = None


def vbat():
    """Battery volts, calibrated against the ADC's own 625/1250 mV/GND refs."""
    global _cal
    if not ADC:
        return None
    try:
        def raw(ch):
            with open("%s/in_voltage%d_raw" % (ADC, ch)) as f:
                return int(f.read())
        if _cal is None:
            gnd, r625, r1250 = raw(14), raw(9), raw(10)
            _cal = (gnd, (r1250 - r625) / 625.0)
        gnd, cpm = _cal
        return (raw(6) - gnd) / cpm * 3.0 / 1000.0
    except Exception:
        return None


def policies():
    return [os.path.join(CPUFREQ, p) for p in os.listdir(CPUFREQ) if p.startswith("policy")]


def pin(khz):
    """Pin every policy, and *verify* it took.

    Writing scaling_min/max can silently fail - a thermal cooling device may
    already have clamped max below the requested value, so the min write is
    rejected and the run continues unpinned. That happened twice here and
    invalidated both results, because "pinned" is the whole variable under test.
    Raise instead of producing an unattributable measurement.
    """
    for p in policies():
        # Widen max first, then raise min, then settle max: this order works
        # whether the current window is above or below the target.
        for path, val in (("/scaling_max_freq", khz),
                          ("/scaling_min_freq", khz),
                          ("/scaling_max_freq", khz)):
            try:
                open(p + path, "w").write(val)
            except OSError as e:
                say("pin: writing %s to %s%s failed: %s" % (val, p, path, e))
    # Settle before verifying: a scaling_min/max write lands via freq_qos and
    # the aggregated value is not guaranteed visible in sysfs on the next read.
    # Reading too early reported "not pinned" for half the rungs of a sweep that
    # had in fact pinned correctly.
    time.sleep(0.5)
    bad = []
    for p in policies():
        lo = read(p + "/scaling_min_freq")
        hi = read(p + "/scaling_max_freq")
        if lo != khz or hi != khz:
            bad.append("%s=%s-%s" % (os.path.basename(p), lo, hi))
    if bad:
        say("ABORT: pin to %s kHz did not take: %s" % (khz, " ".join(bad)))
        say("       (a thermal clamp or a stale min/max window blocked it)")
        raise SystemExit(1)
    say("pin verified: all policies at %s kHz" % khz)


def tmax():
    t = 0
    for z in os.listdir("/sys/class/thermal"):
        if z.startswith("thermal_zone"):
            try:
                t = max(t, int(open("/sys/class/thermal/%s/temp" % z).read()))
            except Exception:
                pass
    return t


def read(path, default="?"):
    try:
        return open(path).read().strip()
    except Exception:
        return default


kids = []


def stop(*_a):
    for p in kids:
        try:
            p.kill()
        except Exception:
            pass
    say("load stopped (%d workers killed)" % len(kids))
    raise SystemExit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

say("=== start: %s workers=%d duration=%ds freq=%s kernel=%s"
    % (sys.argv[0], WORKERS, DURATION, FREQ, os.uname().release))

if FREQ != "range":
    pin(FREQ)
say("range now %s-%s, governor %s"
    % (read(CPUFREQ + "/policy0/scaling_min_freq"),
       read(CPUFREQ + "/policy0/scaling_max_freq"),
       read(CPUFREQ + "/policy0/scaling_governor")))

for _ in range(WORKERS):
    kids.append(subprocess.Popen(["sh", "-c", "while :; do :; done"]))
say("spawned %d busy loops: pids %s" % (len(kids), [p.pid for p in kids]))

def load_on():
    while len(kids) < WORKERS:
        kids.append(subprocess.Popen(["sh", "-c", "while :; do :; done"]))


def load_off():
    for p in kids:
        try:
            p.kill()
            p.wait(timeout=2)
        except Exception:
            pass
    kids.clear()


t0 = time.time()
vmin = None
paused = False
pauses = 0
while time.time() - t0 < DURATION:
    # Sample as fast as the ADC allows for a second, keeping the minimum: the
    # droop that matters is far shorter than a 1 Hz sample period.
    t1 = time.time()
    while time.time() - t1 < 1.0:
        v = vbat()
        if v is not None and (vmin is None or v < vmin):
            vmin = v
    # Thermal guard, every second. Load is removed, frequency is not touched.
    t = tmax()
    if not paused and t > HOT:
        load_off()
        paused = True
        pauses += 1
        say("thermal %d mC > %d: load paused (frequency untouched)" % (t, HOT))
    elif paused and t < COOL:
        load_on()
        paused = False
        say("thermal %d mC < %d: load resumed" % (t, COOL))
    el = int(time.time() - t0)
    if el % 30 == 0:
        alive = sum(1 for p in kids if p.poll() is None)
        say("t=%4ds workers_alive=%d paused=%s pauses=%d load=%s cur=%s trans=%s VBAT=%s min=%s tmax=%d"
            % (el, alive, paused, pauses, read("/proc/loadavg").split()[0],
               read(CPUFREQ + "/policy0/scaling_cur_freq"),
               read(CPUFREQ + "/policy0/stats/total_trans"),
               ("%.3fV" % vbat()) if vbat() is not None else "n/a",
               ("%.3fV" % vmin) if vmin else "n/a", tmax()))
        if alive == 0 and not paused:
            say("ABORT: all workers died - any reset after this point is NOT a load result")
            raise SystemExit(1)
        time.sleep(1)

say("SURVIVED %ds with %d workers (%d thermal pauses); VBAT min %s"
    % (DURATION, WORKERS, pauses, ("%.3f V" % vmin) if vmin else "n/a"))
stop()

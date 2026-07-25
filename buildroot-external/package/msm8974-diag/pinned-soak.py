#!/usr/bin/env python3
"""Overnight single-variable soak: real load at a FIXED OPP (zero DVFS transitions).

Tonight's own baselines on this same kernel:
  ceiling 1036.8 MHz + 4-core load, transitions ENABLED  -> reset after ~30 s
  idle, full range,   transitions ENABLED                -> reset after 17-25 min
  pinned 729.6 MHz,   no load, transitions DISABLED      -> 61 min, survived

This run keeps the frequency pinned (so scaling_min == scaling_max and the
transition counter must stay frozen) while applying the same continuous 4-core
load. If it survives for hours, DVFS transitions - not load, frequency or
temperature - are what kill the board, and pinning becomes a usable interim
configuration. If it dies anyway, transitions are exonerated.

Thermal safety without breaking the experiment: a pinned OPP cannot be
throttled by the thermal governor, so heat is managed by suspending the *load*
instead of lowering the frequency. The frequency never changes either way.
"""
import mmap, os, struct, subprocess, time
import os as _os
DIAG = _os.environ.get("DIAG_DIR", "/var/log/msm8974-diag")

FREQ = os.environ.get("FREQ", "1036800")
HOT, COOL = 85000, 75000
SAW, PMIC_STS = 0xf9012000, 0x14
LOG = "" + DIAG + "/pinned-soak.log"
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


def pin(freq):
    for p in policies():
        open(p + "/scaling_max_freq", "w").write(freq)
        open(p + "/scaling_min_freq", "w").write(freq)


def rd(name):
    try:
        return open(name).read().strip()
    except Exception:
        return "?"


def tmax():
    t = 0
    for z in os.listdir("/sys/class/thermal"):
        if z.startswith("thermal_zone"):
            try:
                t = max(t, int(open("/sys/class/thermal/%s/temp" % z).read()))
            except Exception:
                pass
    return t


def boinc(mode):
    subprocess.run(["boinccmd", "--set_run_mode", mode], capture_output=True)


def loadavg():
    return float(open("/proc/loadavg").read().split()[0])


def stress_running():
    return subprocess.run(["pgrep", "-x", "stress-ng"],
                          capture_output=True).returncode == 0


def load_on():
    """Real load is the point of this soak: BOINC when it has work, otherwise
    stress-ng, so the board is never accidentally soaking idle."""
    boinc("auto")
    if loadavg() < 2.0 and not stress_running():
        subprocess.Popen(["stress-ng", "--cpu", "4", "--cpu-method", "matrixprod"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        say("load: BOINC had no work (load %.2f), started stress-ng" % loadavg())


def load_off():
    boinc("never")
    subprocess.run(["pkill", "-x", "stress-ng"], capture_output=True)


# PMIC verdict for however the previous boot ended.
try:
    out = subprocess.run(["" + DIAG + "/pon-reason.sh"], capture_output=True,
                         text=True).stdout.strip()
    say("PMIC: " + out)
except Exception as e:
    say("PMIC: unavailable (%s)" % e)

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
saw = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=SAW)
mv = lambda: (350000 + ((struct.unpack("<I", saw[PMIC_STS:PMIC_STS + 4])[0] & 0xff) - 70) * 5000) // 1000

pin(FREQ)
time.sleep(1)
base_trans = rd(CPUFREQ + "/policy0/stats/total_trans")
say("PINNED soak start: freq=%s min=%s max=%s rail=%d mV trans=%s kernel=%s"
    % (rd(CPUFREQ + "/policy0/scaling_cur_freq"),
       rd(CPUFREQ + "/policy0/scaling_min_freq"),
       rd(CPUFREQ + "/policy0/scaling_max_freq"), mv(), base_trans,
       os.uname().release))

load_on()
loaded = True
say("load applied (thermal control is by suspending load, never by "
    "changing frequency)")

while True:
    time.sleep(15)
    t = tmax()
    if loaded and t > HOT:
        load_off()
        loaded = False
        say("thermal: %d mC > %d, load suspended (frequency untouched)" % (t, HOT))
    elif not loaded and t < COOL:
        load_on()
        loaded = True
        say("thermal: %d mC < %d, load resumed" % (t, COOL))
    elif loaded and loadavg() < 2.0:
        load_on()
    say("freq=%s trans=%s rail=%d mV tmax=%d load=%s loaded=%d"
        % (rd(CPUFREQ + "/policy0/scaling_cur_freq"),
           rd(CPUFREQ + "/policy0/stats/total_trans"), mv(), t,
           open("/proc/loadavg").read().split()[0], loaded))

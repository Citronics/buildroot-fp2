#!/usr/bin/env python3
"""Sample the DVFS state of an otherwise idle board, fsync'd, for reset forensics.

Companion to load-soak.py, for the opposite condition: no load at all, DVFS
free to run its whole range, and the deep idle state exercised as often as the
board wants to.  It records what the silicon is doing rather than what the
kernel believes, so a reset leaves evidence about the state that preceded it:

  freq     per-core scaling_cur_freq
  rail     the Krait gang rail read from the L2 SAW (VCTL and PMIC_STS,
           uV = selector * 5000) - the physical voltage, not the driver's cache
  spc      per-core deep-idle (power-collapse) entry counters, so a claim that
           collapse was or was not exercised is backed by numbers
  temp     hottest thermal zone, to keep thermal out of any verdict
  vbat     battery volts, calibrated against the ADC's own reference channels

Nothing here applies load or changes any setting: the caller owns the
configuration under test, and this only observes it.

  DIAG_DIR   where to write (default /var/log/msm8974-diag)
  INTERVAL   seconds between samples (default 30)
  DURATION   seconds to run (default 3600)
  TAG        free-text label recorded in the header (e.g. "spc-on")
"""
import glob
import mmap
import os
import sys
import time

DIAG = os.environ.get("DIAG_DIR", "/var/log/msm8974-diag")
INTERVAL = int(os.environ.get("INTERVAL", "30"))
DURATION = int(os.environ.get("DURATION", "3600"))
TAG = os.environ.get("TAG", "untagged")
CPUFREQ = "/sys/devices/system/cpu/cpufreq"
SAW_L2, VCTL, PMIC_STS = 0xf9012000, 0x1c, 0x14
LOG = os.path.join(DIAG, "idle-monitor.log")

os.makedirs(DIAG, exist_ok=True)


def rd(p, d="?"):
    try:
        return open(p).read().strip()
    except Exception:
        return d


def say(msg):
    line = "%s %s" % (rd("/proc/uptime").split()[0], msg)
    with open(LOG, "a") as f:
        f.write(line + "\n")
        f.flush()
        os.fsync(f.fileno())
    print(line, flush=True)


_map = None


def rail():
    """(VCTL uV, PMIC_STS uV) from the L2 SAW, or (None, None)."""
    global _map
    try:
        if _map is None:
            fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
            _map = mmap.mmap(fd, 0x1000, mmap.PROT_READ, mmap.MAP_SHARED,
                             offset=SAW_L2)
            os.close(fd)
        def sel(off):
            return int.from_bytes(_map[off:off+4], "little") & 0xff
        return sel(VCTL) * 5000, sel(PMIC_STS) * 5000
    except Exception:
        return None, None


ADC = None
for h in glob.glob("/sys/bus/iio/devices/iio:device*/in_voltage6_raw"):
    ADC = os.path.dirname(h)
    break
_cal = None


def vbat():
    global _cal
    if not ADC:
        return None
    try:
        def raw(ch):
            return int(open("%s/in_voltage%d_raw" % (ADC, ch)).read())
        if _cal is None:
            _cal = (raw(14), (raw(10) - raw(9)) / 625.0)
        gnd, cpm = _cal
        return (raw(6) - gnd) / cpm * 3.0 / 1000.0
    except Exception:
        return None


def freqs():
    return [rd("%s/policy%d/scaling_cur_freq" % (CPUFREQ, c), "?") for c in range(4)]


def spc():
    out = []
    for c in range(4):
        base = "/sys/devices/system/cpu/cpu%d/cpuidle/state1" % c
        out.append("%s/%s" % (rd(base + "/usage", "?"), rd(base + "/disable", "?")))
    return out


def tmax():
    t = 0
    for z in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try:
            t = max(t, int(open(z).read()))
        except Exception:
            pass
    return t


say("=== start idle-monitor tag=%s interval=%ds duration=%ds kernel=%s"
    % (TAG, INTERVAL, DURATION, os.uname().release))
say("    governor=%s range=%s-%s  spc(usage/disable)=%s"
    % (rd(CPUFREQ + "/policy0/scaling_governor"),
       rd(CPUFREQ + "/policy0/scaling_min_freq"),
       rd(CPUFREQ + "/policy0/scaling_max_freq"), " ".join(spc())))

t0 = time.time()
vmin = None
while time.time() - t0 < DURATION:
    time.sleep(INTERVAL)
    v = vbat()
    if v is not None and (vmin is None or v < vmin):
        vmin = v
    vc, ps = rail()
    say("t=%5ds load=%s freq=%s rail=%s/%s spc=%s tmax=%d vbat=%s min=%s"
        % (int(time.time() - t0), rd("/proc/loadavg").split()[0],
           ",".join(freqs()),
           vc if vc is not None else "?", ps if ps is not None else "?",
           " ".join(spc()), tmax(),
           ("%.3f" % v) if v else "?", ("%.3f" % vmin) if vmin else "?"))

say("SURVIVED %ds idle (tag=%s); VBAT min %s" % (DURATION, TAG,
                                                 ("%.3f V" % vmin) if vmin else "n/a"))

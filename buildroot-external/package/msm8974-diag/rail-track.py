#!/usr/bin/env python3
"""Does the physical Krait gang rail track the OPP the kernel selected?

Sweeps every rung, pins all four policies to it, and compares three numbers:
  required  - the DT voltage for this rung in this die's bin (speed1-pvs9-v1)
  driver    - what our SPM regulator believes it set (its cached volt_sel)
  silicon   - what the L2 SAW actually holds (VCTL and PMIC_STS, uV = sel*5000)

A rail *below* required is a starved core: the silicon runs a frequency it was
not given the voltage for, which on Krait ends as a watchdog reset, not an
error.  Above required only wastes power.  No load is applied, so this cannot
provoke a thermal event.
"""
import mmap, os, sys, time

SAW_L2 = 0xf9012000
VCTL, PMIC_STS = 0x1c, 0x14
CPUFREQ = "/sys/devices/system/cpu/cpufreq"

# DT: opp-microvolt-speed1-pvs9-v1, the phone's bin (kHz -> uV)
REQ = {
    300000: 800000, 422400: 800000, 652800: 800000, 729600: 805000,
    883200: 825000, 960000: 835000, 1036800: 845000, 1190400: 865000,
    1267200: 875000, 1497600: 910000, 1574400: 925000, 1728000: 955000,
    1958400: 1000000, 2265600: 1075000,
}

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.PROT_READ, mmap.MAP_SHARED, offset=SAW_L2)


def sel(off):
    return int.from_bytes(m[off:off+4], "little") & 0xff


def rd(p):
    try:
        return open(p).read().strip()
    except Exception:
        return "?"


def policies():
    return [os.path.join(CPUFREQ, p) for p in sorted(os.listdir(CPUFREQ)) if p.startswith("policy")]


def pin(khz):
    for p in policies():
        for path in ("/scaling_max_freq", "/scaling_min_freq", "/scaling_max_freq"):
            try:
                open(p + path, "w").write(str(khz))
            except OSError:
                pass
    return all(rd(p + "/scaling_min_freq") == str(khz) and
               rd(p + "/scaling_max_freq") == str(khz) for p in policies())


def rail():
    return sel(VCTL) * 5000, sel(PMIC_STS) * 5000


print("kernel %s" % os.uname().release)
print("idle before sweep: VCTL=%d uV PMIC_STS=%d uV driver=%s uV"
      % (rail()[0], rail()[1], rd("/sys/class/regulator/regulator.1/microvolts")))
drv_path = None
for r in sorted(os.listdir("/sys/class/regulator")):
    if rd("/sys/class/regulator/%s/name" % r) == "spm":
        drv_path = "/sys/class/regulator/%s/microvolts" % r
print("spm regulator sysfs: %s" % drv_path)
print()
print("%-9s %-9s %-9s %-9s %-9s %s" % ("rung_kHz", "required", "driver", "VCTL", "PMIC_STS", "verdict"))

bad = []
for khz in sorted(REQ):
    ok = pin(khz)
    if not ok:
        print("%-9d PIN FAILED - skipped" % khz)
        continue
    time.sleep(1.5)
    v, s = rail()
    d = rd(drv_path) if drv_path else "?"
    req = REQ[khz]
    cur = rd(CPUFREQ + "/policy0/scaling_cur_freq")
    verdict = "ok"
    if s < req:
        verdict = "*** STARVED by %d uV ***" % (req - s)
        bad.append((khz, req, s))
    elif s > req:
        verdict = "high by %d uV" % (s - req)
    if cur != str(khz):
        verdict += " (cur=%s!)" % cur
    print("%-9d %-9d %-9s %-9d %-9d %s" % (khz, req, d, v, s, verdict))

# restore
for p in policies():
    open(p + "/scaling_min_freq", "w").write("300000")
    open(p + "/scaling_max_freq", "w").write("2265600")
print("\nrestored 300000-2265600")
print("STARVED rungs: %s" % (bad if bad else "none"))

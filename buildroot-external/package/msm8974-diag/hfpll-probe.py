#!/usr/bin/env python3
"""Read-only probe: does the kernel enable HFPLL output before the PLL locks?

mode_reg (0x00): BIT0 PLL_OUTCTRL, BIT1 PLL_BYPASSNL, BIT2 PLL_RESET_N
status_reg (0x1c): BIT16 lock

Violation signature = mode has OUTCTRL|BYPASSNL|RESET_N all set (PLL running and
its output enabled) while the lock bit is CLEAR. Read mode, status, mode again and
require both mode reads to agree, so a rate change starting mid-sample cannot fake it.
"""
import mmap, os, struct, sys, time, subprocess
import os as _os
DIAG = _os.environ.get("DIAG_DIR", "/var/log/msm8974-diag")

BASES = {
    "hfpll0": 0xf908a000, "hfpll1": 0xf909a000,
    "hfpll2": 0xf90aa000, "hfpll3": 0xf90ba000,
    "hfpll_l2": 0xf9016000,
}
MODE, STATUS, LOCK = 0x00, 0x1c, 1 << 16
POLICIES = "/sys/devices/system/cpu/cpufreq/policy0"

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
maps = {n: mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=b)
        for n, b in BASES.items()}
log = open("" + DIAG + "/hfpll-probe.log", "a", buffering=1)


def trans():
    try:
        return int(open(POLICIES + "/stats/total_trans").read())
    except Exception:
        return -1


def rd(m, off):
    return struct.unpack("<I", m[off:off + 4])[0]


def phase(name, seconds):
    hits = {n: 0 for n in BASES}
    samples = 0
    t_start, t0 = trans(), time.time()
    while time.time() - t0 < seconds:
        for n, m in maps.items():
            mode1 = rd(m, MODE)
            sts = rd(m, STATUS)
            mode2 = rd(m, MODE)
            if mode1 == mode2 and (mode1 & 0x7) == 0x7 and not (sts & LOCK):
                hits[n] += 1
        samples += 1
    dt = trans() - t_start
    tot = sum(hits.values())
    line = ("%s: %.0fs samples=%d cpufreq_transitions=%d "
            "violations_total=%d per_pll=%s" %
            (name, seconds, samples, dt, tot,
             ",".join("%s=%d" % (n, hits[n]) for n in sorted(hits) if hits[n])))
    print(line)
    log.write(line + "\n")
    os.fsync(log.fileno())
    return tot, dt


print("baseline: no forced transitions (expect 0 violations)")
phase("BASELINE-idle", 30)

print("test: forcing 729.6 <-> 2265.6 MHz transitions, 1/s")
hammer = subprocess.Popen(
    ["/bin/sh", "-c",
     "for i in $(seq 1 45); do "
     "for f in 2265600 729600; do "
     "for p in /sys/devices/system/cpu/cpufreq/policy*; do "
     "echo $f > $p/scaling_max_freq; echo $f > $p/scaling_min_freq; done; "
     "sleep 1; done; done"])
try:
    phase("TEST-hammering", 90)
finally:
    hammer.terminate()
    for p in ("policy0", "policy1", "policy2", "policy3"):
        d = "/sys/devices/system/cpu/cpufreq/" + p
        if os.path.isdir(d):
            try:
                open(d + "/scaling_min_freq", "w").write("729600")
                open(d + "/scaling_max_freq", "w").write("2265600")
            except Exception:
                pass
    print("restored normal scaling range")

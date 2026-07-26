#!/usr/bin/env python3
"""Issue the vendor's 'Krait FTS -> PWM' command (L2 SAW VCTL port 2, data 0x80).

Round 2: the userspace mmap STORE to the SAW died silently (SIGBUS, stderr
lost) while reads through the same mapping work.  This version goes through
os.pread/os.pwrite on /dev/mem - the kernel-mediated copy path - and prints
every failure to stdout so nothing is silent this time.
"""
import os
import time

CPUFREQ = "/sys/devices/system/cpu/cpufreq"
SAW_VCTL = 0xf901201c
SAW_PMIC_STS = 0xf9012014
PWM_CMD = (2 << 16) | 0x80


def rd(p):
    with open(p) as f:
        return f.read().strip()


try:
    pols = [os.path.join(CPUFREQ, p) for p in os.listdir(CPUFREQ) if p.startswith("policy")]
    for p in pols:
        for path in ("/scaling_max_freq", "/scaling_min_freq", "/scaling_max_freq"):
            open(p + path, "w").write("300000")
    time.sleep(0.5)
    bad = [p for p in pols if rd(p + "/scaling_min_freq") != "300000"
           or rd(p + "/scaling_max_freq") != "300000"]
    if bad:
        raise SystemExit("ABORT: pin did not take on %s" % bad)
    print("pinned 300000 on all policies")

    # /dev/mem read()/write() EFAULTs on ARM32 MMIO, and python mmap slice
    # writes are byte stores the APCS bus rejects (SIGBUS).  A ctypes
    # from_buffer assignment is a single aligned 32-bit store - the only
    # userspace path that matches what the kernel itself does here.
    import ctypes
    import mmap as _mmap
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    # mmap's positional order is (fileno, length, flags, prot) - passing prot
    # positionally where flags goes silently produced a read-only mapping, and
    # that (not a bus restriction) is what killed both earlier write attempts.
    m = _mmap.mmap(fd, 0x1000, flags=_mmap.MAP_SHARED,
                   prot=_mmap.PROT_READ | _mmap.PROT_WRITE, offset=0xf9012000)

    def reg(off):
        return ctypes.c_uint32.from_buffer(m, off).value

    print("before: VCTL=%#x PMIC_STS=%#x" % (reg(0x1c), reg(0x14)))
    ctypes.c_uint32.from_buffer(m, 0x1c).value = PWM_CMD
    time.sleep(0.001)
    v = reg(0x1c)
    print("after:  VCTL=%#x PMIC_STS=%#x" % (v, reg(0x14)))
    print("PWM COMMAND LATCHED" if v == PWM_CMD else "WRITE DID NOT LATCH (reads %#x)" % v)
except BaseException as e:
    print("POKE FAILED: %r" % e)
    raise

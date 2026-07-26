#!/usr/bin/env python3
"""Hammer a known-safe MMIO register from userspace and log the read rate.

Discriminator for the bus-stall family: if the reset rate tracks MMIO/bus
traffic rather than CPU load, a single core doing tight device-register reads
on an otherwise idle system should die on load-like timescales (minutes), and
the same loop with the read replaced by pure arithmetic should not.

  MODE=mmio   tight reads of the L2 SAW PMIC_STS (0xf9012014) - proven safe
  MODE=spin   identical loop shape, no device access (the control arm)
  DURATION    seconds (default 900)

Logs reads/s every 10 s, fsync'd, so a death leaves the rate on record.
"""
import ctypes
import mmap
import os
import time

MODE = os.environ.get("MODE", "mmio")
DURATION = int(os.environ.get("DURATION", "900"))
LOG = "/var/log/msm8974-diag/mmio-hammer.log"
os.makedirs(os.path.dirname(LOG), exist_ok=True)


def say(msg):
    line = "%s %s" % (open("/proc/uptime").read().split()[0], msg)
    with open(LOG, "a") as f:
        f.write(line + "\n")
        f.flush()
        os.fsync(f.fileno())
    print(line, flush=True)


reader = None
if MODE == "mmio":
    # ctypes.from_buffer requires a writable mapping even for pure reads, so
    # map RW like pwm-poke.py does; only loads are ever issued from here.
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 0x1000, flags=mmap.MAP_SHARED,
                  prot=mmap.PROT_READ | mmap.PROT_WRITE, offset=0xf9012000)
    cell = ctypes.c_uint32.from_buffer(m, 0x14)

    def reader():
        return cell.value
else:
    x = [1]

    def reader():
        x[0] = (x[0] * 1103515245 + 12345) & 0x7fffffff
        return x[0]

say("=== start mmio-hammer mode=%s duration=%ds kernel=%s"
    % (MODE, DURATION, os.uname().release))
t0 = time.time()
total = 0
while time.time() - t0 < DURATION:
    t1 = time.time()
    n = 0
    while time.time() - t1 < 10.0:
        # 1000 accesses per clock check keeps the timing overhead negligible
        for _ in range(1000):
            reader()
        n += 1000
    total += n
    say("t=%4ds rate=%d/s total=%d" % (int(time.time() - t0), n // 10, total))
say("SURVIVED %ds in mode=%s (%d accesses)" % (DURATION, MODE, total))

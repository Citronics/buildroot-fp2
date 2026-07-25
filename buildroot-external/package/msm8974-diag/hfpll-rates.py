#!/usr/bin/env python3
"""Read the HFPLL L-values to learn the operating frequency, even when the
kernel registers no clock drivers (as upstream 6.16 does not for Krait)."""
import mmap, os, struct
XO = 19200000
BASES = {"hfpll0": 0xf908a000, "hfpll1": 0xf909a000, "hfpll2": 0xf90aa000,
         "hfpll3": 0xf90ba000, "hfpll_l2": 0xf9016000}
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
for name, base in BASES.items():
    m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    mode = struct.unpack("<I", m[0x00:0x04])[0]
    l_val = struct.unpack("<I", m[0x04:0x08])[0]
    sts = struct.unpack("<I", m[0x1c:0x20])[0]
    print("  %-9s mode=%#010x (outctrl=%d bypassnl=%d reset_n=%d) L=%3d -> %7.1f MHz  locked=%d"
          % (name, mode, mode & 1, (mode >> 1) & 1, (mode >> 2) & 1, l_val,
             l_val * XO / 1e6, (sts >> 16) & 1))
    m.close()

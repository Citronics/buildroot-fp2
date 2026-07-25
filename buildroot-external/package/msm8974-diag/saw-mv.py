#!/usr/bin/env python3
import mmap, os, struct
f = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xf9012000)
sts = struct.unpack("<I", m[0x14:0x18])[0] & 0xff
vctl = struct.unpack("<I", m[0x1c:0x20])[0] & 0xff
mv = lambda s: (350000 + (s - 70) * 5000) // 1000
print("  PMIC_STS=%#x -> %d mV   VCTL=%#x -> %d mV" % (sts, mv(sts), vctl, mv(vctl)))

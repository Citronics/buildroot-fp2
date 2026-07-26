#!/usr/bin/env python3
"""Dump the non-zero registers of the pm8841 SMPS blocks via regmap debugfs.

pm8841 (SPMI sid 4) carries the CX corner rail (S2, RPM-owned - reads zero
from HLOS) and the 4-phase Krait APC gang (S5..S8, ctrl bases 0x2000, 0x2300,
0x2600, 0x2900).  The interesting byte is MODE_CTL at ctrl+0x45: 0x80 = forced
PWM (what the vendor commands whenever more than one core is online), 0x00 =
PFM, 0x40 = auto.  Our kernel never writes it - this reads what the bootloader
left, which is what the silicon is running on right now.
"""
rows = {}
with open("/sys/kernel/debug/regmap/0-04/registers") as f:
    for line in f:
        reg, val = line.split(": ")
        val = val.strip()
        if val != "00":
            rows[int(reg, 16)] = val

names = {0x08: "REVISION", 0x04: "TYPE", 0x05: "SUBTYPE", 0x40: "VSET_LB",
         0x41: "VSET_UB", 0x45: "MODE_CTL", 0x46: "EN_CTL", 0x08+0x40: "?",
         0x50: "FREQ/CLK_DIV?", 0x51: "?", 0x60: "?"}
blocks = {0x1400: "S1(MX)ctrl", 0x1700: "S2(CX)ctrl", 0x1a00: "S3ctrl",
          0x1d00: "S4ctrl", 0x2000: "S5(APC master)ctrl", 0x2300: "S6ctrl",
          0x2600: "S7ctrl", 0x2900: "S8ctrl",
          0x1500: "S1ps", 0x1800: "S2ps", 0x2100: "S5ps", 0x2400: "S6ps",
          0x2700: "S7ps", 0x2a00: "S8ps"}
for base in sorted(blocks):
    hits = {r - base: v for r, v in rows.items() if base <= r < base + 0x100}
    if hits:
        detail = "  ".join("+%02x=%s%s" % (o, v, "(%s)" % names[o] if o in names else "")
                           for o, v in sorted(hits.items()))
        print("%-20s %s" % (blocks[base], detail))
    else:
        print("%-20s (all zero)" % blocks[base])
# anything non-zero outside the mapped blocks and below 0x1400 (common/misc)
other = [r for r in rows if r >= 0x1400 and not any(b <= r < b + 0x100 for b in blocks)]
if other:
    print("other non-zero regs:", " ".join("%04x=%s" % (r, rows[r]) for r in sorted(other)[:20]))

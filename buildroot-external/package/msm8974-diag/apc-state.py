#!/usr/bin/env python3
"""Read-only: what power-delivery mode is each Krait core actually in?

Downstream krait-regulator.c (which mainline has no equivalent of) manages a
per-core choice between running off the core's internal LDO and bypassing it
(BHS, "bypass head switch") straight onto the shared APC rail, plus the number
of enabled BHS segments. Mainline never touches this, so the cores keep
whatever the bootloader left - which may not suit the frequencies and rail
voltages our DVFS then programs.

APCS_ALIASn_KPSS_ACS @ 0xf9088000 + 0x10000*n
  0x08 APC_PWR_STATUS
  0x14 APC_PWR_GATE_CTL : BHS_EN[0] BHS_SEG_EN[6:1] LDO_BYP[13:8]
                          LDO_PWR_DWN[21:16] BHS_CNT[31:24]
  0x18 APC_LDO_VREF_SET
"""
import mmap, os, struct

PWR_STATUS, PWR_GATE_CTL, LDO_VREF_SET = 0x08, 0x14, 0x18
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)

print("core  PWR_GATE_CTL  BHS_EN BHS_SEG_EN LDO_BYP LDO_PWR_DWN BHS_CNT  LDO_VREF  mode")
for cpu in range(4):
    base = 0xf9088000 + 0x10000 * cpu
    m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    ctl = struct.unpack("<I", m[PWR_GATE_CTL:PWR_GATE_CTL + 4])[0]
    vref = struct.unpack("<I", m[LDO_VREF_SET:LDO_VREF_SET + 4])[0]
    sts = struct.unpack("<I", m[PWR_STATUS:PWR_STATUS + 4])[0]

    bhs_en = ctl & 1
    bhs_seg = (ctl >> 1) & 0x3f
    ldo_byp = (ctl >> 8) & 0x3f
    ldo_pd = (ctl >> 16) & 0x3f
    bhs_cnt = (ctl >> 24) & 0xff

    if bhs_en and ldo_byp == 0x3f:
        mode = "BHS (bypass, full rail)"
    elif bhs_en and ldo_byp == 0:
        mode = "LDO (regulated below rail)"
    elif bhs_en:
        mode = "mixed BHS/LDO segments"
    else:
        mode = "BHS disabled (core off/retention?)"

    # LDO target, if the LDO is the supply path
    ldo_mv = (465000 + ((vref & 0x3f) * 5000)) // 1000
    print("cpu%d  0x%08x    %d      0x%02x       0x%02x     0x%02x        %3d      "
          "0x%08x (%d mV)  %s   [PWR_STATUS=0x%08x]"
          % (cpu, ctl, bhs_en, bhs_seg, ldo_byp, ldo_pd, bhs_cnt, vref, ldo_mv,
             mode, sts))
    m.close()

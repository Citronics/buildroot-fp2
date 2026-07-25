#!/usr/bin/env python3
"""Read-only: per-core Krait power-delivery init, compared with what the vendor
driver programs.

This does not prove anything about the resets. It answers one narrow question:
do the registers the vendor's krait-regulator.c initialises differ on our
kernel, which never writes them at all?

Vendor writes (krait-regulator.c), both gated on KPSS version > 0x20000000:
    APC_PWR_GATE_DLY  (ACS + 0x20)  = 0x30430600   "hardware sequencer delays"
    APC_PWR_GATE_MODE (ACS + 0x1c)  <- switch mode = BHS
    MDD_CONFIG_CTL    (MDD + 0x00)  = 0x00000190
    MDD_MODE          (MDD + 0x10)  = 0x00000002   "enable MDD"

ACS base 0xf9088000 + 0x10000*cpu ; MDD base 0xf908a800 + 0x10000*cpu
(the MDD lives in the same 4K page as that core's HFPLL at ...a000)
"""
import mmap, os, struct

ACS, MDD_PAGE = 0xf9088000, 0xf908a000
PWR_GATE_CTL, PWR_GATE_MODE, PWR_GATE_DLY = 0x14, 0x1c, 0x20
MDD_OFF = 0x800          # MDD block starts 0x800 into the HFPLL page
MDD_CONFIG_CTL, MDD_MODE = 0x00, 0x10

VENDOR = {"PWR_GATE_DLY": 0x30430600, "MDD_CONFIG_CTL": 0x00000190,
          "MDD_MODE": 0x00000002}

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)


def rd(base, off):
    m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    v = struct.unpack("<I", m[off:off + 4])[0]
    m.close()
    return v


print("core  PWR_GATE_CTL  PWR_GATE_MODE  PWR_GATE_DLY            "
      "MDD_CONFIG_CTL       MDD_MODE")
for cpu in range(4):
    acs = ACS + 0x10000 * cpu
    mdd = MDD_PAGE + 0x10000 * cpu
    ctl = rd(acs, PWR_GATE_CTL)
    mode = rd(acs, PWR_GATE_MODE)
    dly = rd(acs, PWR_GATE_DLY)
    mcfg = rd(mdd, MDD_OFF + MDD_CONFIG_CTL)
    mmode = rd(mdd, MDD_OFF + MDD_MODE)

    def tag(name, val):
        want = VENDOR[name]
        return "0x%08x %s" % (val, "== vendor" if val == want
                              else "!= vendor(0x%08x)" % want)

    print("cpu%d  0x%08x    0x%08x     %s  %s  %s"
          % (cpu, ctl, mode, tag("PWR_GATE_DLY", dly),
             tag("MDD_CONFIG_CTL", mcfg), tag("MDD_MODE", mmode)))

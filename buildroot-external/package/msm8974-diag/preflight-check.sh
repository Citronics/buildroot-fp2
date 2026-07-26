#!/bin/sh
# Read-only pre-soak checks. Run this BEFORE applying any load: each line can
# reorder the hypothesis ranking, and none of it costs more than a minute.
#
# Every decoder here is written down once, correctly, on purpose. Two numbers in
# this investigation were wrong because they came from decoders typed inline at
# the prompt: a PMIC_STS byte read as 940 mV when 0xEA is 1170 mV, and a VBAT
# reading of "3.94 V" that was a raw ADC code divided by 10000 when the true
# value was 4.30 V. Both sent the investigation sideways for a while.
#
# Only physical ranges proven safe on this board are touched: the Krait/HFPLL
# block, the SAWs, the APC blocks, and the QFPROM fuse row. Reading RPM MSG RAM
# (0xfc428000) or IMEM (0xfe805000) through /dev/mem resets this SoC instantly -
# use the drivers instead (see RESET-FORENSICS.md).
DIAG=${DIAG_DIR:-/var/log/msm8974-diag}
mkdir -p "$DIAG"
OUT=$DIAG/preflight-$(cut -c1-8 /proc/sys/kernel/random/boot_id).txt

say() { echo "$*" | tee -a "$OUT"; }

say "=== msm8974 pre-soak check, kernel $(uname -r), uptime $(cut -d' ' -f1 /proc/uptime)s"

say ""
say "--- 1. Did the CX corner vote actually arrive?"
say "    rpmpd_set_performance() returns 0 without sending anything when the"
say "    domain is not enabled, so a failure is invisible in dmesg. Want: cx on,"
say "    performance state 6 at a high OPP, four devices attached."
if [ -r /sys/kernel/debug/pm_genpd/pm_genpd_summary ]; then
	grep -iE "domain|cx" /sys/kernel/debug/pm_genpd/pm_genpd_summary | head -20 | tee -a "$OUT"
else
	say "    (pm_genpd_summary unreadable - need root and CONFIG_DEBUG_FS)"
fi

say ""
say "--- 2. Is AVS live behind the driver's back?"
say "    Any enable bit set means the hardware may have been tracking the rail"
say "    down on its own, which no voltage margin can compensate for."
python3 - <<'PY' 2>&1 | tee -a "$OUT"
import mmap, struct
SAWS = [("L2 ", 0xf9012000)] + [("cpu%d" % n, 0xf9089000 + 0x10000 * n) for n in range(4)]
f = open("/dev/mem", "rb")
for name, base in SAWS:
    page = base & ~0xfff
    m = mmap.mmap(f.fileno(), 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
    off = base - page
    avs_ctl, avs_lim = struct.unpack_from("<II", m, off + 0x20)
    sts, vctl = struct.unpack_from("<I", m, off + 0x14)[0], struct.unpack_from("<I", m, off + 0x1c)[0]
    spm_ctl = struct.unpack_from("<I", m, off + 0x30)[0]
    m.close()
    # v2.1 enable is bit 0; the vendor detects on bit 0 but toggles bit 27, so
    # report both rather than pick a side.
    flags = []
    if avs_ctl & (1 << 0):  flags.append("EN(bit0)")
    if avs_ctl & (1 << 27): flags.append("EN(bit27)")
    print("    %s AVS_CTL=0x%08x %-18s AVS_LIMIT=0x%08x  SPM_CTL=0x%08x seq_armed=%s"
          % (name, avs_ctl, ",".join(flags) or "(off)", avs_lim, spm_ctl,
             "yes" if spm_ctl & 1 else "no"))
    # uV = 5000 * selector. 0xEA is 1170 mV, not 940 mV.
    print("        PMIC_STS=0x%02x -> %d mV    VCTL=0x%08x (vlvl 0x%02x, port %d)"
          % (sts & 0xff, (sts & 0xff) * 5, vctl, vctl & 0xff, (vctl >> 16) & 7))
PY

say ""
say "--- 3. Per-core APC state, and the KPSS version that decides which"
say "    registers matter. Mainline never touches CPU0: if it is not in the"
say "    same BHS state as 1-3, its voltage comes from APC_LDO_VREF_SET, a"
say "    register this kernel never writes."
python3 - <<'PY' 2>&1 | tee -a "$OUT"
import mmap, struct
f = open("/dev/mem", "rb")
def rd(base, count=1):
    page = base & ~0xfff
    m = mmap.mmap(f.fileno(), 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
    v = struct.unpack_from("<%dI" % count, m, base - page)
    m.close()
    return v
ver, = rd(0xf9011fd0)
print("    KPSS VERSION = 0x%08x  -> %s" % (ver,
      "> 0x20000000: PWR_GATE_MODE/DLY are the registers that decide the mode"
      if ver > 0x20000000 else "<= 0x20000000: APC_PWR_GATE_CTL decides the mode"))
for n in range(4):
    b = 0xf9088000 + 0x10000 * n
    ctl, vref, mode, dly = rd(b + 0x14)[0], rd(b + 0x18)[0], rd(b + 0x1c)[0], rd(b + 0x20)[0]
    modes = {0: "PC", 1: "LDO", 2: "BHS", 3: "DT(seq picks)", 4: "RET"}
    print("    cpu%d PWR_GATE_CTL=0x%08x BHS_EN=%d SEG=0x%02x LDO_BYP=0x%02x "
          "LDO_PWR_DWN=0x%02x" % (n, ctl, ctl & 1, (ctl >> 1) & 0x3f,
                                  (ctl >> 8) & 0x3f, (ctl >> 16) & 0x3f))
    print("         MODE=0x%08x switch=%s  VREF=0x%08x DLY=0x%08x"
          % (mode, modes.get((mode >> 4) & 7, "?"), vref, dly))
PY

say ""
say "--- 4. What rate is the L2 actually running, and the FTS2 phase/mode."
say "    The vendor keys the CX corner off the L2 rate; this kernel never sets"
say "    or reads it. Nothing here manages phases or PWM-vs-PFM either."
if [ -r /sys/kernel/debug/clk/clk_summary ]; then
	grep -E "hfpll_l2|krait_l2|acpu_aux|qsb" /sys/kernel/debug/clk/clk_summary | tee -a "$OUT"
else
	say "    (clk_summary unreadable)"
fi

say ""
say "--- 5. Was the previous reset a watchdog bite? (needs CONFIG_WATCHDOG_SYSFS)"
if [ -r /sys/class/watchdog/watchdog0/bootstatus ]; then
	bs=$(cat /sys/class/watchdog/watchdog0/bootstatus)
	say "    bootstatus=$bs  $([ "$bs" = "32" ] && echo '(0x20 WDIOF_CARDRESET: reset BY the watchdog)' || echo '(no card-reset flag)')"
	say "    barks serviced: $(grep -c wdt_bark /proc/interrupts 2>/dev/null || echo 0)"
	grep wdt_bark /proc/interrupts 2>/dev/null | tee -a "$OUT"
else
	say "    bootstatus absent - CONFIG_WATCHDOG_SYSFS is not enabled in this build,"
	say "    so 'was this a watchdog bite' cannot be asked. A bite is byte-identical"
	say "    to a reboot at the PMIC, so nothing else can answer it."
fi

say ""
say "--- 6. Persistent-RAM logging"
if [ -d /sys/fs/pstore ] || grep -q pstore /proc/filesystems 2>/dev/null; then
	mountpoint -q /sys/fs/pstore 2>/dev/null || mount -t pstore pstore /sys/fs/pstore 2>/dev/null
	n=$(ls /sys/fs/pstore 2>/dev/null | wc -l)
	say "    pstore records present: $n"
	ls -la /sys/fs/pstore 2>/dev/null | tee -a "$OUT"
	say "    NOTE: an empty dmesg-ramoops beside a populated console-ramoops is"
	say "    the discriminator - it means nothing on this CPU asked for the reset."
else
	say "    no pstore support in this kernel (CONFIG_PSTORE absent)"
fi

say ""
say "--- 7. RPM's own view (driver-mediated, safe - never /dev/mem here)"
for m in APSS MPSS LPSS PRONTO; do
	p=/sys/kernel/debug/qcom_rpm_master_stats/$m
	[ -r "$p" ] && { say "    $m:"; sed 's/^/      /' "$p" | tee -a "$OUT"; }
done
[ -r /sys/kernel/debug/qcom_stats/vmin ] && { say "    vmin:"; sed 's/^/      /' /sys/kernel/debug/qcom_stats/vmin | tee -a "$OUT"; }

say ""
say "--- 8. Previous power-off reason"
for t in "$DIAG/pon-reason.sh" /usr/bin/msm8974-pon-reason ./pon-reason.sh; do
	[ -x "$t" ] && { "$t" | tee -a "$OUT"; break; }
done

say ""
say "--- 9. Battery rail, calibrated against the ADC's own references"
python3 - <<'PY' 2>&1 | tee -a "$OUT"
import glob, os
hits = glob.glob("/sys/bus/iio/devices/iio:device*/in_voltage6_raw")
if not hits:
    print("    no VADC channel 6 found")
else:
    d = os.path.dirname(hits[0])
    def raw(ch):
        return int(open("%s/in_voltage%d_raw" % (d, ch)).read())
    # ch9 = 625 mV ref, ch10 = 1250 mV ref, ch14 = GND, ch6 = VBAT_SNS (1/3)
    gnd, r625, r1250, vb = raw(14), raw(9), raw(10), raw(6)
    cpm = (r1250 - r625) / 625.0
    print("    counts/mV=%.3f (from the 625/1250 mV refs, GND=%d)" % (cpm, gnd))
    print("    VBAT = %.3f V   (raw %d; dividing a raw code by 10000 is WRONG)"
          % ((vb - gnd) / cpm * 3 / 1000, vb))
PY

say ""
say "saved to $OUT"

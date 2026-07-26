#!/usr/bin/env python3
"""Capture the same fields the Android baseline recorded, from our kernel.

Register reads are restricted to the Krait/APC/SAW blocks. The RPM MSG RAM
(0xfc428000) and IMEM (0xfe805000) are never touched: reading them through
/dev/mem resets this SoC instantly.
"""
import glob, mmap, os

def rd(path, d="?"):
    try:
        return open(path).read().strip()
    except Exception:
        return d

def reg(base, offsets):
    out = {}
    try:
        fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
        pg = base & ~0xfff
        m = mmap.mmap(fd, 0x1000, mmap.PROT_READ, mmap.MAP_SHARED, offset=pg)
        for name, off in offsets:
            a = (base - pg) + off
            out[name] = int.from_bytes(m[a:a+4], "little")
        m.close(); os.close(fd)
    except Exception as e:
        out["error"] = str(e)
    return out

print("=== KERNEL"); print(os.uname().release)
print("\n=== CPUFREQ")
for p in sorted(glob.glob("/sys/devices/system/cpu/cpufreq/policy*")):
    print("%s cur=%s min=%s max=%s gov=%s related=%s trans=%s" % (
        os.path.basename(p), rd(p+"/scaling_cur_freq"), rd(p+"/scaling_min_freq"),
        rd(p+"/scaling_max_freq"), rd(p+"/scaling_governor"),
        rd(p+"/related_cpus"), rd(p+"/stats/total_trans")))
print("available:", rd("/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies"))

print("\n=== REGULATORS (name / uV / state)")
for r in sorted(glob.glob("/sys/class/regulator/regulator.*")):
    n = rd(r+"/name")
    if n in ("?", ""):
        continue
    print("%-22s %10s uV  %-9s type=%s" % (n, rd(r+"/microvolts"), rd(r+"/state"), rd(r+"/type")))

print("\n=== GENPD / performance states")
for f in ("/sys/kernel/debug/pm_genpd/pm_genpd_summary",):
    t = rd(f, "")
    if t:
        for line in t.splitlines():
            if any(k in line for k in ("domain", "cx", "mx", "gfx", "mss")):
                print(line)

print("\n=== CLOCKS (krait / l2 / hfpll)")
t = rd("/sys/kernel/debug/clk/clk_summary", "")
for line in t.splitlines():
    if any(k in line.lower() for k in ("l2", "krait", "hfpll", "acpu")):
        print(line.rstrip())

print("\n=== CPUIDLE")
for c in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]/cpuidle/state*")):
    print("%s %-12s disable=%s usage=%-8s time=%-10s lat=%s" % (
        "/".join(c.split("/")[-3:]), rd(c+"/name"), rd(c+"/disable"),
        rd(c+"/usage"), rd(c+"/time"), rd(c+"/latency")))

print("\n=== THERMAL")
for z in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
    print("%s %-18s %s mC" % (os.path.basename(z), rd(z+"/type"), rd(z+"/temp")))

print("\n=== SAW (L2 @0xf9012000 and per-core @0xf9089000+n*0x10000)")
SAW = [("PMIC_STS",0x14),("RST",0x18),("VCTL",0x1c),("AVS_CTL",0x20),("AVS_LIMIT",0x24),("SPM_CTL",0x30)]
def show(tag, base, offs):
    v = reg(base, offs)
    if "error" in v:
        print("%s @%#x ERROR %s" % (tag, base, v["error"])); return
    print("%s @%#x  %s" % (tag, base, "  ".join("%s=%#x" % (k, v[k]) for k, _ in offs)))
show("saw_l2  ", 0xf9012000, SAW)
for n in range(4):
    show("saw_c%d  " % n, 0xf9089000 + n*0x10000, SAW)

print("\n=== APC per-core power switch (@0xf9088000+n*0x10000) and KPSS version")
APC = [("PWR_GATE_CTL",0x14),("LDO_VREF_SET",0x18),("PWR_GATE_MODE",0x1c),("PWR_GATE_DLY",0x20)]
for n in range(4):
    show("apc_c%d  " % n, 0xf9088000 + n*0x10000, APC)
show("kpss_ver", 0xf9011fd0, [("VERSION",0x0)])
MDD = [("MDD_CONFIG_CTL",0x0),("MDD_MODE",0x4)]
for n in range(4):
    show("mdd_c%d  " % n, 0xf908a800 + n*0x10000, MDD)

print("\n=== PMIC forensics")
for f in sorted(glob.glob("/sys/kernel/debug/qcom_pon/*")) + ["/sys/firmware/devicetree/base/model"]:
    print(f, "->", rd(f))

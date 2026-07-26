# Android / vendor CPU DVFS + power reference specification — Fairphone 2 (MSM8974Pro-AA)

Target: reproduce stock Android behaviour on a mainline-based kernel, exactly, before deviating.

## 0. Provenance of every claim in this document

| Tag | Source | Where |
|---|---|---|
| `VK` | `FairphoneMirrors/android_kernel_fairphone_msm8974`, branch **`int/10/fp2`**, HEAD `e61ed9bae4e7` — Fairphone's official Android-10 BSP, Linux **3.4.113** | `<scratch>/vk` (shallow, sparse) |
| `VD10` | `fairphone-mirror/device_fairphone_fp2`, branches `int/10/fp2` and `rel/10/fp2/23.02.0-rel` — the Android-10 device tree that pairs with `VK` | `<scratch>/fp10/` |
| `VD6` | `FairphoneMirrors/android_device_fairphone_FP2` (`fp2-m-sibon`, Android 6) | `<scratch>/vd` |
| `QC` | `FairphoneMirrors/android_device_qcom_common`, `fp2*sibon` branches (`init.qcom.post_boot.sh`) | `<scratch>/hunt-d/` |
| `FORK` | this repo, branch `6.18/rc` | `/var/home/marc/Projects/linux-msm8x74` |
| `LK` | lk2nd bootloader source | `<scratch>/lk2nd-krait.c` |

`<scratch>` = `/tmp/claude-1000/-var-home-marc-Projects-linux-msm8x74/fe96ce02-47ff-4665-bb69-834de9037f0e/scratchpad`.

**Which DTB FP2 boots.** The BSP builds exactly one 8974 DTB:

```
VK/arch/arm/mach-msm/Makefile.boot:50
    dtb-$(CONFIG_ARCH_MSM8974) += msm8974pro-ab-pm8941-mtp.dtb
```

Fairphone reuses Qualcomm's *MTP* board files verbatim; there is no `*fairphone*` DTS.
Include chain (this is FP2's effective device tree, and every DT citation below is in it):

```
msm8974pro-ab-pm8941-mtp.dts:15,16   → msm8974pro-ab-pm8941.dtsi + msm8974-mtp.dtsi
  model = "Qualcomm MSM 8974Pro-AA/AB MTP"                    (…-mtp.dts:19)
msm8974pro-ab-pm8941.dtsi:16-23      qcom,msm-id = <208 …> <217 0x10000> <218 …>   ← soc_id 217 is here
msm8974pro-ab-pm8941.dtsi:13         → msm8974pro-pm8941.dtsi
msm8974pro-pm8941.dtsi:19            → msm8974pro.dtsi   (also pulls msm8974-regulator.dtsi, msm8974-clock.dtsi)
msm8974pro.dtsi:22                   → msm8974pro-pm.dtsi
msm8974pro.dtsi                      → msm8974.dtsi
```

Verified by grep that **no** file in that chain overrides `qcom,cpufreq-table`, `qcom,l2-fmax`, the
`qcom,clock-krait@f9016000` supplies, or `qcom,msm-thermal` (other than the three
`/delete-property/` lines at `msm8974pro.dtsi:38-42`). The base `msm8974.dtsi` values therefore apply.

---

# (a) THE SPECIFICATION

## a.1 What drives DVFS at all

| Layer | Vendor component | File |
|---|---|---|
| cpufreq driver | `qcom,msm-cpufreq` → `msm_cpufreq` | `VK/arch/arm/mach-msm/cpufreq.c` |
| CPU/L2 clock tree + PVS voltage plan | `qcom,clock-krait-8974` | `VK/arch/arm/mach-msm/clock-krait-8974.c`, `clock-krait.c` |
| per-core APC regulator (LDO/BHS) | `qcom,krait-pdn` + 4× `qcom,krait-regulator` | `VK/arch/arm/mach-msm/krait-regulator.c` |
| gang voltage transport | L2 SAW/SPM → PM8841 FTS over SPMI | `VK/arch/arm/mach-msm/spm_devices.c`, `spm-v2.c`, `krait-regulator-pmic.c` |
| CX / analog corner votes | `rpm-regulator-smd` (PM8841 S2 corner, PM8941 L12) | `VK/arch/arm/mach-msm/rpm-regulator-smd.c` |
| in-kernel thermal | `qcom,msm-thermal` (KTM) | `VK/drivers/thermal/msm_thermal.c` |
| idle | `qcom,lpm-levels` + `qcom,pm-8x60` + SAW2 SPM | `VK/arch/arm/mach-msm/lpm_levels.c`, `msm-pm.c`, `pm-data.c` |

Relevant config, `VK/arch/arm/configs/fairphone_defconfig`:

```
:489  CONFIG_MSM_PM=y                     :514  CONFIG_MSM_SPM_V2=y
:515  CONFIG_MSM_L2_SPM=y                 :543  CONFIG_KRAIT_REGULATOR=y
:712  CONFIG_CPU_FREQ=y                   :739  CONFIG_CPU_FREQ_MSM=y
:716  CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
:444  # CONFIG_MSM_CPU_FREQ_SET_MIN_MAX is not set
:530  # CONFIG_MSM_CPR is not set          :542  # CONFIG_MSM_CPR_REGULATOR is not set
:446  # CONFIG_MSM_AVS_HW is not set       :529  # CONFIG_MSM_DCVS is not set
:461  # CONFIG_MSM_SPM_REGULATOR is not set
:2114 CONFIG_THERMAL_MONITOR=y            :2113 CONFIG_THERMAL_TSENS8974=y
```

## a.2 The PVS voltage plan actually selected — `qcom,speed1-pvs12-bin-v1`

Table name is built from the fuse at `0xfc4b80b0`:
`snprintf(table_name, …, "qcom,speed%d-pvs%d-bin-v%d", speed, pvs, pvs_ver)` —
`clock-krait-8974.c:687-689`, fuse decode `get_krait_bin_format_b()` `:416-477`.
`qcom,pvs-config-ver = <1>` (`msm8974.dtsi:1040`) is only stored and re-exported as the
`pvs_config_ver` module param (`:680-685`, `:590-591`) — it selects nothing.

The 29-row plan, `VK/arch/arm/boot/dts/msm8974pro.dtsi:883-912` (`<rate_Hz  uV  µA>`), matches the
owner's extracted table exactly (800 mV flat to 806.4 MHz, 1040 mV at 2265.6 MHz, max 2265.6 MHz):

| Hz | µV | µA | | Hz | µV | µA |
|---|---|---|---|---|---|---|
| 300 000 000 | 800000 | 76 | | 1 574 400 000 | 905000 | 458 |
| 345 600 000 | 800000 | 87 | | 1 651 200 000 | 920000 | 486 |
| 422 400 000 | 800000 | 108 | | 1 728 000 000 | 935000 | 515 |
| 499 200 000 | 800000 | 129 | | 1 804 800 000 | 950000 | 543 |
| 576 000 000 | 800000 | 150 | | 1 881 600 000 | 965000 | 572 |
| 652 800 000 | 800000 | 171 | | 1 958 400 000 | 980000 | 604 |
| 729 600 000 | 800000 | 193 | | 2 035 200 000 | 995000 | 636 |
| 806 400 000 | 800000 | 215 | | 2 112 000 000 | 1010000 | 669 |
| 883 200 000 | 810000 | 237 | | 2 150 400 000 | 1025000 | 703 |
| 960 000 000 | 820000 | 260 | | 2 188 800 000 | 1025000 | 703 |
| 1 036 800 000 | 830000 | 282 | | 2 265 600 000 | 1040000 | 738 |
| 1 113 600 000 | 840000 | 306 | | | | |
| 1 190 400 000 | 850000 | 330 | | | | |
| 1 267 200 000 | 860000 | 354 | | | | |
| 1 344 000 000 | 870000 | 378 | | | | |
| 1 420 800 000 | 880000 | 404 | | | | |
| 1 497 600 000 | 890000 | 431 | | | | |

**These numbers are used verbatim.** The only two mutators are inert on FP2
(`krait_update_uv()`, `clock-krait-8974.c:570-586`): the `+25000 µV` boost needs the `boost` module
param (default `false`, `:567-568`), and the `max(1150000, uv[i])` floor applies only to CPUIDs
`0x511F04D0/0x511F04D1/0x510F06F0` (Krait-2, MSM8960-era), not to 8974's Krait 4.
There is no `qcom,avs-tbl` in the DT and `CONFIG_MSM_AVS_HW=n`, so AVS never trims anything either.

The 29 rows become the CPU clock's `fmax`/`vdd_uv`/`vdd_ua` arrays
(`clk_init_vdd_class()`, `:529-547`, called `:710-717`); this is also what caps the CPU clock at
2265.6 MHz (`kpss_core_round_rate()`, `clock-krait.c:410-416`).

## a.3 **The cpufreq table Android actually exposes — 14 OPPs, lowest = 300 MHz**

Source table, `<cpu_kHz  l2_kHz  mem_MBps>` (3 columns because `l2_clk` exists —
`cpufreq.c:426-439`), `VK/arch/arm/boot/dts/msm8974.dtsi:1666-1685`:

```
1669  qcom,cpufreq-table =
1670      <  300000  300000  572 >,   1677      < 1190400 1036800 3509 >,
1671      <  422400  422400 1144 >,   1678      < 1267200 1267200 4684 >,
1672      <  652800  499200 1525 >,   1679      < 1497600 1497600 4684 >,
1673      <  729600  576000 2342 >,   1680      < 1574400 1574400 6103 >,
1674      <  883200  576000 2342 >,   1681      < 1728000 1651200 6103 >,
1675      <  960000  960000 3509 >,   1682      < 1958400 1728000 7102 >,
1676      < 1036800 1036800 3509 >,   1683      < 2265600 1728000 7102 >,
                                      1684      < 2457600 1728000 7102 >;
```

`cpufreq_parse_dt()` (`cpufreq.c:463-509`) rounds every CPU rate through
`clk_round_rate(cpu_clk[0], …)` and **stops at the first row that does not increase**:

```
487      if (i > 0 && f <= freq_table[i-1].frequency)
488              break;
```

Row 14 (`2457600`) is clamped by `fmax[28] = 2265600000` to `2265600`, equals row 13, so it is
dropped. **FP2's effective cpufreq table is rows 0-13 — 14 OPPs:**

| # | CPU kHz | CPU µV (PVS12) | L2 kHz | Mem MBps |
|---|---|---|---|---|
| 0 | **300 000** | 800000 | 300000 | 572 |
| 1 | 422 400 | 800000 | 422400 | 1144 |
| 2 | 652 800 | 800000 | 499200 | 1525 |
| 3 | 729 600 | 800000 | 576000 | 2342 |
| 4 | 883 200 | 810000 | 576000 | 2342 |
| 5 | 960 000 | 820000 | 960000 | 3509 |
| 6 | 1 036 800 | 830000 | 1036800 | 3509 |
| 7 | 1 190 400 | 850000 | 1036800 | 3509 |
| 8 | 1 267 200 | 860000 | 1267200 | 4684 |
| 9 | 1 497 600 | 890000 | 1497600 | 4684 |
| 10 | 1 574 400 | 905000 | 1574400 | 6103 |
| 11 | 1 728 000 | 935000 | 1651200 | 6103 |
| 12 | 1 958 400 | 980000 | 1728000 | 7102 |
| 13 | **2 265 600** | 1040000 | 1728000 | 7102 |

Note this is a **subset** of the 29-row clock plan: 345.6, 499.2, 576, 806.4, 1113.6, 1344, 1420.8,
1651.2, 1804.8, 1881.6, 2035.2, 2112, 2150.4 and 2188.8 MHz exist in the voltage plan but are
**not offered to cpufreq**. Governors only ever land on the 14 rates above.

**Each core scales independently.** All four `cpu%d_clk` lookups succeed
(`clock-krait-8974.c:398-401`), so `is_sync` stays false (`cpufreq.c:563-570`) and
`cpumask_setall(policy->cpus)` is not taken (`cpufreq.c:256-258`) → four independent policies.

### a.3.1 scaling_min / scaling_max / governor at boot — **the 960 MHz claim is REFUTED**

`VD10/…/root/init.qcom.power.rc` (`<scratch>/fp10/int_10_fp2__init.qcom.power.rc`, byte-identical
in `rel/10/fp2/23.02.0-rel`). `on boot` → `trigger enable-low-power` (`:130-131`):

```
 64-67  scaling_governor = "interactive"           (cpu0..cpu3)
 68     interactive/above_hispeed_delay "19000 1400000:39000 1700000:19000"
 69     interactive/go_hispeed_load 99
 70     interactive/hispeed_freq 1190400
 71     interactive/io_is_busy 1
 72     interactive/target_loads "85 1500000:90 1800000:70"
 73     interactive/min_sample_time 40000
 74     interactive/timer_rate 30000
 75     interactive/sampling_down_factor 100000
 76     interactive/timer_slack 30000
 77     interactive/up_threshold_any_cpu_load 50
 78     interactive/sync_freq 1036800
 79     interactive/up_threshold_any_cpu_freq 1190400
 81-84  scaling_min_freq 300000                    (cpu0..cpu3)   ← ***300 MHz***
 99     cpu_boost/boost_ms 20
100     cpu_boost/sync_threshold 1728000
101     cpu_boost/input_boost_freq 1497600
102     cpu_boost/input_boost_ms 40
```

`scaling_max_freq` is **never written** → stays at the speed-bin maximum, 2265600.
Offline-charging mode uses `powersave` + the same `scaling_min_freq 300000` (`:117-124`).

Corroboration on the older BSP: `QC/rootdir/etc/init.qcom.post_boot.sh` — soc_id 217 is in the
`interactive` branch at `:279`; `hispeed_freq 1190400` `:290`; and the four
`echo 300000 > …/scaling_min_freq` writes at `:319-322` sit **outside** the soc_id switch,
i.e. unconditional for every 8974.

Kernel side agrees: `# CONFIG_MSM_CPU_FREQ_SET_MIN_MAX is not set`
(`fairphone_defconfig:444`) compiles out the only clamp (`cpufreq.c:269-277`), so
`policy->min` = table minimum = **300000**.

**Where "960 MHz" comes from, and why it is not a floor.**
`qcom,freq-mitigation-value = <960000>` (`msm8974.dtsi:2374`) is the emergency thermal **ceiling**
applied to **CPU0 only** at 110 °C — the opposite of a floor (§a.7). The only other 960000 in the
whole BSP is `ondemand/optimal_freq` / `ondemand/sync_freq` in a post_boot branch FP2 never takes.
`729600` never appears as a min-freq anywhere.

**The one real min-freq floor in the vendor kernel is cold-temperature only:**
`qcom,vdd-apps-rstr { qcom,levels = <1881600 1958400 2265600>; qcom,freq-req; }`
(`msm8974.dtsi:2396-2400`) → `update_cpu_min_freq_all(1881600)` when any tsens ≤ 5 °C, released
above 10 °C (`msm_thermal.c:345-371`, `:314-343`, `:1193-1244`).

## a.4 The L2 plan and the L2 → CX corner mapping

### a.4.1 L2 rates and the CPU→L2 map

The L2 rate is column 2 of `qcom,cpufreq-table`, and it follows the **highest-frequency online
core**, not each core:

```
cpufreq.c:80-95   update_l2_bw():
    for_each_online_cpu(cpu) index = max(index, freq_index[cpu]);
    clk_set_rate(l2_clk, l2_khz[index] * 1000);
```

Distinct L2 rates in use (11): 300000, 422400, 499200, 576000, 960000, 1036800, 1267200,
1497600, 1574400, 1651200, 1728000 kHz. L2 ceiling = 1728000 kHz, from the last `qcom,l2-fmax`
row becoming `l2_clk.fmax[3]` (`clock-krait-8974.c:727-735`, `clock-krait.c:410-414`).

Non-obvious features of the map (all from the table in §a.3): 729.6 **and** 883.2 MHz both run L2
at 576 MHz; 1036.8 **and** 1190.4 MHz both run L2 at 1036.8 MHz; 1958.4 **and** 2265.6 MHz both
run L2 at 1728 MHz. The L2 is never run at the CPU rate above 1728 MHz.

### a.4.2 `qcom,l2-fmax` → CX corner (confirmed and completed)

```
VK/arch/arm/boot/dts/msm8974.dtsi:1042-1046
    qcom,l2-fmax =
        <          0 0                  >,
        <  576000000 4 /* SVS_SOC */    >,
        < 1036800000 5 /* NORMAL */     >,
        < 1728000000 7 /* SUPER_TURBO */ >;
```

Parsed as `<fmax, corner>` pairs into the L2 clock's `vdd_class`
(`clock-krait-8974.c:727-735`); `fmax[n]` is the **highest** L2 rate allowed at vote level `n`:

| L2 rate | vote level | RPM corner | corner name |
|---|---|---|---|
| 0 (off) | 0 | 0 | no vote |
| 1 … 576 000 kHz | 1 | **4** | SVS_SOC |
| 576 001 … 1 036 800 kHz | 2 | **5** | NORMAL |
| 1 036 801 … 1 728 000 kHz | 3 | **7** | SUPER_TURBO |

Consumer: `l2-dig-supply = <&pm8841_s2_corner_ao>` (`msm8974.dtsi:1035`), fetched as `"l2-dig"`
(`clock-krait-8974.c:603-607`).

### a.4.3 The HFPLLs vote on CX too — second, independent path

```
clock-krait-8974.c:38-47
    static int hfpll_uv[] = {
        RPM_REGULATOR_CORNER_NONE,        0,
        RPM_REGULATOR_CORNER_SVS_SOC,     1800000,
        RPM_REGULATOR_CORNER_NORMAL,      1800000,
        RPM_REGULATOR_CORNER_SUPER_TURBO, 1800000, };
    static DEFINE_VDD_REGULATORS(vdd_hfpll, …, 2, hfpll_uv, NULL);
    static unsigned long hfpll_fmax[] = { 0, 998400000, 1996800000, 2900000000UL };
```

`vdd_hfpll` is **one shared vote class for all five HFPLLs** (hfpll0-3 + hfpll_l2 —
`:71, :87, :103, :119, :135`), with two regulators:
`hfpll-dig-supply = <&pm8841_s2_corner_ao>` (CX corner) and
`hfpll-analog-supply = <&pm8941_l12_ao>` (1.8 V fixed) — `msm8974.dtsi:1036-1037`,
fetched `:609-619`.

| HFPLL rate | RPM corner on CX | analog |
|---|---|---|
| ≤ 998 400 000 Hz | **4** SVS_SOC | 1.8 V |
| ≤ 1 996 800 000 Hz | **5** NORMAL | 1.8 V |
| ≤ 2 900 000 000 Hz | **7** SUPER_TURBO | 1.8 V |

**HFPLL rate for a given core rate.** The Krait primary mux tries sources in list order and takes
the first that rounds *exactly* (`mux_set_rate()`, `clock-generic.c:109-116`); order is
`hfpllN` (direct), `hfpllN_div` (÷2), `sec_mux` (`clock-krait-8974.c:216-220`). The HFPLL rounds to
a multiple of 19.2 MHz clamped to `[537 600 000, 2 900 000 000]`
(`hfpll_clk_round_rate()`, `clock-krait.c:210-227`; `hdata.min_rate/max_rate`,
`clock-krait-8974.c:60-61`). Therefore:

* core rate ≥ 576 MHz → **HFPLL runs at the core rate**;
* core rate < 537.6 MHz → **HFPLL runs at 2× the core rate** (÷2 path).

### a.4.4 Resulting CX corner per OPP — **Android does NOT pin SUPER_TURBO**

Effective CX corner = max over all voters on `pm8841_s2` (the two Krait paths shown here, plus
unrelated subsystems). Per OPP, with all cores at that rate:

| CPU kHz | HFPLL kHz | HFPLL corner | L2 kHz | L2 corner | **CX corner** | mainline label |
|---|---|---|---|---|---|---|
| 300 000 | 600 000 (÷2) | 4 | 300 000 | 4 | **4 SVS_SOC** | `rpmpd_opp_svs_soc` |
| 422 400 | 844 800 (÷2) | 4 | 422 400 | 4 | **4 SVS_SOC** | `rpmpd_opp_svs_soc` |
| 652 800 | 652 800 | 4 | 499 200 | 4 | **4 SVS_SOC** | `rpmpd_opp_svs_soc` |
| 729 600 | 729 600 | 4 | 576 000 | 4 | **4 SVS_SOC** | `rpmpd_opp_svs_soc` |
| 883 200 | 883 200 | 4 | 576 000 | 4 | **4 SVS_SOC** | `rpmpd_opp_svs_soc` |
| 960 000 | 960 000 | 4 | 960 000 | 5 | **5 NORMAL** | `rpmpd_opp_nom` |
| 1 036 800 | 1 036 800 | 5 | 1 036 800 | 5 | **5 NORMAL** | `rpmpd_opp_nom` |
| 1 190 400 | 1 190 400 | 5 | 1 036 800 | 5 | **5 NORMAL** | `rpmpd_opp_nom` |
| 1 267 200 | 1 267 200 | 5 | 1 267 200 | 7 | **7 SUPER_TURBO** | `rpmpd_opp_super_turbo` |
| 1 497 600 | 1 497 600 | 5 | 1 497 600 | 7 | **7 SUPER_TURBO** | `rpmpd_opp_super_turbo` |
| 1 574 400 | 1 574 400 | 5 | 1 574 400 | 7 | **7 SUPER_TURBO** | `rpmpd_opp_super_turbo` |
| 1 728 000 | 1 728 000 | 5 | 1 651 200 | 7 | **7 SUPER_TURBO** | `rpmpd_opp_super_turbo` |
| 1 958 400 | 1 958 400 | 5 | 1 728 000 | 7 | **7 SUPER_TURBO** | `rpmpd_opp_super_turbo` |
| 2 265 600 | 2 265 600 | 7 | 1 728 000 | 7 | **7 SUPER_TURBO** | `rpmpd_opp_super_turbo` |

With cores at mixed rates the answer is the same as for the fastest core (both voters are maxima).

### a.4.5 Corner-number Rosetta stone (vendor ↔ mainline) — verified, no off-by-one

Vendor enum, `VK/arch/arm/mach-msm/include/mach/rpm-regulator-smd.h:31-39`:
`NONE=1, RETENTION=2, SVS_KRAIT=3, SVS_SOC=4, NORMAL=5, TURBO=6, SUPER_TURBO=7`.

Vendor puts `corner − 1` on the RPM wire:
`corner = min_uV - RPM_REGULATOR_CORNER_NONE;` — `rpm-regulator-smd.c:713`, wire range `[0,6]` (`:127`).

Mainline sends the OPP level **verbatim**, clamped to `max_state = MAX_CORNER_RPMPD_STATE = 6`
(`FORK:drivers/pmdomain/qcom/rpmpd.c:1058-1075`, `:43`, `:729-733`), and the fork's corner OPP table
is levels 1-6 (`FORK:arch/arm/boot/dts/qcom/qcom-msm8974.dtsi:1762-1783`). So:

| vendor DT number | vendor name | RPM wire value | mainline `opp-level` | mainline label |
|---|---|---|---|---|
| 2 | RETENTION | 1 | 1 | `rpmpd_opp_ret` |
| 3 | SVS_KRAIT | 2 | 2 | `rpmpd_opp_svs_krait` |
| **4** | **SVS_SOC** | 3 | **3** | **`rpmpd_opp_svs_soc`** |
| **5** | **NORMAL** | 4 | **4** | **`rpmpd_opp_nom`** |
| 6 | TURBO | 5 | 5 | `rpmpd_opp_turbo` |
| **7** | **SUPER_TURBO** | 6 | **6** | **`rpmpd_opp_super_turbo`** |

The mainline labels are semantically correct. Beware the trap: to request the vendor's **NORMAL**
you must use **`rpmpd_opp_nom`**, and the vendor's **SVS_SOC** is **`rpmpd_opp_svs_soc`** — the
numbers differ by one from the vendor DT's, the names do not.

## a.5 Rail topology

```
                 VPH_PWR
                    │
        PM8841 FTS "krait-regulator-pmic"  (SPMI: ctl@0x2000, ps@0x2100, freq@0x2200)
        = the external APC SMPS.  NOT an RPM regulator; commanded by the L2 SAW.
                    │  VDD_APC  (one ganged rail, 1-4 phases)
   ┌────────────┬───┴────────┬────────────┐
 ┌─┴──┐       ┌─┴──┐       ┌─┴──┐       ┌─┴──┐        per core: LDO ∥ BHS ∥ LDO-BYP
 │K0  │       │K1  │       │K2  │       │K3  │        (krait0..3_vreg)
 └─┬──┘       └─┬──┘       └─┬──┘       └─┬──┘
 Krait0       Krait1       Krait2       Krait3

separate rails, voted by the Krait clock driver, not by the cores:
  CX  = PM8841 S2, corner, ACTIVE-SET ONLY   ← l2-dig + hfpll-dig
  1.8 = PM8941 L12,        ACTIVE-SET ONLY   ← hfpll-analog
```

### a.5.1 Nodes

Parent, `VK/arch/arm/boot/dts/msm8974-regulator.dtsi:457-468`:

```
krait_pdn: krait-pdn@f9011000 {
        reg = <0xf9011000 0x1000>,        /* apcs_gcc            */
              <0xfc4b80b0 8>;             /* phase-scaling-efuse */
        compatible = "qcom,krait-pdn";
        qcom,pfm-threshold = <76>;
        qcom,use-phase-scaling-factor;
        qcom,phase-scaling-factor-bits-pos = <16>;
        qcom,valid-scaling-factor-versions = <0 1 0 0>;
};
```
Pro override, `msm8974pro-pm8941.dtsi:36-39`: adds `qcom,use-phase-switching;` and changes
`qcom,valid-scaling-factor-versions = <0 1 1 0>`.

Per-core, `msm8974-regulator.dtsi:470-485` (krait0; 1/2/3 identical at `:487-501`, `:503-517`,
`:519-533` with the obvious address and `qcom,cpu-num` changes):

```
krait0_vreg: regulator@f9088000 {
        compatible = "qcom,krait-regulator";
        regulator-name = "krait0";
        reg = <0xf9088000 0x1000>,   /* APCS_ALIAS0_KPSS_ACS */
              <0xf908a800 0x1000>;   /* APCS_ALIAS0_KPSS_MDD */
        reg-names = "acs", "mdd";
        regulator-min-microvolt = <500000>;
        regulator-max-microvolt = <1100000>;    /* Pro: 1120000 */
        qcom,headroom-voltage     = <150000>;
        qcom,retention-voltage    = <675000>;
        qcom,ldo-default-voltage  = <750000>;
        qcom,ldo-threshold-voltage= <850000>;
        qcom,ldo-delta-voltage    = <50000>;    /* Pro: 12500  */
        qcom,cpu-num = <0>;
};
```
Pro overrides, `msm8974pro-pm8941.dtsi:41-59`: `regulator-max-microvolt = <1120000>` and
`qcom,ldo-delta-voltage = <12500>` on all four.

Addresses: ACS = `0xf9088000 + 0x10000·n`, MDD = `0xf908a800 + 0x10000·n`.

### a.5.2 How the CPUs are attached

```
VK/arch/arm/boot/dts/msm8974.dtsi:1031-1037
        cpu0-supply = <&krait0_vreg>;
        cpu1-supply = <&krait1_vreg>;
        cpu2-supply = <&krait2_vreg>;
        cpu3-supply = <&krait3_vreg>;
        l2-dig-supply       = <&pm8841_s2_corner_ao>;
        hfpll-dig-supply    = <&pm8841_s2_corner_ao>;
        hfpll-analog-supply = <&pm8941_l12_ao>;
```

**Each core has its own regulator device.** They are *not* pointed at the SAW.

### a.5.3 The gang voltage, and the SAW as transport

`set_pmic_gang_voltage()` — `krait-regulator.c:730-777`:

```
setpoint = DIV_ROUND_UP(uV, LV_RANGE_STEP);      /* LV_RANGE_STEP = 5000  (:64) */
rc = msm_spm_set_vdd(0, setpoint);               /* "value of CPU is don't care" */
```
clamped to `[PMIC_VOLTAGE_MIN 350000, PMIC_VOLTAGE_MAX 1355000]` (`:62-63`, `:741-751`).

`msm_spm_set_vdd()` routes **every** per-CPU request to the single L2 SAW because the L2 node
carries `qcom,L2-spm-is-apcs-master` (`msm8974pro-pm.dtsi:126` → `spm_devices.c:476-478`;
routing `spm_devices.c:53-74`). L2 SAW node, `msm8974pro-pm.dtsi:102-127`:

```
reg = <0xf9012000 0x1000>;   qcom,core-id = <0xffff>;   qcom,saw2-cfg = <0x14>;
qcom,saw2-pmic-data0 = <0x02030080>;   qcom,saw2-pmic-data1 = <0x00030000>;
qcom,vctl-timeout-us = <50>;  qcom,vctl-port = <0x0>;
qcom,phase-port = <0x1>;      qcom,pfm-port = <0x2>;
```
Per-core SAWs (`0xf9089000/f9099000/f90a9000/f90b9000`, `msm8974pro-pm.dtsi:14-100`) carry **no**
`vctl/phase/pfm` ports, so they cannot do voltage control at all (`spm_devices.c:455-479`).

**The gang voltage carries NO margin.** `get_vmax()` is a plain maximum:

```
krait-regulator.c:898-916
static int get_vmax(struct pmic_gang_vreg *pvreg) {
        int vmax = 0; …
        list_for_each_entry(kvreg, &pvreg->krait_power_vregs, link) {
                if (!kvreg->reg_en) continue;
                v = kvreg->uV;
                if (vmax < v) vmax = v;
        }
        return vmax; }
```
i.e. `VDD_APC = max(PVS µV of the four cores)`, exactly, with no additive headroom.
Ramp-up settling is `DIV_ROUND_UP(Δ, SLEW_RATE=2395)` µs (`:836-841`); on a rise the rail is set
first then the LDO/BHS modes, on a fall the modes first (`krait_voltage_increase/decrease`,
`:834-895`). Boot value is `CORE_VOLTAGE_BOOTUP = 900000` per core (`:66`, `:1339`).

### a.5.4 LDO vs BHS — the exact rule

```
krait-regulator.c:779-810   configure_ldo_or_hs_one()
    if (!kvreg->reg_en)   return 0;
    if (kvreg->force_bhs) return 0;
    if (kvreg->uV <= kvreg->ldo_threshold_uV
        && kvreg->uV - kvreg->ldo_delta_uV + kvreg->headroom_uV <= vmax)
                switch_to_using_ldo(kvreg);
    else    switch_to_using_bhs(kvreg);
```

With FP2's Pro values (`ldo_threshold = 850000`, `ldo_delta = 12500`, `headroom = 150000`):

> **A core uses LDO iff `core_µV ≤ 850 000` AND `gang_vmax ≥ core_µV + 137 500`. Otherwise BHS.**

LDO output voltage = `core_µV − 12 500`, quantised to 5000 µV with offset 465000
(`set_krait_ldo_uv()`, `:315-324`; `KRAIT_LDO_VOLTAGE_OFFSET/STEP`, `:69-71`).
A voltage change while already in LDO transits through BHS first (`:665-668`).

Consequences on FP2, using the 14-OPP voltages:

* **Voltage-eligible for LDO** (≤ 850 mV): OPPs 0-7, i.e. 300 → 1 190 400 kHz.
  1 267 200 kHz (860 mV) and above are BHS unconditionally.
* The second condition means LDO only engages when a *sibling core* holds the gang high:
  an 800 mV core needs `vmax ≥ 937 500`, which among the 14 OPPs only 1 958 400 kHz (980 mV) and
  2 265 600 kHz (1040 mV) provide. **So in the common case where all cores sit at similar rates,
  all four run on BHS**, and LDO is the exception (one core idling while another is at ≥1.96 GHz).
* `force_bhs` is set at probe (`:1349`) and around every hotplug transition
  (`krait_regulator_cpu_callback()`, `:1050-1100`: set on `CPU_UP_PREPARE`/`CPU_UP_CANCELED`/
  `CPU_DOWN_PREPARE`, cleared on `CPU_ONLINE`/`CPU_DOWN_FAILED`), so a core entering or leaving
  power collapse is always on BHS.

### a.5.5 Retention voltage — and the frequency-dependent idle gate

`kvreg_ldo_voltage_init()` (`:260-264`) programs, at probe, into `APC_LDO_VREF_SET`:
`VREF_RET = 675 000` µV and `VREF_LDO = 750 000` µV (the `qcom,retention-voltage` and
`qcom,ldo-default-voltage`).

`pmic_min_uV_for_retention = min over cores of (retention_uV + headroom_uV) = 675000 + 150000 =`
**825 000 µV** (`:1354-1357`, seeded `INT_MAX` at `:1582`). And:

```
krait-regulator.c:751-765   (inside set_pmic_gang_voltage)
    if (uV < pvreg->pmic_min_uV_for_retention) { … msm_pm_enable_retention(false); … }
    else                                        { … msm_pm_enable_retention(true);  … }
```

`msm_pm_enable_retention()` (`msm-pm.c:880-901`) globally enables/disables the **retention idle
state for all cores**, checked ahead of the per-CPU table in `msm_cpu_pm_check_mode()`
(`msm-pm.c:779-781`) and re-checked with a bail-out in `msm_pm_retention()` (`:420-421`).

Applied to FP2's OPP voltages, retention idle is:

| gang voltage | CPU rates that produce it | retention idle |
|---|---|---|
| 800 000 µV | 300 000 – 729 600 kHz | **disabled** |
| 810 000 µV | 883 200 kHz | **disabled** |
| 820 000 µV | 960 000 kHz | **disabled** |
| ≥ 830 000 µV | 1 036 800 kHz and above | **enabled** |

This is the only place in the vendor stack where an idle state is gated on frequency.

### a.5.6 Phases and PFM/PWM

`pmic_gang_set_phases()` (`:462-…`): phase count from `coeff_total` (a load model, `get_coeff1/2`,
`:345-379`), capped by the number of online CPUs (`:518-520`). Below
`qcom,pfm-threshold = <76>` the FTS is put in **PFM** via `msm_spm_enable_fts_lpm()`
(`:481-492`), above it forced to **PWM** (`:497-505`). On Pro (`qcom,use-phase-switching`) the phase
count goes out through the L2 SAW `phase-port` (`msm_spm_apcs_set_phase()`,
`spm_devices.c:314-334`), not a direct PMIC write. `COEFF2_UV_THRESHOLD = 850000` (`:344`).

### a.5.7 MX / vdd-mem

**There is no MX (vdd-mem) vote anywhere in the FP2 CPU-DVFS path.** Grep over the whole include
chain finds no `vdd-mem`, `vddmx` or `qcom,lpm-resources`; the only `vdd-mem` in the tree is in
`msm8974pro-pma8084.dtsi:173`, a different board that FP2 does not include, and its
`lpm_resources` driver is not even present in this kernel. CPU scaling touches exactly three
external rails: VDD_APC (via SAW), CX corner (`pm8841_s2_corner_ao`) and 1.8 V
(`pm8941_l12_ao`).

Both corner votes are **active-set only** (`qcom,set = <1>`): `pm8841_s2_corner_ao`
`msm8974-regulator.dtsi:102-109`, `pm8941_l12_ao` `:305-312`. They do not raise the RPM sleep set,
so the corner falls away in system sleep. (`pm8841_s2_corner`, the both-sets variant with
`qcom,consumer-supplies = "vdd_dig"`, is `qcom,set = <3>` at `:93-101` and is used by other
subsystems, not by Krait DVFS.) Pro also permits AUTO mode on VDD_CX:
`&pm8841_s2_corner { qcom,init-smps-mode = <0>; }` (`msm8974pro-pm8941.dtsi:64-66`).

## a.6 CPR — **not used on the APC rail. PVS values are meant to be used as-is.**

* `# CONFIG_MSM_CPR is not set` (`fairphone_defconfig:530`);
  `# CONFIG_MSM_CPR_REGULATOR is not set` (`:542`);
  `# CONFIG_MSM_SPM_REGULATOR is not set` (`:461`).
* There is **no `qcom,cpr-regulator` (or `qcom,cpr`) node** anywhere in FP2's DT chain. The only
  `cpr` hits in the 8974 DT are bus-slave labels (`msm8974-bus.dtsi:148,158,1015,1024`) and
  `qcom,rpm-rbcpr-stats@fc000000` (`msm8974pro-pm.dtsi:377-378`), which is a read-only window onto
  statistics kept by **RPM firmware** for the rails RPM owns (CX/MX) — it neither reads nor writes
  the APC rail.
* `cpr-regulator.c` and `msm_cpr.c` exist in the tree but are not built and not instantiated.

**Trim direction / magnitude: none. Zero.** The open-loop `qcom,speed1-pvs12-bin-v1` voltages are
the voltages that reach the rail, unmodified (see §a.2 for the two inert mutators). Any margin a
mainline port adds on top is a deviation from Android, not a reproduction of it.

## a.7 Thermal

### a.7.1 In-kernel `msm_thermal` (KTM) — the only CPU-frequency mitigation on FP2

Node, `VK/arch/arm/boot/dts/msm8974.dtsi:2356-2401`:

```
qcom,sensor-id = <5>;                        qcom,poll-ms = <250>;
qcom,limit-temp = <60>;                      qcom,temp-hysteresis = <10>;
qcom,therm-reset-temp = <115>;               qcom,freq-step = <2>;
qcom,freq-control-mask = <0xf>;
qcom,core-limit-temp = <80>;                 qcom,core-temp-hysteresis = <10>;
qcom,core-control-mask = <0xe>;
qcom,hotplug-temp = <110>;                   qcom,hotplug-temp-hysteresis = <20>;
qcom,cpu-sensors = "tsens_tz_sensor5".."tsens_tz_sensor8";
qcom,freq-mitigation-temp = <110>;           qcom,freq-mitigation-temp-hysteresis = <20>;
qcom,freq-mitigation-value = <960000>;       qcom,freq-mitigation-control-mask = <0x01>;
qcom,vdd-restriction-temp = <5>;             qcom,vdd-restriction-temp-hysteresis = <10>;
vdd-dig-supply = <&pm8841_s2_floor_corner>;  vdd-gfx-supply = <&pm8841_s4_floor_corner>;
  qcom,vdd-dig-rstr  { qcom,levels = <5 7 7>; qcom,min-level = <1>; };
  qcom,vdd-gfx-rstr  { qcom,levels = <5 7 7>; qcom,min-level = <1>; };
  qcom,vdd-apps-rstr { qcom,levels = <1881600 1958400 2265600>; qcom,freq-req; };
```
Pro removes only the PMIC-software-mode properties (`msm8974pro.dtsi:38-42`), so PSM is off.

**Two distinct regimes — this matters:**

1. **Boot-up regime only** (`polling_enabled`): step-wise ladder. At ≥ 60 °C step down
   `freq_step = 2` table indices, release below 50 °C
   (`do_freq_control()`, `msm_thermal.c:1296-1336`). Floor is
   `limit_idx_low = 0` (`:824`, never reassigned) = **300 000 kHz**. From index 13 the ladder is
   `2265600 → 1728000 → 1497600 → 1190400 → 960000 → 729600 → 422400 → 300000`.
   Mask `0xf` = all four CPUs.
2. **After `late_initcall`** this path is switched off: `interrupt_mode_init()`
   (`:1942-1956`) sets `polling_enabled = 0` and calls `disable_msm_thermal()` (`:1922-1940`,
   resetting `limited_max_freq = UINT_MAX`), and `check_temp()` stops rescheduling (`:1367-1370`).
   The binding documents the split (`VK/Documentation/devicetree/bindings/arm/msm/msm_thermal.txt:49-54`).
   From then on the only frequency mitigation is the **single-step emergency cap**:
   `freq_mitigation_notify()` / `do_freq_mitigation()` (`:1587-1629`, `:1543-1585`) →
   **at 110 °C cap CPU0 only (mask 0x01) to 960 000 kHz; release at 90 °C.**
3. **Hotplug**, both regimes: `do_core_control()` (`:1006-1054`) offlines one masked core per
   250 ms poll at ≥ 80 °C (mask `0xe` → CPU3, CPU2, CPU1), onlining below 70 °C;
   `hotplug_notify()` (`:1431-1458`) offlines masked cores at 110 °C, releases at 90 °C.
   Note Android *disables* `core_control` while it switches governor and re-enables it
   (`VD10 init.qcom.power.rc:57`, `:93`).
4. **Hard reset trip**: `qcom,therm-reset-temp = <115>` arms a secure watchdog bite on **any** of
   the 11 tsens sensors:
   ```
   msm_thermal.c:940-942
       pr_err("TSENS:%d reached temperature:%ld. System reset\n", …);
       scm_call_atomic1(SCM_SVC_BOOT, THERM_SECURE_BITE_CMD, 0);
   ```
   armed at `:3144-3146` with hi 115 °C / lo 105 °C. **This is a silent, panic-less reset path
   that exists in the vendor kernel and is worth knowing about when chasing silent resets** — though
   it is vendor-only code, absent from mainline.
5. **Cold-temperature min-freq floor**: see §a.3.1 — 1 881 600 kHz on all CPUs at ≤ 5 °C.

**So: the lowest frequency Android's thermal mitigation will drive the CPU *ceiling* down to is
300 000 kHz (boot-up regime) or 960 000 kHz on CPU0 (steady-state emergency at 110 °C).
It never raises the floor for heat, only for cold.**

### a.7.2 TSENS

```
VK/arch/arm/boot/dts/msm8974.dtsi:2218-2228
tsens: tsens@fc4a8000 {
        compatible = "qcom,msm-tsens";
        reg = <0xfc4a8000 0x2000>, <0xfc4bc000 0x1000>;
        interrupts = <0 184 0>;
        qcom,sensors = <11>;
        qcom,slope = <3200 …×11>;
        qcom,calib-mode = "fuse_map1";
};
```
No board override. **No trip points and no cooling-device wiring exist in DT**: the driver
registers 11 zones `tsens_tz_sensor0..10` with two runtime-programmable trips
(`TSENS_TRIP_WARM/COOL`) and `tsens_thermal_zone_ops` has no `.bind`/`.unbind`
(`VK/drivers/thermal/msm8974-tsens.c:244-248`, `:613-621`, `:1583-1625`). There is no
`cpufreq_cooling` device. Consumers are `msm_thermal` and userspace only.
PMIC zone: `pm8941_tz` from `qcom,qpnp-temp-alarm` (`msm-pm8941.dtsi:36-43`).

### a.7.3 Userspace `thermal-engine` — does no CPU-frequency mitigation at all

`VD10/configs/thermal-engine-8974.conf` (identical on `int/10/fp2` and
`rel/10/fp2/23.02.0-rel`; `<scratch>/fp10/int_10_fp2__thermal-engine-8974.conf`), all 38 lines:

```
 1  sampling         5000
 3  [CPU0_MONITOR]        (and [CPU1_MONITOR] :12, [CPU2_MONITOR] :21, [CPU3_MONITOR] :30)
 4  algo_type        monitor
 5  sensor           cpu0
 6  sampling         65
 7  thresholds       115000
 8  thresholds_clr   110000
 9  actions          shutdown
10  action_info      0
```

**No `action_info` names any kHz value; the only action is `shutdown` at 115.0 °C.** This is the
generic CAF 8974 file, adopted by Fairphone from Android 9 onward, and byte-identical in
LineageOS's FP2 tree. Daemon started at `VD6 init.target.rc:154`.

(For completeness: the older Android-5.1 FPOS config used four `algo_type ss` closed-loop
controllers, `device cpu`, `set_point 70000`, `set_point_clr 55000`, `time_constant 16`, plus a
`[PMIC]` monitor on `pm8941_tz` doing battery-current mitigation at 70/75 °C. It also names no kHz
value; an `ss` controller walks `scaling_available_frequencies`, so its floor is also 300 000 kHz.)

**Conclusion for a 90 °C board:** stock Android does nothing about 90 °C in userspace, and in the
steady-state kernel regime nothing until 110 °C. The 60 °C step-down ladder people remember is
boot-only. Any 90 °C mitigation in the fork is a deliberate improvement, not Android parity.

## a.8 Idle / power collapse

### a.8.1 Levels defined

`VK/arch/arm/boot/dts/msm8974pro-pm.dtsi:129-196`:

```
lpm_levels: qcom,lpm-levels {
        compatible = "qcom,lpm-levels";
        qcom,allow-synced-levels;                      /* PRO-ONLY (:131) */
        qcom,default-l2-state = "l2_cache_retention";   /* (:132) */
```

CPU levels, `qcom,cpu-modes` (`:136-171`):

| idx | `qcom,mode` | latency-us | ss-power | energy-overhead | time-overhead | broadcast timer | lines |
|---|---|---|---|---|---|---|---|
| 0 | `wfi` | 1 | 715 | 17700 | 2 | – | :138-144 |
| 1 | `retention` | 35 | 542 | 34920 | 40 | – | :146-152 |
| 2 | `standalone_pc` | 300 | 476 | 225300 | 350 | – | :154-160 |
| 3 | `pc` | 500 | 400 | 280000 | 500 | **yes** (:168) | :162-169 |

System levels, `qcom,system-modes` (`:172-195`):

| idx | `qcom,l2` | latency-us | ss-power | energy-overhead | time-overhead | min cpu mode | sync | rpm sleep set | lines |
|---|---|---|---|---|---|---|---|---|---|
| 0 | `l2_cache_gdhs` | 500 | 163 | 577736 | 1000 | `standalone_pc` | yes | no | :175-183 |
| 1 | `l2_cache_pc` | 30000 | 83 | 2274420 | 6605 | `pc` | yes | **yes** (:193) | :185-194 |

Properties from older schemes (`qcom,vdd-mem-upper-bound`, `qcom,vdd-dig-upper-bound`,
`qcom,irqs-detectable`, `qcom,gpio-detectable`, `qcom,pm-modes`, per-CPU level nodes) **do not
exist** in this BSP; their driver (`lpm_resources.c`) is not present. No `status`/`qcom,disable` on
any SPM or LPM node.

Related nodes: `qcom,pm-8x60@fe805664` (`:330-350`) with `qcom,pc-mode = "tz_l2_int"` (`:336`),
`qcom,cpus-as-clocks` (`:337`, → clk-API ramp rather than acpuclk, `msm-pm.c:1159-1197`),
`qcom,lpm-levels = <&lpm_levels>` (`:338`); `qcom,cpu-sleep-status@f9088008` (`:352-357`);
`qcom,pm-boot` `qcom,mode = "tz"` (`:198-201`).

### a.8.2 What is enabled in normal operation — **SPC on all four cores, yes**

Kernel defaults enable only WFI (`VK/arch/arm/mach-msm/pm-data.c:16-135`; PC/SPC/retention all
`idle_enabled = 0`; `suspend_enabled = 1` only for PC on cpu1-3). **Android userspace turns the
rest on at every boot** — `VD10 root/init.qcom.power.rc`, `on enable-low-power`
(triggered from `on boot`, `:130-131`):

```
34  write /sys/module/lpm_levels/enable_low_power/l2 4         ← L2 POWER_COLLAPSE
35-38  msm_pm/modes/cpu{0,1,2,3}/power_collapse/suspend_enabled            1
39-42  msm_pm/modes/cpu{0,1,2,3}/power_collapse/idle_enabled               1
43-46  msm_pm/modes/cpu{0,1,2,3}/standalone_power_collapse/suspend_enabled 1
47-50  msm_pm/modes/cpu{0,1,2,3}/standalone_power_collapse/idle_enabled    1
51-54  msm_pm/modes/cpu{0,1,2,3}/retention/idle_enabled                    1
```

**Answer to the question as asked: yes — in normal operation stock Android has
standalone power collapse enabled for idle AND suspend on all four cores, together with full
power collapse (idle + suspend) on all four cores and retention (idle) on all four cores; the L2
low-power cap is set to POWER_COLLAPSE (4).** In offline-charging mode the L2 cap drops to GDHS
(2) and only cpu0 gets idle PC (`:107-112`).

Level selection at runtime: `lpm_cpu_power_select()` walks levels and filters each with
`msm_cpu_pm_check_mode()` (`lpm_levels.c:539-542`, `msm-pm.c:773-787`), which also honours the
retention gate of §a.5.5. `qcom,allow-synced-levels` lets all four cores be in PC concurrently
(`lpm_levels.c:535-537`) and makes `msm_cpu_pm_probe()` take remote spinlock `"S:7"` to serialise
the PC handoff with TZ (`msm-pm.c:1233-1248`, used in `msm_pm_collapse()` `:507-510`).
SPC vs PC differ only in `notify_rpm` and in clock ramping — PC calls
`ramp_down_last_cpu`/`ramp_up_first_cpu` (`msm-pm.c:613-663`, invoked `:692-698`), SPC does not
(`:593-611`).

### a.8.3 SPM sequences (exact bytes)

All nodes `compatible = "qcom,spm-v2"`, `qcom,saw2-ver-reg = <0xfd0>`,
`qcom,saw2-avs-{ctl,hysteresis,limit,dly} = <0>`, `qcom,saw2-spm-dly = <0x3C102800>`,
`qcom,saw2-spm-ctl = <0x1>`.

**Per-core SAWs** — `qcom,spm@f9089000` (`:14-34`), `@f9099000` (`:36-56`), `@f90a9000` (`:58-78`),
`@f90b9000` (`:80-100`); `qcom,saw2-cfg = <0x01>`; sequences byte-identical on all four
(core 0 lines cited; others at `:50-55`, `:72-77`, `:94-99`):

```
qcom,saw2-spm-cmd-wfi = [03 0b 0f];                                              (:28)
qcom,saw2-spm-cmd-ret = [42 1b 00 d8 5B 03 d8 5b 0b 00 42 1b 0f];                (:29)
qcom,saw2-spm-cmd-spc = [00 20 80 10 E8 5B 03 3B E8 5B 82 10 0B 30 06 26 30 0F]; (:30-31)
qcom,saw2-spm-cmd-pc  = [00 20 80 10 E8 5B 03 3B E8 5B 82 10 0B 30 06 26 30 0F]; (:32-33)
```

**On 8974Pro `spc` and `pc` are byte-identical.** On non-Pro v2 they differ in one byte
(`msm8974-v2-pm.dtsi:30-33`: `spc` has `E8 5B 03 3B`, `pc` has `E8 5B 07 3B`). The functional
SPC/PC difference on Pro therefore comes entirely from the driver (`notify_rpm`, RPM/MPM sleep-set
programming, clock ramp), not from the SPM microcode.

**L2 / APCS SAW** — `qcom,spm@f9012000` (`:102-127`), `qcom,saw2-cfg = <0x14>`:

```
qcom,saw2-spm-cmd-ret  = [1f 00 03 00 0f];                                (:122)
qcom,saw2-spm-cmd-gdhs = [00 32 42 03 44 50 02 32 50 0f];                 (:123)
qcom,saw2-spm-cmd-pc   = [00 10 32 b0 11 42 07 01 b0 12 44 50 02 32 50 0f];(:124-125)
qcom,L2-spm-is-apcs-master;                                                (:126)
```
No `qcom,saw2-spm-cmd-pc-no-rpm` → `l2_cache_pc_no_rpm` is unavailable.

Sequence ↔ mode mapping (`spm_devices.c:390-402`): CPU `wfi`→CLOCK_GATING,
`ret`→POWER_RETENTION, `spc`→POWER_COLLAPSE with `notify_rpm=0`, `pc`→POWER_COLLAPSE with
`notify_rpm=1`; L2 `ret`/`gdhs`/`pc`→RETENTION/GDHS/POWER_COLLAPSE.
Derived sequence-RAM offsets: CPU SAW `wfi`@0, `ret`@3, `spc`@16, `pc`@34; L2 SAW `ret`@0,
`gdhs`@5, `pc`@15.

Hazard worth recording: `msm_spm_dev_set_low_power_mode()` leaves `start_addr = 0` when no
`(mode, notify_rpm)` pair matches (`spm_devices.c:134-158`) — an unmatched request silently runs
the sequence at offset 0. Only reachable via `MSM_SPM_L2_MODE_PC_NO_RPM`, which Pro never requests.

L2 resting state is `l2_cache_retention` (`:132` → `lpm_levels.c:1080-1097`, `:428-429`).
L2 flush flag ↔ TZ: PC → `MSM_SCM_L2_OFF`, GDHS → `MSM_SCM_L2_GDHS`, RETENTION/DISABLED →
`MSM_SCM_L2_ON` (`lpm_levels.c:204-244`), consumed by
`scm_call_atomic1(SCM_SVC_BOOT, SCM_CMD_TERMINATE_PC, flag)` (`msm-pm.c:486-532`) with only the
last core in PC passing the real flag (`:493-494`).

## a.9 APC power-gate / MDD programming — exact values and exact timing

Register map, `VK/arch/arm/mach-msm/krait-regulator.c:80-95`
(ACS base = `0xf9088000 + 0x10000·n`, MDD base = `0xf908a800 + 0x10000·n`,
APCS-GCC base = `0xf9011000`):

| symbol | offset | absolute (cpu*n*) |
|---|---|---|
| `APC_SECURE` | `0x00` | ACS+0x00 |
| `CPU_PWR_CTL` | `0x04` | ACS+0x04 |
| `APC_PWR_STATUS` | `0x08` | ACS+0x08 |
| `APC_PWR_GATE_CTL` | `0x14` | ACS+0x14 |
| `APC_LDO_VREF_SET` | `0x18` | ACS+0x18 |
| `APC_PWR_GATE_MODE` | `0x1C` | ACS+0x1C |
| `APC_PWR_GATE_DLY` | `0x20` | ACS+0x20 |
| `PWR_GATE_CONFIG` | `0x44` | `0xf9011044` (GCC) |
| `VERSION` | `0xFD0` | `0xf9011FD0` (GCC) |
| `MDD_CONFIG_CTL` | `0x00` | MDD+0x00 |
| `MDD_MODE` | `0x10` | MDD+0x10 |

Field layout used below (`:107-147`): `BHS_CNT` = bits 31:24 (default **64**),
`LDO_PWR_DWN` = 21:16, `CLK_SRC_SEL` = 15 (default 0), `LDO_BYP` = 13:8,
`BHS_SEG_EN` = 6:1 (default **0x3F**), `BHS_EN` = 0.
`APC_LDO_VREF_SET`: `VREF_RET` = 14:8, `VREF_LDO` = 6:0, step 5000 µV, offset 465000 µV.
`APC_PWR_GATE_MODE`: `PWR_GATE_SWITCH_MODE` = 6:4, values `PC=0, LDO=1, BHS=2, DT=3, RET=4`.

### Step 1 — `krait_pdn_probe()`, once, before any child regulator exists

`krait-regulator.c:1540-1605`. Order: ioremap APCS-GCC → `krait_pdn_phase_scaling_init()` →
gang state (`pmic_vmax_uV = 350000`, `retention_enabled = true`,
`pmic_min_uV_for_retention = INT_MAX`) → **`glb_init()`** → `of_platform_populate()` (children
probe) → debugfs → `register_syscore_ops(&boot_cpu_mdd_ops)`.

```
krait-regulator.c:1187-1198  glb_init(apcs_gcc_base)
    version = readl_relaxed(apcs_gcc_base + VERSION);          /* 0xf9011FD0 */
    if (version > KPSS_VERSION_2P0 /* 0x20000000 */)
            writel_relaxed(0x0308736E, apcs_gcc_base + PWR_GATE_CONFIG);
    else
            writel_relaxed(0x0008736E, apcs_gcc_base + PWR_GATE_CONFIG);
```

> **`PWR_GATE_CONFIG` (0xf9011044) = `0x0308736E`** if KPSS VERSION > `0x20000000`,
> else `0x0008736E`. Comment: *"configure bi-modal switch"*.

### Step 2 — per-core `krait_power_probe()`; for **cpu0 only**, `kvreg_hw_init()`

`:1300-1380`. Sets `uV = CORE_VOLTAGE_BOOTUP = 900000`, `mode = HS_MODE`, `force_bhs = true`;
folds `retention_uV + headroom_uV` into the gang's `pmic_min_uV_for_retention` (`:1354-1357`);
`online_at_probe()` (`:1284-1296`, reads `CPU_PWR_CTL` bit 7, clears `force_bhs` if already
online); `kvreg_ldo_voltage_init()` (`:260-264`) writing `VREF_RET = 675000`,
`VREF_LDO = 750000`; then:

```
krait-regulator.c:1363-1365
    if (kvreg->cpu_num == 0)
            kvreg_hw_init(kvreg);
```

```
krait-regulator.c:1157-1173  kvreg_hw_init()
    /* setup the bandgap that configures the reference to the LDO */
    writel_relaxed(0x00000190, kvreg->mdd_base + MDD_CONFIG_CTL);
    /* Enable MDD */
    writel_relaxed(0x00000002, kvreg->mdd_base + MDD_MODE);
    mb();
    if (version > KPSS_VERSION_2P0) {
            /* Configure hardware sequencer delays. */
            writel_relaxed(0x30430600, kvreg->reg_base + APC_PWR_GATE_DLY);
            /* Enable the hardware sequencer in BHS mode. */
            writel_relaxed(0x00000021, kvreg->reg_base + APC_PWR_GATE_MODE);
    }
```

> **`MDD_CONFIG_CTL` = `0x00000190`**
> **`MDD_MODE` = `0x00000002`** (then a 5 µs `MDD_SETTLING_DELAY_US` wait when written via
> `__krait_power_mdd_enable()`, `:325-341`)
> **`APC_PWR_GATE_DLY` = `0x30430600`** (only if VERSION > 0x20000000)
> **`APC_PWR_GATE_MODE` = `0x00000021`** (only if VERSION > 0x20000000)
>   = bit0 set (hardware sequencer enabled) + `PWR_GATE_SWITCH_MODE = 2` (BHS) in bits 6:4.

### Step 3 — secondary cores, at SMP bring-up, **before the core leaves reset**

`secondary_cpu_hs_init(base_ptr, cpu)`, `krait-regulator.c:1663-1740`, called from platform SMP:

```
reg_val = BHS_CNT_DEFAULT<<24 | LDO_PWR_DWN_MASK | CLK_SRC_DEFAULT<<15 | BHS_EN_MASK;
writel(reg_val, base + APC_PWR_GATE_CTL);   /* = 0x403F0001 */   mb(); udelay(1);
reg_val |= BHS_SEG_EN_DEFAULT<<1;
writel(reg_val, base + APC_PWR_GATE_CTL);   /* = 0x403F007F */   mb(); udelay(1);
reg_val |= LDO_BYP_MASK;
writel(reg_val, base + APC_PWR_GATE_CTL);   /* = 0x403F3F7F */
… then kvreg_hw_init(kvreg) if that core's regulator has already probed (:1703),
  otherwise the same MDD_CONFIG_CTL/MDD_MODE/DLY/MODE writes inline (:1709-1724) …
if (!the_gang || !the_gang->manage_phases)
        writel(0x10003, l2_saw_base + 0x1c);   /* max phases */   mb(); udelay(50);
```

> **`APC_PWR_GATE_CTL` written in three stages: `0x403F0001` → `0x403F007F` → `0x403F3F7F`**,
> 1 µs between the first two; i.e. BHS_CNT=64, LDO powered down, BHS enabled, all 6 BHS segments
> enabled, LDO bypass on. Plus **L2 SAW + 0x1C = `0x10003`** (max phases) if the gang driver has
> not taken over phase management yet, then 50 µs.

`lk2nd` performs the **same** `APC_PWR_GATE_CTL` staging and the same `0x10003` phase write for
secondary cores (`LK cpu_boot_kpssv2()`, `<scratch>/lk2nd-krait.c:81-130`) — but **not**
`PWR_GATE_CONFIG`, `APC_PWR_GATE_DLY`, `APC_PWR_GATE_MODE`, `MDD_CONFIG_CTL` or `MDD_MODE`.
That is exactly consistent with the fork measuring those five as zero.

### Step 4 — runtime LDO/BHS switching

With VERSION > 0x20000000 the driver only rewrites `PWR_GATE_SWITCH_MODE`
(BHS=2 at `:602-608`, LDO=1 at `:671-679`) and lets the hardware sequencer do the rest, waiting
`BHS_SETTLING_DELAY_US`/`LDO_SETTLING_DELAY_US` = 1 µs. On VERSION ≤ 0x20000000 it performs the
manual `BHS_EN` → `BHS_SEG_EN` → `LDO_BYP` → `LDO_PWR_DWN` dance (`:610-650`) and the reverse
(`:684-703`).

### Step 5 — suspend/resume

`register_syscore_ops(&boot_cpu_mdd_ops)` (`:1438-1441`, `:1604`): `MDD_MODE = 0` on suspend,
`MDD_MODE = 0x2` on resume, for **cpu0 only** (`boot_cpu_mdd_off/on`, `:1423-1436`).

### **UNKNOWN**

Whether FP2's KPSS `VERSION` register (`0xf9011FD0`) reads greater than `0x20000000` — i.e. whether
the `APC_PWR_GATE_DLY = 0x30430600` / `APC_PWR_GATE_MODE = 0x00000021` writes and the
`PWR_GATE_CONFIG = 0x0308736E` (rather than `0x0008736E`) variant apply — could **not** be
established from source. No file in `VK`, `VD10`, or the lk2nd sources records the value, and it is
read from hardware at runtime. Circumstantial support for `> 0x20000000` (the hardware-sequencer
path): 8974Pro reduces `qcom,ldo-delta-voltage` from 50000 to 12500, and `LDO_DELTA_MIN` is 10000
(`:154`), which only makes sense with the fast hardware switch. **This must be settled with one
32-bit read of `0xf9011FD0` before implementing §c.6.** The owner's existing
`<scratch>/apc-full.py` reads the ACS/MDD registers but not `VERSION`; adding that one read is a
two-line change.

## a.10 One-page summary of the target behaviour

1. 14 CPU OPPs: 300 000 … 2 265 600 kHz, exactly the list in §a.3.
2. Voltages: `qcom,speed1-pvs12-bin-v1`, used verbatim, **no margin, no CPR trim**.
3. `VDD_APC = max(PVS µV of the four cores)`, programmed as `DIV_ROUND_UP(µV, 5000)` through the
   L2 SAW to a PM8841 FTS.
4. Four independent cpufreq policies; L2 follows the fastest online core per the CPU→L2 column.
5. CX corner is **rate-dependent**: SVS_SOC ≤ 883.2 MHz, NORMAL 960–1 190.4 MHz,
   SUPER_TURBO ≥ 1 267.2 MHz. Active-set only. No MX vote.
6. HFPLLs have their own CX vote (SVS_SOC/NORMAL/SUPER_TURBO by PLL rate) plus a fixed 1.8 V analog
   supply.
7. Per-core LDO ∥ BHS: LDO iff `core_µV ≤ 850 000` and `gang_vmax ≥ core_µV + 137 500`; in
   practice mostly BHS.
8. Retention idle is globally disabled whenever the gang sits below 825 000 µV, i.e. at
   ≤ 960 MHz.
9. APC power-gate + MDD are programmed with the exact constants of §a.9.
10. Governor `interactive`, `scaling_min_freq = 300000` on all four cores, `scaling_max_freq`
    untouched; input boost to 1 497 600 kHz for 40 ms.
11. Idle: WFI + retention + SPC + PC all enabled on all four cores; L2 cap = POWER_COLLAPSE.
12. Thermal: nothing before 110 °C in steady state (then a 960 MHz cap on CPU0 and hotplug of
    CPU1-3), plus core hotplug from 80 °C, plus a 115 °C secure-bite reset.

---

# (b) GAP ANALYSIS vs the fork (`6.18/rc`)

Fork state read at `e8333aa715322dcd3a0be52216f382909fe3a9b9` ("Merge 6.18/topic/hfpll-lock-poll
(regmap fast_io) into 6.18/rc"). `6.18/staging` has an identical tree. All DTS/`spm.c`/cpufreq blobs
are byte-identical to `8c0f9a3e8511`, so line numbers are stable.

Files: `arch/arm/boot/dts/qcom/qcom-msm8974.dtsi` (SoC base, CPU nodes, `cpu_opp_table`, SAW/ACC/HFPLL,
`rpmpd` + corner table, idle-states, `kraitcc`), `qcom-msm8974pro.dtsi` (19 lines, **no DVFS
content**), `qcom-msm8974pro-fairphone-fp2.dts` (569 lines: thermal trips, the six disabled OPPs,
PMIC regulators, the SAW rail margin), `qcom-msm8974pro-fairphone-fp2-headless.dts`
(`#include`s the above; **DVFS behaviour identical on both DTBs**).

Legend: **[H]** best-supported candidate for the resets · **[M]** wrong power/perf or latent hazard ·
**[L]** divergence only · **[—]** no gap.

---

## b.0 What the fork's own experiments already exclude — read this before the gap list

Three results in the fork's own commit messages constrain the search far more than any source
reading can, and they invalidate parts of the reasoning that produced the current tree.

1. **The resets are not DVFS *transitions*.** `aaef04366525`: *"pinned 729.6 MHz, idle 61 min, no
   reset; pinned 1036.8 MHz, 4-core load reset after 5 min at 77 C; full range, 4-core load reset
   within seconds to minutes; full range, idle reset after 17-25 min"*, and decisively
   *"scaling_min_freq equalled scaling_max_freq and the cpufreq transition counter never moved…
   simply running four cores at that operating point is enough"*.
   → The failure reproduces at a **static** operating point. This directly undercuts the rationale
   of `dedf12dc6cd7` ("hold the corner at super-turbo … the two remaining deaths point at the corner
   *transition* window"): there is no transition to blame.

2. **It is not a rail brownout.** `aaef04366525`: *"Every reset reports PS_HOLD in the PMIC's
   POFF_REASON with no UVLO, no PMIC watchdog and no thermal bit."*
   → PS_HOLD deassert with **no UVLO** means the PMIC was *told* to drop the rails, not that they
   sagged. On this SoC that is the signature of an **APSS/secure watchdog bite or a TZ-initiated
   reset following a hang**, not of undervoltage. (It is also the owner's own hypothesis #2 in
   `fp26.18restartanalysis.md`.)

3. **It is not undervoltage.** `ed04a7722738` probed +200 mV and `150261dfd128` reverted it; the
   merge subject records the outcome: *"revert the 200 mV probe: it shortened MTBF and added heat."*
   → More voltage made it **worse**. Combined with (2), the mechanism is consistent with a
   power/heat-accelerated **hang**, and inconsistent with a voltage deficit.

**Also closed, so it is not re-opened:** the PM8941 over-temperature path is *not* the PS_HOLD
source. The fork's PMIC thermal zone uses gen1 threshold set 0 — trips 105 000 / 125 000 /
145 000 mC (`FORK:arch/arm/boot/dts/qcom/pm8941.dtsi:14-31`, matching
`drivers/thermal/qcom/qcom-spmi-temp-alarm.c:67-72`) — which is **identical** to the vendor's
`qcom,threshold-set = <0>` (`VK:arch/arm/boot/dts/msm-pm8941.dtsi:36-43`). A reset at 77 °C is
30 °C below stage 1. No gap, no suspect.

**Consequence for this gap analysis:** the highest-value gaps are those that change the *static*
configuration of the CPU/L2/PLL/CX complex under sustained multi-core load — i.e. **G5 (L2 rate)**
and **G7 (HFPLL supply votes)**. The margin (G4) and the corner pin (G2) are compensating hacks that
the evidence says are not working, and should be *removed* rather than tuned.

---

## G5 — L2 left at whatever the bootloader set, while Android scales it to the CPU rate **[H] — top candidate**

*Android:* the L2 tracks the **fastest online core** across 11 rates, 300 000 → 1 728 000 kHz
(`VK:cpufreq.c:80-95`; column 2 of §a.3). At the fork's failing test point, 1 036 800 kHz, Android
runs the L2 at **1 036 800 kHz**; at the fork's top OPP it runs it at **1 728 000 kHz**.

*Fork:* there is **no L2 OPP table and no CPU→L2 coupling at all.** `kraitcc` exposes the L2 mux as
index 4 (`drivers/clk/qcom/krait-cc.c:17-25`) but **no DT node references `<&kraitcc 4>`** — the CPU
nodes consume indices 0-3 only (`qcom-msm8974.dtsi:49, 67, 85, 103`), and the cache node carries no
clocks at all:

```
FORK:arch/arm/boot/dts/qcom/qcom-msm8974.dtsi:113-118
        l2: l2-cache {
                compatible = "cache";
                cache-level = <2>;
                cache-unified;
                qcom,saw = <&saw_l2>;
        };
```

The only code that ever sets the L2 rate is unmodified mainline `krait-cc.c` probe, which
force-reinits the mux and then **restores whatever rate the bootloader left**, floored at 384 MHz:

```
drivers/clk/qcom/krait-cc.c:408-417
        cur_rate = clk_get_rate(clks[l2_mux]);
        aux_rate = 384000000;
        if (cur_rate < aux_rate) { pr_info("L2 @ Undefined rate. Forcing new rate.\n");
                                   cur_rate = aux_rate; }
        clk_set_rate(clks[l2_mux], aux_rate);
        clk_set_rate(clks[l2_mux], 2);
        clk_set_rate(clks[l2_mux], cur_rate);
        pr_info("L2 @ %lu KHz\n", clk_get_rate(clks[l2_mux]) / 1000);
```

Then a refcount is held and the rate is never touched again for the whole uptime.

*Difference:* four Krait cores at 1 036 800 kHz — every instruction fetch, every miss, every
coherency operation — sharing an L2 running somewhere between **384 000 and 729 600 kHz**, i.e. 37 %
to 70 % of the rate Android uses for that CPU frequency, and 22 % to 42 % of the rate Android uses
at the top OPP.

*Why this is the top candidate:* it is the one gap whose signature matches **all three** constraints
of §b.0 simultaneously. It is a purely **static** misconfiguration (no transition involved — matches
(1)). It produces a **hang**, not a voltage collapse — a saturated L2 under four-core load is a
stall/livelock mechanism, and a hang is exactly what "PS_HOLD with no UVLO" reports (matches (2)).
And it is **aggravated by more power**: raising the rail raised the cores' effective load and heat
without giving the L2 any more throughput, which is why +200 mV shortened MTBF (matches (3)). It
also explains the frequency dependence directly: at a pinned 729.6 MHz the CPU:L2 ratio is close to
Android's (Android would use 576 000 kHz) and the board survived 61 minutes; at 1 036 800 kHz the
ratio is badly wrong and it died in 5 minutes.

Secondly, the L2 rate is what Android derives the **CX requirement** from (`qcom,l2-fmax`, §a.4.2).
A stale L2 rate therefore also breaks the corner logic, coupling this gap to G2 and G7.

*Cost to test:* **a two-line DT change, no driver code.** `of_clk_add_hw_provider()` calls
`of_clk_set_defaults(np, true)` (`drivers/clk/clk.c:5027, 5069` → `clk-conf.c:170-182`), so
`assigned-clocks = <&kraitcc 4>; assigned-clock-rates = <1728000000>;` on the `kraitcc` provider
node pins the L2 at the vendor's rate for the top OPP. See c.1.

## G7 — HFPLL nodes have no supply or power-domain properties **[H]**

*Android:* all five HFPLLs (four core PLLs **and** the L2 PLL) vote as a function of their own output
rate on CX **and** on a 1.8 V analog rail:
`hfpll-dig-supply = <&pm8841_s2_corner_ao>`, `hfpll-analog-supply = <&pm8941_l12_ao>`
(`VK:msm8974.dtsi:1036-1037`), thresholds `{≤998.4 MHz → SVS_SOC, ≤1996.8 MHz → NORMAL,
≤2900 MHz → SUPER_TURBO}` (`VK:clock-krait-8974.c:38-47`).

*Fork:* the five HFPLL nodes (`hfpll_l2` `qcom-msm8974.dtsi:1998-2005`; `hfpll0..3` `:2114-2148`)
carry **exactly** `compatible`, `reg`, `clocks = <&xo_board>`, `clock-names = "xo"`,
`#clock-cells = <0>`, `clock-output-names` — and nothing else. Absent: `vdd-dig-supply`,
`vdd-analog-supply`, `hfpll-dig-supply`, `power-domains`, `required-opps`, `operating-points-v2`.
`git grep -i 'regulator|supply|vdd'` over `drivers/clk/qcom/hfpll.c`, `clk-hfpll.c`, `clk-hfpll.h`
returns **zero hits** — the driver has no supply concept.

*Difference:* nothing guarantees CX or the 1.8 V analog rail is at the level a PLL needs *before* it
is asked to lock at that rate. The **1.8 V analog rail is never voted at all.** The CX half is
currently covered *by accident* through the blanket `super_turbo` pin on the CPU OPPs (G2) — which
means **G2 and G7 are coupled: removing the pin without adding PLL votes would be a regression.**

*Why [H]:* the fork has already found and fixed two real bugs in exactly this PLL's lock path —
`955f1d90b2fc` (the poll waited for *unlocked*, so it returned on the first read and enabled
`PLL_OUTCTRL` on an unlocked PLL) and `33a69825af14` (a 100 ms sleeping poll with IRQs off, now an
atomic 200 µs wait). Those fixes made a lock failure *visible*; a PLL asked to lock on an
under-voted analog rail is a plausible reason it was failing. A core running off an unlocked or
marginal PLL hangs rather than browning out — again matching §b.0 (2).

## G4 — Invented `qcom,vdd-margin-microvolt = <100000>` **[M], and the evidence says remove it**

*Android:* **zero margin.** `get_vmax()` is a plain maximum with no additive term
(`VK:krait-regulator.c:898-916`); `set_pmic_gang_voltage()` converts µV to a setpoint with no offset
(`:768`); the PVS table is not trimmed (§a.2) and there is no CPR (§a.6). The 150 mV
`qcom,headroom-voltage` is **not** a rail margin — it appears only inside the LDO-eligibility
predicate (`:794-797`).

*Fork:*
```
FORK:arch/arm/boot/dts/qcom/qcom-msm8974pro-fairphone-fp2.dts:566-568
        &saw_l2 { qcom,vdd-margin-microvolt = <100000>; };
```
```
FORK:drivers/soc/qcom/spm.c:360-366
static int spm_set_voltage_sel(struct regulator_dev *rdev, unsigned int selector)
{       …
        /* Board-level safety margin on top of the fused PVS table */
        selector = min_t(unsigned int, selector + drv->margin_sel,
                         drv->reg_data->range->max_sel);
```
with `margin_sel = DIV_ROUND_UP(100000, 5000) = 20` steps (`spm.c:640-643`), i.e. **+100 mV on every
setpoint**. `qcom,vdd-margin-microvolt` is fork-local and undocumented (no `Documentation/` hit).
The DT comment justifying it is also stale: it names *"speed3-pvs5-v1 on the reference unit"*, which
`ed04a7722738` corrected to speed1-pvs12-v1 before `150261dfd128` reverted that commit and restored
the wrong text.

*Good news, verified:* **the fork's underlying voltage table is already correct.** The 31 OPP nodes
carry per-bin `opp-microvolt-speed1-pvs12-v1` triplets that match §a.2 exactly (729.6 MHz →
800000; 1036.8 → 830000; 2265.6 → 1040000), selected via `dev_pm_opp_set_config()`'s `prop_name`
(`drivers/cpufreq/qcom-cpufreq-nvmem.c:518-533`). The generic `opp-microvolt` fallbacks are the
higher, non-binned values and are not used on this die. So the **only** voltage deviation from
Android is the +100 mV.

*Risk:* **[M]** — and the direction of the fix is now clear rather than uncertain. The fork's own
200 mV experiment showed *more* margin makes things **worse**, so this is not compensating for a
voltage deficit; it is adding heat and masking the real fault. Two secondary hazards: at the top OPP
it commands 1 140 000 µV, above the `regulator-max-microvolt = <1120000>` the vendor sets on the
per-core Krait regulators (§a.5.1) — not clipped, because the SAW's own limit is 1 275 000, but
outside the range the vendor considered valid for a Krait core; and it lifts the rail across the
825 000 µV retention gate (§a.5.5) at OPPs where Android deliberately keeps retention **off**, which
will silently change idle-state selection if G9/c.7 ever enables retention.

## G6 — APC power-gate / MDD partly unprogrammed **[M]** (downgraded — mainline covers more than expected)

*Android:* the five register groups of §a.9.

*Fork — what IS programmed:* unmodified mainline `arch/arm/mach-qcom/platsmp.c:214-312`
(`kpssv2_release_secondary()`, run once per **secondary** CPU at cold boot) performs the *same*
three-stage sequence as the vendor, with the same constants:

```
platsmp.c:256-258   reg_val = (64 << BHS_CNT_SHIFT) | (0x3f << LDO_PWR_DWN_SHIFT) | BHS_EN;
                    writel_relaxed(reg_val, reg + APC_PWR_GATE_CTL);
platsmp.c:264       reg_val |= 0x3f << BHS_SEG_SHIFT;      /* Turn on BHS segments */
platsmp.c:271       reg_val |= 0x3f << LDO_BYP_SHIFT;      /* bypass so BHS supplies power */
platsmp.c:275       writel_relaxed(0x10003, l2_saw_base + APCS_SAW2_2_VCTL);   /* max phases */
```

i.e. `APC_PWR_GATE_CTL = 0x403F3F7F` and the `0x10003` max-phase write — **matching §a.9 Step 3
exactly**, which also means every core is deliberately held in **BHS with its LDO powered down and
bypassed**, and phase count is left at maximum (the safe direction).

*Fork — what is NOT programmed:* `PWR_GATE_CONFIG`, `APC_PWR_GATE_DLY`, `APC_PWR_GATE_MODE`,
`MDD_CONFIG_CTL`, `MDD_MODE`. Exhaustive grep: `PWR_GATE_MODE`, `MDD_CONFIG_CTL`, `MDD_MODE`,
`msm-mdd` → **0 hits anywhere in the tree**; `krait-regulator`/`qcom,krait-regulator`/`LDO_HDR` →
**0 hits**; `krait_set/get_l2_indirect_reg` exists (`arch/arm/common/krait-l2-accessors.c`) but its
sole consumer is `drivers/clk/qcom/clk-krait.c` — **clock mux/divider programming only, never
voltage/LDO/BHS**. Consistent with the owner's measurement of all zeros.

*Difference, assessed honestly:*
* **MDD is latent, not active.** Its documented purpose is *"the bandgap that configures the
  reference to the LDO"* and *"required when the core switches to LDO mode"*
  (`VK:krait-regulator.c:1159-1161`, `:1655-1657`). Because `platsmp.c` forces BHS with the LDO
  powered down and bypassed, the LDO is never used, so a disabled MDD has nothing to corrupt — **as
  long as nothing else puts a core into LDO or retention.**
* **`APC_PWR_GATE_MODE = 0` is a live concern.** Zero means `PWR_GATE_SWITCH_MODE = 0 = PC` **and**
  the hardware sequencer disabled (bit 0 clear). The vendor deliberately writes `0x21`
  (sequencer enabled, mode = BHS). The fork *does* use core power collapse
  (`cpu_spc`, §G9), so a core is repeatedly power-gated and restored through hardware whose switch
  mode says PC and whose sequencer delays are all zero. Whether that is harmful depends on whether
  the sequencer is even consulted with bit 0 clear — **which cannot be determined from source and
  needs the KPSS `VERSION` read of §a.9.**
* **cpu0 asymmetry.** `kpssv2_release_secondary()` runs only for secondaries. cpu0's
  `APC_PWR_GATE_CTL` is whatever the boot chain left. The vendor covers cpu0 explicitly via
  `if (kvreg->cpu_num == 0) kvreg_hw_init(kvreg)` (`VK:krait-regulator.c:1363-1365`) and a
  suspend/resume syscore hook for cpu0's MDD (`:1438-1441`). **The fork has never verified that
  cpu0's power-gate state matches cpu1-3's** — a one-line addition to the existing `apc-full.py`
  answers it, and an asymmetric cpu0 would be an excellent explanation for a load-dependent hang.

## G2 — CX pinned at the top corner on every OPP, and on the sleep set too **[M]**

*Android:* rate-dependent — SVS_SOC ≤ 883.2 MHz, NORMAL 960–1 190.4 MHz, SUPER_TURBO ≥ 1 267.2 MHz
(§a.4.4) — from two independent votes (L2 rate via `qcom,l2-fmax`, PLL rate via `hfpll_fmax`), both
on `pm8841_s2_corner_ao`, i.e. **active set only** (§a.5.7).

*Fork:* all 31 CPU OPPs carry `required-opps = <&rpmpd_opp_super_turbo>` (`grep -c` = 32: 31 uses +
1 label), i.e. corner 6 = vendor SUPER_TURBO — the maximum, since
`.max_state = MAX_CORNER_RPMPD_STATE = 6` (`drivers/pmdomain/qcom/rpmpd.c:729-733`, `:43`).
Plumbed by `power-domains = <&rpmpd MSM8974_VDDCX>` + `power-domain-names = "cx"` on each CPU
(`qcom-msm8974.dtsi:53-54, 71-72, 89-90, 107-108`) and
`.pd_names = { "cx" }, .pd_flags = PD_FLAG_DEV_LINK_ON | PD_FLAG_REQUIRED_OPP`
(`a474697820e4`, `qcom-cpufreq-nvmem.c:406-419` + `:535-547`).

*Two differences:*
1. The corner never moves — it is placed once at cpufreq init and held, including at idle.
2. **The domain is `MSM8974_VDDCX`, not `MSM8974_VDDCX_AO`.** `MSM8974_VDDCX` maps to
   `cx_s2b_corner`, which is *not* `active_only`, so `to_active_sleep()` sets
   `sleep = active` (`rpmpd.c:983-992`) and the corner is pinned in the RPM **sleep** set as well.
   Android's Krait votes are active-set only and always fall away in sleep.

*Risk:* **[M]** — safe direction for stability, so unlikely to be a reset cause, but a large idle and
sleep power/heat penalty on a board that reaches 90 °C, and it masks the real CX requirement. Given
§b.0 (1), the transition-race rationale in `dedf12dc6cd7` is not supported by the later data, so this
pin has no remaining evidential basis. **But it cannot be removed before G7 is fixed** (see c.4).

## G3 — Six low OPPs disabled to make 729.6 MHz the floor, on a refuted premise **[M]**

*Android:* the floor is **300 000 kHz**, written explicitly four times at every boot
(`VD10 init.qcom.power.rc:81-84`) and again in the older BSP
(`QC init.qcom.post_boot.sh:319-322`, outside the soc_id switch and so unconditional for all 8974).
`729600` never appears as a minimum anywhere in the BSP.

*Fork:* `qcom-msm8974pro-fairphone-fp2.dts:152-174` sets `status = "disabled"` on the six OPPs from
300 000 000 to 652 800 000 Hz, with the in-tree justification at `:144-151`: *"Raise the CPU
frequency floor to 729.6 MHz… Android BSP never throttled below 960 MHz… Disabling the OPPs below
the floor raises both the idle minimum and the deepest thermal throttle step."*

*Difference:* **the premise is false.** 960 000 appears in the BSP only as a thermal *ceiling* for
CPU0 at 110 °C (`VK:msm8974.dtsi:2374`) and as an `ondemand` tuning value in a post_boot branch FP2
never executes. The comment inverts a ceiling into a floor.

*Risk:* **[M]** — worse idle power and thermals than stock, and it removes the low-rate states from
the experiment. Note the low OPPs are exactly where the gang sits below the 825 mV retention gate
(§a.5.5) and where the CPU:L2 ratio would be closest to Android's; suppressing them destroys
evidence. Not itself a reset cause — §b.0 (1) shows a pinned 729.6 MHz idle survived 61 minutes
while a pinned 1 036 800 kHz under load did not, i.e. the danger is **above** the floor, not below it.

## G8 — 22 usable OPPs where Android offers 14 **[M]**

*Android:* exactly the 14 rates of §a.3.

*Fork:* **31 OPP nodes** (`qcom-msm8974.dtsi:135-1705`). Six are `status = "disabled"` (G3). Three
(2 342 400 000, 2 419 200 000, 2 457 600 000 Hz at `:1619, :1648, :1677`) carry
`opp-supported-hw = <0x8>` = speed bin 3 only, and the reference die is speed bin 1
(`versions = 1 << 1 = 0x2`, `qcom-cpufreq-nvmem.c:252`), so `0x8 & 0x2 == 0` and they are
hardware-gated off. **Net: 22 usable OPPs, 729 600 000 → 2 265 600 000 Hz.**

*Difference:* **11 rates Android never offers a governor are live** — 806.4, 1 113.6, 1 344, 1 420.8,
1 651.2, 1 804.8, 1 881.6, 2 035.2, 2 112, 2 150.4, 2 188.8 MHz. All 11 exist in the vendor *voltage*
plan (`VK:msm8974pro.dtsi:883-912`) but are absent from `qcom,cpufreq-table`, so the vendor never
validated them as cpufreq targets. Each carries its own HFPLL rate and, under Android, would carry
its own L2 rate and CX corner — none of which the fork derives. (The remaining 11 of the fork's 22
are Android OPPs; Android's other 3 — 300, 422.4, 652.8 MHz — are below the fork's floor, G3.)

*Risk:* **[M]** — each extra OPP is an unvalidated static configuration, and §b.0 (1) says static
configurations are what kill this board. Cheap to remove; shrinks the search space.

## G1 — All four CPUs share one SAW regulator instead of four per-core Krait regulators **[L] for voltage**

*(Downgraded after verification. The voltage behaviour turns out to be equivalent.)*

*Android:* four `qcom,krait-regulator` devices, `cpu0-supply … cpu3-supply`
(`VK:msm8974.dtsi:1031-1034`); the gang is set to `max()` over the four cores' requests
(`get_vmax()`, `VK:krait-regulator.c:898-916`).

*Fork:* `cpu-supply = <&saw_l2_vreg>` on all four CPUs (`qcom-msm8974.dtsi:52, 70, 88, 106`), one
regulator inside the L2 SAW (`:1988-1996`, `regulator-min/max-microvolt = <350000>/<1275000>`).
No `krait*_vreg` nodes exist. The per-CPU SAW2s deliberately have **no** regulator children —
`efb36868f19c` removed them: *"the per-CPU SAW2 SPM blocks are not wired to the PMIC… Writing to
per-CPU SAW2 VCTL registers causes hard crashes."*

*Verified equivalence:* Linux's regulator core aggregates across consumers of a shared regulator,
taking the **maximum** of their `min_uV`:

```
FORK:drivers/regulator/core.c:458-487   regulator_check_consumers()
        list_for_each_entry(regulator, &rdev->consumer_list, list) { …
                if (*min_uV < voltage->min_uV) *min_uV = voltage->min_uV; }
```
called from `regulator_set_voltage_unlocked()` (`:4046`) and `regulator_sync_voltage()` (`:4544`).
Each CPU is a distinct consumer device, and every OPP's `opp-microvolt` is a `<V V 1275000>` triplet
(commit `39f97169c19b`, "Use voltage triplets in OPP table for shared regulator"), so the upper
bound never constrains the aggregate. **Result: the rail sits at the maximum of the four cores'
PVS voltages — the same value Android's `get_vmax()` produces.** A core at 2 265 600 kHz cannot be
undervolted by a sibling dropping to the floor.

Additionally, `platsmp.c:256-271` forces every core into BHS with the LDO powered down and bypassed
(G6), which is also Android's *dominant* mode on FP2 (§a.5.4 shows LDO only engages when a sibling
holds the gang ≥ 937 500 µV, i.e. only when another core is at ≥ 1 958 400 kHz).

*Residual gap:* the per-core layer Android has and the fork does not — LDO/BHS mode management, MDD,
per-core headroom, and phase management. That is **G6**, not a voltage-correctness problem.

*Risk:* **[L]** for rail voltage. The topology is a faithful-enough reproduction; the missing pieces
are the register-level ones in G6.

## G9 — Idle: one SPC state where Android has four levels **[M]**

*Android:* WFI + retention + standalone PC + full PC, all enabled for idle **and** (bar retention)
for suspend, on **all four cores**, with the L2 low-power cap at POWER_COLLAPSE
(`VD10 init.qcom.power.rc:34-54`); retention additionally gated on gang voltage ≥ 825 000 µV
(§a.5.5); SPM byte sequences per §a.8.3.

*Fork:* WFI (driver-provided) plus exactly one DT idle state:
```
FORK:arch/arm/boot/dts/qcom/qcom-msm8974.dtsi:120-128
        idle-states {
                cpu_spc: cpu-spc {
                        compatible = "qcom,idle-state-spc", "arm,idle-state";
                        entry-latency-us = <150>;
                        exit-latency-us  = <200>;
                        min-residency-us = <2000>;
                };
        };
```
referenced by all four CPUs (`:56, 74, 92, 110`). `cpuidle-qcom-spm.c:32-58` implements it as
`spm_set_low_power_mode(PM_SLEEP_MODE_SPC)` → `cpu_suspend(0, qcom_pm_collapse)` with
`qcom_scm_cpu_power_down(QCOM_SCM_CPU_PWR_DOWN_L2_ON)`, returning the SAW to Standby on exit.
`spm.c:234-245` / `:255-268` hold the compiled-in sequences (CPU: `spm_cfg 0x1`,
`spm_dly 0x3C102800`, 21 bytes, SPC at index 3; L2: `spm_cfg 0x14`, 5 bytes). No `qcom,spm-*`
properties exist in DT. **No retention state and no full (RPM-notifying) PC.**

*Differences:* the fork is **more conservative** than Android — SPC with L2 kept on matches Android's
`standalone_pc` semantics (no clock ramp, `notify_rpm = 0`), and omitting retention avoids the
825 mV gate entirely. So this is not a stability regression relative to Android.

*Risk:* **[M]**, entirely because of the coupling to G6: SPC power-gates the core and brings it back
through hardware whose `APC_PWR_GATE_MODE` is 0 and whose sequencer delays are 0. **Idle and G6 must
be treated as one problem.** Also worth noting from the owner's own dossier that mainline's menu-governor
rework (`779b1a1cb13a`, partly reverted by `db86f55bf81a`) changes how often SPC is entered — an
untested hypothesis (#3 there) that a `cpuidle.off=1` soak would settle in one run.

## G10 — CPR **[—]**

Neither side uses CPR on the APC rail (§a.6; fork has none). Recorded so it is not re-opened: there
is no closed-loop trim to reproduce, and therefore **no justification anywhere for adjusting the PVS
numbers in either direction.**

## G11 — Governor and boot policy **[L]**

*Android:* `interactive` with the tunables of §a.3.1, `scaling_min_freq = 300000`, `scaling_max_freq`
untouched, `cpu_boost` input boost to 1 497 600 kHz for 40 ms, `timer_rate 30000` (30 ms).

*Fork:* whatever the Debian/Ubuntu userspace sets (`schedutil`).

*Risk:* **[L]**. `interactive` is gone upstream and `schedutil` is the right modern equivalent. Two
things are worth copying because they change *which* OPPs are visited and how often: the 300 000 kHz
floor (G3) and a rate limit comparable to 30 ms. A `schedutil` re-evaluating every ~1 ms exercises
transitions an order of magnitude harder than Android ever did — worth neutralising as a *diagnostic*
even though §b.0 (1) says transitions are not the failure.

## G12 — Thermal **[L]**

*Android:* nothing until 110 °C in steady state (then CPU0 → 960 MHz, CPU1-3 offlined), core hotplug
from 80 °C, a 115 °C secure-bite reset, a 115 °C userspace `shutdown`. **No mitigation at 90 °C.**

*Fork:* mainline `tsens` + DT `thermal-zones` + `cpufreq_cooling` (`#cooling-cells = <2>` on each CPU,
`qcom-msm8974.dtsi:55`), with FP2 trip overrides from `afd63e174909` (passive 70 → 90 °C, hysteresis
3 → 10, critical → 105 °C).

*Risk:* **[L]** for resets, but **[M]** as an interpretation hazard, in both directions: because
Android tolerated 90 °C without acting, "it reaches 90 °C" is not evidence of a fork-specific fault;
and equally "Android must have throttled" is not a licence to invent a 960 MHz floor (G3). Keep
mainline's design.

## Summary table

| # | Gap | Android | Fork | Risk |
|---|---|---|---|---|
| **G5** | **L2 rate** | 11 rates, follows fastest core, 300 M–1 728 M | **left at bootloader rate (≥384 M), never scaled; no DT consumer of `<&kraitcc 4>`** | **H** |
| **G7** | **HFPLL supplies** | CX corner + 1.8 V per PLL rate, all 5 PLLs | **none; driver has no supply concept** | **H** |
| G4 | Rail margin | **0 µV** | invented +100 000 µV (PVS table itself is correct) | M |
| G6 | APC power-gate / MDD | 5 register groups, exact constants | `APC_PWR_GATE_CTL` + phases done by `platsmp.c`; `PWR_GATE_CONFIG`/`DLY`/`MODE`/`MDD_*` never written; cpu0 unverified | M |
| G2 | CX corner | rate-dependent 4/5/7, active set only | pinned corner 6 on all 31 OPPs, **and on the sleep set** | M |
| G3 | Frequency floor | 300 000 kHz | 729 600 kHz, 6 OPPs disabled on a **refuted** premise | M |
| G8 | OPP count | 14 | 22 usable (31 nodes − 6 disabled − 3 hw-gated) | M |
| G9 | Idle states | WFI+ret+SPC+PC ×4, L2 PC cap | WFI + `cpu_spc` (L2 on) only | M |
| G1 | CPU rail attachment | 4× per-core `krait*_vreg`, gang = `max()` | 1 shared `saw_l2_vreg`; **core aggregation verified equivalent** | L |
| G10 | CPR | none | none | — |
| G11 | Governor / floor | `interactive`, min 300 MHz, 30 ms rate | distro `schedutil` | L |
| G12 | Thermal | nothing < 110 °C steady state | mainline zones + `cpufreq_cooling` | L |
| — | PMIC over-temp | gen1 set 0: 105/125/145 °C | **identical** (`pm8941.dtsi:14-31`) | — (closed) |

---

# (c) ORDERED CONVERGENCE PLAN

Ground rules, from `CLAUDE.md` §1.1/§1.2 and the owner's own method (one hypothesis at a time;
enumerate every delta before a soak; never lose evidence):

* **One step per soak.** Each step changes one thing and has its own pass/fail test.
* **No step introduces a number that does not appear in `VK`.** Where a vendor behaviour cannot be
  expressed in mainline, the step says so and names the code that would be needed.
* Soak gate: ≥ 60 min, DVFS unpinned over the full intended range, fsync'd device-side log,
  `journalctl --list-boots` checked by per-boot tail (not timestamps), PON/POFF reason recorded
  (`051929315a9b` already provides this).
* **Ordering is by information-per-soak, not by tidiness.** §b.0 says the failure is a static-config
  hang, so the steps that change static config come first; the two compensating hacks (G4 margin,
  G2 corner pin) are removed last, because they are the current safety net.
* Steps c.0-c.4 are **DT/config only**. c.5 onwards need new driver code, flagged explicitly.

---

### c.0 — Baseline instrumentation, no functional change — **prerequisite**

1. **Read KPSS `VERSION` at `0xf9011FD0`.** This is the only UNKNOWN in §a.9 and it decides whether
   c.6 writes `APC_PWR_GATE_DLY`/`APC_PWR_GATE_MODE` and which `PWR_GATE_CONFIG` value applies.
   Two lines added to the existing `<scratch>/apc-full.py`.
2. **Read the actual L2 rate.** `dmesg | grep 'L2 @'` (`krait-cc.c:417` prints it) plus
   `/sys/kernel/debug/clk/.../clk_rate` for the L2 mux. G5's entire magnitude depends on whether
   lk2nd left it at 384, 729.6 or some other rate — measure it, do not assume.
3. **Dump `APC_PWR_GATE_CTL` for all four cores including cpu0** and compare. `platsmp.c` only
   covers secondaries; an asymmetric cpu0 is a live G6 sub-hypothesis.
4. Record the "before" column at several pinned OPPs: SAW voltage selector, effective RPM CX corner,
   each HFPLL's `L`/`MODE`/`STATUS`, per-core `APC_PWR_GATE_*` and `MDD_*`. Existing tooling covers
   most of this (`apc-state.py`, `hfpll-probe.py`, `smps-scan.sh`, `saw-mv.py`, `percore.sh`).
5. Record `schedutil`'s `rate_limit_us`.

*Testable:* read-only; success = a complete "before" table. *No changes.*

---

### c.1 — **Pin the L2 at the vendor rate for the top OPP** (G5) — highest information per soak

Pure DT, no driver code. `of_clk_add_hw_provider()` → `of_clk_set_defaults(np, true)`
(`drivers/clk/clk.c:5027, 5069` → `clk-conf.c:170-182`) honours `assigned-clock-rates` on a clock
**provider** node, so:

```
&kraitcc {
        assigned-clocks      = <&kraitcc 4>;        /* l2_mux, krait-cc.c:17-25 */
        assigned-clock-rates = <1728000000>;        /* VK:msm8974.dtsi:1683 — vendor L2 rate
                                                      for the 2265.6 MHz CPU OPP */
};
```

*Why first:* it is the only change that matches all three constraints of §b.0, it is two lines, and
it directly targets the exact configuration that failed (four cores at a static 1 036 800 kHz).

*Test, in this order:*
 1. Confirm `L2 @ 1728000 KHz` in dmesg and via clk debugfs.
 2. **Reproduce the known-failing case exactly:** pin all four cores at 1 036 800 kHz, four-core
    load, and compare against the recorded 5-minute MTBF at 77 °C. This is a direct A/B against an
    existing measurement — the cleanest experiment available.
 3. If (2) survives, a 60-min full-range soak with load.

*Value either way:* if it survives, G5 is confirmed and c.4 becomes the real fix. If it still dies
in ~5 minutes, G5 is eliminated as the primary cause and attention moves to c.2 — which is itself
worth one soak.

*No invented values* — 1 728 000 000 Hz is `VK:msm8974.dtsi:1683`.

---

### c.2 — Give the HFPLLs their supply votes (G7)

Two routes; prefer (1).

1. **Idiomatic and upstreamable, needs a small driver change.** Add
   `power-domains = <&rpmpd MSM8974_VDDCX_AO>` and an `operating-points-v2` table to each of
   `hfpll0..3` and `hfpll_l2`, with `required-opps` per `VK:clock-krait-8974.c:38-47`:
   ≤ 998 400 000 Hz → `rpmpd_opp_svs_soc`; ≤ 1 996 800 000 Hz → `rpmpd_opp_nom`;
   ≤ 2 900 000 000 Hz → `rpmpd_opp_super_turbo`.
   **New code required:** `drivers/clk/qcom/clk-hfpll.c` currently has no supply/OPP concept at all
   (verified: zero `regulator|supply|vdd` hits). It needs an OPP/genpd handle and a
   `dev_pm_opp_set_rate()`-or-`dev_pm_genpd_set_performance_state()` call in `clk_hfpll_set_rate()`,
   ordered **vote-then-raise** on the way up and **lower-then-unvote** on the way down. This is a
   genuine mainline gap and a reasonable upstream submission.
2. **No new code, less faithful.** Fold the union of the PLL and L2 requirements into the CPU OPPs'
   `required-opps` — i.e. exactly the "CX corner" column of §a.4.4, which is already the maximum of
   both voters. This ties the vote to the CPU rather than the PLL, but reproduces the same corner at
   every OPP. Acceptable as an interim and as the c.4 mechanism.

Also add the **1.8 V analog rail**, which is currently unvoted entirely: the mainline equivalent of
`pm8941_l12_ao` (`VK:msm8974-regulator.dtsi:305-312`). If it is not modelled in the fork's DT,
model it rather than skipping it.

Use `MSM8974_VDDCX_AO`, not `MSM8974_VDDCX`: the vendor's Krait votes are active-set only (§a.5.7),
and `cx_s2b_corner_ao` is the `active_only` peer (`rpmpd.c:240-247`).

*Test:* pin each OPP, read the effective RPM CX corner, compare against §a.4.4. Then re-run the
HFPLL lock-violation counter that found `955f1d90b2fc` — if missing votes were behind the lock
failures, it should improve. Then a 60-min soak.

*No invented values.*

---

### c.3 — Restore Android's frequency floor and trim to Android's 14 OPPs (G3, G8)

Two sub-steps, each its own soak — but both are pure DT and cheap.

**c.3a — re-enable the six low OPPs.** Delete the `status = "disabled"` lines at
`qcom-msm8974pro-fairphone-fp2.dts:152-174` and fix the comment at `:144-151`, which is factually
wrong (§G3). Set `scaling_min_freq = 300000` to match `VD10 init.qcom.power.rc:81-84`.
*Test:* confirm the board idles at 300 MHz; 60-min idle soak. If it resets **only** with low OPPs
enabled, that localises the fault to low-rate states — a result, not a failure.

**c.3b — trim to the 14 rates of §a.3.** Disable everything else, including the three
`opp-supported-hw = <0x8>` entries (already hw-gated on this die, but remove them from the DT
reasoning). Cross-check every surviving OPP's `opp-microvolt-speed1-pvs12-v1` against §a.2 — they
already match, so any mismatch found here is a plumbing bug to fix, not to paper over.
*Test:* `scaling_available_frequencies` equals the 14 exactly; 60-min soak.

*No invented values* — every rate is from `VK:msm8974.dtsi:1669-1683`, every voltage from
`VK:msm8974pro.dtsi:883-912`.

---

### c.4 — Make the L2 rate and the CX corner rate-dependent, **in one step**

These cannot be separated: Android's CX corner is a function of the L2 rate **and** each PLL's rate
(§a.4), so moving one without the other either under-votes or wastes power.

1. **L2 OPP table** with the 11 vendor L2 rates (300 000, 422 400, 499 200, 576 000, 960 000,
   1 036 800, 1 267 200, 1 497 600, 1 574 400, 1 651 200, 1 728 000 kHz), each with `required-opps`
   per `qcom,l2-fmax` (§a.4.2): ≤ 576 000 → `rpmpd_opp_svs_soc`; ≤ 1 036 800 → `rpmpd_opp_nom`;
   ≤ 1 728 000 → `rpmpd_opp_super_turbo`.
2. **CPU → L2 coupling** per column 2 of §a.3, with the L2 following the **fastest online core**.
   ⚠️ **NEW DRIVER CODE REQUIRED.** Mainline has no equivalent of `VK:cpufreq.c:80-95`
   (`update_l2_bw()`). Options: a `cpufreq` transition notifier that takes the max index over online
   CPUs and calls `clk_set_rate()` on `<&kraitcc 4>`; or a small `devfreq`/interconnect-style driver;
   or extend `qcom-cpufreq-nvmem.c` with an optional "companion clock" table. The notifier is the
   smallest and most obviously correct; the OPP-table-per-CPU-with-`required-opps`-on-an-L2-genpd
   route is the more upstreamable one. **Until this exists, keep c.1's static 1 728 000 kHz pin** —
   pinning high is conservative and must be recorded as a deliberate deviation.
3. **CPU OPP `required-opps`** ← the per-OPP CX corner of §a.4.4. Only valid once c.2 gives the PLLs
   their own vote (route 1) or as the union (route 2).

*Test:* per OPP, read the L2 rate and the effective CX corner and compare against §a.4.4;
throughput check (the L2 rate is user-visible in memory bandwidth); 60-min soak with load.

*No invented values.*

---

### c.5 — Remove the invented margin (G4)

Only after c.1-c.4 are in and verified, because the margin is the current safety net.

Delete `qcom,vdd-margin-microvolt = <100000>` from
`qcom-msm8974pro-fairphone-fp2.dts:566-568` **and** the `margin_sel` code from
`drivers/soc/qcom/spm.c` (`:360-366`, `:640-643`) and its struct field, taking the rail to the bare
`speed1-pvs12-v1` voltages (§a.2, §a.6). Keep the three genuine `spm.c` fixes
(`609e2c283b38` VCTL PORT mask, `2bc1999098fb` selector encoding, `8ec3dd7bb397` PMIC_STS poll) —
those are real bugs, cross-checked against the vendor driver, and unrelated to the margin.

*Test:* confirm the commanded selector equals `DIV_ROUND_UP(PVS µV, 5000)` at several pinned OPPs
(e.g. 2 265 600 kHz → 1 040 000 µV → selector 208); 60-min soak with load.

*If this regresses* while c.1-c.4 are all verified, that is a genuinely new result: it would mean
this die needs more than its fuse specifies. That is a **measurement** to make — a per-OPP
undervolt/overvolt sweep with the existing `undervolt-test.py` / `descend-validate.py`, producing a
per-OPP delta with evidence — not a uniform number to guess. Note the fork already has evidence
against a uniform margin: +200 mV was *worse* than +100 mV.

*This step removes invented values rather than adding any.*

---

### c.6 — **NEW DRIVER CODE**: per-core Krait regulator + APC/MDD init (G6, residual G1)

**Cannot be done in mainline without new code.** There is no `krait-regulator` equivalent:
`drivers/regulator/` on `6.18/rc` has no krait/saw regulator (only `labibb`, `pm8008`, `refgen`,
`rpmh`, `rpm`, `smd`, `spmi`, `usb_vbus`), and the only CPU-rail regulator is the thin SAW one in
`drivers/soc/qcom/spm.c` with no notion of per-core LDO/BHS, gang aggregation, headroom, phases or
MDD.

**What the code must be** — a new `drivers/regulator/qcom-krait-regulator.c`:

* Parent for `qcom,krait-pdn` (`0xf9011000` APCS-GCC + `0xfc4b80b0` phase-scaling efuse), holding
  gang state; on probe, read `VERSION` at `+0xFD0` and write `PWR_GATE_CONFIG` at `+0x44`
  (`0x0308736E` if `> 0x20000000`, else `0x0008736E`).
* Four children `qcom,krait-regulator`, `reg = <acs>, <mdd>` per §a.5.1, each a `regulator_dev` for
  CPU*n*'s `cpu-supply`; `set_voltage` programs the gang to `max()` over the four with the
  `DIV_ROUND_UP(µV, 5000)` encoding and the `[350000, 1355000]` clamp, reusing the existing SAW
  write path.
* Per core: `MDD_CONFIG_CTL = 0x00000190`, `MDD_MODE = 0x00000002` (+5 µs); if
  `VERSION > 0x20000000`, `APC_PWR_GATE_DLY = 0x30430600` and `APC_PWR_GATE_MODE = 0x00000021`;
  `APC_LDO_VREF_SET` ← `VREF_RET = 675 000`, `VREF_LDO = 750 000` µV.
* cpu0 covered explicitly (the vendor's `if (cpu_num == 0) kvreg_hw_init()`), plus the
  suspend/resume syscore hook toggling cpu0's `MDD_MODE`.
* LDO/BHS predicate of §a.5.4 with the FP2 constants (`ldo_threshold 850000`, `ldo_delta 12500`,
  `headroom 150000`, `retention 675000`, `ldo_default 750000`, `min 500000`, `max 1120000`), the
  rise-then-switch / switch-then-fall ordering, `SLEW_RATE 2395` settling, `force_bhs` around
  hotplug.

**Reconcile with existing mainline, do not duplicate:** `arch/arm/mach-qcom/platsmp.c:256-275`
already writes the vendor's `APC_PWR_GATE_CTL` staging and the `0x10003` max-phase value for
secondaries (§G6). The new driver must not fight it.

**Gate:** do **not** write `APC_PWR_GATE_DLY`/`APC_PWR_GATE_MODE` until c.0 establishes
`VERSION > 0x20000000`. If it is not, the vendor path is the manual BHS dance and these two
registers must be left alone — writing them would be invented behaviour.

*Suggested commit split (bisectable, review-friendly):*
 1. binding + parent/child probe + per-core `regulator_dev` with gang `max()` aggregation, always
    BHS, no LDO — behaviour-neutral vs today, since the core already aggregates (G1);
 2. **APC power-gate + MDD init** — the part with actual expected effect, and the cleanest possible
    test: `apc-full.py` shows every register matching §a.9 on **all four** cores;
 3. LDO/BHS mode management;
 4. phase / PFM management — lowest value, highest risk; consider never doing it (see c.9).

*Test:* after (2), register readback on all four cores, then a 60-min soak, then a soak with SPC
idle active (this is the G6×G9 coupling).

*No invented values* — every constant is quoted in §a.9.

---

### c.7 — Idle states, coupled with c.6

Only after c.6 step 2 is verified by readback. Move towards Android's set — retention, and full
(RPM-notifying) PC, on all four cores, with the L2 low-power cap at power-collapse
(`VD10 init.qcom.power.rc:34-54`), using the vendor SPM byte sequences of §a.8.3 as the reference for
whatever mainline's `qcom,saw2`/`cpuidle-qcom-spm` programs.

Two vendor behaviours have **no mainline equivalent** and need new code if wanted:

* **The retention gate** (§a.5.5): retention idle disabled whenever the gang is below 825 000 µV — a
  callback from the regulator into the idle driver (`VK:msm-pm.c:880-901`). In mainline this is the
  c.6 driver disabling a `cpuidle` state (or applying a genpd/OPP constraint) when the gang drops.
  **Do not enable retention idle before this exists.** On FP2's table that gate covers every rate at
  or below 960 MHz, and it is the *only* frequency-dependent idle restriction the vendor has.
* `qcom,allow-synced-levels` plus the `"S:7"` remote spinlock serialising the PC handoff with TZ
  (`VK:msm-pm.c:1233-1248`). Verify whether mainline's SPM/PSCI path has an equivalent before
  enabling concurrent PC on all four cores.

Cheap adjacent experiment worth one soak, from the owner's own dossier hypothesis #3: boot with
`cpuidle.off=1`. If the resets stop, the fault is in the idle path and c.6/c.7 become the whole
story; if not, idle is eliminated. One run, no code.

*Test:* one state at a time — enable, confirm via `cpuidle` stats that it is actually entered,
60-min soak.

---

### c.8 — Governor policy parity (any time after c.3a)

`scaling_min_freq = 300000` (c.3a), and consider raising `schedutil`'s `rate_limit_us` toward the
30 000 µs of `interactive/timer_rate` (`VD10 init.qcom.power.rc:74`) while debugging, so the fork is
not exercising OPP transitions an order of magnitude harder than Android ever did.

Treat this as a **diagnostic**, not a fix. §b.0 (1) already says transitions are not the failure, so
if a long rate limit changes the MTBF, that contradicts the pinned-OPP evidence and is itself the most
interesting result available.

*No invented values.*

---

### c.9 — Explicitly out of scope

* **Thermal**: keep mainline's `thermal-zones` + `cpufreq_cooling` and the `afd63e174909` trips.
  Android's design is worse and partly relies on vendor-only TZ calls. Do **not** reproduce
  `qcom,freq-mitigation-value = <960000>` as a floor — it is a ceiling for CPU0 at 110 °C.
* **CPR**: nothing to do (§a.6, G10). No licence to adjust PVS numbers.
* **PMIC over-temperature**: already identical to the vendor (§b.0). Closed.
* **Phase / PFM management** (`qcom,pfm-threshold = <76>`, phase count vs online CPUs): the
  bootloader's `0x10003` max-phase state is already in effect and is the safe direction. Dynamic
  phase management is a power optimisation with real stability risk — defer indefinitely.
* **Reproducing `interactive`**: not possible or desirable upstream.

---

## Open questions to settle on-device (in priority order)

1. **What rate is the L2 actually running at?** (`dmesg | grep 'L2 @'`.) Sets the magnitude of G5,
   the top-ranked gap. — c.0.2
2. **Does pinning the L2 at 1 728 000 kHz survive the known-failing 1 036 800 kHz four-core test?**
   A direct A/B against an existing 5-minute MTBF measurement. — c.1
3. **KPSS `VERSION` at `0xf9011FD0`.** Gates c.6. — c.0.1
4. **Does cpu0's `APC_PWR_GATE_CTL` match cpu1-3's?** `platsmp.c` only covers secondaries. — c.0.3
5. **Which mainline regulator corresponds to `pm8941_l12_ao`** (1.8 V HFPLL analog), and is it
   modelled in the fork's DT at all? — c.2
6. **Does `cpuidle.off=1` change the MTBF?** One soak, no code; eliminates or confirms the whole
   idle/G6/G9 cluster. — c.7

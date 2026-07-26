# Audit of the fork-only SPM / DVFS code

Findings from a code audit of the MSM8974 CPU voltage and idle path, done after
a night of on-device probing failed to converge. The point of the audit was to
stop guessing from reset timing and read the code that has never been reviewed:
mainline v6.18 has no msm8974 CPU DVFS at all, and upstream's Krait SPM code is
used only by apq8064/ipq8064, which drive **per-CPU** SAWs — not an L2 "gang"
SAW. Everything below is cited to the tree; claims are split into what was read
directly and what remains inference.

## PROVEN

### P1 — the rail margin silently disappears on specific transitions

`spm_set_voltage_sel()` adds `margin_sel` to the selector and stores the
**margined** value in `drv->volt_sel` (`drivers/soc/qcom/spm.c:364-368`).
`spm_get_voltage_sel()` returns that cached value and never reads hardware
(`spm.c:379-384`). The regulator core takes `old_selector` from that getter
(`drivers/regulator/core.c:3707`), maps the **unmargined** request to a selector
(`core.c:3725`), and then:

```c
			if (old_selector == selector)
				ret = 0;          /* core.c:3730-3731 — no write */
```

So whenever the new OPP's bare voltage happens to equal the previous OPP's
*margined* voltage, the hardware write is skipped and that operating point runs
at **zero margin**. For this die's column (`speed1-pvs12-v1`) the collisions are:

- 100 mV margin: 820→920, 850→950, 880→980 mV
- 50 mV margin: 800→850, 810→860, 820→870, 830→880, 840→890, 870→920 mV

Consequence for the investigation: full-range soaks did not test what they were
believed to test. Pinned measurements are unaffected (the margin is applied once
and does land — measured `PMIC_STS=0xc8` = 1000 mV at 729.6 MHz with a 200 mV
margin).

**The same defect also shortens the settle delay on every rise.** The core
computes the ramp wait from the same mismatched pair —
`delay = |list_voltage(old_selector) − list_voltage(selector)| / ramp_delay`
(`core.c:3749-3756`, `ramp_delay = 1250` uV/µs at `spm.c:267`) — so with a 100 mV
margin every rise waits `|Δ − 100 mV|/1250` instead of `Δ/1250`, i.e. **80 µs
too little**, and some rises get zero. Worked against the vendor's own slew rate
of 2395 uV/µs (`krait_voltage_increase()`): 1651.2→2457.6 MHz moves the rail
1015→1170 mV and needs 65 µs, but waits 44 µs. That is a genuine
clock-before-rail window on every upward transition — the failure class the
whole investigation has been chasing, and it is invisible to any margin.

**Fix:** delete `margin_sel` and `qcom,vdd-margin-microvolt`; if an offset is
ever wanted, use the standard `regulator-microvolt-offset`
(`drivers/regulator/of_regulator.c:113`), which the core adds *before* mapping
(`core.c:3698`) and subtracts in `get_voltage` (`core.c:4602`), keeping the cache
coherent.

### P2 — `get_voltage_sel` never reads hardware, so drift is unrecoverable

Because the getter returns a driver-private value, any divergence between what
the driver believes and what the SAW actually holds (an aborted sequence, AVS, a
dropped SPMI transaction) is permanent *and* invisible: the driver keeps
reporting the phantom value and the core keeps skipping writes. The register
that would resolve this is already mapped and already polled at `spm.c:546-552`.

**Fix:** for v2.1, return `PMIC_STS` `CURR_VLVL`. Keep the cache only for v1.1,
which has no readback.

### P3 — L2-SAW PMIC command constants are written into all four per-CPU SAWs

The fork's new `spm_reg_offset_v2_1_cpu` (`spm.c:205-218`) makes
`PMIC_DATA_0 = 0x02030080` / `PMIC_DATA_1 = 0x00030000` (`spm.c:238-239`) live on
`saw0..3`. Upstream carries the same values in the struct but its offset table
has no PMIC_DATA entries, so those writes were **dead**. The vendor sets these
constants on the **L2** SAW only (`msm8974-v2-pm.dtsi`); its per-CPU nodes carry
no `pmic-data*` at all. This is the one pure-idle-path register delta against the
stable 6.16 configuration.

**Fix:** point the `-cpu` entry at the upstream offset table and drop the
now-dead `pmic_data` from it. The extended table is only needed by the `-l2`
entry, whose `set_vdd` is the sole consumer of VCTL/PMIC_STS/RST/AVS.

### P4 — divide-by-zero / dead store

`spm.c:648-649` computes `DIV_ROUND_UP(init_uV - rdesc->min_uV, rdesc->uV_step)`
where neither field is set for a linear-range descriptor, and the result is
immediately overwritten by `linear_range_get_selector_high()`. Cosmetic on
hardware with UDIV; still wrong, and present upstream. Delete the line.

## SUSPECTED, ranked by fit to the observed signature

### S1 — the L2 SAW sequencer is armed by probe, then poked from the cpufreq path with no serialisation against idle

- probe arms it: `spm_set_low_power_mode(STBY)` sets `SPM_CTL` EN=1 with index 0,
  which for the L2 entry is the vendor's **retention** sequence
  (`spm.c:760-761`, sequence bytes `1F 00 03 00 0F` = vendor `saw2-spm-cmd-ret`)
- the voltage path writes `RST=1` to that same SAW to kick its state machine
  (`spm.c:528`), from a **preemptible** context (`spm.c:375`)
- meanwhile cpuidle promises TZ the opposite:
  `qcom_scm_cpu_power_down(QCOM_SCM_CPU_PWR_DOWN_L2_ON)`
  (`drivers/cpuidle/cpuidle-qcom-spm.c:34`)
- nothing anywhere tells the L2 SAW not to run its sequence

Why this fits: the L2 SAW's trigger is all-cores-idle, so the failure would be
load-independent, frequency-independent and timing-random. An aborted retention
sequence leaves either the L2 in retention while software believes it is on
(hang → watchdog bite → PS_HOLD warm reset, no output) or the SAW's PMIC state
machine non-idle (the next VCTL write never lands — i.e. P2's phantom voltage).
It requires DVFS **and** idle, which matches every data point: 6.16 stable
(upstream v6.18 has no `qcom,msm8974-saw2-v2.1-l2` match entry at all, so the L2
SAW is never touched — the bootloader's state is left alone and `VCTL` is written
exactly once by `kpssv2_release_secondary()`), pinned+idle survived 61 min (no
`RST`/`VCTL` writes at all), full-range+idle dies in 17–25 min.

**Fix direction:** treat the msm8974 L2 entry as regulator-only — do not arm its
sequencer (skip SEQ/CFG/DLY/PMIC_DATA and the `spm_set_low_power_mode()` call,
and clear `SPM_CTL` EN explicitly) — and wrap the `RST`/`VCTL`/poll block in
`get_cpu()`/`put_cpu()` or `local_irq_save()`. The vendor does exactly this
pinning, and says why: *"we may race the vdd change with the SPM state machine of
that core, which could also be changing the voltage of that core during power
collapse."*

### S2 — AVS re-enabled with v1.1 field widths on a v2.1 selector

`spm.c:554-560` builds AVS limits with `GENMASK(15,10)`/`GENMASK(22,17)`
(`spm.c:40-41`) — 6-bit fields — from a `volt_sel` that reaches 220 on v2.1, so
the limits are truncated to nonsense (220 → 28) and AVS is then re-enabled
(`spm.c:563-566`). The fork also never clears `AVS_CTL` at probe
(`.avs_ctl = 0` means the write is skipped, `spm.c:747-748`) where the vendor
explicitly programs `qcom,saw2-avs-ctl = <0>` on every SAW. Lethal **if** the
bootloader left AVS enabled — one read settles it.

### S3 — unbounded `spm_register_write_sync()` loop on the idle path

`spm.c:320-337`, called twice per idle cycle with interrupts off from
`qcom_cpu_spc()`. The vendor documents the SPM auto-clearing the start-address
field, i.e. the field can change under the loop. Bound it with
`read_poll_timeout_atomic()` and warn.

## Closed questions

- **The hardcoded SPM constants match the vendor byte-for-byte.** `cmd-wfi`
  `[03 0b 0f]`, `cmd-spc` `[00 20 80 10 E8 5B 03 3B E8 5B 82 10 0B 30 06 26 30
  0F]`, L2 `cmd-ret` `[1F 00 03 00 0F]`, per-CPU `cfg=0x01`, L2 `cfg=0x14`,
  `dly=0x3C102800` — all identical. The only deviation is P3.
- **"A waking core drops the gang rail below what a busy sibling needs" is
  refuted in software.** The OPP table has no `opp-shared`, so each CPU gets its
  own regulator consumer and the core aggregates `max(min_uV)`. The hardware path
  (a per-CPU SPM issuing PMIC commands during collapse) is what P3 opens.
- **APC power-gate / MDD zeros are safe as configured.** `MDD_CONFIG_CTL`/
  `MDD_MODE` matter only for per-core LDO mode, which mainline never uses (probe
  shows `BHS_EN=1`, `BHS_SEG_EN=0x3f`, LDO bypassed). `PWR_GATE_MODE=0` leaves
  the staged hardware sequencer off, and mainline does the manual BHS bring-up
  once per core (`arch/arm/mach-qcom/platsmp.c:256-272`, matching lk2nd).
- **The pinned super-turbo CX corner does not interact with power collapse.**
  `PD_FLAG_DEV_LINK_ON` keeps the CX genpd runtime-active and the idle path never
  votes the RPM. Its cost is permanent extra power/heat (vendor `qcom,l2-fmax`
  would vote corner 4 at L2 = 729.6 MHz), which feeds the aggregate-power axis,
  not the idle axis.

## Clock side (krait-cc / HFPLL)

The steady-state HFPLL programming is **correct and vendor-exact**:
`config_val = 0x04D0405D`, `user_vco_mask = 0x100000`, `user_val = 0x8`,
`low_vco_max_rate = 1248000000`, min/max 537.6 MHz–2.9 GHz, and the register
offsets all match `qcom,hfpll-config-val` in the vendor DT. There is no droop
register on msm8974 (vendor `reg` length is 0x20), so its absence here is right,
not a gap. The device's own probe log agrees: 0 unlocked-output violations across
30 s idle plus 90 s of 729.6↔2265.6 MHz hammering. **A mis-programmed PLL is not
the cause.** What the audit did find:

- **C1 (proven) — `__clk_hfpll_init_once()` picks the VCO band from a stale
  rate.** It is called from `__clk_hfpll_enable()`, which `clk_hfpll_set_rate()`
  calls *after* programming `USER_CTL` and `L_VAL`; it then reads
  `clk_hw_get_rate()`, which the clk core only updates after `set_rate` returns,
  and overwrites `USER_CTL` wholesale from the **old** rate. The vendor instead
  derives the band from hardware (`readl(l_offset) * src_rate`). Concrete effect
  here: probe's forced 384 MHz→2 Hz→restore dance can leave a PLL at
  `USER_CTL = 0x100008` — high band with `L_VAL = 40` — i.e. locked but
  out-of-band until the next `set_rate` heals it. Out-of-band-but-locked is
  exactly "locks, then drifts with temperature and voltage".
  *Fix:* hoist the one-time init before the L/USER writes, and read `L_VAL` from
  hardware instead of `clk_hw_get_rate()`.
- **C2 (proven) — an out-of-bounds table index gets written into a live CPU
  mux.** `krait_mux_get_parent()` returns `clk_mux_val_to_index()`'s `-EINVAL`
  through a `u8`, so it becomes **234**, is stored in `mux->old_index`, and the
  POST notifier calls `set_parent(hw, 234)` → `table[234]` on a 2- or 3-entry
  array (~930 bytes past it), masked to 2 bits and written into the live clock
  mux. Unmapped hardware values today are 1 and 3 for the secondary mux and 3 for
  the primary; since the garbage written can itself be 1 or 3, one occurrence
  makes the fault sticky. *Fix:* fall back to `safe_sel` on a negative index and
  validate in `set_parent`.
- **C3 (proven) — `clk_hfpll_init()` compares the whole mode register against
  0x7** where the vendor masks `& 0x7` (and `hfpll_is_enabled()` in the same file
  masks correctly). If the bootloader leaves any bit ≥ 3 set in `PLL_MODE`, a
  running, locked PLL is treated as disabled and `CONFIG_CTL`/`M`/`N`/`USER_CTL`
  are written to it live, with no bypass or reset around the writes. One-line
  fix, affects every HFPLL platform.
- **C4 (proven) — the aux safe parent is unreachable.** `krait-cc.c` asks for
  `"apu_aux"` while the clock is registered as `"acpu_aux"`; with
  `krait-cc-v2` (our compatible) that branch is taken, so the secondary mux has
  exactly one resolvable parent: `qsb`, registered at a fictional 1 Hz. QSB is
  therefore the effective safe parent for every DVFS transition on all four cores
  and the L2. Not fatal — 542+ hammer transitions survived, and QSB is a real
  ~225 MHz clock — but the intended safe source is dead code and the rate
  bookkeeping is fiction.
- **C5 — no `ABORT_RATE_CHANGE` case** in `krait_notifier_cb()`, so a failed PRE
  notification leaves the core parked on QSB permanently.
- **C6 — the mux/safe-parent ordering itself is sound.** Traced against
  `clk.c`: the PRE notifier reaches the primary mux in every reachable topology,
  the switch to the safe parent is committed with a barrier before the PLL is
  touched, and the mux is restored only after the PLL is locked and `OUTCTRL` is
  set. The L2 mux is handled identically. No window with a core on a disabled or
  mid-reprogram PLL.

**Supplies:** there is no regulator code anywhere in the Krait clock stack, and
the binding forbids it (`qcom,hfpll.yaml` is `additionalProperties: false` with
no `*-supply`), so this is an upstream gap rather than a fork omission. The
analog rail is covered — `pm8941_l12` is `always-on`+`boot-on` at 1.8 V, and
`qcom_smd-regulator` only ever writes the RPM **active** set, which is exactly
what the vendor's `_ao` handle does. The digital (CX) side is covered only as a
side effect of the CPU OPP pin.

**One real semantic divergence:** we attach `MSM8974_VDDCX`, not
`MSM8974_VDDCX_AO`, so the super-turbo corner is mirrored into the RPM **sleep**
set. The vendor never votes CX super-turbo in sleep. That blocks vdd-min/XO
shutdown and holds pm8841 S2 at its top corner continuously — a power and
thermal cost, and consistent with "more margin made it hotter and worse".

**The MX theory is now closed for good.** The vendor does not vote MX for the
Krait/L2/HFPLL path either (`pm8841_s1` appears only on the MSS and pronto nodes),
`msm8974_rpmpds[]` has no MX domain at all, and `MSM8974_VDDMX` does not exist in
the bindings — so nothing in this fork *could* vote it. The vendor even pins MX at
its 675 mV minimum in the RPM sleep set. Mainline models a CX→MX parent where the
domain exists (`cx_rwcx0_lvl.parent = mx_rwmx0_lvl`), but msm8974 has no such
domain.

## Top unverified assumption: does the CX vote actually arrive?

Everything protecting the HFPLL digital logic and the L2 rests on one link nobody
has checked: that `required-opps = <&rpmpd_opp_super_turbo>` reaches the RPM as a
corner request. The plumbing reads correct end to end, but
`rpmpd_set_performance()` **silently returns 0 without sending anything** if the
domain is not enabled — so a failure here produces no dmesg evidence at all.

If the vote is not landing, every symptom fits: HFPLL digital and L2 logic run on
whatever corner the remote subsystems happen to hold, resets happen at any
frequency because the L2 is *always* at 729.6 MHz, idle or loaded, and no amount
of APC margin helps because the starved rail is CX. It would also explain why the
"pin CX at super-turbo" commit appeared to change nothing.

**Measurement (read-only, no `/dev/mem`):** after the device has been up long
enough for `sync_state` to fire, read `/sys/kernel/debug/pm_genpd/pm_genpd_summary`
and confirm the `cx` domain is `on` with performance state **6**, with four
devices attached. Anything else — `off`, state 0, or fewer than four devices — is
the bug, and the fix is in the attach path, not the clock drivers.

## Fork-delta findings

The complete delta against 6.18.40 is 74 files, +6781/−196. Beyond the items
above:

- **`6.18/rc` was missing `7fc3ec8151dc` ("take a spinlock for register
  access").** It had been on staging since `4975b57c83eb`, so rc — and therefore
  the `.deb` on the device and every soak to date — ran with regmap taking a
  **mutex** and allocating `GFP_KERNEL` while callers held `clk_hfpll::lock` with
  interrupts disabled. Merged into rc as `e8333aa71532`. Any conclusion drawn
  from earlier soaks is confounded by this.
- **The margin write bypasses regulator constraints.** The addition happens
  *after* `regulator_set_voltage()` has validated the request, so
  `regulator-max-microvolt` is unenforceable and the top rungs silently clamp at
  selector 255 = 1.275 V.
- **`saw_l2_vreg` has no board-level window** — it declares the raw hardware
  range 350000–1275000 µV with no name, no floor. Nothing structurally prevents
  350 mV on the rail feeding all four Kraits and the L2.
- **Eight other board families inherit FP2-tuned DVFS** from the shared
  `qcom-msm8974.dtsi` (Krait cpufreq down to 300 MHz at raw PVS voltages with a
  permanent max CX vote), while the margin and the 729.6 MHz floor are FP2-only
  overrides. Separately, the rpmpd migration deleted OnePlus bacon's unique
  `pm8841_s2` `min-microvolt = <875000>` **and** its `regulator-always-on` with
  no rpmpd equivalent.
- **The CX corner was keyed off the wrong variable.** The vendor's `qcom,l2-fmax`
  keys the corner off the **L2** rate; the first fork attempt graded it by CPU
  rate, and the current one pins it at max — which is accidentally safe and hides
  the real gap, namely that nothing in the fork ever sets or even reads the L2
  rate.
- **`qcom,vdd-margin-microvolt` is undocumented** (no binding update) and FP2 is
  its only user — unupstreamable as a knob; it should have been debugfs or a
  module parameter.
- **Branch hygiene defeats bisection of exactly this bug.** The
  `cpufreq-cx-corner`, `pon-reason` and `ci-dispatch-guard` topics were each cut
  from staging, so they contain all of dvfs-spm + adsp-sensors + gpu-iommu +
  smd-rpm-clocks + mmcc — none can be built or tested in isolation, or rebased
  for submission. And `d9b7c51b26fe`, whose own subject says "needs testing and
  probably a proper fix", is on **rc** and therefore in every soaked image.

## The next experiment, and why this one

Disable the SPC idle state at runtime — no reflash, no new code, everything else
byte-identical:

```sh
for f in /sys/devices/system/cpu/cpu*/cpuidle/state1/disable; do echo 1 > "$f"; done
grep . /sys/devices/system/cpu/cpu*/cpuidle/state1/{name,disable,usage}
```

Then soak **idle** (the configuration with the tightest known MTBF, 17–25 min)
for at least 90 minutes, sampling `state1/usage` into the fsync'd log so the
result can prove SPC never ran.

- **Survives ≫ 25 min with `usage` frozen** → the idle × DVFS class is
  confirmed. Then bisect one variable at a time: (a) don't arm the L2 SAW
  sequencer, (b) revert the per-CPU offset table (P3), (c) pin the L2 write.
- **Dies at the usual 17–25 min with `usage` frozen** → the entire idle path is
  exonerated, including everything here except P1/P2/S2, and attention moves to
  aggregate power (four HFPLLs at ~4× the 6.16 aggregate clock, the pinned CX
  corner, the carrier supply) and the HFPLL/clk side.

Four read-only register checks worth doing first, since any of them can reorder
the ranking in under a minute (SAW MMIO reads are proven safe on this rig, unlike
RPM MSG RAM — see RESET-FORENSICS.md):

| address | meaning |
|---|---|
| `0xf9012020` bit 0 | L2 SAW AVS enable — if set, S2 is live and must be fixed first |
| `0xf9089004` bit 2 (+`0x10000*n`) | per-CPU `SAW2_ID` PMIC-arbiter present — if clear, the P3 mechanism is inert |
| `0xf9089014` (+`0x10000*n`) | per-CPU `PMIC_STS` — a nonzero `CURR_VLVL` means a per-CPU SAW has driven the PMIC |
| `0xf9012030` bit 0 | confirms probe armed the L2 sequencer (expect set) |

## Baseline readings from the stable 6.16 kernel (2026-07-26)

Taken with `msm8974-preflight` on the freshly reinstalled vanilla Ubuntu image
running `6.16.12-msm8974-citronics-lime-fp2` — the configuration that soaks for
8 h+ without a reset. Full output in `evidence/2026-07-26-preflight-6.16-baseline.txt`.
Four of these settle open questions, and two of them cut against assumptions this
fork was built on.

**AVS is off on all five SAWs** (`AVS_CTL = 0` on the L2 and all four per-CPU
SAWs). So the bootloader does not arm it, and the truncated-window hazard in the
v2.1 setter was latent rather than live. The fix is hardening; it is not the
cause of anything observed.

**The CX domain is not voted at all on the stable kernel** — `pm_genpd_summary`
shows `cx`, `cx_ao` and `cx_vfc` all `off-0`. The 6.16 baseline runs cpu0 at
960 MHz off a locked HFPLL with CX sitting whereever RPM leaves it by default,
for hours. That is worth keeping in mind before treating "CX starvation" as
established: the reference configuration does not vote CX either. Our fork went
from a graded vote, to a permanent super-turbo pin, and has now landed on a
rate-graded vote — none of which the stable kernel does.

**The L2 SAW sequencer is not armed on the stable kernel**: `SPM_CTL = 0` on the
L2 SAW, `PMIC_STS = 0` (it is not driving the rail), and `VCTL = 0x00010003` —
port 1, data 3, i.e. exactly the "enable max phases" write that
`kpssv2_release_secondary()` leaves behind, never touched again. Our probe arms
that sequencer with the vendor's retention sequence and then pokes `RST` from the
cpufreq path. This is now a *measured* delta against the stable configuration,
not an inferred one.

**KPSS `VERSION` = `0x20010000`**, so it is above the `0x20000000` threshold: on
this part `APC_PWR_GATE_MODE`/`APC_PWR_GATE_DLY` are the registers that decide
the per-core power-switch mode, not `APC_PWR_GATE_CTL`. Both read **0** — mode
field 0, which in the vendor's encoding is PC rather than BHS(2) — while
`PWR_GATE_CTL = 0x403f3f7f` (BHS_EN set, all segments enabled, LDO bypassed).
The vendor writes `MODE = 0x21` and `DLY = 0x30430600` here. The stable kernel
shares the zeros, so zeros alone are survivable; what is untested is whether they
remain survivable once the rail is being scaled.

One asymmetry to note: **cpu0 has `LDO_VREF_SET = 0x3f` where cpu1-3 read 0.**
With the LDO bypassed this should not affect the delivered voltage, but it is a
real difference on the core mainline never "releases", and it is the kind of
detail worth re-checking on the 6.18 image.

## Baseline measurements, 6.16 vanilla, 2026-07-26

Taken with `msm8974-preflight` on the freshly reinstalled 6.16 image — i.e. the
bootloader-provided state, with none of this fork's DVFS code running. Raw
report in `evidence/2026-07-26-preflight-baseline-6.16.txt`. Four open questions
close here.

**AVS is off in hardware.** `AVS_CTL = 0x00000000` and `AVS_LIMIT = 0x00000000`
on all five SAWs. So the bootloader does not arm AVS, and the truncated-window
re-arm bug (S2) was **latent, not active** — worth fixing, which it now is, but
it was never the trigger. One candidate retired.

**KPSS VERSION = 0x20010000**, i.e. greater than `0x20000000`. This was the
flagged unknown, and it matters: above that threshold the vendor stops using
`APC_PWR_GATE_CTL` to select the head-switch mode and instead programs
`APC_PWR_GATE_MODE = 0x21` and `APC_PWR_GATE_DLY = 0x30430600`. On this die both
read **zero** on all four cores, so the mode field decodes as **PC**, not BHS,
and the hardware sequencer is off. `APC_PWR_GATE_CTL` is `0x403f3f7f` on every
core, which is exactly the vendor's final staged value — so the part mainline
*does* write matches, and the part that actually governs the mode on this
silicon is the part nobody writes. That makes the missing APC/MDD programming a
concrete gap rather than a maybe.

**CPU0 differs from its siblings**: `APC_LDO_VREF_SET = 0x3f` on cpu0 versus `0`
on cpu1-3. CPU0 is the core mainline never touches (`kpssv2_release_secondary()`
only handles secondaries), so this asymmetry comes from the bootloader.

**The L2 SAW is untouched on the baseline**: `SPM_CTL = 0` (sequencer *not*
armed), `PMIC_STS = 0` (never drives the rail), and `VCTL = 0x00010003` — port 1,
data 3, which is precisely the "enable max phases" write from
`kpssv2_release_secondary()` and the only thing that ever writes VCTL here. Our
fork arms that sequencer at probe and then pokes `RST` from the voltage path, so
S1 is confirmed as a real behavioural delta against the stable configuration,
independent of whether it is the trigger.

Also recorded: `qcom_stats` read `vmin` without incident — **Count: 0**, so this
SoC has never entered VDD-min, and the flagged risk of touching RPM code RAM at
`0xfc190000` through that driver did not materialise. Battery rail 4.397 V idle,
calibrated against the ADC's own references. Boot reason `pon=0x80` (KPD), a
clean cold start with no prior reset.

## The PMIC named it: UVLO at vendor voltages, 2026-07-26

Measured on `6.18.40-...-gaa55b1b242a1` — the kernel with all sixteen changes,
i.e. **no rail margin at all**, Android's exact fourteen operating points with a
300 MHz floor, CX graded by rate on the active-only domain, and the ten SPM and
Krait clock fixes. Four-core `stress-ng` on the full range reset the board after
roughly 40 seconds, and this time the PMIC said what happened:

```
pon_reason=0x02  warm_reset=0x0002  poff=0x2000  poff_bits: UVLO
verdict=BROWNOUT (PMIC undervoltage lockout)
```

Supporting facts from the same boot: `bootstatus = 0`, so **not** an APCS
watchdog bite — a question that could not even be asked before
`CONFIG_WATCHDOG_SYSFS` was enabled. Temperatures were 68–90 °C, far from any
trip. No panic, no kernel output.

UVLO is a statement about the PMIC's **input** rail, not about the Krait core
voltage. It fires when VPH_PWR crosses the lockout threshold, around
3.4–3.5 V. Steady-state VBAT measured 4.35–4.40 V idle and 4.24–4.30 V under
load, so the collapse must be a fast transient that a few-Hz ADC cannot see.

What this rules out, and it is a lot:

- **Not the voltage table.** This kernel commands exactly the fused PVS values,
  the same ones Android uses, and CPR is not enabled on this SoC so those values
  are meant to be used as-is. Adding margin made it *worse* (200 mV: 39 s, also
  UVLO); removing it entirely still browns out. Voltage magnitude is not the
  lever in either direction.
- **Not the OPP set.** The exposed rungs are now Android's, verified on the
  shipped DTB.
- **Not the watchdog**, not thermal, not a panic.

What it points at is total power draw. Corroborating: the 6.16 baseline runs for
hours on this same board, but it has no CPU DVFS — cpu0 sits at 960 MHz and
cores 1-3 run off the aux mux near 600 MHz, roughly 2.8 GHz aggregate against
the 4×1728 MHz this soak reached. And this rig is a Fairphone 2 motherboard on a
carrier with **no battery**: VBAT is fed directly, so there is no cell impedance
to absorb a current step. On a phone, the battery is exactly what does that job.

Two UVLO events now, at opposite ends of the voltage range, are the first
mechanism-level evidence in this investigation. The discriminator is current, so
the next measurement varies only that: `msm8974-load-scale-mtbf` pins the
frequency at 1728 MHz and runs 1, then 2, then 4 loaded cores for ten minutes
each, logging calibrated VBAT throughout. If one and two cores survive where
four browns out, current draw is confirmed and the fix is a power-delivery one -
bulk capacitance, a lower-impedance feed, or a battery - with a frequency or
core cap as the software-side mitigation. If all three brown out alike, current
is exonerated and the remaining candidates are the unscaled L2 rate and the
unprogrammed APC power-gate mode.

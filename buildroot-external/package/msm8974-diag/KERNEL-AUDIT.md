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

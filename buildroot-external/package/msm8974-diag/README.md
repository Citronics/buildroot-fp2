# msm8974-diag

Diagnostics for the MSM8974 CPU power/clock path, written while chasing silent
resets on the 6.18 fork. On this SoC a bad power or clock state resets the board
with **no kernel output at all** — no panic, no oops, nothing on serial — so
everything here is built around two ideas: read hardware state directly, and
write evidence to disk with `fsync` so a reset cannot erase it.

Deploy onto a freshly flashed device with `msm8974-diag-deploy` (root). It
installs the units, pins the CPUs to the safe floor at every boot, and enables
**nothing** that applies load — experiments must be started deliberately.

## Why this exists

The Krait DVFS stack on msm8974 is entirely downstream-of-nobody: mainline
v6.18 has no CPU OPP table, no `kraitcc`/`hfpll` DT nodes, no `cpu-supply`, and
`spm.c` has no `smp_set_vdd_v2_1_l2` at all. postmarketOS ships
`msm8974-mainline` `v6.16.12-msm8974` unpatched, and its config does not even
build `KRAITCC`/`QCOM_HFPLL`/`ARM_QCOM_CPUFREQ_NVMEM`. lk2nd never programs the
Krait clock either. So this fork's DVFS is the only software that has ever
driven these PLLs and this rail, and it has no external validation.

## What this die actually is (read from the fuses, not from spec sheets)

Published sources disagree about the Fairphone 2's SoC (Snapdragon 801
"MSM8974AB v3", 2.26 GHz, is the common claim). The silicon answers for itself:

| Source | Value |
|---|---|
| `/sys/devices/soc0/machine` | `MSM8974PRO-AA` (`soc_id=217`, revision 1.1) |
| Krait `PTE_EFUSE` at `0xfc4b80b0`, decoded as `get_krait_bin_format_b()` | **speed bin 1, PVS bin 12, PVS version 1** → `speed1-pvs12-v1` |
| `drv->versions` handed to the OPP core | `1 << 1` = `0x2` |
| `scaling_available_frequencies` on the 6.18 fork | 22 rungs, **729.6 → 2265.6 MHz** |

Consequences worth knowing before touching the OPP table:

- The DT carries rungs up to 2457.6 MHz, but the three above 2265.6 are gated
  `opp-supported-hw = <0x8>` (speed bin 3 only). With this die's mask `0x2`
  the OPP core filters them out, so the kernel exposes exactly the rated
  2.26 GHz ceiling. **The board is not being overclocked** - verified on the
  running kernel, not inferred from the DT.
- Downstream's per-bin tables (`qcom,speedN-pvsM-bin-vK` in `msm8974pro.dtsi`)
  exist only for speed bins 1 and 3, and bin 1's table stops at 2265.6 MHz -
  independent confirmation of the fuse reading.
- The fork's DT does model voltages per bin (`opp-microvolt-speed1-pvs12-v1`,
  selected by the driver via `config.prop_name = pvs_name`), and for this die
  that column matches the vendor table **exactly on all 28 rungs**. So the
  rail is not being starved relative to vendor spec: at 1036.8 MHz the vendor
  asks 830 mV, and the fork asks 830 mV plus the SAW margin.

That last point retro-explains an earlier measurement: 880 mV observed at
1036.8 MHz was simply 830 mV + the 50 mV margin then in force. It also weakens
the undervoltage theory considerably - Android runs this die at 830 mV there,
and the fork reset in 5 minutes at 880 mV.

## Read-only probes

| Tool | What it reads |
|---|---|
| `msm8974-pon-reason` | PMIC PON/POFF reason via regmap debugfs (a 6-register seek read, no kernel patch needed). Decodes `UVLO` (rail collapsed), `PMIC_WD`/`STAGE3` (hardware broke a hang), `TFT`/`OTST3` (thermal), `PS_HOLD` (SoC-initiated). |
| `msm8974-hfpll-rates` | Each HFPLL's mode/L/lock bits at `0xf908a000 + 0x10000*cpu`; rate = L × 19.2 MHz. Works even when no clock driver is loaded. |
| `msm8974-saw-mv` | L2 SAW `PMIC_STS`/`VCTL`. Encoding: `uV = 5000 × selector` (matches the vendor's `setpoint = uV/5000`). |
| `msm8974-apc-state` | Per-core LDO vs BHS mode, `BHS_SEG_EN`, `LDO_BYP`, LDO VREF. |
| `msm8974-apc-full` | Adds `APC_PWR_GATE_MODE`/`APC_PWR_GATE_DLY` and the MDD block, flagged `== vendor` / `!= vendor` against what `krait-regulator.c` programs. |
| `msm8974-apc-smps` | PMIC SMPS type/range/setpoint over SPMI (read-only regmap debugfs). |
| `msm8974-hfpll-probe` | Samples all five HFPLLs looking for output enabled while the lock bit is clear — catches an unlocked PLL being switched in. |

## Stressors and soaks

- `msm8974-hammer-full` / `msm8974-hammer-small` — forced DVFS transitions
  (729.6↔2265.6 and 729.6↔1497.6 MHz), one per second, fsync'd flip counter.
- `msm8974-soak-log` — vitals every 15 s: uptime, frequency, **cpufreq
  transition counter**, CX corner, max temperature, load, phase.
- `msm8974-pinned-soak` — real load at one fixed OPP (transition counter must
  stay frozen). Thermals are handled by suspending the *load*, never by
  lowering the frequency, so "survived" is never a throttling artifact.
- `msm8974-converge-validate` — finds the highest rung the board survives under
  sustained 4-core load. It starts at `START` (default 1036800 kHz, the measured
  death point) and **bisects**: a rung surviving `HOLD` seconds raises the lower
  bound, a rung that resets the board lowers the upper bound. Starting at the
  known failure rather than at the top of the table makes the first result a
  direct A/B against the recorded death instead of ~20 certain failures. State
  is fsync'd, so a silent reset *is* the measurement — the next boot judges the
  rung and picks the next candidate. It records the boot id, so a process
  restart is never miscounted as a board reset; it waits for the remoteprocs to
  finish booting before judging anything (modem bring-up is itself a suspect);
  and a reset during the post-PASS soak is recorded as a failure of that rung,
  because a rung that survives 45 minutes and then dies never was stable.
- `msm8974-ceiling-sweep` — the ascending variant, with a no-transition control
  rung first.
- `msm8974-load-cycle` — duty-cycled real load (BOINC when it actually has
  tasks, else `stress-ng`), so a soak is never accidentally idle.

## Measurements on the reference FP2 (6.18 fork, CX pinned at super-turbo)

| Configuration | Result |
|---|---|
| pinned 729.6 MHz, idle | 61 min, no reset |
| pinned 1036.8 MHz, 4-core load, **transition counter frozen** | reset after 5 min at 77 °C |
| full range, 4-core load | reset within seconds to minutes |
| full range, idle | reset after 17–25 min |
| `hammer-full` (729.6↔2265.6) | reset at 352 / 507 / 2405 flips |
| `hammer-small` (729.6↔1497.6) | 1671 flips clean |
| 6.16 (no DVFS at all) | stable; cpu0 at 960 MHz, hfpll1/2/3 **off**, SAW never driving the rail |

Every reset reported `PS_HOLD` with **no** `UVLO`, no PMIC watchdog and no
thermal bit — the SoC gives up rather than the PMIC dropping a rail.

Ruled out with evidence: DVFS transitions (died with the counter frozen),
thermal, PMIC undervoltage lockout, Linux/systemd watchdog, per-core LDO/BHS
misconfiguration (all cores read `BHS_EN=1`, segments enabled, LDO bypassed),
SMPS phase scaling (the vendor gates it on a DT property its own msm8974 trees
never set), the SAW vlevel encoding, and the SPM constants (`spm_cfg`,
`pmic_data0/1`, `cmd-ret` sequence all match `msm8974-v2-pm.dtsi` exactly).

One real defect was found and fixed along the way: `clk-hfpll`'s lock poll had
an inverted exit condition, so `PLL_OUTCTRL` was asserted ~10 µs after reset
de-assert while the PLL needs ~60 µs to lock. `msm8974-hfpll-probe` showed 59
violations per 90 transitions before the fix and 0 after — but the resets
continued, so it was a genuine bug and not the cause.

## Do not read these physical addresses over /dev/mem

`fw-forensics.py` dumps RPM MSG RAM (`0xfc428000`) and IMEM (`0xfe805000`) -
firmware-owned SRAM that survives a warm reset - hoping the RPM's own log would
explain a silent reset. **Running it reset the board instantly**, before even an
empty report inode reached disk, so it is kept here as documentation and is
deliberately *not* installed by the package. Those ranges are XPU/TZ-protected
on this SoC and an unauthorised access is itself a reset.

Two things follow, and the second one matters for the whole investigation:

1. Only probe ranges already proven safe by repetition here: the Krait/HFPLL
   block (`0xf908_0000`+), the SAWs (`0xf9012000`, `0xf90b_8000`+), the APC/MDD
   blocks, and the QFPROM fuse row at `0xfc4b80b0`.
2. An XPU violation produces **exactly** the signature we had been reading as a
   power problem: no kernel output, `pon_reason=0x01`, `warm_reset=0x0002`,
   `poff=PS_HOLD`. So that signature does **not** distinguish a rail event from
   a bus/permission violation, and "PS_HOLD, never UVLO" is not evidence for a
   brownout. Any suspect that can touch a protected register belongs back on the
   list.

## Writing files to a board that resets

After any `scp` to a board under test, `sync` and compare checksums. A file
copied shortly before a reset came back **correctly sized and entirely
zero-filled** (ext4 delayed allocation lost the data blocks but kept the
inode), and the resulting `203/EXEC` looked like a permissions problem for
several minutes. Also note `/home` may reject exec; install helpers that
systemd must exec into `/usr/local/sbin`.

## Safety rules (learned the hard way)

1. **Never offline a CPU.** `echo 0 > cpuN/online` panics this kernel: NULL
   deref in `tick_nohz_get_sleep_length` from `teo_select` via
   `arch_cpu_idle_dead`, then "Attempted to kill the idle task". None of the
   tools here offline CPUs.
2. **Never leave `scaling_min_freq` pinned high unattended** — thermal
   throttling becomes impossible and the board can reach its 105 °C critical
   trip, which looks like a reset but isn't.
3. Keep `pin-early` at the floor. A boot must never come up at an untested
   operating point; raise the ceiling deliberately, from userspace.
4. Logs live in `$DIAG_DIR` (default `/var/log/msm8974-diag`). On the Ubuntu
   test image, run with `DIAG_DIR=/home/citro`.

`evidence/` holds the raw logs from the investigation (not installed into
images).

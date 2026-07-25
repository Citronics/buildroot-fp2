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
- `msm8974-descend-validate` — walks the ceiling down (960 → 883.2 → 806.4 →
  729.6 MHz) under sustained 4-core load, 45 min per rung, resuming across
  resets and stepping down automatically; says explicitly if every rung fails.
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

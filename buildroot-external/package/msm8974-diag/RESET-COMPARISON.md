# FP2 resets: Android as the reference, and what the measurements have closed

A working document for the comparison in progress. It exists because this
investigation repeatedly mistook a single measurement for a conclusion, so every
claim is tagged with what it rests on:

- **PROVEN** — measured directly, reproducible or corroborated by a second source
- **SUGGESTIVE** — one measurement, consistent but not repeated or controlled
- **RULED OUT** — a measurement contradicts it
- **OPEN** — no measurement yet

Do not delete superseded claims; move them to the closed list with the evidence
that closed them. Knowing what was already excluded is what stops the loop from
repeating.

## 0. Why the comparison is against Android, and not against our 6.16

Our 6.16 was used as a "stable baseline" for a while. It is **not a valid
control**, and results resting on it have been withdrawn:

- it never scales the CPU rail, so its DVFS code is not under test at all;
- it runs a much narrower, lower frequency range, so it never visits the
  operating points where the failure happens;
- it is a far simpler configuration overall, so "6.16 survives, 6.18 resets"
  conflates *our DVFS code* with *running fast at all*.

**Stock Android on the same handset is the only apples-to-apples reference**:
same silicon, same die bin, same 14 frequency rungs, full per-core DVFS, real
power collapse — and no resets. Every difference that matters is therefore a
difference between the vendor's DVFS/power implementation and ours, and that is
what §2 enumerates.

## 1. The two boards, and what each can prove

| | **rig** | **phone** |
|---|---|---|
| hardware | bare FP2 motherboard on a Citronics Lime carrier | complete handset |
| power | carrier feeds VBAT directly, **no battery** | **real battery** |
| silicon | soc_id 217 (MSM8974PRO-AA) rev 1.1, speed bin 1, **PVS 12** | same soc_id/rev/bin, **PVS 9** |
| access | ssh over USB-ethernet hub | ssh over the RNDIS gadget |
| reset signature | `poff=0x2000` = **UVLO** (brownout), every time | `poff=0x0002` = **PS_HOLD** (SoC-initiated), every time |

These are **two different faults**, and the PMIC distinguishes them cleanly:

- The **rig** browns out. It resets at the lowest operating point the silicon
  has (4 cores at 300 MHz, 743 s), MTBF is load-independent (2 cores at
  1728 MHz survived 600 s), steady VBAT is healthy at 4.2–4.4 V with one
  captured transient at 3.421 V — right at the pm8941 lockout threshold. With
  `dcin`/`usbin` offline and no battery there is **no software fix and no knob
  to raise**. The rig cannot validate kernel work until its feed is fixed
  (bulk capacitance at the pads, connector, wiring impedance).
- The **phone** does not brown out. It resets with **PS_HOLD**, i.e. something
  on the SoC asked for the shutdown, at 50–70 °C with VBAT ≥ 3.94 V. This is
  the kernel bug, isolated for the first time on hardware that is not
  power-starved. **All kernel conclusions below come from the phone.**

## 2. The systematic difference: Android live vs ours live

Both columns are live captures from the *same handset* — vendor 3.4 (evidence
`evidence/2026-07-26-real-phone-android-baseline.txt`) and our 6.18.40
(`g86d3fa288686`). "?" marks a row still under analysis.

### 2.1 Where we already match the vendor

| aspect | Android | ours | status |
|---|---|---|---|
| frequency table | 14 rungs, 300000–2265600 kHz | identical 14 rungs | **same** |
| `scaling_min_freq` | 300000 | 300000 | **same** (the old "960 MHz floor" claim is refuted on hardware) |
| per-core independence | 4 cores, own frequencies | 4 policies, `related_cpus` one each | **same** |
| die bin decode | `speed1-pvs9-v1` | same decode from `PTE_EFUSE` | **same** |
| OPP voltage table | vendor per-bin table | matches on all 28 rungs | **same** |
| **physical rail vs OPP** | n/a | **required == VCTL == PMIC_STS on every rung tested, 300 → 1958.4 MHz** | **ours PROVEN correct** |
| AVS | never armed | `AVS_CTL = 0` on all five SAWs | **same** |
| MX rail | 675 mV, **disabled** | not voted (no MX domain in `rpmpd`) | **same** |
| CX vote arrives | yes | `cx_ao` on, performance state 6 | **same** |

### 2.2 Where we differ from the vendor

| aspect | Android | ours | implicated? |
|---|---|---|---|
| **CPU rail architecture** | **4 per-core regulators** (`krait0..3`) with per-core LDO / BHS / bypass switching, *plus* the gang rail | **one shared gang regulator** (the L2 SAW) with 4 consumers; per-core switches never managed | **structural, top suspect** |
| `APC_PWR_GATE_MODE` | `0x21` | **`0x0`** | open |
| `APC_PWR_GATE_DLY` | `0x30430600` | **`0x0`** | open |
| `MDD_CONFIG_CTL` / `MDD_MODE` | `0x190` / `0x2` | **`0x0` / `0x0`** | open |
| `LDO_VREF_SET` | vendor-managed | `0x3f` on cpu0, **`0x0` on cpu1–3** (asymmetric) | open |
| **L2 clock** | **1497.6 MHz**, scaled with the fastest core | **729.6 MHz, fixed** — nothing consumes `<&kraitcc 4>` | open |
| CX corner | voted **dynamically** 5 ↔ 7 from the L2 rate (`qcom,l2-fmax`) | rate-graded in DT; sits at state 6 | open |
| governor | `interactive` | `conservative` | **no** — resets also happen pinned |
| idle levels | vendor lpm levels | `WFI` + `cpu-spc` (350 µs) | open |
| per-core SAW `SPM_CTL` | ? | `0x31` (cpu0,2,3) / `0x1` (cpu1) | ? |
| L2 SAW sequencer | ? | **armed** (`SPM_CTL=0x1`), `pmic_data0/1 = 0x02030080 / 0x00030000` | ? |

`KPSS VERSION = 0x20010000` on this die, which is above the threshold where
`PWR_GATE_MODE`/`DLY` are the registers that decide the switch mode — so the
three zeroed register groups above are not obviously harmless.

## 2.5 Epistemic ruling (Marc, 2026-07-26)

Only the **Android live capture on the phone** is ground truth. Data from our
6.16 on the phone is excluded alongside the rig data: 6.16 has no DVFS, lower
frequencies, and a simpler configuration, so nothing it does or survives says
anything about our DVFS stack. What Android proves — and all it proves — is
that **this hardware (phone + battery) runs a full DVFS stack without resets**.
Ours resets. The delta is in our software. Claims below that leaned on 6.16
have been re-based accordingly.

## 3. What the measurements have closed

**The commanded setpoint tracks the OPP exactly. PROVEN — but note the limit
of the claim.** Sweeping every rung with all four policies pinned and reading
the L2 SAW directly: `required == driver == VCTL == PMIC_STS`, exactly, on
300 000, 422 400, 729 600, 1 036 800, 1 190 400, 1 497 600 and 1 958 400 kHz,
and `dmesg` contains no `timeout setting the voltage` — the SPM writes latch.
An earlier note that the driver (875 mV) disagreed with the silicon (955 mV)
was a **sampling race** during active DVFS, not a defect: at rest all three
numbers agree.

**The limit:** `VCTL`/`PMIC_STS` are the SPMI arbiter's latched *command*, not
a measurement of the voltage at the Krait pads — and the sweep ran **unloaded**.
What is excluded is "the kernel asks for the wrong voltage". What is *not*
excluded is the rail **drooping under sustained 4-core current** (regulator
mode, phase configuration, load-line): that failure would show a correct
setpoint, no PMIC fault record (FAULT_REASON watches the input rail, not the
outputs), death only under load, and a clean idle — which is exactly the
observed signature. Only a scope at the pads, or a survival-vs-current
measurement, can discriminate.

**Frequency alone does not reset it. PROVEN.** All 14 rungs including 2265.6 MHz
were selected and held, unloaded, with no reset; the board then stayed up for
20+ minutes across the whole sweep.

**Every rung is selectable. PROVEN.** A sweep that reported "PIN FAILED" on 7 of
14 rungs was **a defect in the harness**, not the kernel: `scaling_min/max`
writes land through `freq_qos` and the aggregated value is not guaranteed
visible on the next read. With a settle delay all 14 pin exactly. Both harnesses
now settle *and* verify, and abort loudly rather than produce an unattributable
measurement — two earlier results were lost to exactly this.

**Load with no transitions still resets. PROVEN (one clean run).** Four cores
pinned at 1190.4 MHz, verified pinned in the log, died in under 30 s at 65–70 °C
with `PS_HOLD`. So the reset does not require frequency transitions, does not
require the top OPPs, and is not thermal.

**Withdrawn: the "resets at idle" observation.** A 31-minute watcher recorded
four resets at 130–300 s intervals and then 925 s clean, but soaks were running
concurrently during the first window, so "idle" meant only "the watcher was not
loading it". Contaminated; not evidence. A clean instrumented idle run is now in
progress as the baseline arm of an A/B (§5).

### Closed list (unchanged, with the evidence that closed it)

- **Voltage table / margin. RULED OUT.** Per-bin column matches the vendor on
  all 28 rungs. The invented 100 mV margin cancelled itself on some transitions
  (fixed, removed); 200 mV made MTBF worse and added ~20 % heat.
- **MX/CX starvation. RULED OUT.** msm8974 has no MX power domain in `rpmpd`;
  Android leaves MX at 675 mV disabled; our CX vote does arrive.
- **The modem. RULED OUT.** Disabled at DT level; the board still reset.
- **AVS. RULED OUT.** `AVS_CTL = 0` on all five SAWs; the bootloader never arms
  it. The truncated-window defect in our setter was real but latent, and fixed.
- **HFPLL misprogramming. RULED OUT.** Config, VCO mask, user value, switch
  point and offsets are vendor-exact; 0 unlocked samples across 90 s of
  hammering. (One boot-time `hfpll1 failed to lock` warning remains, from our
  own instrumentation, at 0.518 s with `L_VAL 0` — worth explaining, but it is a
  boot-time enable of an unconfigured PLL, not the steady-state path.)
- **Thermal. RULED OUT.** Failures at 48–70 °C; trips are 90 °C passive /
  105 °C critical; Android runs at 82 °C untroubled.
- **PMIC over-temperature. RULED OUT.** Our PM8941 trip set matches the
  vendor's `qcom,threshold-set = <0>`.
- **Steady-state supply on the phone. RULED OUT.** VBAT ≥ 3.94 V, and the
  signature is PS_HOLD, not UVLO.
- **Mutex in atomic on the DVFS path. FIXED** (`.fast_io` on the HFPLL regmap,
  `e8333aa71532`) — and it invalidates every soak taken before it.
- **ramoops / pstore forensics. DEAD END.** Neither our reserved region nor the
  bootloader's scratch region survives a warm reset on this SoC.

## 3.5 Death table — phone, our 6.18 (`g86d3fa288686`, rc3.14 DTB)

Every death: clean PS_HOLD, `bootstatus=0`, `FAULT_REASON1/2=0`, no console
output.

| configuration | outcome |
|---|---|
| unloaded rung sweep incl. 2265.6 MHz + register probes | no reset, 40+ min |
| idle, DVFS free (conservative, mostly 300 MHz), instrumented | **reset at 2132 s** (35.5 min), 47 °C, rail 800 mV correct at last sample |
| idle, pinned 300 MHz (after a 12 s aborted load) | **reset at ~325 s uptime** |
| 4-core load, pinned **300 MHz** (pin verified, ladder rung 1) | **reset < 30 s** |
| 4-core load, pinned **300 MHz** (replication, pin verified, rail watched: setpoint never moved, 54 °C, VBAT 4.20 V) | **reset at 90–120 s** |
| 4-core load, pinned 1190.4 MHz (pin verified) | **reset < 30 s**, 65–70 °C |
| 4-core load, DVFS free (earlier in the day) | reset 30–120 s |
| 4-core load, pinned 300 MHz, **FTS commanded to PWM** (port-2 write verified still latched at t=30: `rail=640000/800000`) | **reset 30–60 s** — the PWM command changed nothing |

Android reference on the same handset: 4 cores at 1.5–2.27 GHz, 82 °C —
no reset (and years of product-level stability).

**Reading of the table:** 4-core load ⇒ MTBF ≈ 0.5–2 min at *any* frequency
(300 MHz kills like 1190.4); idle ⇒ MTBF ≈ 5–35 min. Both scatter widely — a
statistical failure process, not a threshold. Load's few-hundred-mA draw at
800 mV is trivial for a PWM-mode FTS and above a PFM-mode one's capability,
so the FTS-mode hypothesis survives this table; a current-magnitude threshold
does not. During the replication the SAW setpoint was sampled every second
and never moved — no other writer drives port 0 under load.

## 4. The surviving hypotheses (reassessed 2026-07-26 afternoon)

The reset is **SoC-initiated and clean**: PM8941 `FAULT_REASON1/2 = 0x00` (no
PMIC watchdog, no OTST3, no input UVLO recorded), the Linux watchdog is
`inactive` with `bootstatus=0`, and the IMEM reboot-mode cookie is empty.
Something outside Linux — TZ, a secure watchdog, or the RPM — pulled PS_HOLD,
or was asked to. The discriminating observation across all admissible runs:
**load kills, idle does not**, even though idle exercises power collapse ~29×/s
and load barely exercises it at all.

**S1 — rail droop under sustained load (electrical, in-spec setpoint).
REFUTED as far as software can, 2026-07-26 evening.** The discriminator ran:
all policies pinned to 300 MHz (no port-0 traffic), the vendor's own
"FTS → PWM" command written to L2 SAW `VCTL` port 2 (single aligned 32-bit
store; verified latched, and still latched at the t=30 s sample under load —
`rail=640000/800000`), then the standard 4-worker load. **It died in the same
30–60 s window as every unpoked run.** Caveat kept honestly: a latched `VCTL`
proves the register write, not SPMI delivery — the vendor polls the PMIC FSM
to confirm transmission, and if the PVC port is not enabled in this boot's
SAW configuration the command may never have left the block. But combined
with 4×300 MHz busy loops drawing only a few hundred mA at 800 mV — modest
even for PFM — the mode/droop family is no longer credible as the primary
cause. (The two earlier "failed poke" runs were a Python `mmap` signature
bug — flags/prot swapped positionally yields a read-only mapping — not a bus
restriction; recorded so nobody re-fights that.)

**S2 — per-core power-switch/MDD configuration never programmed.** Vendor
writes `PWR_GATE_MODE = 0x21`, `PWR_GATE_DLY = 0x30430600`,
`MDD_CONFIG_CTL = 0x190`, `MDD_MODE = 0x2`; ours are zero, on a die whose
`KPSS VERSION` puts those registers in charge. **Demoted for the load death**:
under 4 busy loops the cores barely enter collapse, and at idle (29
collapses/s) the board is clean — the naive "collapse inrush" version predicts
the opposite ordering. The rig's SPC-off 900 s run is inadmissible (UVLO
hardware). Still open as a *combined* factor (collapse exit into a loaded,
high-current rail).

**S3 — the L2 at 729.6 MHz while cores run to 2.27 GHz.** The vendor scales the
L2 to 1497.6 MHz and votes CX from it. Note the busy-loop load is L1-resident
and barely touches the L2, yet dies — so if S3 matters it is not via L2
*traffic*. A DT-only pin of the L2 to 1036.8 MHz changed nothing on the rig
(inadmissible board, weak evidence either way).

**S4 — the reset actor is unidentified, and finding it is worth more than
another soak.** A full 4-core hang with no armed Linux watchdog should freeze,
not reboot — yet the SoC reboots cleanly. So either a TZ/RPM-side watchdog
exists and fires (standard downstream flow: WDT bite → TZ saves context →
PS_HOLD reset), or the failure is not a hang but a secure-side fault. IMEM is
safely readable via the syscon regmap
(`/sys/kernel/debug/regmap/dummy-sram@0xfe805000/registers`) — the TZ diag
region may already contain the answer after a reset.

## 4.5 Vendor-BSP audit results (three parallel source audits, 2026-07-26)

Three independent audits of the vendor 3.4 BSP (`int/10/fp2`) against our tree,
each with file:line evidence (full texts in the session transcript; key claims
reproduced here).

**Closed by the audits (no longer suspects):**

- **Our SPM programming is byte-exact vendor**: both SAW sequences, `spm_cfg`,
  `spm_dly`, `pmic_data0/1`, init `SPM_CTL` — all match the FP2 DT
  (`msm8974pro-pm.dtsi`). The "fork-only SPM constants" worry is closed.
- **No clock concurrency race**: mainline serialises every `clk_set_rate`
  under the global `prepare_lock`, and each core has a private HFPLL, divider,
  mux and cp15 register. Four policies cannot race each other.
- **Voltage↔rate ordering is equivalent to the vendor's** (voltage-first up,
  rate-first down), and the shared-rail aggregation is a max with no window in
  which the rail can dip below a running core's requirement.
- **The static L2 is "slow, not unsafe"**: no core:L2 ratio limit exists
  anywhere in the vendor BSP; the vendor itself ships ratios up to 1.53; a
  slower L2 draws less current. Demoted as a reset cause (still a parity and
  performance defect: vendor scales the L2 by a max-over-cores table and
  votes CX from `qcom,l2-fmax`; the L2 imposes **no** gang-rail floor).
- **OPP voltages byte-identical to the vendor tables** (pvs9 and pvs12 both
  checked). CX corner: our pinned level 6 *is* the vendor's ceiling
  (their corner 7); Android's observed 5↔7 = our 4↔6.
- **Phase count is fine**: `platsmp.c` writes port 1 = 4 phases at secondary
  release — the vendor's maximum/conservative setting for load.
- **CPU0's head switch is fine**: measured `PWR_GATE_CTL = 0x403f3f7f` on all
  four cores (pure BHS, LDO powered down) — lk2nd leaves cpu0 in the same
  state mainline puts cpu1-3 into.
- **MDD / `LDO_VREF_SET` zeros are safe in our configuration**: MDD is the
  bandgap for the per-core LDO/retention modes, which we never select (always
  BHS, no SPM retention state programmed).

**The convergent top suspect — S1 sharpened:**

Two audits independently landed on the same omission: **the Krait gang FTS's
PFM/PWM mode is never commanded by our kernel.** The vendor forces **PWM**
(`0x80`) through L2 SAW `VCTL` **port 2** whenever more than one core is
online or load exceeds `qcom,pfm-threshold` (`krait-regulator.c:481-508`),
before raising phases; our driver writes port 0 (voltage) only, and nothing
else in the tree touches port 2. The SAW's `pmic_data0/1` decode as exactly
the PWM (`…80`) and PFM (`…00`) command bytes. So the FTS mode is whatever
the bootloader left — **and it is unreadable from HLOS** (SPMI ownership
filter returns zeros for the pm8841 APC peripherals; verified live). A gang
rail left in PFM/auto supplies idle handsomely and collapses under a 4-core
current step, invisible to `PMIC_STS`. One audit's summary: the only
candidate that explains load-dependence, frequency-independence (pinned
1190.4 dies like 2.27 GHz), temperature aggravation, the clean PS_HOLD, and
Android's immunity.

**Demoted or terminal-mechanism-missing:**

- **Missing `local-timer-stop` on `cpu_spc`** (real mainline Krait-wide DT
  bug: `armv7-timer` has no `always-on`, so the clockevent is C3STOP, yet
  cpuidle never hands the tick to the broadcast timer around collapse).
  *But*: the idle baseline's 30 s samples land at 30.04 s intervals through
  ~29 collapses/s — timers are punctual through SPC on this silicon — and the
  proposed terminal mechanism (APSS watchdog bite) is dead: watchdog
  `inactive`, `bootstatus=0` on a boot that followed a PS_HOLD death. Fix for
  correctness/parity; not the reset chain as proposed.
- **Unserialized `TERMINATE_PC`** (vendor takes a TZ-released SMEM remote
  spinlock around every collapse — FP2 sets `qcom,allow-synced-levels`; our
  `qcom_scm_cpu_power_down()` takes nothing). A TZ-side inconsistency
  resetting via PS_HOLD fits the signature, **but** concurrent collapse is
  far more frequent at idle (which survives) than under load (which dies) —
  the inversion argues against the naive form. Stays mid-rank pending the
  PS_HOLD-actor analysis.
- **Sec-mux parent map inverted** (`sec_mux_map = {2,0}` with parents
  `{qsb, acpu_aux}` — index 1 programs selector 0 = QSB, the state the
  vendor's own comment forbids; armed by our `8c8328961a45` rename). Live
  snapshot shows cores at 307.2 MHz off `hfpll_div` at the 300 MHz rung, so
  it has not fired; cannot explain the pinned-1190.4 death. **Fix
  regardless** (one-liner), it is a real trap.
- **HFPLL output enabled after a failed lock poll** (our boot log's
  `hfpll1 failed to lock (L_VAL 0)` proves the path live; vendor waits
  forever). Transition-path only; cannot explain the pinned death. Fix
  regardless.
- **APC config zeros** (`PWR_GATE_MODE`/`DLY`/`PWR_GATE_CONFIG` — the last
  now measured `0x0` vs vendor `0x0308736E`): with the hardware sequencer
  disabled, the likely consequence is a *shallower* collapse than the
  vendor's (clamps + reset, head switch never opened), i.e. electrically
  safer, not less. Parity item, not a reset mechanism on current evidence.

## 5. The test plan (revised)

Single variable per run, precondition verified in the log, thermal kept out of
the verdict:

1. **Idle baseline, `cpu-spc` enabled** — 45 min, `idle-monitor.py` sampling
   frequency, setpoint, collapse counters, temp, VBAT every 30 s. *In
   progress.* The §1.1 gate, and the "idle is clean" leg of the inversion
   argument.
2. **Load ladder at fixed frequency** (replaces the idle SPC-off arm, which the
   inversion argument demoted): four workers pinned at **300 MHz** (800 mV,
   lowest current). Survive 30 min ⇒ step up through 883.2 → 1190.4 →
   1497.6 with the same harness. Survival time falling with rising
   current/voltage ⇒ **electrical (S1)**; survival independent of rung ⇒
   logical bug in the load path. Each run logs the setpoint every sample — if
   `VCTL`/`PMIC_STS` ever moves during a pinned run, someone else is driving
   the rail (sequencer), which is its own answer.
3. **The port-2 PWM discriminator** (after the ladder, single variable): with
   the frequency pinned (no port-0 traffic), issue the vendor's own
   "FTS → PWM" command — L2 SAW `VCTL` port 2, data `0x80`, exactly what
   `krait-regulator.c` sends whenever a second core comes online — then rerun
   the deadliest ladder rung. Survives where it died ⇒ S1 convicted, and the
   fix is the vendor-parity port-2 write in the kernel. (Runtime poke is the
   *measurement*; the fix lands as a driver patch.)
4. **Identify the reset actor** (S4) — read the IMEM TZ diag region immediately
   after a load-induced reset via the safe syscon path; serial console attached
   for anything TZ prints on the way down.
5. **Only then design the fix** on whichever of S1–S4 the ladder, the
   discriminator and the PS_HOLD-actor analysis convict.

## 6. The warm-reset era (2026-07-26 late evening)

The PS_HOLD-actor analysis (audits file, report 4) landed three corrections
that were applied on the device the same evening:

- **Correction of our own forensics:** PM8941 is PON **gen1** — it has no
  `FAULT_REASON` registers, so the earlier "FAULT_REASON=0x00" reads were
  vacuous. The PMIC-side exclusion still holds via `POFF_REASON` itself
  (only the PS_HOLD bit ever sets; PMIC_WD/TFT/UVLO/OTST3/STAGE3 all clear).
- **Every reset until now was a PMIC hard reset** (`PS_HOLD_RST_CTL=7`, full
  rail cycle — lk2nd's setting), which by itself explains every failed
  ramoops attempt. The PMIC is now latched to **warm reset** (`085a: 01`,
  survives lk2nd and spontaneous deaths; a systemd unit keeps controlled
  reboots warm). Post-warm-death boots print **no PON line at all** — the
  rails now stay up through the deaths.
- **pstore/ramoops is closed permanently under lk2nd**: a pmsg canary was
  lost across a *verified* warm reset from both 0x0ff00000 and lk2nd's own
  scratch region 0x30f80000 — lk2nd/SBL reinitializes DDR on every boot
  path. (Android's working ramoops ran under the signed aboot.) All earlier
  "ramoops dead end" results are hereby explained: hard resets wiped DDR by
  construction; warm resets die to the bootloader's DDR reinit.
- **The TZ diag table is TZ-protected**: the readable IMEM window
  (0x720–0x7ff) holds a "TZDI" descriptor, four advancing per-CPU counters
  (0x738–0x744) and a small resetting counter (0x75c); the table proper at
  0xfe806000 **stalls HLOS reads** (reader wedges in D-state; the widened
  syscon window was reverted — do not re-widen). `reset_type` is not
  reachable from Linux on this firmware.
- **A hang cannot reset this SoC** (`WDT_EN=0`, nothing armed): the actor
  acts *proactively*. Remaining candidates: RPM `ERR_FATAL` on a rail/corner
  vote (best structural fit — and our `VDDCX_AO` + rate-graded corner votes
  are new in this fork), TZ `err_fatal` on a bus event (the `/dev/mem`
  family), a CX/MX-internal brownout, or a TZ-owned secure watchdog.

**Now running:** the idle SPC-off A/B (2 h, `state1/disable=1` verified and
logged every sample) against the 325–2132 s idle baseline — with warm reset
this now discriminates cleanly. Next avenues, in value order: an RPM-stats +
CX-corner fsync'd trace to catch a frozen RPM; a serial console on the
phone's UART for SBL/TZ warm-boot banners; a small module for the XPU
err-fatal SMC query.

## Update log

- **2026-07-26** — Created. Rig column complete (all resets UVLO, including at
  300 MHz). Phone vendor baseline captured. SPC-off 900 s pass recorded as
  suggestive; its A/B control inconclusive.
- **2026-07-26, later** — Reframed: 6.16 dropped as an invalid control, Android
  is the sole reference; added the field-by-field live diff (§2). New PROVEN
  results: the commanded setpoint tracks every OPP exactly; frequency alone does
  not reset; all 14 rungs are selectable (the "PIN FAILED" rows were a harness
  defect). Withdrew the "resets at idle" observation as contaminated. Both
  harnesses now settle-and-verify their preconditions and abort loudly. Clean
  idle baseline started.
- **2026-07-26, reassessment** — Fresh-eyes audit of the conclusions: (a) "rail
  not starved" narrowed to "setpoint correct, unloaded" — droop under load is
  unmeasured and fits the whole signature, promoted to S1; (b) SPC/collapse
  demoted: the load that kills barely collapses, the idle that collapses 29×/s
  is clean, and the rig's SPC-off run is inadmissible; (c) all 6.16-on-phone
  evidence excluded by ruling (§2.5); (d) reset forensics hardened: PMIC
  FAULT_REASON1/2 = 0x00, Linux watchdog inactive, IMEM reboot cookie empty —
  the PS_HOLD is deliberate and clean, actor unknown (S4). Plan revised: load
  ladder (survival vs current) replaces the idle SPC-off arm.
- **2026-07-26, evening — S1 (FTS mode / droop) refuted by the PWM
  discriminator**; death table §3.5 extended with two 300 MHz load deaths and
  the PWM-latched death. Every DVFS-adjacent hypothesis is now measured-clean
  or refuted: setpoint, voltage table, transitions, frequency, thermal,
  supply, regulator mode. Death rate tracks *activity* (~10–30× between idle
  and load) with wide scatter — a statistical process. **Critical path is now
  identifying the PS_HOLD actor (S4)**: an IMEM diff trap is armed to
  fingerprint the next spontaneous idle death, and the PS_HOLD-mechanism
  analysis is being pulled in. The prepared parity fixes (sec-mux map, HFPLL
  lock, local-timer-stop, APC config) stay queued behind the actor question.
- **2026-07-26, the idle baseline died — inversion argument RETRACTED.** The
  clean idle baseline (nothing else running, verified) reset at **t=2132 s**
  (35.5 min): all cores 300 MHz, rail 800 mV = correct, 47 °C, VBAT 4.22 V,
  SPC ~30/s per core — same clean PS_HOLD, `bootstatus=0`, last sample
  fsync'd 30 s before death. So **idle dies too, ~30–60× slower than load**
  (35 min vs 30–120 s). Consequences: the load/idle inversion used to demote
  collapse in the previous entry is void; the TZ-concurrency hypothesis is
  now *contradicted in direction* (it predicts idle — far more concurrent
  collapse — dies faster, and it dies slower); the FTS-PFM hypothesis (S1)
  *gains* — PFM tolerates idle current with occasional wake-inrush glitches
  and fails quickly under sustained load, and Android (PWM forced whenever
  >1 core online) is immune at any temperature. Note the rig showed the same
  *pattern* (idle 17–25 min, load seconds-to-minutes) beneath its genuine
  UVLO problem. The idle SPC-off arm is back on the menu as a follow-up A/B
  against this 35-min baseline; ladder first (bigger expected effect).

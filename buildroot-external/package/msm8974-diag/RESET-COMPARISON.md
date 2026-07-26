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

## 4. The surviving hypotheses (reassessed 2026-07-26 afternoon)

The reset is **SoC-initiated and clean**: PM8941 `FAULT_REASON1/2 = 0x00` (no
PMIC watchdog, no OTST3, no input UVLO recorded), the Linux watchdog is
`inactive` with `bootstatus=0`, and the IMEM reboot-mode cookie is empty.
Something outside Linux — TZ, a secure watchdog, or the RPM — pulled PS_HOLD,
or was asked to. The discriminating observation across all admissible runs:
**load kills, idle does not**, even though idle exercises power collapse ~29×/s
and load barely exercises it at all.

**S1 — rail droop under sustained load (electrical, in-spec setpoint).
Promoted to top suspect.** Everything "proven" about the rail is about the
*commanded* setpoint, unloaded (§3). If our FTS2 (pm8841 S2) configuration
differs from the vendor's under load — regulator mode (PWM vs auto/PFM), phase
count, or a sequencer-applied sleep mode never restored — the rail sags under
4-core current, cores fail timing and hang, and something resets the SoC with
exactly the observed clean forensics. Fits: load-kills/idle-clean, no PMIC
fault, worse under more load. Test: survival-vs-current ladder (below); audit
what the armed L2 SAW sequencer's `pmic_data[1]` mode write does.

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
3. **Identify the reset actor** (S4) — read the IMEM TZ diag region immediately
   after a load-induced reset via the safe syscon path; serial console attached
   for anything TZ prints on the way down.
4. **Only then design the fix** on whichever of S1–S4 the ladder and the vendor
   BSP analyses (four running in parallel) convict.

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

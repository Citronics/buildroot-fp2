# FP2 resets: the live comparison, and what could still cause them

A working document for the comparison currently in progress. It exists because
this investigation repeatedly mistook a single measurement for a conclusion, so
every claim below is tagged with what it rests on:

- **PROVEN** — measured directly, reproducible or corroborated by a second source
- **SUGGESTIVE** — one measurement, consistent but not yet repeated or controlled
- **RULED OUT** — a measurement contradicts it
- **OPEN** — no measurement yet

Update this file as results land. Do not delete superseded claims; move them to
the closed list with the evidence that closed them, because knowing what was
already excluded is what stops the loop from repeating.

## The two boards

| | **rig** | **phone** |
|---|---|---|
| hardware | bare FP2 motherboard on a Citronics Lime carrier | complete handset |
| power | carrier feeds VBAT directly, **no battery** | **real battery** |
| silicon | soc_id 217 (MSM8974PRO-AA) rev 1.1, speed bin 1, **PVS 12** | same soc_id/rev/bin, **PVS 9** |
| network | USB-ethernet via on-board hub | wifi/modem |
| access | ssh over ethernet | adb (root, userdebug) |

Same SoC and same speed bin. The PVS difference is expected to change voltages
by 15-20 mV (our DT carries both columns), not behaviour.

## The comparison matrix

| kernel | on the rig | on the phone | what the pair proves |
|---|---|---|---|
| vendor 3.4 (Android) | n/a | **DONE** | the platform's own reference behaviour |
| our 6.16 (no CPU DVFS) | **DONE** | *pending* | whether a good supply changes a DVFS-less kernel |
| our 6.18 (with our DVFS) | **DONE** | *pending* | **the decisive cell**: isolates our kernel from the supply |

The rig column is complete and the rig fails in it. The phone column is what
separates "our kernel is broken" from "that rig's supply is broken", and only
the bottom-right cell can do that.

## Measurements so far

### Rig, our 6.18 (`gaa55b1b242a1`, Android's 14 OPPs, no margin)
| configuration | outcome |
|---|---|
| 4 cores, ceiling 1497.6 MHz | UVLO reset, 313 s |
| 4 cores, ceiling 883.2 MHz | UVLO reset, **89 s** |
| 4 cores, ceiling 422.4 MHz | UVLO reset, 572 s |
| 4 cores, ceiling **300 MHz** (lowest OPP) | UVLO reset, 743 s |
| 2 cores pinned 1728 MHz | **survived 600 s**, VBAT min 4.023 V |
| 4 cores pinned 1728 MHz | UVLO reset, 40 s |
| 4 cores pinned 883.2 MHz, **cpu-spc disabled** | **survived 900 s**, spc usage frozen |
| 4 cores pinned 883.2 MHz, cpu-spc enabled (A/B control) | **INCONCLUSIVE** - log stops at t=5 s and the next boot reports `pon_reason=0x80` (power key), not UVLO, so a manual power-cycle cannot be excluded. **Re-run needed.** |

Every reset above reported `poff=0x2000` (**UVLO**). VBAT steady-state stayed
4.2-4.4 V with one captured sample at **3.421 V**, essentially at the pm8941
lockout threshold.

### Phone, vendor Android 3.4
| configuration | outcome |
|---|---|
| 4 cores, 1.5-2.27 GHz, 60 s | **no reset**, 81-83 C, VBAT steady 3.93-3.98 V |

Roughly six times the aggregate clock of the load that kills the rig, at a
*lower* absolute rail voltage, with no instability.

## Hardware candidates

**H1 — feed impedance / insufficient bulk capacitance at the pads. SUGGESTIVE,
current hardware lead.**
A battery is milliohms and instantaneous; a wired feed through a connector is
tens to hundreds of milliohms with inductance, and a bench supply's loop recovers
in milliseconds - far slower than a four-core load step. Supports: steady-state
rail is healthy while a captured transient reached 3.421 V; the phone with a
battery is immune at 6x the load. Against: nothing yet. Settled by a scope at the
FP2's own VBAT pads during a load step, or by adding low-ESR bulk capacitance and
re-running.

**H2 — intermittent or degrading board-to-carrier contact. SUGGESTIVE.**
Supports: failures grew more frequent across the session; MTBF scatters wildly
(89 s to 743 s) in a way a threshold does not explain. Settled by reseating and
by measuring DC drop across the feed under load.

**H3 — supply transient response. OPEN.**
Many bench supplies have poor step response. Same discriminator as H1.

**H4 — average current limit. RULED OUT.**
2 cores at 1728 MHz (more power) survived 600 s while 4 cores at 300 MHz (about
4x less CPU power) failed at 743 s. A current ceiling would order those the other
way. Also `smbb-dcin`/`smbb-usbin` are both `online=0` with battery `present=0`,
so nothing in the path is current-limiting - and there is therefore no software
knob to raise.

**H5 — thermal. RULED OUT.**
Failures occur at 48-69 C, far below the 90 C passive trip; the phone is fine at
82 C. Stock Android takes no frequency action at 90 C at all.

**H6 — PMIC over-temperature. RULED OUT.**
Our PM8941 zone trips (105/125/145 C) are identical to the vendor's
`qcom,threshold-set = <0>`.

## Software candidates

**S1 — core power-collapse inrush is never staged. SUGGESTIVE, current software
lead.**
The vendor programs `APC_PWR_GATE_DLY = 0x30430600` and
`APC_PWR_GATE_MODE = 0x21` to stagger the BHS head switch precisely to limit
inrush. Measured on both our 6.18 **and** the stable 6.16: both registers read
**0**, and KPSS `VERSION = 0x20010000` puts this part above the threshold where
those are the registers that decide the mode. Supports: with `cpu-spc` disabled -
which removes collapse-exit entirely - the rig survived 900 s at a rung whose
recorded baseline was 89 s, with the idle counter provably frozen. Against: one
observation only, against MTBFs that scatter to 743 s; the A/B control is
inconclusive. Note this cannot be the whole story on its own, because 6.16 shares
the unwritten registers and is stable - but 6.16 also never scales the rail.
Settled by repeating the SPC-off run and getting a clean SPC-on control, then by
programming the vendor values and keeping collapse enabled.

**S2 — the L2 rate is never scaled. OPEN.**
`krait-cc` restores whatever the bootloader left (729.6 MHz here) and nothing
consumes `<&kraitcc 4>`. The phone shows the vendor running the L2 at 1497.6 MHz
with the fastest core at 1267.2 MHz, and voting the CX corner from that rate.
A DT-only test branch exists (`6.18/test/l2-rate-pin`).

**S3 — voltage table or margin. RULED OUT.**
Our per-bin column matches the vendor table for this die on all 28 rungs, the
driver selects it via `prop_name`, and the invented 100 mV margin both failed to
help and cancelled itself on specific transitions (fixed and removed). 200 mV
made MTBF worse and added ~20% heat.

**S4 — MX/CX starvation. RULED OUT.**
The vendor votes MX only for MSS and pronto; msm8974 has no MX power domain in
`rpmpd`; `MSM8974_VDDMX` does not exist in the bindings. On the phone MX sits at
675 mV **disabled**. And the CX vote does arrive on our kernel: `cx_ao` reads
`on` at performance state 6.

**S5 — the modem. RULED OUT.**
Disabled at DT level (verified `status = "disabled"`, only wcnss and adsp
present) and the rig still reset 8 s into an idle boot.

**S6 — AVS tracking the rail down. RULED OUT.**
`AVS_CTL = 0` on all five SAWs on the rig; the bootloader never arms it. The
truncated-window defect in our setter was real but latent, and is fixed.

**S7 — HFPLL misprogramming. RULED OUT.**
Config value, VCO mask, user value, switch point and offsets are vendor-exact,
and the probe recorded 0 unlocked-output samples across 90 s of hammering.

**S8 — mutex in atomic context on the DVFS path. FIXED, and it invalidates older
data.**
`rc` lacked `.fast_io` on the HFPLL regmap while callers hold a spinlock with
interrupts disabled. Every soak before `e8333aa71532` ran with that.

## What each pending test discriminates

1. **Re-run SPC-off, then a clean SPC-on control on the rig.** Turns S1 from
   suggestive into proven or dead. Cheap, runtime-only, no rebuild.
2. **Our 6.16 on the phone.** If it is stable (expected), it confirms the phone
   as a working reference and gives the DVFS-less control on a good supply.
3. **Our 6.18 on the phone — the decisive test.** Stable ⇒ our kernel is clean
   and the rig's supply was the whole story. Unstable ⇒ a genuine kernel defect,
   isolated for the first time on hardware that is not power-starved.
4. **Scope on the rig's VBAT pads**, or adding bulk capacitance. Settles H1/H2/H3
   and is the only thing that makes the rig usable for kernel work again.

## Update log

- **2026-07-26** — Created. Rig column complete (all resets UVLO, including at
  300 MHz). Phone vendor baseline captured. SPC-off 900 s pass recorded as
  suggestive; its A/B control inconclusive (possible manual power-cycle). Next:
  6.16 on the phone.

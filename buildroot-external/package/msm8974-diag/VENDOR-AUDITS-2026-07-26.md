# Vendor-BSP audits, 2026-07-26 — full reports

Three parallel source audits of the vendor Android BSP against this fork,
run while isolating the phone's PS_HOLD reset (see `RESET-COMPARISON.md` for
the evidence model these plug into). Kept verbatim because the file:line
citations are the part that ages well; a fourth analysis (what can assert
PS_HOLD on MSM8974) was still running when this was written and gets appended
when it lands.

Provenance shared by all three:

- **Vendor** = `FairphoneMirrors/android_kernel_fairphone_msm8974`, branch
  `int/10/fp2` (Linux 3.4.113), FP2's effective DT being the
  `msm8974pro-ab-pm8941-mtp.dts` include chain.
- **Ours** = this fork at `6.18/staging` (v6.18.40 base).
- Claims tagged **PROVEN** (vendor code/DT says so) or **INFERRED**.

Headline synthesis (details in the reports):

1. Our SPM programming is **byte-exact vendor** — sequences, `spm_cfg`,
   `spm_dly`, `pmic_data0/1`, init `SPM_CTL` all match. Exonerated.
2. Two audits converge on the same omission as top suspect: **the Krait gang
   FTS PWM/PFM mode is never commanded** (vendor forces PWM via L2 SAW VCTL
   port 2 whenever >1 core is online; we only write port 0). The SAW's
   `pmic_data0/1` are exactly the PWM/PFM command bytes.
3. Exonerated along the way: clk concurrency, voltage↔rate ordering, shared
   rail aggregation, phase count (we set the vendor's max, 4 phases), CPU0's
   head switch, MDD/VREF zeros (BHS-only config), the static L2 as a reset
   cause, OPP voltages, the CX corner.
4. Real defects found that do NOT explain the pinned-frequency death (parity
   fixes once the main bug is convicted): inverted sec-mux parent map (can
   program QSB), HFPLL output enabled after a failed lock poll, `cpu_spc`
   missing `local-timer-stop` (Krait-wide mainline DT bug), `PWR_GATE_CONFIG`
   zero, unserialized `TERMINATE_PC`.

Device measurements taken alongside (this fork, real FP2, kernel
`g86d3fa288686`): per-core `PWR_GATE_CTL=0x403f3f7f` on all four cores
(pure BHS, LDO down — cpu0 included); `PWR_GATE_MODE/DLY = 0`,
`MDD_* = 0`, `PWR_GATE_CONFIG = 0` vs vendor `0x0308736E`;
`KPSS_VERSION = 0x20010000`; per-core SAW `SPM_CTL` sampled `0x31/0x1`;
L2 SAW setpoint == OPP requirement on every rung swept (unloaded);
PM8941 `FAULT_REASON1/2 = 0x00` after a load reset; Linux watchdog
`inactive`, `bootstatus=0`; IMEM reboot cookie empty; pm8841 APC
peripherals (S5–S8) unreadable from HLOS (SPMI ownership filter).

---

## Report 1 — SPM/SAW sequencer vs vendor

### Vendor reference obtained

`FairphoneMirrors/android_kernel_fairphone_msm8974` @ `int/10/fp2`, sparse.
FP2 DTB chain confirmed: `msm8974pro-ab-pm8941-mtp.dts` →
`msm8974pro-ab-pm8941.dtsi` → `msm8974pro-pm8941.dtsi` → `msm8974pro.dtsi` →
`msm8974pro-pm.dtsi` (all five SAW nodes) + `msm8974-regulator.dtsi`.

**Headline: the SPM programming itself is exonerated. Every sequence byte,
`spm_cfg`, `spm_dly`, `pmic_data0/1`, and the init `SPM_CTL` value in
`drivers/soc/qcom/spm.c` are byte-exact against the vendor's FP2 DT.** The
PS_HOLD candidates are all *adjacent* to the SAW: things the vendor does
through the SAW, or alongside it, that we never do.

### 1. SAW2 SPM byte-code

What the vendor sources actually prove:

| Fact | Evidence |
|---|---|
| `0x0F` = END of program; sequences are byte streams packed LE into 32-bit words at SAW2+0x80 | `arch/arm/mach-msm/spm-v2.c:275,280` (copy loop breaks on `last_cmd == 0x0f`); `spm-v2.c:83` |
| Start address in `SPM_CTL` is a **7-bit byte** index (0..127), bits [10:4] | `spm-v2.c:111-114` (`addr &= 0x7F; addr <<= 4;` mask `0xFFFFF80F`) |
| `0x03` = halt/sleep-wait, **no** RPM notify; `0x07` = same **+ RPM sleep handshake** (bit `0x04` = notify RPM) | Triple-proven: `msm8974pro-pm.dtsi:30` (spc) vs `:32` (pc) — 18 bytes identical except byte 6; tagged `notify_rpm` 0/1 at `spm_devices.c:393-394`. Also `msm8226-v2-pm.dtsi:98-106` and `board-8064.c:2083` vs `:2103` |
| One field asserts **apc_pdn** (APC head-switch power-down) | `board-8064.c:2108` comment "*8064AB has a different command to assert apc_pdn*" — the only delta in that pair is `0x54`→`0x84` |

Encoding model — INFERRED: `byte = (field[7:4] << 4) | value[3:0]`. Field
`0x0` is the sequencer's own control field (`0x03` halt, `0x07` halt+RPM,
`0x0F` end). Fields `0x1`–`0xF` drive control outputs. Disambiguation: within
one program the descent and ascent halves reuse the **same high nibble with
different low nibbles** (`msm8974-v1-pm.dtsi:31-32`,
`msm8974pro-pm.dtsi:124-125`), which fits a descend/ascend power sequencer and
not the reverse convention.

**Not determinable:** which output each field 0x1–0xF drives. No mnemonic
table, macro, or comment anywhere in the vendor tree.

Our two sequences, byte by byte — PROVEN identical to vendor:

- **Per-CPU** (`drivers/soc/qcom/spm.c:249-251`): `03 0B 0F` at offset 0 ==
  `qcom,saw2-spm-cmd-wfi` (`msm8974pro-pm.dtsi:28`); the 18 bytes at offset 3
  == `qcom,saw2-spm-cmd-spc` (`:30-31`) — descent, halt **without** RPM notify
  (correct for standalone PC), ascent, END. We deliberately omit the vendor's
  `-cmd-ret`; nothing points at it.
- **L2** (`spm.c:270`): `1F 00 03 00 0F` == `qcom,saw2-spm-cmd-ret` for
  core-id 0xffff (`msm8974pro-pm.dtsi:122`). Halt is `0x03`, so an autonomous
  L2 retention entry **cannot** tell the RPM to enter system sleep. Both our
  `start_index[]` entries are 0, so the retention program is the only
  reachable L2 program — same as the vendor. `0x1F` appears only on 8974's
  L2; 8226/8610 ship `00 03 00 0f`. Its function is not determinable.

### 2. `pmic_data0/1`, and every path that can write the Krait rail

PROVEN:

- Values are vendor-exact: `0x02030080` / `0x00030000` at
  `msm8974pro-pm.dtsi:116-117`.
- Semantics per binding: "*specify the pmic data value and the associated FTS
  index to send the PMIC data to*"
  (`Documentation/devicetree/bindings/arm/msm/spm-v2.txt:34-35`). They are
  pre-staged PVC/SPMI payloads.
- On SAW2 **major 2** (our silicon) the vendor's voltage path never touches
  them: `msm_spm_drv_set_vctl2()` writes **only** `VCTL`, masking `0x700FF`
  (`spm-v2.c:144-160`). Our driver splits identically. **Match.**
- `VCTL` layout is `{data[7:0], port[18:16]}`, and `PMIC_STS` only reflects
  port-0 writes (`spm-v2.c:150-153`, `:468-474`). FP2 port map: **0 =
  voltage, 1 = phase count, 2 = PWM/PFM mode** (`msm8974pro-pm.dtsi:119-121`).
- **The two data bytes are exactly the vendor's FTS mode constants:**
  `PMIC_DATA_0 = 0x020300`**`80`** with `#define PMIC_FTS_MODE_PWM 0x80`
  (`krait-regulator.c:456`); `PMIC_DATA_1 = 0x000300`**`00`** with
  `#define PMIC_FTS_MODE_PFM 0x00` (`:455`).

INFERRED (strongly supported): `PMIC_DATA_0/1` are the pre-staged "**put the
Krait FTS in PWM**" and "**put it in PFM**" commands the sequencer can issue
autonomously. So the sequencer has a path to write the Krait rail behind the
regulator's back — but what it writes is a **mode** (PWM↔PFM), not a
sleep/retention setpoint.

Complete list — every way the Krait gang rail can be written:

| # | Path | Vendor | Ours |
|---|---|---|---|
| 1 | `VCTL` port 0 = FTS selector (setpoint) | `spm-v2.c:358-418` ← `krait-regulator.c:769` | `spm.c:476-535` ✔ |
| 2 | `VCTL` port 1 = phase count − 1 | `msm_spm_apcs_set_phase` `spm_devices.c:314-321` ← `krait-regulator.c:402-413`, **dynamic 1/2/4 by load** | one hardcoded `writel_relaxed(0x10003, l2_saw_base + 0x1c)` = port 1, data 3 → 4 phases, `arch/arm/mach-qcom/platsmp.c:274-275`, once per secondary release |
| 3 | `VCTL` port 2 = FTS PWM/PFM mode | `msm_spm_enable_fts_lpm` `spm_devices.c:327-334` ← `krait-regulator.c:485` (→PFM) / `:499` (→PWM) | **never written by anything** |
| 4 | SPM sequencer issuing `PMIC_DATA_0/1` | L2 sequencer armed EN=1 with both loaded | identical |
| 5 | AVS hardware tracking | disabled (`msm8974pro-pm.dtsi:110-112`) | disabled (`spm.c:703-706`) ✔ |
| 6 | *(per-core, not gang)* LDO/BHS head switch + MDD | `krait-regulator.c:81-95, 597-675, 1157-1198` | only `APC_PWR_GATE_CTL` at CPU release, `platsmp.c:107, 258-272` |

### 3. `spm_cfg` / `spm_dly` / `start_index` comparison

Per-CPU (vendor `msm8974pro-pm.dtsi:14-34`; ours `spm.c:245-254`): CFG, DLY,
SPM_CTL init and the wfi start address all match. SPC start address differs
numerically (vendor 16, ours 3) because we omit `ret` — **same target
program**, harmless. Deltas: vendor zeroes `AVS_CTL/LIMIT/DLY/HYST` and
`PMIC_DATA_0..7` at init (`spm-v2.c:524-525`), our offset table never maps
them so they are never written (see Rank 4).

L2 (vendor `msm8974pro-pm.dtsi:102-127`; ours `spm.c:264-277`): CFG `0x14`,
DLY, SPM_CTL init `0x1`, `pmic_data0/1`, AVS 0/0, ret start 0 — all match.
Benign deltas: AVS_DLY/HYST never written; our vctl poll 200 µs vs vendor
50 µs. **No consequential mismatch.**

### 4. Does the vendor arm the L2 SAW EN bit in normal operation?

PROVEN: yes — permanently, from init, with the retention program selected
(`qcom,saw2-spm-ctl = <0x1>` for core-id 0xffff, flushed in
`msm_spm_drv_init`). During operation only the **index** moves
(`lpm_set_l2_mode` → `msm_spm_dev_set_low_power_mode`), and on exit the
default `l2_cache_retention` is restored. EN is cleared only for
`MSM_SPM_MODE_DISABLED`, which the 8974 lpm path never requests. Per-CPU SAWs:
`0x01` at init and after **every** wake, index → ret/spc/pc on entry; restore
is explicit and unconditional (`msm-pm.c:588`, `:450`, `hotplug.c:187`); ours
does the same (`cpuidle-qcom-spm.c:55`). **Match.** Useful precedent: the
vendor ships **EN=0** on the L2 for 8226/8610 (`msm8226-v2-pm.dtsi:91`,
`msm8610-v2-pm.dtsi:91`) — arguably the correct configuration for a kernel
that never uses L2 low-power modes.

### 5. Decoding `SPM_CTL = 0x31` vs `0x1`

PROVEN: bit0 = EN; bits[10:4] = 7-bit byte start address. `0x01` = EN, start 0
(our wfi program); `0x31` = EN, start 3 (our spc program). cpu0/2/3 were armed
for standalone power collapse and cpu1 for plain WFI at the instant sampled —
benign if sampled mid-idle, a lost STBY restore if it persists while 100 %
busy (test T5). Bits[3:1] zero in both; 8226/8610 ship `0x8` so bit3 is a real
but undocumented control bit.

### Ranked candidates (report 1)

**Rank 1 — TZ power-collapse handoff is unserialized (PROVEN delta).** Vendor
takes a remote spinlock (shared with the secure monitor) around
`SCM_CMD_TERMINATE_PC`, released by TZ itself, "*so that both Linux and the
secure context have a consistent view regarding the number of running cpus*"
(`msm-pm.c:500-511, 524`), enabled because FP2 sets
`qcom,allow-synced-levels` (`msm8974pro-pm.dtsi:131`). Ours:
`qcom_cpu_spc()` → `qcom_scm_cpu_power_down()` with no lock, no core
counting. Test T1: disable `state1` on all cores, re-soak — bisects the whole
report (ranks 1, 2, part of 3/4).

**Rank 2 — Krait per-core head switch, MDD and the hardware sequencer never
initialized (PROVEN delta).** Vendor writes per core `MDD_CONFIG_CTL=0x190`,
`MDD_MODE=0x2` (`krait-regulator.c:1160-1162`), `APC_PWR_GATE_DLY=0x30430600`
(`:1167`), `APC_PWR_GATE_MODE=0x21` (`:1170`, "*Enable the hardware sequencer
in BHS mode*"; mode field also has `_PC=0`, `_RET=4` — **the states the SAW's
SPC/retention program drives the head switch into, and only if bit0 is
set**), and `PWR_GATE_CONFIG=0x0308736E` at APCS GCC `0xf9011044` (`:1195`).
Ours writes only `APC_PWR_GATE_CTL` using the pre-KPSS-2.0 recipe. Test T2:
read-only dump (done — all zeros confirmed, `PWR_GATE_CTL` pure BHS on all
four cores).

**Rank 3 — the FTS PWM/PFM mode is never commanded (PROVEN delta).** Vendor
forces PWM via port 2 whenever load > `qcom,pfm-threshold = <76>`
(`msm8974-regulator.dtsi:466`) or more than one core is online, *before*
raising phases, with a 50 µs settle (`krait-regulator.c:481-508`). We never
write port 2. Our L2 SAW is armed with `PMIC_DATA_1` = the PFM command. If
the FTS ends up in PFM, a 4-core current step produces droop that `PMIC_STS`
cannot see. Test T3: read the FTS mode over SPMI (**attempted — blocked by the
SPMI ownership filter, reads as zero**); runtime alternative: clear L2 SAW EN
(`0xf9012030 = 0`, precedent 8226/8610), or command PWM via port 2 and A/B.

**Rank 4 — per-CPU SAW AVS_*/PMIC_DATA_* left at bootloader values (PROVEN
delta).** Vendor zeroes all of them on every SAW at init; our offset table
never maps them. Test T4: read SAW2_ID bit 2 ("PMIC arbiter present") and
`PMIC_DATA_0/1` on the per-CPU SAWs — nonzero on an arbiter-present SAW = a
live second writer on the gang rail.

**Rank 5 — the phase write is an unsynchronized raw VCTL poke racing DVFS
(PROVEN delta).** `platsmp.c:275` writes `0x10003` with no PMIC-FSM-idle poll
and no exclusion against port-0 voltage writes; vendor routes through
`msm_spm_drv_set_pmic_data()` which polls the FSM idle (`spm-v2.c:475-486`).
Bring-up/hotplug only; low probability, catastrophic outcome (data `0x03` on
port 0 would be selector 3 ≈ 15 mV). Test T5: sample the five SPM_CTLs +
VCTL/PMIC_STS under sustained load.

**Could not determine (report 1):** per-field semantics of opcodes
0x10–0xFF; whether any byte of `1f 00 03 00 0f` triggers a `PMIC_DATA_n`
send; exact `PMIC_DATA_n[31:8]` layout; `SPM_CTL` bits[3:1]; the register
spec of `APC_PWR_GATE_MODE` bit 0; what lk2nd actually leaves in the APC/MDD/
FTS-mode/per-CPU-SAW registers; who asserts PS_HOLD; whether this build
enables `cpuidle-qcom-spm` (it does — confirmed on device).

---

## Report 2 — power-collapse / cpuidle vs vendor

FP2 config facts that prune the search space, PROVEN:
`fairphone_defconfig:446` `# CONFIG_MSM_AVS_HW is not set` (AVS save/restore
around collapse is a no-op on FP2); `:496` `# CONFIG_MSM_JTAG is not set`;
`:543` `CONFIG_KRAIT_REGULATOR=y`, `:461`
`# CONFIG_MSM_SPM_REGULATOR is not set` (the per-core krait regulators *are*
the FP2 path).

PROVEN identical, so *not* deltas: the per-CPU SAW2 SPC microcode; the L2 ret
sequence and pmic-data; `spm-ctl=0x1`/`cfg=0x14`; the secondary-release
`CPU_PWR_CTL` write order 0x21→0x20→0x00→0x80 (`V/platsmp.c:145-170` ==
`F/platsmp.c:279-295`). ARM generic code covers two suspicions:
`suspend.c:99` does `flush_cache_louis()` and `sleep.S:129` does
`bl cpu_init` — both not deltas.

### 1. Vendor collapse ENTRY/EXIT, in order (standalone_pc = our `cpu-spc`)

Entry: (1) `lpm_cpu_prepare()` → `CLOCK_EVT_NOTIFY_BROADCAST_ENTER` — **hands
the tick to the always-on broadcast timer** (`lpm_levels.c:666-680`);
(2) AVS save/clear — no-op on FP2; (3) `cpu_pm_enter()` → GIC CPU-IF/PPI +
`CNTKCTL` saved; (4) `msm_spm_set_low_power_mode(POWER_COLLAPSE,
notify_rpm=false)` → SAW start index = spc, EN=1; (5) boot vector =
`cpu_resume` (`pm-boot.c:71-100`); (6) jtag save — no-op; (7)
`cpu_suspend(0, msm_pm_collapse)`; (8) in the finisher: `cpu_cnt_lock`,
`cpu_count++`, last-core L2 flag, then **acquire the SMEM remote spinlock
`scm_handoff_lock` before dropping `cpu_cnt_lock`; released by the secure
monitor** (`msm-pm.c:491-510`, enabled by `qcom,allow-synced-levels`);
(9) L1 flush, L2 stays on; (10) debug counter; (11)
`scm_call_atomic1(SCM_SVC_BOOT, SCM_CMD_TERMINATE_PC, MSM_SCM_L2_ON)` — TZ
does the final gate; the SAW2 microcode executes on WFI. (12) **Nothing on
this path writes `APC_PWR_GATE_CTL`, MDD, `LDO_VREF_SET`, the gang rail, or
the phase count** — those writes exist only in `krait-regulator.c`
probe/hotplug/mode-switch paths. INFERRED: the head-switch transition itself
is executed by the APC hardware sequencer armed at `krait-regulator.c:1167-1170`.

Exit: TZ warm-boots to `cpu_resume`; fall-through counter; `cpu_count--` with
`BUG_ON`; jtag restore; `cpu_init(); local_fiq_enable()`;
`boot_config_after_pc` (NULL in tz mode); `cpu_pm_exit()`;
`msm_spm_set_low_power_mode(CLOCK_GATING)`; AVS restore;
`lpm_cpu_unprepare()` → `BROADCAST_EXIT`, local timer reprogrammed.

On CPU **hotplug** up the full APC re-init runs: `secondary_cpu_hs_init()`
(`krait-regulator.c:1662-1743`).

### 2. `PWR_GATE_MODE=0x21`, `PWR_GATE_DLY=0x30430600`

PROVEN (`krait-regulator.c:136-143, 1165-1171`): bits[6:4] =
`PWR_GATE_SWITCH_MODE` (`PC=0, LDO=1, BHS=2, DT=3, RET=4`); `0x21` =
BHS + bit0 ("hardware sequencer enable"). On `version > 0x20000000` (ours
0x20010000) the LDO/BHS switch collapses to a single write of that mode field
(`:602-611`, `:671-680`) — the hardware owns the switch on our silicon.
`PWR_GATE_DLY` layout NOT DETERMINABLE (only the two writes exist; INFERRED a
per-transition delay profile). With both zero on a 0x20010000 part: PROVEN
that BHS-vs-LDO is then decided by software via `APC_PWR_GATE_CTL` — and our
measured `0x403f3f7f` decodes as `BHS_CNT=64, LDO_PWR_DWN=0x3f, LDO_BYP=0x3f,
BHS_SEG_EN=0x3f, BHS_EN=1` = pure BHS, LDO powered down — the same electrical
endpoint the vendor's mode=BHS reaches. Inrush at CPU release: staged
identically to the vendor. Inrush at collapse exit: NOT DETERMINABLE;
INFERRED that with the sequencer disabled there is no programmed PC→BHS
profile and the more likely reading is the head switch is *never opened at
all* — i.e. our "power collapse" may be clamps+reset only, **shallower** than
intended, rather than an unstaged re-close.

### 3. `MDD_CONFIG_CTL=0x190`, `MDD_MODE=0x2`

PROVEN: `0x190` = "*setup the bandgap that configures the reference to the
LDO*"; `0x2` = enable, 5 µs settling; needed "*when the core switches to LDO
mode*" (`krait-regulator.c:1659-1660`). PROVEN-negative for our
configuration: all four cores are hard-wired BHS with the LDO powered down and
no SPM retention programmed. INFERRED residual: anything selecting LDO/RET on
a core with MDD off and `VREF_RET=0` browns that core out; needs an external
trigger; low probability.

### 4. Collapse with the gang rail high; rail↔collapse ordering

PROVEN, yes to both: the vendor routinely collapses one core while three run
at 1.5–2.27 GHz on a high gang rail and does not lower the rail for collapse.
Ordering rules: increase = gang first, wait `(vmax-old)/2395` µV/µs, then
switch per-core modes; decrease = force BHS first, then lower the gang;
retention disabled whenever the gang would go below 825 mV, with a cross-core
IPI (`msm-pm.c:868-901`).

### 5. Per-core regulator vs our shared gang rail — what we omit

(a) per-core LDO mode below 850 mV — power only; (b) MDD — §3; (c) **DLY +
MODE=0x21 on every core — changes what the APC does at collapse/restore**;
(d) **`PWR_GATE_CONFIG` (APCS GCC + 0x44) = `0x0308736E`** for v>2.0
("configure bi-modal switch") — measured **0** on our device; (e)
`VREF_LDO/VREF_RET` init — §3; (f) phase count/PFM↔PWM — **false lead for
phases**: our `platsmp.c:275` sets the vendor's maximum (4 phases) and we
never enter PFM *by our own action* (mode is bootloader-inherited, see report
1 rank 3); (g) `force_bhs` across hotplug — we never use LDO; (h) MDD across
suspend.

Complete absence in the fork, verified by grep: no reference anywhere to
`PWR_GATE_CONFIG`, `PWR_GATE_MODE`, `PWR_GATE_DLY`, `MDD_*`, `LDO_VREF_SET`.

### 6. Exit-restore code we have no equivalent of

Hotplug exit: `secondary_cpu_hs_init()` = staged BHS + MDD/DLY/MODE + 4
phases; ours reproduces the staged BHS and phases but not MDD/DLY/MODE.
Idle exit: the vendor has **no per-core switch/MDD restore at idle-collapse
exit at all** — INFERRED: the vendor's answer to "who re-closes the head
switch after an idle collapse" is the APC hardware sequencer, the one thing we
never arm. And one thing we genuinely lack: `lpm_cpu_unprepare()`'s
`BROADCAST_EXIT`.

### Ranked (report 2)

**#1 — `cpu-spc` missing `local-timer-stop` → per-core arch-timer comparator
silently lost across collapse.** PROVEN config mismatch: our `armv7-timer` has
no `always-on` → `arch_timer_c3stop=true` → `CLOCK_EVT_FEAT_C3STOP`; our
`cpu_spc` has no `local-timer-stop` → cpuidle never calls
`tick_broadcast_enter/exit`; nothing saves `CNTP_CVAL/CNTP_CTL`. The vendor
always hands the tick to broadcast; upstream's own `qcom,idle-state-spc` on
msm8916/8939/8976/8917/qcm2290 declares `local-timer-stop` (apq8064/8084 are
missing it too — a mainline Krait-wide oversight). INFERRED reset chain via
watchdog bite. *[Post-audit device evidence: idle sample timestamps land at
30.04 s intervals through ~29 collapses/s, and the APSS watchdog is inactive
with bootstatus=0 — both legs of the proposed chain fail on this device; kept
as a correctness/parity fix, demoted as the cause.]* Test: pinned
`nanosleep(3 ms)` overshoot loop per CPU + `tick_broadcast_oneshot_mask` vs
climbing `state1/usage`.

**#2 — No serialization of concurrent `TERMINATE_PC`.** PROVEN vendor
requirement (SMEM remote spinlock, `qcom,allow-synced-levels`), INFERRED
consequence (TZ-side inconsistency → PS_HOLD). Test: disable state1 on
cpu1-3 only, leave cpu0's enabled; survival ≫900 s with cpu0's usage still
climbing = concurrency, not collapse itself.

**#3 — APC hardware sequencer never armed + `PWR_GATE_CONFIG` never
programmed.** INFERRED. Test: read `0xf9011044` (done — reads 0) and the
ordered write experiment (MDD → DLY → MODE, never MODE first).

**#4 — MDD unconfigured + `VREF_RET=0`.** PROVEN omission, INFERRED (low)
risk. Test: write `0x190`/`0x2` (vendor holds them on continuously — no-risk
write), re-soak.

**#5 — rail↔collapse ordering** — PROVEN not applicable (no LDO, no SPM
retention; our `ramp_delay=1250` is more conservative than vendor 2395).
Test: re-read `PWR_GATE_CTL`/`MODE` after a soak for drift.

**#6 — phases** — PROVEN non-issue.

**Could not determine (report 2):** SAW2 microcode byte encoding;
`PWR_GATE_DLY` layout; `PWR_GATE_CONFIG` bits[25:24]; whether TZ enforces the
handoff-lock protocol; whether Krait really loses `CNTP_CVAL/CTL` across SPC;
whether the APSS watchdog runs on this image (it does not — measured
inactive); whether FP2's stock DTB is really the MTP chain (no
fairphone-specific dts exists in the mirror).

---

## Report 3 — krait-cc / HFPLL concurrency, L2, and the shared rail

### 1. Vendor L2-rate rule and L2→CX rule

PROVEN — the L2 rate is a table lookup indexed by the **max cpufreq index
over online CPUs**, done in cpufreq (`V/cpufreq.c:81-109`, `update_l2_bw`,
under a dedicated `l2bw_lock`), called after the CPU rate change succeeds,
with an `also_cpu` override during `CPU_UP_PREPARE`. Max, never an average,
not a ratio. Table = `qcom,cpufreq-table` `<cpu_khz, l2_khz, mem_MBps>`
(`V/msm8974.dtsi:1669-1684`):

| CPU MHz | L2 MHz | ratio | | CPU MHz | L2 MHz | ratio |
|---|---|---|---|---|---|---|
| 300.0 | 300.0 | 1.00 | | 1190.4 | 1036.8 | 1.15 |
| 422.4 | 422.4 | 1.00 | | 1267.2 | 1267.2 | 1.00 |
| 652.8 | 499.2 | 1.31 | | 1497.6 | 1497.6 | 1.00 |
| 729.6 | 576.0 | 1.27 | | 1574.4 | 1574.4 | 1.00 |
| 883.2 | 576.0 | **1.53** | | 1728.0 | 1651.2 | 1.05 |
| 960.0 | 960.0 | 1.00 | | 1958.4 | 1728.0 | 1.13 |
| 1036.8 | 1036.8 | 1.00 | | 2265.6 | 1728.0 | 1.31 |
| | | | | 2457.6 | 1728.0 | 1.42 |

Max ratio the vendor ever programs: **1.533**. L2 ceiling: **1728 MHz**.

PROVEN — L2 rate → CX corner: `qcom,l2-fmax` `<rate_Hz, rpm_corner>` as the
L2 clock's `vdd_class` fmax table, "first fmax ≥ rate":
`0→0, 576000000→4 (SVS_SOC), 1036800000→5 (NORMAL), 1728000000→7
(SUPER_TURBO)`. Rail = `l2-dig-supply = <&pm8841_s2_corner_ao>` = VDD_DIG/CX,
shared with `hfpll-dig`. Corner numbering is 1-based and the RPM wire value is
`enum − 1`, so vendor 4/5/7 == our opp-level 3/4/6. **The measured Android
"5↔7" is our "4↔6", and our pinned CX = 6 is the vendor's ceiling — CX is not
starved.** Second CX consumer: `vdd_hfpll` fmax `{0, 998.4M, 1996.8M, 2.9G}`
plus 1.8 V analog.

### 2. L2 at 729.6 MHz with cores at 1.5–2.27 GHz: slow, not unsafe

PROVEN — nothing in our tree can move the L2 (`<&kraitcc 4>` has no
consumer; krait-cc probe restores the rate it found). PROVEN — **no maximum
core:L2 ratio exists anywhere in the vendor BSP**; Krait↔L2 is an
asynchronous boundary; the vendor runs the L2 *slower* than the CPU at 8 of
15 rungs. At our pinned death point (1190.4) our ratio is 1.632 vs the
vendor's worst shipped 1.533 — 6 % beyond, not credibly fatal; at 2265.6 the
ratio is 3.106, unprecedented but a throughput deficit; a slower L2 draws
*less* current. **Demote the L2 as the reset cause; keep as a
performance/parity defect** (and the reason CX never moves).

### 3. Concurrency and ordering audit

PROVEN — there is no cross-core clk race: the clk core serialises every
`clk_set_rate` under the global `prepare_lock`, each core has a private
HFPLL/div/mux/cp15 register, plus `krait_clock_reg_lock` around register
access. Cost is contention, not corruption: each transition holds `h->lock`
IRQs-off across disable → L_VAL write → up-to-200 µs lock poll → enable.

Three real defects:

**(a) PROVEN — the secondary-mux parent map is inverted.** Vendor:
selector 2 = AUX, selector 0 = QSB (`clock-krait-8974.c:144-152`). Ours:
`sec_mux_map = {2, 0}` with `parent_data = {qsb, acpu_aux}` → index 0
("qsb") programs 2 = AUX, index 1 ("acpu_aux") programs 0 = **QSB — the
state the vendor's probe comment forbids** (mirrored verbatim in our
`krait-cc.c:408-411`). The primary map is correct, isolating the sec mux as
the outlier. `acpu_aux` = 300 MHz = our lowest OPP, and
`__clk_mux_determine_rate_closest` prefers exact matches — the 300 MHz rung
is the trigger. **Armed by `8c8328961a45`** ("fix the shared aux clock
name"): before it, `acpu_aux` was unresolvable and index 0 was accidentally
correct. Live snapshot: pri muxes on `hfpll*_div` at 307.2 MHz, so it had not
fired at sample time.

**(b) PROVEN — a core can be clocked from an unlocked HFPLL.** On lock-poll
timeout the code WARNs and **enables the output anyway**
(`clk-hfpll.c:86-109`); the boot log's `hfpll1 failed to lock in 200 us
(L_VAL 0)` proves the path live (msm8974 `hfpll_data` has no `.l_val`, and
krait-cc's `clk_prepare_enable(hfpll*_div)` enables the PLL before any rate is
set). The vendor waits unconditionally forever — can hang, never runs a core
off an unlocked PLL.

**(c) PROVEN — the safe-parent switch is silently skipped when the mux's
enable_count is 0** (`krait_mux_set_parent` writes only
`if (__clk_is_enabled(hw->clk))`; no `.is_enabled` op so this is
`core->enable_count`). If a running core's pri mux ever has count 0, the
PRE_RATE_CHANGE park is a no-op while `clk_hfpll_set_rate` still tears the
PLL down → core loses its clock mid-flight. Normally safe (probe enables all
four with every CPU online); no assertion guards it.

Ordering itself is correct (PRE parks on safe parent; `clk_change_rate`
prepares/enables the new parent before `set_parent`; `ABORT_RATE_CHANGE`
restores).

### 4. Voltage ↔ rate ordering, shared gang rail

Vendor PROVEN: `vote_rate_vdd(new)` → `set_rate()` → `unvote_rate_vdd(old)`
(`V/clock.c:511-528`), per-level refcounts, top-down max scan; gang =
`get_vmax()` over enabled cores under one global lock. The vendor's cores
each have their own vdd_class/regulator; the L2 is on a different rail and
never votes the gang.

Ours PROVEN equivalent, no defect: OPP core scaling up =
required-opps → level → regulators → clks; down = reverse. Regulator core
aggregation = max over consumers' mins; every OPP written `<V V 1275000>` so
the ceiling never binds. Core A dropping its request cannot dip the rail
below core B's requirement — `regulator_check_consumers` runs before any
hardware write, unchanged aggregates are skipped, and on a rise
`spm_set_voltage_sel` polls the latch and the core waits out `ramp_delay`.

### 5. Does the L2 impose a rail-voltage floor we never apply?

PROVEN — no: the vendor's L2 votes only a CX corner (`vdd_ua = NULL`), is not
a member of `krait_power_vregs`, contributes nothing to `get_vmax()`. And the
CX floor it would impose is already covered (729.6 → corner 5/NORMAL = our
level 4; we sit at 6). PROVEN — our core voltages are byte-identical to the
vendor's pvs9 **and** pvs12 tables (1190.4: 865000/850000; 1497.6:
910000/890000; 1958.4: 1000000/980000; 2265.6: 1060000/1040000). What the
vendor derives from the table and we throw away: the **third cell** — per-core
load in mA (`330*load + load*673*ratio/1000`), driving the phase count and
PFM/PWM mode.

### Ranked (report 3)

**#1 — No PMIC gang-rail PFM→PWM (and dynamic phase) management.** INFERRED
(our state) / PROVEN (vendor behaviour). Vendor switches the gang FTS out of
PFM into PWM whenever `load_total > qcom,pfm-threshold = 76` or more than one
CPU is online, then programs 1/2/4 phases from the load coefficient
(`krait-regulator.c:467-540`; enabled for Pro by `qcom,use-phase-switching`,
`msm8974pro-pm8941.dtsi:36`). Both controls go through **L2 SAW2 VCTL with a
nonzero port index** (`spm_devices.c:314-334` → `spm-v2.c:442-465`). Our
driver writes only port 0 and says so. So the gang rail runs at whatever
phase count and mode lk2nd left, forever. **The only candidate that explains
every piece of evidence: load-dependent, frequency-independent (kills a
pinned 1190.4 MHz just as it kills 2.27 GHz), temperature-aggravated, no
panic (rail droop → core hang → PS_HOLD), immune under Android.** Test:
read the gang SMPS mode/phase over SPMI idle vs load, compare against Android
at the same load [attempted from HLOS — blocked by the ownership filter];
alternative: the port-2 PWM command + A/B.

**#2 — sec-mux map inverted; the 300 MHz OPP can program QSB.** PROVEN
(code), INFERRED (that it fires). Cannot explain the pinned-1190.4 death;
one-line fix. Test: check `acpu_aux` rate (reads 300000000 live) and whether
a 300000-pinned soak dies in seconds.

**#3 — HFPLL output enabled after failed lock.** PROVEN path, boot WARN
proves it live; transitions only. Test: transition storm, count lock
failures.

**#4 — L2 permanently 729.6 MHz.** PROVEN; low as reset cause, high as
parity. Real fix: couple the L2 to max(core rates) per the §1 table and vote
CX from `qcom,l2-fmax`.

**#5 — CPU0's APC state never programmed by mainline.** INFERRED risk —
*[closed by device measurement: cpu0 reads the same pure-BHS
`PWR_GATE_CTL=0x403f3f7f` as cpu1-3]*.

**#6 — confirm the delivery mechanism first, zero risk:** after the next
reset read `/sys/class/watchdog/watchdog0/bootstatus`: `1` = APSS watchdog
bite (a core hung — #2/#3/#5); `0` = PS_HOLD came from elsewhere (rail
collapse / TZ) → #1. *[Measured on a post-death boot: 0.]*

**Could not determine (report 3):** what lk2nd leaves in the gang PMIC
(mode/phases) or per-core LDO/BHS; FP2's own vendor DTS (no fairphone dts in
the mirror — validated against the MTP chain); which PVS bin the efuse picks
(pvs9 per the phone's decode; both tables match ours anyway); whether the
pinned test was truly transition-free given the 75 °C passive trip [the run
peaked at 70 °C]; why the live `clk_summary` shows 307.2 MHz from
`hfpll*_div` rather than the sec mux at 300 MHz; anything outside the
clock/DVFS/regulator stack (`devfreq_msm_cpufreq_update_bw` — CPU→DDR
bandwidth voting — is a third thing the vendor drives from the same max index
and we do not drive at all).

---

## Report 4 — what can assert PS_HOLD on MSM8974 (the reset actor)

Delivered after the day's field data (death table, watchdog inactive,
FTS-mode refuted). Three headline corrections, then the ranked actors.

### Corrections that change how the evidence reads

1. **PM8941 has no FAULT_REASON register — the earlier `0x00` read was
   vacuous.** PON gen1 (PM8941, subtype 0x01) has `SOFT_RESET_REASON1/2` at
   0x80E/0x80F; `FAULT_REASON1/2` (0x8C8/0x8C9) exist only on PON gen2
   (PMI8994+), per the vendor's `is_pon_gen1()` gating in `qpnp-power-on.c`.
   **The PMIC-side exclusion still holds, by POFF_REASON itself**: PMIC_WD
   (bit2), TFT (12), UVLO (13), OTST3 (14), STAGE3 (15) are all clear; only
   PS_HOLD (bit1) is ever set.

2. **Every reset until 2026-07-26 evening was a PMIC *hard* reset** —
   lk2nd's reboot path programs `PON_PS_HOLD_RST_CTL (0x85A) = 7`
   (hard reset: full rail cycle), and mainline `pm8941_reboot_notify()`
   writes 7 unless `reboot_mode == warm`. A hard reset cuts DDR *and* IMEM —
   a complete, mundane explanation for every failed ramoops attempt.
   FP2's own Android uses **warm reset for every reboot** (`restart.c:277`,
   the hard branch is dead code). *Field follow-up: type 1 was latched via
   `echo warm > /sys/kernel/reboot/mode` + reboot, verified to persist
   across lk2nd and across spontaneous deaths (`085a: 01`, `085b: 80`), and
   post-warm-death boots print no PON line at all — the rails now stay up
   through the deaths.*

3. **A TZ diag region exists at IMEM+0x720** (`qcom,tz-log@fe805720` in the
   vendor DT, layout in `tz_log.c`: header, per-CPU `boot_info[]`,
   `reset_info[] = {reset_type, reset_cnt}`, `int_info[]`, log ring).
   *Field follow-up: on this firmware the readable 0x720–0x7ff window holds
   a descriptor ("TZDI" tag, table pointer 0xfe806000, plus four advancing
   per-CPU counters at 0x738–0x744 and a small resetting counter at 0x75c) —
   and the table itself at 0xfe806000+ is TZ-protected: HLOS reads STALL
   (the reader wedges in D-state until reboot; widening the syscon window is
   a trap, reverted). `reset_type` is therefore not reachable from Linux on
   this firmware.*

### Ranked PS_HOLD actors

| # | Mechanism | Verdict on the evidence |
|---|---|---|
| 1 | **RPM `ERR_FATAL`** on an invalid/unsatisfiable rail or corner vote (`CORE_VERIFY` aborts: corner out of range, corner/level mixing, the Mx ≥ all-rails invariant, rail-settle timeout) → RPM abort → TZ → PS_HOLD, in µs–ms with zero console output | **Best structural fit**; rate ∝ RPM message traffic. Note the fork's `MSM8974_VDDCX_AO` + rate-graded corner changes are exactly the kind of vote pattern this punishes. Not yet tied to the pinned-load case (no rate changes ⇒ no corner votes in steady state) — needs the RPM-stats trap. |
| 2 | **TZ `err_fatal` on a bus/permission event** (XPU violation, AHB timeout, NOC/BIMC error) — the same family as the known `/dev/mem` instant reset | Fully consistent; probability per bus transaction scales with activity. |
| 3 | **SoC-internal rail brownout (CX/MX/APC)** releasing PS_HOLD with no software actor — recorded as PS_HOLD, never UVLO (UVLO watches VPH only) | The one candidate needing no actor; survives the FTS→PWM null (the failing rail would be CX/MX, not APC). |
| 4 | **Secure (TZ-owned) watchdog** — SBL-armed, TZ-petted, invisible to Linux; bite asserts PS_HOLD | Possible; fixed timeout fits a load-proportional MTBF poorly. |
| 5 | APSS/KPSS watchdog | **EXCLUDED**: `WDT_EN=0` at probe (state `inactive`), lk2nd ≥18.0 explicitly disables it, nothing arms it. **Corollary: a plain hang cannot reset this SoC — the actor acts proactively.** |
| 6 | PMIC-side (PMIC WD, OTST3, STAGE3, TFT, UVLO, keys) | **EXCLUDED** by POFF_REASON bits. PM8941 stage-3 is 160 °C (not 145); PM8841 stage-2 auto-shutdown at 140 °C stays armed and its PON block is undeclared in mainline DT — worth adding, low priority. |
| 7 | Krait timing failure as a direct reset | **EXCLUDED as direct** (produces a hang/abort, not a reset; watchdog off ⇒ nothing terminal). Survives only as a feeder into #2. |
| 8 | Stray software PS_HOLD write (`msm-poweroff`) | Near-excluded (an orderly path prints and writes the reboot-mode cookie; the cookie is always empty). |

### The forensic channel outcome (field addendum)

The recommended measurement — flip to warm reset, harvest pstore + TZ diag —
was executed the same evening. Warm reset latched and held. **pstore/ramoops
is closed permanently under lk2nd**: a pmsg canary written pre-reboot was
lost across a *verified* warm reset from both candidate regions
(0x0ff00000 and lk2nd's own scratch 0x30f80000) — lk2nd/SBL reinitializes
DDR on every path (Android's working ramoops ran under the signed aboot).
The TZ diag table is TZ-protected past 0xfe806000. What warm reset *does*
preserve: the SoC/PMIC state itself (no PON re-latch, IMEM counters
accumulate), and it removes the rail cycle from every future death.

Remaining actor-identification avenues, in value order: (a) SPC-off idle A/B
(running — discriminates collapse for the idle deaths); (b) an RPM-stats +
CX-corner 5 Hz fsync'd trace to catch a frozen RPM (actor #1); (c) a serial
console on the phone's UART for SBL/TZ warm-boot banners; (d) a tiny kernel
module for the `TZ_XPU_VIOLATION_ERR_FATAL_NOOP` SMC query (actor #2).

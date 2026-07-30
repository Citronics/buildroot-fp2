# Reference corpus — Fairphone 2 / msm8974pro (LAB-OPERATIONS.md §2.3 / §2.4)

Written 2026-07-30 (campaign session 1). Every fact below carries its source;
re-verify before trusting anything marked *pending validation*.

## Resolved trees

| Role | Tree | Ref / commit | Validation |
|---|---|---|---|
| **Mainline base** (develop + ship) | `github.com/mlainez/linux-msm8x74` (this fork, tracks `stable/linux-6.18.y`) | campaign vehicle pin: `1a41629d475842fb5033a0a9ba61fdc9c84299b8` = `6.18/topic/cx-corner-idle-reset` (= `6.18/rc` tree + revert of vote-by-rate, see below) | Exact tree (modulo one uncommitted hfpll patch) running on the DUT 2026-07-30, boots to multi-user, CX pinned confirmed live via genpd |
| **Community fork** (cherry-pick source) | `github.com/msm8974-mainline/linux` | local clone `~/Projects/linux-msm8974-upstream` (fetched 2026-03-31); pmaports builds tag `v6.15.11-msm8974` | pmaports `device/testing/linux-postmarketos-qcom-msm8974/APKBUILD` (maintainer Luca Weiss); project is EOL for this fork's purposes — patches owned here since 6.18 |
| **Downstream / vendor** (register-level truth) | `FairphoneMirrors/android_kernel_fairphone_msm8974` = remote `fairphone` in the kernel repo; **reference ref: `fairphone/rel/10/fp2/22.08.0-rel`** (`e61ed9bae4e7`, fetched 2026-07-30) | pmaports' downstream pin `284400aea4b9` (LineageOS mirror) is an **ancestor** of 22.08 — the lineages converge | **partial** (probed 2026-07-30): oracle runs Android 10 `23.02.0-rel`, kernel `3.4.113-perf-ge8679ce1538`; that commit is NOT in the mirror (it ends at 22.08). Adopted 22.08 head as reference — clock/rail/PVS tables are stable across point releases; revisit if a 23.02 source drop is located. |

## pmaports facts (clone `~/Projects/pmaports`, unshallowed + blobless 2026-07-30, was at `f4ca5fb76c58` 2026-03-15)

- FP2 is `device/testing/device-fairphone-fp2` — **testing** maturity, like every
  msm8974 device (none reached community/main).
- 13 devices share the SoC package `linux-postmarketos-qcom-msm8974`: fp2, htc-m8,
  lg-hammerhead, oneplus-bacon, samsung-hlte, samsung-klte, samsung-lt03lte,
  sony-{amami,leo,castor,sirius,togari}.
- **Known-good config** `config-postmarketos-qcom-msm8974.armv7`:
  `QCOM_RPMPD=y`, `QCOM_SPM=y`, `ARM_QCOM_SPM_CPUIDLE=y`, but
  **`QCOM_HFPLL`, `KRAITCC`, `ARM_QCOM_CPUFREQ_NVMEM` all unset, `PSTORE` unset** —
  postmarketOS ships msm8974 **without CPU DVFS** (boot frequency only).
  Consequence: the community known-good validates the "6.18 with DVFS gated off"
  baseline (CP1); nobody's community config exercises the path this campaign debugs.
- `deviceinfo`: fastboot flash, `deviceinfo_generate_extlinux_config="true"`,
  dtb `qcom-msm8974pro-fairphone-fp2`, getty `ttyMSM0;115200`,
  msdos subpartition table ("lk2nd does not support GPT for subpartitions").
- Downstream archived package builds `LineageOS/android_kernel_fairphone_msm8974`
  @ `284400aea4b9` with **gcc6** (`device/archived/linux-fairphone-fp2-downstream/APKBUILD`).

## Mainline siblings worth mining (in-tree `arch/arm/boot/dts/qcom/`, 6.18 base)

`qcom-msm8974pro-samsung-klte` (+kltechn/common), `qcom-msm8974pro-oneplus-bacon`,
`qcom-msm8974pro-htc-m8`, `qcom-msm8974pro-sony-xperia-shinano-*`, and non-pro
`hammerhead`, `hlte`, `rhine-*`. Same PMIC/SAW/rpmpd topology; check them for CX/L2
handling before inventing anything.

## Current branch-state facts (verified 2026-07-30, supersede the session briefing)

- `6.18/rc` = `ac185c36cc06`, `6.18/staging` = `f21a650e2e04`, **identical trees**
  (`git diff` empty). Both carry the `xpu-err-fatal` topic (TZ XPU err-fatal armed).
- Both **carry `11c9727035d8` "vote the CX corner by rate"** (graded CX votes) — the
  configuration with the ~19 min idle PS_HOLD field MTBF per the revert's commit message.
- `6.18/topic/cx-corner-idle-reset` = `1a41629d4758` reverts it (CX re-pinned
  super-turbo, all 31 OPPs); pushed to origin 2026-07-30. This is the campaign
  vehicle tree until staging is reconciled.
- Uncommitted-but-preserved: hfpll `.l_val = 0x1c` seed patch
  (`~/Projects/msm8974-scratch/preserved/hfpll-lval-seed-uncommitted-20260730.patch`),
  was part of the `-dirty` kernel (#17) the DUT ran on Ubuntu.

# Making a silent reset leave evidence

Every hypothesis about the MSM8974 silent resets has so far been tested by
waiting for a reset and inferring from timing. That approach raised and killed
four hypotheses in one night without converging. This document is the
instrumentation plan that replaces it, with the configuration verified against
the config we actually build from
(`buildroot-external/board/fairphone2/linux.config`) and the device tree in the
kernel fork.

## What we have today

| Symbol | State | Consequence |
|---|---|---|
| `CONFIG_PSTORE*` | **absent entirely** | no ramoops. The blind spot is total. |
| `CONFIG_QCOM_WDT` | `y` | the APCS watchdog driver **is** bound |
| `CONFIG_WATCHDOG_SYSFS` | absent | `bootstatus` does not exist, so "was this reset a watchdog bite?" is **currently unanswerable** |
| `CONFIG_WATCHDOG_PRETIMEOUT_GOV` | absent | a bark prints one line and nothing else |
| `CONFIG_QCOM_RPM_MASTER_STATS` | `y` | already probing, already mapping RPM MSG RAM legitimately |
| `CONFIG_QCOM_STATS` | `m` | built, never loaded |
| `SOFTLOCKUP_DETECTOR`, `HARDLOCKUP_DETECTOR`, `DETECT_HUNG_TASK` | all absent | no lockup evidence is possible |
| `PANIC_TIMEOUT` | 0 | a caught panic hangs forever and an unattended soak loses it — pass `panic=10` |

## The honest split: what ramoops can and cannot capture

This matters more than the feature list, because the likely failure mode is that
the SoC is reset by TZ/RPM/hardware **without executing any kernel code**:

- **`dmesg-ramoops-*` will probably be empty** — it is written only from
  `kmsg_dump()`, which needs a panic path. Its emptiness is itself a result: it
  discriminates "externally killed" from "panicked with a dead console".
- **`console-ramoops-0` logs continuously**, so whatever printk happened last is
  in DDR. Modest gain over the host serial log, and subject to
  `console_loglevel` — do not raise that globally, it floods a 115200 UART
  inside the timing window being measured.
- **`pmsg-ramoops-0` (`/dev/pmsg0`) is the real win.** A userspace writer at
  1–5 Hz (uptime, per-CPU frequency, corners, VADC VPH, tsens) turns a silent
  reset into full state at T-0, with no UART traffic, no eMMC I/O and no
  dependency on a filesystem having flushed. Strictly better than the fsync'd
  eMMC logging this package currently does.
- **pstore/ftrace is a trap here**: it traces every function, costs 10–50× and
  rewrites every timing relationship in the SPM/HFPLL/regulator paths under
  suspicion. Reserve it for one narrow, targeted soak after localisation, never
  as standing instrumentation. (It also needs `FTRACE`, absent today.)

## ramoops region

Reserved memory is contiguous from `0x08000000` to `0x0fefffff`
(mpss → mba → wcnss → adsp → venus → smem → tz → rfsa → rmtfs), so the only
hole below the 256 MiB boundary is **`0x0ff00000`–`0x0fffffff`, 1 MiB**. The FP2
board DTS carries no reserved-memory of its own and the headless DTS includes
the display one, so a single node covers both DTBs.

```dts
&reserved_memory {
	ramoops@ff00000 {
		compatible = "ramoops";
		reg = <0x0ff00000 0x00100000>;
		no-map;
		record-size	= <0x00008000>;	/* 32 KiB x 12 dmesg records */
		console-size	= <0x00080000>;	/* 512 KiB rolling console  */
		pmsg-size	= <0x00020000>;	/* 128 KiB userspace log    */
		ftrace-size	= <0x00000000>;
		ecc-size	= <0x00000010>;
		max-reason	= <3>;		/* KMSG_DUMP_EMERG */
	};
};
```

```
CONFIG_PSTORE=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_PSTORE_PMSG=y
CONFIG_PSTORE_RAM=y     # =y, not =m: ramoops_init is a postcore_initcall
# CONFIG_PSTORE_COMPRESS is not set   # uncompressed stays readable from a raw dump
```

Two details that decide whether this works at all:

- **Sizes must be powers of two** — `ramoops_probe` silently rounds each one
  down to one.
- **`no-map` is required on ARM32.** With it, the range is hidden from
  `for_each_mem_range()`, `pfn_valid()` is false, and pstore takes
  `persistent_ram_iomap()`: `ioremap_wc` plus `memcpy_toio()`, so records are
  never sitting in a dirty D-cache line when the SoC is dropped. Without it you
  get a write-combine alias of the cacheable linear map, which is
  architecturally unpredictable on ARMv7. Several in-tree examples omit
  `no-map`; do not copy them.

The RAM is expected to survive because a PON warm reset does not cycle the DDR
rail — that is an argument, not proof, so **validate it before trusting it**:

1. Boot, `mount -t pstore pstore /sys/fs/pstore`. "no valid data in buffer" on a
   first boot is expected.
2. `reboot` (same PS_HOLD path as the failure). `console-ramoops-0` must exist
   and end with the shutdown messages. If it doesn't, the region is being
   wiped — retry at `0x6ff00000`, 1 MiB below the CMA window.
3. `echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger`.
   `dmesg-ramoops-0` must hold the panic and backtrace. This validates the
   frontend, the ECC and RAM survival in one shot.
4. Copy `/sys/fs/pstore/*` aside on boot and unlink the records — they live only
   in RAM, and dmesg slots stay occupied until removed.

## Is the reset already a watchdog bite? Currently unanswerable — fix that first

The APCS watchdog node is enabled (`qcom,apss-wdt-msm8974`, `0xf9017000`, bark
SPI 3 / bite SPI 4, `sleep_clk`), the driver is built in, and
`WATCHDOG_HANDLE_BOOT_ENABLED=y` means that **if the bootloader armed it, the
kernel is petting it right now** — in which case any 30 s starvation of that
worker bites, resets via TZ, and produces exactly the PS_HOLD signature we see.

A bite is byte-identical to a reboot at the PMIC, so PMIC forensics cannot
separate them. Only the APCS side can, and it costs one symbol:

```
CONFIG_WATCHDOG_SYSFS=y
```

Then `cat /sys/class/watchdog/watchdog0/bootstatus` (the driver sets
`WDIOF_CARDRESET` when `WDT_STS` bit 0 is set at probe), plus
`grep wdt_bark /proc/interrupts` to see whether barks are firing at all.
Calibrate against a deliberately forced bite before believing a zero, since it
is unverified whether `WDT_STS` survives a PS_HOLD reset on this SoC.

To convert a *serviceable* hang into a logged backtrace, add
`WATCHDOG_PRETIMEOUT_GOV` + `_GOV_PANIC` + `_DEFAULT_GOV_PANIC` and widen the
bark-to-bite window (`echo 10 > .../pretimeout`) so the panic has time to write.
**Limit, stated plainly:** the bark is a plain GIC SPI and ARM32/GICv2 has no
NMI, so a CPU spinning with interrupts disabled will never take it, and the
bark's affinity is CPU0. This catches deadlock, livelock with IRQs on, and
worker starvation; it cannot catch an IRQ-off stall. It also *adds* a reset
mechanism, so run it as its own single-variable experiment.

Cheap companions: `SOFTLOCKUP_DETECTOR`, and `HARDLOCKUP_DETECTOR` — which on
ARM32 resolves to the **buddy** detector (neighbour-CPU hrtimer counters), so it
works without NMI. A caught lockup is positive proof; silence proves nothing.

## Free data we are already collecting and never reading

`CONFIG_QCOM_RPM_MASTER_STATS=y` is built in and the `master-stats` node exists,
so the driver already `devm_ioremap()`s the four MSG-RAM slices of
`sram@fc428000`. Read it:

```
/sys/kernel/debug/qcom_rpm_master_stats/{APSS,MPSS,LPSS,PRONTO}
```

Per master: XO-shutdown count, last shutdown/bringup request and ack timestamps,
last sleep/wake transition durations, wakeup reason (0 = rude wakeup), active
cores mask. Sampled into `/dev/pmsg0` this gives RPM-level truth about whether
APSS ever entered XO shutdown and whether the radios were thrashing.

**This also corrects a hazard note recorded earlier in this investigation.**
Reading `0xfc428000` over `/dev/mem` reset the board instantly, and the
conclusion drawn was "that region is unreadable". It isn't: this driver maps and
reads the same RAM every boot without incident. The difference is the access
path — a driver uses `readl`/`memcpy_fromio` on a Device mapping, while
`/dev/mem` hands userspace a mapping that `memcpy` hits with unaligned
multi-word bursts, which the slave and its XPU reject and the NoC escalates to a
reset. The rule stands (never `/dev/mem` these regions) but the data is
available. The same applies to IMEM, which is already a `syscon`/`simple-mfd`
whose `reboot-mode` child lk2nd reads — making an IMEM crash cookie (a few words
written at SPC entry, before a SAW vlevel write, a heartbeat) feasible through
the existing regmap, and unlike ramoops it does not depend on DDR surviving.

`CONFIG_QCOM_STATS=m` would give `/sys/kernel/debug/qcom_stats/{vmin,vlow}` —
the most direct possible measurement of whether the SoC ever entered VDD-min.
**Treat as a hazard:** its probe reads RPM *code* RAM at `0xfc190000`, a
different XPU domain never exercised on this board. `modprobe` it once,
deliberately, on a throwaway boot, ready to power-cycle. Never fold it into a
soak build.

There is no TZ log driver in this tree, and CoreSight (ETM/ETF/ETR all present
in DT, `CORESIGHT=n`) has no upstream post-reset persistence path — correct in
theory, out of budget.

## Evidence outside the SoC, ranked

1. **Host-timestamped serial plus a 1 Hz device heartbeat** — time-of-death to
   ≤1 s and the whole state trajectory, on storage the reset cannot touch, at
   zero kernel risk. Timestamp on the host; the device has no RTC and its
   journal timestamps scramble after unclean resets. Keep it to one line
   (115200 ≈ 11 KB/s); the high-rate version belongs in `/dev/pmsg0`.
2. **PMIC PON/POFF forensics** — already printed at every boot by
   `qcom-pon`. Separates UVLO (rail collapse) from PS_HOLD (the MSM asked).
   Cannot separate reboot from watchdog bite.
3. **Power telemetry outside the board** — a logging PSU or USB power meter at
   10–100 Hz on the carrier input: current collapsing *before* the reset edge
   means brownout, collapsing *at* it means TZ/watchdog. Coarse, but a real
   discriminator with no kernel risk.
4. **A scope on VPH_PWR** — definitive for a sub-millisecond droop that every
   software instrument here is blind to. Ranked below (3) only for access.
5. **Host-side `ip monitor` / 1 Hz ping** — removes the "did it actually
   reboot or just wedge" ambiguity for free.

## Priority

| # | Item | Buys | Risk |
|---|---|---|---|
| 1 | host serial timestamps + 1 Hz heartbeat + PON dump per boot | time-of-death, trajectory | none |
| 2 | ramoops with console + pmsg | closes the blind spot; state at T-0 | low–med (validate per the protocol above) |
| 3 | `WATCHDOG_SYSFS=y`, read `bootstatus` | answers "is it already a bite" | none, read-only |
| 4 | sample RPM master stats into `/dev/pmsg0` | RPM sleep/wake truth | none, already probing |
| 5 | pretimeout `GOV_PANIC`, bark at T−10 s | serviceable hang → backtrace | med, adds a reset mechanism |
| 6 | soft/hard lockup detectors (buddy) | a catch is proof | low–med |
| 7 | `modprobe qcom_stats` for vmin/vlow | did the SoC enter VDD-min | **med–high, may itself reset** |
| 8 | IMEM crash cookie via the existing syscon | survives when DDR doesn't | med |

Worthless here: `PSTORE_BLK` (panic-only, and it writes to a rootfs this project
has already corrupted twice), the dmesg zone alone for an externally triggered
reset, and PMIC reason as a bite-versus-reboot discriminator.

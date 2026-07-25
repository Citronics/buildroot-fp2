#!/bin/sh
# Decode the PM8941 PON block: why we booted, and how the previous boot ended.
# Read-only, via the pmic-spmi regmap in debugfs, six registers only (each
# output line carries its own address, so the offset arithmetic is verifiable).
#
#   0x808 PON_REASON1   0x80a/b WARM_RESET_REASON1/2   0x80c/d POFF_REASON1/2
#
# POFF bits (vendor qpnp-power-on.c): 0 SOFT, 1 PS_HOLD, 2 PMIC_WD, 3 GP1,
# 4 GP2, 5 KPDPWR+RESIN, 6 RESIN_N, 7 KPDPWR_N, 11 CHARGER, 12 TFT,
# 13 UVLO, 14 OTST3, 15 STAGE3.
REG=/sys/kernel/debug/regmap/0-00/registers
mount -t debugfs none /sys/kernel/debug 2>/dev/null

[ -r $REG ] || { echo "pon: $REG not readable"; exit 0; }

# 9 bytes per line ("08xx: vv\n"); 0x800 is line 2048.
dump=$(dd if=$REG bs=9 skip=2048 count=16 2>/dev/null)
get() { echo "$dump" | awk -v a="$1" '$1 == a":" { print $2 }'; }

pon=$(get 0808); w1=$(get 080a); w2=$(get 080b)
p1=$(get 080c); p2=$(get 080d)
[ -n "$p1" ] || { echo "pon: unexpected dump format"; exit 0; }

poff=$(( 0x$p1 | (0x$p2 << 8) ))
names="SOFT PS_HOLD PMIC_WD GP1 GP2 KPDPWR+RESIN RESIN_N KPDPWR_N - - - CHARGER TFT UVLO OTST3 STAGE3"
decoded=""
i=0
for n in $names; do
  if [ $(( (poff >> i) & 1 )) = 1 ] && [ "$n" != "-" ]; then
    decoded="$decoded $n"
  fi
  i=$((i + 1))
done
[ -n "$decoded" ] || decoded=" none"

verdict="inconclusive"
case " $decoded " in
  *UVLO*)            verdict="BROWNOUT (PMIC undervoltage lockout)" ;;
  *PMIC_WD*|*STAGE3*) verdict="HANG broken by hardware (PMIC watchdog/stage3)" ;;
  *TFT*|*OTST3*)     verdict="THERMAL" ;;
  *PS_HOLD*)         verdict="SoC-initiated reset (normal reboot OR TZ/RPM/watchdog path)" ;;
  *SOFT*)            verdict="software shutdown" ;;
esac

echo "pon_reason=0x$pon warm_reset=0x$w2$w1 poff=0x$p2$p1 poff_bits:$decoded verdict=$verdict"

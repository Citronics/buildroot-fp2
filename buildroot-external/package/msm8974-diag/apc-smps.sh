#!/bin/sh
# Read the APC SMPS (pm8841 s2) setpoint directly from the PMIC over SPMI,
# via the read-only regmap debugfs. qcom_spmi-regulator.c register map:
#   base+0x04 TYPE  base+0x05 SUBTYPE  base+0x40 VOLTAGE_RANGE
#   base+0x41 VOLTAGE_SET  base+0x45 MODE  base+0x46 ENABLE
# FTS2 encoding is 5 mV steps, same family as the SAW vlevel.
mount -t debugfs none /sys/kernel/debug 2>/dev/null
for dev in 0-04 0-05; do
  R=/sys/kernel/debug/regmap/$dev/registers
  [ -r $R ] || continue
  for name in s1:0x1400 s2:0x1700 s3:0x1a00 s4:0x1d00; do
    lbl=${name%%:*}; base=${name##*:}
    line=$(( base / 1 ))
    dump=$(dd if=$R bs=9 skip=$((base)) count=80 2>/dev/null)
    t=$(echo "$dump"  | awk -v a=$(printf %04x $((base+0x04))) '$1==a":"{print $2}')
    st=$(echo "$dump" | awk -v a=$(printf %04x $((base+0x05))) '$1==a":"{print $2}')
    rg=$(echo "$dump" | awk -v a=$(printf %04x $((base+0x40))) '$1==a":"{print $2}')
    vs=$(echo "$dump" | awk -v a=$(printf %04x $((base+0x41))) '$1==a":"{print $2}')
    md=$(echo "$dump" | awk -v a=$(printf %04x $((base+0x45))) '$1==a":"{print $2}')
    en=$(echo "$dump" | awk -v a=$(printf %04x $((base+0x46))) '$1==a":"{print $2}')
    [ "$t" = "XX" ] || [ -z "$t" ] && continue
    mv=$(( 0x$vs * 5 ))
    echo "$dev $lbl: type=0x$t subtype=0x$st range=0x$rg set=0x$vs (${mv} mV if 5mV steps) mode=0x$md enable=0x$en"
  done
done

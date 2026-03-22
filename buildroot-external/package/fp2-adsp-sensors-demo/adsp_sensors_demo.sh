#!/bin/sh
# Fairphone 2 ADSP Sensor Demo - All 5 sensors (BusyBox compatible)
# Gracefully handles missing sensors (e.g. if a kernel module is not loaded)

find_iio_by_name() {
  for d in /sys/bus/iio/devices/iio:device*; do
    [ "$(cat "$d/name" 2>/dev/null)" = "$1" ] && echo "$d" && return
  done
}

ACCEL=$(find_iio_by_name qcom-smgr-accel)
GYRO=$(find_iio_by_name qcom-smgr-gyro)
MAG=$(find_iio_by_name qcom-smgr-mag)
PROX=$(find_iio_by_name qcom-smgr-prox)
LIGHT=$(find_iio_by_name qcom-smgr-light)

for dev in "$ACCEL" "$GYRO" "$MAG" "$PROX" "$LIGHT"; do
  [ -z "$dev" ] && continue
  echo 0 > "$dev/buffer/enable" 2>/dev/null
  for f in "$dev"/scan_elements/in_*_en; do
    [ -f "$f" ] && echo 1 > "$f"
  done
  echo 1 > "$dev/buffer/length"
  echo 1 > "$dev/buffer/enable"
done

# Wait for ADSP to start delivering samples after buffer enable
sleep 1

# Read scale factors (default to 1 if sensor missing)
ACCEL_SCALE=1
GYRO_SCALE=1
MAG_SCALE=1
LIGHT_SCALE=1
[ -n "$ACCEL" ] && ACCEL_SCALE=$(cat "$ACCEL/in_accel_scale")
[ -n "$GYRO" ] && GYRO_SCALE=$(cat "$GYRO/in_anglvel_scale")
[ -n "$MAG" ] && MAG_SCALE=$(cat "$MAG/in_magn_scale")
[ -n "$LIGHT" ] && LIGHT_SCALE=$(cat "$LIGHT/in_illuminance_scale")

cleanup() {
  printf "\n"
  for dev in "$ACCEL" "$GYRO" "$MAG" "$PROX" "$LIGHT"; do
    [ -z "$dev" ] && continue
    echo 0 > "$dev/buffer/enable" 2>/dev/null
  done
  exit 0
}
trap cleanup INT TERM

while true; do
  # 3-axis sensors: 3x int32 + 4-byte pad + 8-byte timestamp = 24 bytes
  # Single-value sensors: 1x int32 + 4-byte pad + 8-byte timestamp = 16 bytes
  # Save to temp files since BusyBox od pipe behavior is unreliable

  ax=0; ay=0; az=0; gx=0; gy=0; gz=0; mx=0; my=0; mz=0; prox=0; light=0

  if [ -n "$ACCEL" ]; then
    dd if="/dev/$(basename "$ACCEL")" of=/tmp/sa bs=24 count=1 2>/dev/null
    A=$(od -A none -t d4 /tmp/sa)
    ax=$(echo $A | awk '{print $1}')
    ay=$(echo $A | awk '{print $2}')
    az=$(echo $A | awk '{print $3}')
  fi

  if [ -n "$GYRO" ]; then
    dd if="/dev/$(basename "$GYRO")" of=/tmp/sg bs=24 count=1 2>/dev/null
    G=$(od -A none -t d4 /tmp/sg)
    gx=$(echo $G | awk '{print $1}')
    gy=$(echo $G | awk '{print $2}')
    gz=$(echo $G | awk '{print $3}')
  fi

  if [ -n "$MAG" ]; then
    dd if="/dev/$(basename "$MAG")" of=/tmp/sm bs=24 count=1 2>/dev/null
    M=$(od -A none -t d4 /tmp/sm)
    mx=$(echo $M | awk '{print $1}')
    my=$(echo $M | awk '{print $2}')
    mz=$(echo $M | awk '{print $3}')
  fi

  if [ -n "$PROX" ]; then
    dd if="/dev/$(basename "$PROX")" of=/tmp/sp bs=16 count=1 2>/dev/null
    P=$(od -A none -t d4 /tmp/sp)
    prox=$(echo $P | awk '{print $1}')
  fi

  if [ -n "$LIGHT" ]; then
    dd if="/dev/$(basename "$LIGHT")" of=/tmp/sl bs=16 count=1 2>/dev/null
    L=$(od -A none -t d4 /tmp/sl)
    light=$(echo $L | awk '{print $1}')
  fi

  ax_s=$(awk "BEGIN{printf \"%.3f\", ${ax:-0} * $ACCEL_SCALE}")
  ay_s=$(awk "BEGIN{printf \"%.3f\", ${ay:-0} * $ACCEL_SCALE}")
  az_s=$(awk "BEGIN{printf \"%.3f\", ${az:-0} * $ACCEL_SCALE}")
  gx_s=$(awk "BEGIN{printf \"%.5f\", ${gx:-0} * $GYRO_SCALE}")
  gy_s=$(awk "BEGIN{printf \"%.5f\", ${gy:-0} * $GYRO_SCALE}")
  gz_s=$(awk "BEGIN{printf \"%.5f\", ${gz:-0} * $GYRO_SCALE}")
  mx_s=$(awk "BEGIN{printf \"%.3f\", ${mx:-0} * $MAG_SCALE}")
  my_s=$(awk "BEGIN{printf \"%.3f\", ${my:-0} * $MAG_SCALE}")
  mz_s=$(awk "BEGIN{printf \"%.3f\", ${mz:-0} * $MAG_SCALE}")

  if [ "${prox:-0}" -gt 0 ] 2>/dev/null; then
    prox_label="NEAR"
  else
    prox_label="FAR"
  fi

  printf "\033[2J\033[H"
  printf "========================================\n"
  printf "  Fairphone 2 ADSP Sensor Demo\n"
  printf "  LSM330D + AK8963 + LT1PA01 via SMGR\n"
  printf "========================================\n\n"

  if [ -n "$ACCEL" ]; then
    printf "  ACCELEROMETER (m/s^2)\n"
    printf "    X: %8s\n" "$ax_s"
    printf "    Y: %8s\n" "$ay_s"
    printf "    Z: %8s\n\n" "$az_s"
  else
    printf "  ACCELEROMETER: not found\n\n"
  fi

  if [ -n "$GYRO" ]; then
    printf "  GYROSCOPE (rad/s)\n"
    printf "    X: %8s\n" "$gx_s"
    printf "    Y: %8s\n" "$gy_s"
    printf "    Z: %8s\n\n" "$gz_s"
  else
    printf "  GYROSCOPE: not found\n\n"
  fi

  if [ -n "$MAG" ]; then
    printf "  MAGNETOMETER (gauss)\n"
    printf "    X: %8s\n" "$mx_s"
    printf "    Y: %8s\n" "$my_s"
    printf "    Z: %8s\n\n" "$mz_s"
  else
    printf "  MAGNETOMETER: not found\n\n"
  fi

  if [ -n "$PROX" ]; then
    printf "  PROXIMITY\n"
    printf "    State:  %s\n\n" "$prox_label"
  else
    printf "  PROXIMITY: not found\n\n"
  fi

  if [ -n "$LIGHT" ]; then
    light_lux=$(awk "BEGIN{printf \"%.1f\", ${light:-0} * $LIGHT_SCALE}")
    printf "  AMBIENT LIGHT\n"
    printf "    Lux: %8s\n\n" "$light_lux"
  else
    printf "  AMBIENT LIGHT: not found\n\n"
  fi

  printf "  Press Ctrl+C to exit\n"

  sleep 0.2
done

#!/bin/sh
# The U-Boot script that sets up the fastboot loop (see uboot-loop/boot.cmd).
set -e
"${HOST_DIR}/bin/mkimage" -A arm -T script -C none -n "fp2 autoloop" \
	-d "$(dirname "$0")/uboot-loop/boot.cmd" "${TARGET_DIR}/boot/boot.scr" > /dev/null
# WCNSS start-up with the display active resets the SoC on 6.18.
rm -f "${TARGET_DIR}/lib/firmware/wcnss.mdt" "${TARGET_DIR}"/lib/firmware/wcnss.b*
# Not wanted on a test image: it holds the first boot for half a minute.
rm -f "${TARGET_DIR}/etc/init.d/S15first-boot-resize"

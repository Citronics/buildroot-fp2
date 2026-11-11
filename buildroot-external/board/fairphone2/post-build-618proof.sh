#!/bin/sh
# The U-Boot script that sets up the fastboot loop (see uboot-loop/boot.cmd).
set -e
"${HOST_DIR}/bin/mkimage" -A arm -T script -C none -n "fp2 autoloop" \
	-d "$(dirname "$0")/uboot-loop/boot.cmd" "${TARGET_DIR}/boot/boot.scr" > /dev/null
# WCNSS start-up with the display active resets the SoC on 6.18.
rm -f "${TARGET_DIR}/lib/firmware/wcnss.mdt" "${TARGET_DIR}"/lib/firmware/wcnss.b*
# Not wanted on a test image: it holds the first boot for half a minute.
rm -f "${TARGET_DIR}/etc/init.d/S15first-boot-resize"

# Optional second kernel, for an A/B on the same system: FP2_KERNEL_B is a
# kernel build directory, FP2_KERNEL_B_SRC its source tree. The kernel lands in
# /boot as zImage-b and fp2-b.dtb, its modules next to the main kernel's.
if [ -n "${FP2_KERNEL_B}" ]; then
	make -C "${FP2_KERNEL_B_SRC}" O="${FP2_KERNEL_B}" ARCH=arm \
		CROSS_COMPILE="${HOST_DIR}/bin/armv7-nerves-linux-gnueabihf-" \
		INSTALL_MOD_PATH="${TARGET_DIR}" INSTALL_MOD_STRIP=1 \
		DEPMOD="${HOST_DIR}/sbin/depmod" modules_install > /dev/null
	cp "${FP2_KERNEL_B}/arch/arm/boot/zImage" "${TARGET_DIR}/boot/zImage-b"
	cp "${FP2_KERNEL_B}/arch/arm/boot/dts/qcom/qcom-msm8974pro-fairphone-fp2.dtb" \
		"${TARGET_DIR}/boot/fp2-b.dtb"
fi

#!/bin/bash
# Initialize U-Boot environment in the image at offset 0x10000 (64 KiB)
# Format: non-redundant (CRC32 LE + data), size 0x20000 (128 KiB)
set -euo pipefail

IMAGES_DIR="${BINARIES_DIR:-output/images}"
SDCARD_IMG="${IMAGES_DIR}/sdcard.img"
UBOOT_ENV_OFFSET=$((0x10000))  # 64 KiB
UBOOT_ENV_SIZE=$((0x20000))    # 128 KiB

echo "=== Initializing U-Boot Environment in Image ==="

if [ ! -f "${SDCARD_IMG}" ]; then
    echo "ERROR: ${SDCARD_IMG} not found!"
    exit 1
fi

# Resolve mkenvimage: prefer Buildroot host tool, fallback to PATH
MKENVIMAGE_BIN=""
if [ -n "${HOST_DIR:-}" ] && [ -x "${HOST_DIR}/bin/mkenvimage" ]; then
    MKENVIMAGE_BIN="${HOST_DIR}/bin/mkenvimage"
elif command -v mkenvimage >/dev/null 2>&1; then
    MKENVIMAGE_BIN="$(command -v mkenvimage)"
fi

if [ -z "${Mkenvimage_BIN:-$MKENVIMAGE_BIN}" ]; then
    echo "ERROR: mkenvimage not found."
    echo "       Enable host u-boot-tools in Buildroot (BR2_PACKAGE_HOST_UBOOT_TOOLS=y)"
    echo "       or ensure mkenvimage is in PATH."
    exit 1
fi

# Create temp files and cleanup on exit
TMPENV="$(mktemp)"
TMPENV_IMG="$(mktemp)"
cleanup() { rm -f "${TMPENV}" "${TMPENV_IMG}"; }
trap cleanup EXIT

# Initial RAUC env (non-redundant)
cat > "${TMPENV}" << 'EOF'
BOOT_ORDER=A B
BOOT_A_LEFT=3
BOOT_B_LEFT=0
EOF

echo "Initial U-Boot environment:"
cat "${TMPENV}"
echo ""

# Build a full 128 KiB env image (CRC32 LE + data, padded by mkenvimage)
"${MKENVIMAGE_BIN}" -s "${UBOOT_ENV_SIZE}" -o "${TMPENV_IMG}" "${TMPENV}"

# Sanity check: size must be exactly UBOOT_ENV_SIZE
img_size=$(stat -c%s "${TMPENV_IMG}")
if [ "${img_size}" -ne "${UBOOT_ENV_SIZE}" ]; then
    echo "ERROR: Generated env size (${img_size}) != ${UBOOT_ENV_SIZE}"
    exit 1
fi

# Write the environment blob at the target offset
# Note: bs=1 avoids any block alignment pitfalls; performance is acceptable once.
dd if="${TMPENV_IMG}" of="${SDCARD_IMG}" \
   bs=1 seek="${UBOOT_ENV_OFFSET}" conv=notrunc status=none

printf "U-Boot environment initialized at offset 0x%x (size 0x%x)\n" \
       "${UBOOT_ENV_OFFSET}" "${UBOOT_ENV_SIZE}"

echo "=== U-Boot environment initialization complete ==="

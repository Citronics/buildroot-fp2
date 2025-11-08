#!/bin/bash
set -e

BOARD_DIR="$(dirname $0)/.."

echo "=== Post-image script for lemon_rauc ==="

# 1. Create rootfs copies for A/B slots
echo "Creating rootfs-a.ext4 and rootfs-b.ext4..."
cp "${BINARIES_DIR}/rootfs.ext4" "${BINARIES_DIR}/rootfs-A.ext4"
cp "${BINARIES_DIR}/rootfs.ext4" "${BINARIES_DIR}/rootfs-B.ext4"

# 2. Create boot images for both slots
echo "Creating boot images..."
"${BOARD_DIR}/scripts/create_boot_image.sh"

# 3. Create the complete SD card image with genimage
echo "Creating SD card image with genimage..."
support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"

# 4. Initialize U-Boot environment in the image
echo "Initializing U-Boot environment..."
"${BOARD_DIR}/scripts/init-uboot-env.sh"

# 5. Create RAUC update bundle
echo "Creating RAUC update bundle..."
"${BOARD_DIR}/scripts/create-rauc-bundle.sh"

echo "=== Post-image script complete ==="
echo "Images created:"
echo "  - ${BINARIES_DIR}/sdcard.img (complete image)"
echo "  - ${BINARIES_DIR}/update.raucb (RAUC bundle)"

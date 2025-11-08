#!/bin/bash
# Script to create RAUC update bundle

set -e

BOARD_DIR="$(dirname $0)/.."
IMAGES_DIR="${BINARIES_DIR:-output/images}"
BUNDLE_DIR="${IMAGES_DIR}/rauc-bundle"

echo "=== Creating RAUC Update Bundle ==="

# Create bundle directory
rm -rf "${BUNDLE_DIR}"
rm -rf "${IMAGES_DIR}/update.raucb"
mkdir -p "${BUNDLE_DIR}"

# Create a generic boot image for the bundle
# This will be customized by RAUC install hook for the target slot
echo "Creating generic boot image for bundle..."
BOOT_STAGING="${IMAGES_DIR}/boot_bundle_staging"
rm -rf "${BOOT_STAGING}"
mkdir -p "${BOOT_STAGING}/extlinux"

# Copy boot files
cp "${IMAGES_DIR}/zImage" "${BOOT_STAGING}/"
cp "${IMAGES_DIR}/initramfs.gz" "${BOOT_STAGING}/"
cp "${IMAGES_DIR}/qcom-msm8974pro-fairphone-fp2.dtb" "${BOOT_STAGING}/"

# Copy generic extlinux.conf (will be modified by install hook)
cp "${BOARD_DIR}/extlinux/extlinux.conf.bundle" "${BOOT_STAGING}/extlinux/extlinux.conf"

# Create boot image
genext2fs -b $((64 * 1024)) \
    -d "${BOOT_STAGING}" \
    -L "boot" \
    "${BUNDLE_DIR}/boot.img"

# Copy rootfs and boot images
echo "Copying rootfs image..."
cp "${IMAGES_DIR}/rootfs.ext4" "${BUNDLE_DIR}/rootfs.ext4"

# Copy install hook
echo "Copying install hook..."
cp "${BOARD_DIR}/overlay/etc/rauc/install-hook.sh" "${BUNDLE_DIR}/install-hook.sh"
chmod +x "${BUNDLE_DIR}/install-hook.sh"

# Create manifest
cat > "${BUNDLE_DIR}/manifest.raucm" << EOF
[update]
compatible=lemon-rauc-v1
version=$(date +%Y.%m.%d-%H%M%S)
description=Lemon RAUC Update Bundle

[hooks]
filename=install-hook.sh

[image.rootfs]
filename=rootfs.ext4

[image.boot]
filename=boot.img
EOF

# Sign and create bundle
CERT_PATH="${BOARD_DIR}/overlay/etc/rauc/ca.cert.pem"
KEY_PATH="${BOARD_DIR}/overlay/etc/rauc/ca.key.pem"

if [ -f "${CERT_PATH}" ] && [ -f "${KEY_PATH}" ]; then
    echo "Creating signed RAUC bundle..."
    rauc bundle \
        --cert="${CERT_PATH}" \
        --key="${KEY_PATH}" \
        "${BUNDLE_DIR}" \
        "${IMAGES_DIR}/update.raucb"

    echo "RAUC bundle created: ${IMAGES_DIR}/update.raucb"

    # Show bundle info (optional, ignore errors if keyring not available)
    echo ""
    echo "Bundle information:"
    rauc info --keyring="${CERT_PATH}" "${IMAGES_DIR}/update.raucb" 2>/dev/null || \
        echo "  Bundle: ${IMAGES_DIR}/update.raucb"
        echo "  (Run 'rauc info update.raucb' on target device for full details)"
else
    echo "ERROR: Certificate or key not found!"
    echo "Run scripts/generate-certs.sh first"
    exit 1
fi

echo "=== RAUC bundle creation complete ==="

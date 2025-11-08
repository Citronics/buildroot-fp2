#!/bin/sh
set -e

# Set default BINARIES_DIR if not provided by Buildroot
BINARIES_DIR="${BINARIES_DIR:-${PWD}/output/images}"

# Set default BR2_EXTERNAL_CITRONICS_PATH if not provided
if [ -z "${BR2_EXTERNAL_CITRONICS_PATH}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    BR2_EXTERNAL_CITRONICS_PATH="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

# Paths and constants
BOOT_A_IMG="${BINARIES_DIR}/boot-A.ext2"
BOOT_B_IMG="${BINARIES_DIR}/boot-B.ext2"
BOOT_IMG="${BINARIES_DIR}/boot.ext2"  # For RAUC bundle
BOOT_SIZE_MB=64
BOOT_A_STAGING="${BINARIES_DIR}/boot_a_staging"
BOOT_B_STAGING="${BINARIES_DIR}/boot_b_staging"

echo "Creating boot images for RAUC A/B setup..."
echo "BINARIES_DIR: ${BINARIES_DIR}"

create_boot_image() {
    local STAGING_DIR=$1
    local OUTPUT_IMG=$2
    local LABEL=$3
    local SLOT=$4

    echo "Creating $OUTPUT_IMG (slot $SLOT)..."

    # Clean and recreate staging directory
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"

    # Copy required boot files
    cp "${BINARIES_DIR}/zImage" "$STAGING_DIR/"
    cp "${BINARIES_DIR}/initramfs.gz" "$STAGING_DIR/"
    cp "${BINARIES_DIR}/qcom-msm8974pro-fairphone-fp2.dtb" "$STAGING_DIR/"

    # Copy extlinux.conf depending on slot
    mkdir -p "$STAGING_DIR/extlinux"
    if [ "$SLOT" = "A" ]; then
        cp "${BR2_EXTERNAL_CITRONICS_PATH}/board/lemon_rauc/extlinux/extlinux.conf.slot-a" \
           "$STAGING_DIR/extlinux/extlinux.conf"
    else
        cp "${BR2_EXTERNAL_CITRONICS_PATH}/board/lemon_rauc/extlinux/extlinux.conf.slot-b" \
           "$STAGING_DIR/extlinux/extlinux.conf"
    fi

    echo "Staging directory content:"
    ls -lh "$STAGING_DIR"
    ls -lh "$STAGING_DIR/extlinux"
    echo "Total size:"
    du -sh "$STAGING_DIR"

    echo "Verifying staging directory..."
    if [ ! -f "$STAGING_DIR/zImage" ]; then
        echo "ERROR: zImage not found in staging directory!"
        exit 1
    fi

    echo "Files in staging before genext2fs:"
    find "$STAGING_DIR" -type f -ls

    echo "Creating ${BOOT_SIZE_MB}MB ext2 image with genext2fs..."
    rm -f "$OUTPUT_IMG"

    (
        # Run genext2fs from BINARIES_DIR to avoid absolute path issues
        cd "$BINARIES_DIR"
        genext2fs -B 1024 \
            -b $((BOOT_SIZE_MB * 1024)) \
            -d "$(basename "$STAGING_DIR")" \
            -L "$LABEL" \
            "$(basename "$OUTPUT_IMG")"
    )

    sync

    if [ -f "$OUTPUT_IMG" ]; then
        IMAGE_SIZE=$(stat -c%s "$OUTPUT_IMG" 2>/dev/null || stat -f%z "$OUTPUT_IMG" 2>/dev/null || echo "0")
        echo "$OUTPUT_IMG created (size: $IMAGE_SIZE bytes)"

        echo "Verifying image content..."
        debugfs -R "ls -l" "$OUTPUT_IMG" 2>/dev/null | head -20 || echo "  (verification skipped)"
    else
        echo "ERROR: Failed to create $OUTPUT_IMG"
        exit 1
    fi
}

# Create boot-A image
create_boot_image "$BOOT_A_STAGING" "$BOOT_A_IMG" "boot-a" "A"

# Create boot-B image
create_boot_image "$BOOT_B_STAGING" "$BOOT_B_IMG" "boot-b" "B"

# Duplicate boot-A for generic boot.ext2 used in RAUC bundles
cp "$BOOT_A_IMG" "$BOOT_IMG"

echo "Boot images created:"
echo "  - $BOOT_A_IMG (slot A, active)"
echo "  - $BOOT_B_IMG (slot B, backup)"
echo "  - $BOOT_IMG (for RAUC bundles)"

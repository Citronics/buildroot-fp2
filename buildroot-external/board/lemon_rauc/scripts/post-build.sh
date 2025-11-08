#!/bin/bash
# Post-build script for Lemon RAUC configuration

set -e

TARGET_DIR=$1
BOARD_DIR="$(dirname $0)/.."

mkdir -p "${TARGET_DIR}/boot"
mkdir -p "${TARGET_DIR}/mnt/data"

echo "=== Lemon RAUC Post-Build Script ==="

# Generate test certificates if they don't exist
if [ ! -f "${BOARD_DIR}/overlay/etc/rauc/ca.cert.pem" ]; then
    echo "Generating RAUC test certificates..."
    "${BOARD_DIR}/scripts/generate-certs.sh"
fi

# Create RAUC status directory
mkdir -p "${TARGET_DIR}/data/rauc"

# Create mount points for both slots
mkdir -p "${TARGET_DIR}/mnt/rauc/slot-a"
mkdir -p "${TARGET_DIR}/mnt/rauc/slot-b"

echo "=== Post-build configuration complete ==="

#!/bin/sh
# This script generates test certificates for RAUC signing
# DO NOT USE IN PRODUCTION - Generate proper certificates instead

set -e

BOARD_DIR="$(dirname $0)/.."
CERT_DIR="${BOARD_DIR}/overlay/etc/rauc"

mkdir -p "${CERT_DIR}"

# Generate CA key and certificate if they don't exist
if [ ! -f "${CERT_DIR}/ca.key.pem" ]; then
    echo "Generating RAUC CA certificate (test only - replace in production)..."

    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout "${CERT_DIR}/ca.key.pem" \
        -out "${CERT_DIR}/ca.cert.pem" \
        -subj "/O=Citronics/CN=Lemon RAUC Test CA" \
        -days 3650

    echo "CA certificate generated at ${CERT_DIR}/ca.cert.pem"
    echo "CA key generated at ${CERT_DIR}/ca.key.pem"
    echo ""
    echo "WARNING: These are test certificates only!"
    echo "Generate proper certificates for production use."
fi

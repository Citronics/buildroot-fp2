#!/bin/sh
set -e

# Debug output
echo "[install-hook] ========================================"
echo "[install-hook] Action: $1"
echo "[install-hook] RAUC_SLOT_NAME: $RAUC_SLOT_NAME"
echo "[install-hook] RAUC_IMAGE_NAME: $RAUC_IMAGE_NAME"
echo "[install-hook] RAUC_IMAGE_ARCHIVE: $RAUC_IMAGE_ARCHIVE"
echo "[install-hook] RAUC_IMAGE_DIGEST: $RAUC_IMAGE_DIGEST"
echo "[install-hook] RAUC_SLOT_DEVICE: $RAUC_SLOT_DEVICE"
echo "[install-hook] ========================================"

case "$1" in
    slot-install)
        echo "[install-hook] Installing image '$RAUC_IMAGE_NAME' to slot '$RAUC_SLOT_NAME'"

        case "$RAUC_SLOT_NAME" in
            rootfs.0|boot.0)
                SLOT="A"
                ROOT_DEVICE="/dev/mmcblk0p20p5"
                BOOT_DEVICE="/dev/mmcblk0p20p1"
                ;;
            rootfs.1|boot.1)
                SLOT="B"
                ROOT_DEVICE="/dev/mmcblk0p20p6"
                BOOT_DEVICE="/dev/mmcblk0p20p2"
                ;;
            *)
                echo "ERROR: Unknown slot $RAUC_SLOT_NAME"
                exit 1
                ;;
        esac

        if [ "$RAUC_IMAGE_NAME" = "boot" ]; then
            echo "[install-hook] Writing boot image to $BOOT_DEVICE"
            echo "[install-hook] Source: $RAUC_IMAGE_ARCHIVE"
            dd if="$RAUC_IMAGE_ARCHIVE" of="$BOOT_DEVICE" bs=4M conv=fsync
            echo "[install-hook] Boot image written successfully"
        fi

        if [ "$RAUC_IMAGE_NAME" = "rootfs" ]; then
            echo "[install-hook] RAUC will handle rootfs installation automatically (type=ext4)"
        fi

        # Optional: Update extlinux.conf if you can mount the rootfs slot temporarily
        if [ "$RAUC_IMAGE_NAME" = "rootfs" ]; then
            echo "[install-hook] Updating extlinux.conf for slot $SLOT"
            MOUNT_POINT=$(mktemp -d)
            mount "$ROOT_DEVICE" "$MOUNT_POINT"

            if [ -f "$MOUNT_POINT/boot/extlinux/extlinux.conf" ]; then
                sed -i "s|rauc\.slot=[AB]|rauc.slot=${SLOT}|g" "$MOUNT_POINT/boot/extlinux/extlinux.conf"
                echo "[install-hook] Updated extlinux.conf for slot $SLOT"
            fi

            umount "$MOUNT_POINT"
            rmdir "$MOUNT_POINT"
        fi
        ;;
esac

echo "[install-hook] Done."
exit 0

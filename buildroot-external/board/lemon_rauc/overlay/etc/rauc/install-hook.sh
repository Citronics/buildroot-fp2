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
        echo "[install-hook] Update extlinux for slot '$RAUC_SLOT_NAME'"

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
            mount -t ext2 "$BOOT_DEVICE" "$BOOT_MOUNT"

            if [ -f "$BOOT_MOUNT/extlinux/extlinux.conf" ]; then
                # Update the bootpart and rootfs parameters for the correct slot
                if [ "$SLOT" = "A" ]; then
                    sed -i 's|bootpart=/dev/mmcblk0p20p[0-9]|bootpart=/dev/mmcblk0p20p1|g' "$BOOT_MOUNT/extlinux/extlinux.conf"
                    sed -i 's|rootfs=/dev/mmcblk0p20p[0-9]|rootfs=/dev/mmcblk0p20p5|g' "$BOOT_MOUNT/extlinux/extlinux.conf"
                    sed -i 's|rauc\.slot=[AB]|rauc.slot=A|g' "$BOOT_MOUNT/extlinux/extlinux.conf"
                    sed -i 's|menu title.*|menu title Lemon RAUC - Slot A|g' "$BOOT_MOUNT/extlinux/extlinux.conf"
                else
                    sed -i 's|bootpart=/dev/mmcblk0p20p[0-9]|bootpart=/dev/mmcblk0p20p2|g' "$BOOT_MOUNT/extlinux/extlinux.conf"
                    sed -i 's|rootfs=/dev/mmcblk0p20p[0-9]|rootfs=/dev/mmcblk0p20p6|g' "$BOOT_MOUNT/extlinux/extlinux.conf"
                    sed -i 's|rauc\.slot=[AB]|rauc.slot=B|g' "$BOOT_MOUNT/extlinux/extlinux.conf"
                    sed -i 's|menu title.*|menu title Lemon RAUC - Slot B|g' "$BOOT_MOUNT/extlinux/extlinux.conf"
                fi
                sync
                echo "[install-hook] Updated extlinux.conf: bootpart=$BOOT_DEVICE, rootfs=$ROOT_DEVICE, slot=$SLOT"
            else
                echo "[install-hook] Warning: extlinux.conf not found in boot partition"
            fi

            umount "$BOOT_MOUNT"
            rmdir "$BOOT_MOUNT"
        fi

        if [ "$RAUC_IMAGE_NAME" = "rootfs" ]; then
            echo "[install-hook] RAUC will handle rootfs installation automatically (type=ext4)"
        fi
esac

echo "[install-hook] Done."
exit 0

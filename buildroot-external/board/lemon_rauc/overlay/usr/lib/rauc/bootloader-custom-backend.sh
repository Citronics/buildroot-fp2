#!/bin/sh
# RAUC custom bootloader backend for lk2nd with U-Boot environment support
#
# This script implements the RAUC bootloader interface by directly manipulating
# U-Boot environment variables stored in the userdata partition.

set -e

# U-Boot environment configuration (must match lk2nd extlinux.conf settings)
UBOOT_ENV_PART="/dev/mmcblk0p20"  # userdata partition
UBOOT_ENV_OFFSET=$((0x10000))      # 64KB offset (0x10000)
UBOOT_ENV_SIZE=$((0x20000))        # 128KB size (0x20000)

# Helper functions
uboot_env_get() {
    local var="$1"
    fw_printenv -n "$var" 2>/dev/null || echo ""
}

uboot_env_set() {
    local var="$1"
    local value="$2"
    fw_setenv "$var" "$value"
}

# RAUC bootloader backend interface implementation
case "$1" in
    get-primary)
        # Return the slot that will be booted next
        BOOT_ORDER=$(uboot_env_get BOOT_ORDER)
        PRIMARY=$(echo "$BOOT_ORDER" | awk '{print $1}')
        echo "$PRIMARY"
        ;;

    set-primary)
        # Set which slot should be booted next
        SLOT="$2"

        # Set BOOT_ORDER to prioritize the requested slot
        if [ "$SLOT" = "A" ]; then
            uboot_env_set BOOT_ORDER "A B"
        elif [ "$SLOT" = "B" ]; then
            uboot_env_set BOOT_ORDER "B A"
        else
            echo "ERROR: Invalid slot: $SLOT" >&2
            exit 1
        fi
        ;;

    get-state)
        # Return the state of a slot (good, bad, or attempts left)
        SLOT="$2"
        LEFT=$(uboot_env_get "BOOT_${SLOT}_LEFT")

        if [ -z "$LEFT" ] || [ "$LEFT" -eq 0 ]; then
            echo "bad"
        elif [ "$LEFT" -eq 3 ]; then
            echo "good"
        else
            echo "$LEFT"
        fi
        ;;

    set-state)
        # Set the state of a slot
        SLOT="$2"
        STATE="$3"

        case "$STATE" in
            good)
                # Slot is good, set to 3 attempts
                uboot_env_set "BOOT_${SLOT}_LEFT" "3"
                ;;
            bad)
                # Slot is bad, set to 0 attempts
                uboot_env_set "BOOT_${SLOT}_LEFT" "0"
                ;;
            [0-9]*)
                # Set specific number of attempts
                uboot_env_set "BOOT_${SLOT}_LEFT" "$STATE"
                ;;
            *)
                echo "ERROR: Invalid state: $STATE" >&2
                exit 1
                ;;
        esac
        ;;

    *)
        echo "ERROR: Unknown command: $1" >&2
        echo "Usage: $0 {get-primary|set-primary|get-state|set-state} [args...]" >&2
        exit 1
        ;;
esac

exit 0

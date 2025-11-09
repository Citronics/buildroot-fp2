#!/bin/sh
# RAUC custom bootloader backend for lk2nd with U-Boot environment support
#
# This script implements the RAUC bootloader interface by directly manipulating
# U-Boot environment variables stored in the userdata partition.

# Désactiver les couleurs dans les appels à fw_printenv/fw_setenv
export TERM=dumb
export NO_COLOR=1

set -e

# U-Boot environment configuration (must match lk2nd extlinux.conf settings)
UBOOT_ENV_PART="/dev/mmcblk0p20"  # userdata partition
UBOOT_ENV_OFFSET=$((0x10000))      # 64KB offset (0x10000)
UBOOT_ENV_SIZE=$((0x20000))        # 128KB size (0x20000)

# Helper functions (note: we tolerate a missing / invalid env by lazy-init)
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
ensure_env_defaults() {
    # Si BOOT_ORDER est absent, laisser lk2nd déjà l'avoir créé ou créer des valeurs cohérentes.
    local order
    order=$(uboot_env_get BOOT_ORDER)
    if [ -z "$order" ]; then
        # Tenter un set minimal; si fw_setenv échoue pour CRC, lk2nd régénèrera après reboot.
        fw_setenv BOOT_ORDER "A B" 2>/dev/null || true
        fw_setenv BOOT_A_LEFT "3" 2>/dev/null || true
        fw_setenv BOOT_B_LEFT "0" 2>/dev/null || true
    fi
}

case "$1" in
    get-primary)
        ensure_env_defaults
        # Return the slot that will be booted next
        BOOT_ORDER=$(uboot_env_get BOOT_ORDER)
        PRIMARY=$(echo "$BOOT_ORDER" | awk '{print $1}')
        echo "$PRIMARY"
        ;;

    set-primary)
        ensure_env_defaults
        # Set which slot should be booted next
        SLOT="$2"

        # Set BOOT_ORDER to prioritize the requested slot
        if [ "$SLOT" = "A" ]; then
            uboot_env_set BOOT_ORDER "A B"
            uboot_env_set BOOT_A_LEFT "3"
        elif [ "$SLOT" = "B" ]; then
            uboot_env_set BOOT_ORDER "B A"
            uboot_env_set BOOT_B_LEFT "3"
        else
            echo "ERROR: Invalid slot: $SLOT" >&2
            exit 1
        fi
        ;;

    get-state)
        ensure_env_defaults
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
        ensure_env_defaults
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

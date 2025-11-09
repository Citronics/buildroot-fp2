#!/bin/sh
# RAUC custom bootloader backend for lk2nd with U-Boot environment support

# Désactiver les couleurs
export TERM=dumb
export NO_COLOR=1

set -e

# Configuration U-Boot
UBOOT_ENV_PART="/dev/mmcblk0p20"
UBOOT_ENV_OFFSET=$((0x10000))
UBOOT_ENV_SIZE=$((0x20000))

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

get_booted_slot() {
    local root_dev=$(awk '$2 == "/" {print $1}' /proc/mounts)
    case "$root_dev" in
        */dev/mmcblk0p20p5) echo "A" ;;  # rootfs.0
        */dev/mmcblk0p20p6) echo "B" ;;  # rootfs.1
        *) echo "unknown" ;;
    esac
}

# Corrige les valeurs par défaut (BOOT_B_LEFT=3 au lieu de 0)
ensure_env_defaults() {
    local order=$(uboot_env_get BOOT_ORDER)
    if [ -z "$order" ]; then
        fw_setenv BOOT_ORDER "B A" 2>/dev/null || true  # Priorité à B
        fw_setenv BOOT_A_LEFT "3" 2>/dev/null || true
        fw_setenv BOOT_B_LEFT "3" 2>/dev/null || true   # Corrige BOOT_B_LEFT=3
    fi
}

case "$1" in
    get-primary)
        ensure_env_defaults
        # Contrat RAUC: get-primary doit renvoyer le PROCHAIN slot (ordre de boot)
        BOOT_ORDER=$(uboot_env_get BOOT_ORDER)
        if [ -n "$BOOT_ORDER" ]; then
            echo "$BOOT_ORDER" | awk '{print $1}'
        else
            echo "A"  # défaut raisonnable
        fi
        ;;

    set-primary)
        ensure_env_defaults
        SLOT="$2"
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
        SLOT="$2"
        STATE="$3"
        case "$STATE" in
            good) uboot_env_set "BOOT_${SLOT}_LEFT" "3" ;;
            bad) uboot_env_set "BOOT_${SLOT}_LEFT" "0" ;;
            [0-9]*) uboot_env_set "BOOT_${SLOT}_LEFT" "$STATE" ;;
            *) echo "ERROR: Invalid state: $STATE" >&2; exit 1 ;;
        esac
        ;;

    # Nouvelle commande : retourne le slot booté actuel (pour RAUC)
    get-booted-slot)
        get_booted_slot
        ;;

    *)
        echo "ERROR: Unknown command: $1" >&2
        echo "Usage: $0 {get-primary|set-primary|get-state|set-state|get-booted-slot}" >&2
        exit 1
        ;;
esac

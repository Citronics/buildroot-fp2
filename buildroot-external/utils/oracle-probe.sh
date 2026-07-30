#!/bin/sh
# oracle-probe.sh - derive a target profile from an oracle device (vendor/stock stack).
#
# Target-agnostic. Collects raw dumps into an artifact directory and emits a
# machine-readable target-profile.env. Read-only on the device: it mounts debugfs
# if needed but writes nothing else and flashes nothing.
#
# Keep this in <BR2_EXTERNAL>/utils/. See LAB-OPERATIONS.md sections 2-4.
#
# Usage:
#   ./oracle-probe.sh -o <artifact-dir> [-s <adb-serial>] [-t <target-name>]
#
# Notes on scope:
#   * Everything collected here is MODEL-scoped and may be trusted for the target
#     family, EXCEPT the fuse/bin/calibration values gathered in the "die" section,
#     which are specific to THIS silicon and must be re-read on the DUT.
#   * Path names below are typical of Qualcomm/Android targets. Each is probed and
#     recorded only if present, so the script is safe to run on other platforms;
#     extend the lists for a new platform family rather than assuming.

set -u

OUT=""
SERIAL=""
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT="$2"; shift 2 ;;
        -s) SERIAL="$2"; shift 2 ;;
        -t) TARGET="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$OUT" ] || { echo "error: -o <artifact-dir> is required" >&2; exit 2; }

ADB="adb"
[ -n "$SERIAL" ] && ADB="adb -s $SERIAL"

command -v adb >/dev/null 2>&1 || { echo "error: adb not found in PATH" >&2; exit 1; }

$ADB wait-for-device || { echo "error: no device" >&2; exit 1; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
[ -n "$TARGET" ] || TARGET="unknown-target"
DIR="$OUT/$TARGET/oracle/$STAMP"
RAW="$DIR/raw"
mkdir -p "$RAW" || exit 1

PROFILE="$DIR/target-profile.env"
LOG="$DIR/probe.log"

say() { echo "$*" | tee -a "$LOG"; }

# Run a command on the device with the best privilege available.
# Tries: adb shell su -c '<cmd>'  then plain adb shell '<cmd>'.
dev() {
    _c="$1"
    _r=$($ADB shell "su -c '$_c'" 2>/dev/null)
    if [ -z "$_r" ]; then
        _r=$($ADB shell "$_c" 2>/dev/null)
    fi
    printf '%s' "$_r" | tr -d '\r'
}

# Capture a device command into raw/<name>; record whether it produced anything.
grab() {
    _name="$1"; _cmd="$2"
    _out=$(dev "$_cmd")
    if [ -n "$_out" ]; then
        printf '%s\n' "$_out" > "$RAW/$_name"
        say "  [ok]      $_name"
    else
        say "  [empty]   $_name    (cmd: $_cmd)"
    fi
}

say "oracle-probe $STAMP  target=$TARGET"
say "artifacts: $DIR"
[ -n "$SERIAL" ] && say "adb serial: $SERIAL"

# Root availability is worth knowing explicitly: much of the useful state is
# root-only, and a silently unrooted probe yields a misleadingly thin profile.
if [ "$(dev 'id -u')" = "0" ]; then
    say "root: yes"; ROOT=yes
else
    $ADB root >/dev/null 2>&1 && $ADB wait-for-device
    if [ "$(dev 'id -u')" = "0" ]; then say "root: yes (adb root)"; ROOT=yes
    else say "root: NO - profile will be incomplete"; ROOT=no; fi
fi

say "== identity =="
grab props            'getprop'
grab cpuinfo          'cat /proc/cpuinfo'
grab version          'cat /proc/version'
grab cmdline          'cat /proc/cmdline'
grab soc0             'for f in /sys/devices/soc0/*; do echo "$f: $(cat $f 2>/dev/null)"; done'
grab socinfo_legacy   'for f in /sys/devices/system/soc/soc0/*; do echo "$f: $(cat $f 2>/dev/null)"; done'

say "== storage / partitions =="
grab partitions       'cat /proc/partitions'
grab by-name          'ls -l /dev/block/bootdevice/by-name/ /dev/block/platform/*/by-name/ 2>/dev/null'
grab block-sizes      'for d in /sys/class/block/*; do echo "$(basename $d) $(cat $d/size 2>/dev/null)"; done'
grab mounts           'cat /proc/mounts'
grab fstab            'cat /fstab.* 2>/dev/null'

say "== boot chain =="
grab bootloader_props 'getprop | grep -i -E "bootloader|ro.boot|verifiedboot|secure"'

say "== vendor device tree (the platform's own hardware description) =="
# Pull the whole tree; it is the most complete hardware description available and
# frequently better than any vendor source you can find online.
for dtpath in /proc/device-tree /sys/firmware/devicetree/base; do
    if [ -n "$(dev "ls $dtpath 2>/dev/null | head -1")" ]; then
        say "  pulling $dtpath ..."
        $ADB pull "$dtpath" "$RAW/device-tree" >/dev/null 2>&1 \
            && say "  [ok]      device-tree ($dtpath)" \
            || say "  [failed]  device-tree pull ($dtpath) - try: adb pull $dtpath"
        break
    fi
done

say "== kernel config =="
if [ -n "$(dev 'ls /proc/config.gz 2>/dev/null')" ]; then
    $ADB shell "su -c 'cat /proc/config.gz'" 2>/dev/null > "$RAW/config.gz" \
        || $ADB shell 'cat /proc/config.gz' 2>/dev/null > "$RAW/config.gz"
    [ -s "$RAW/config.gz" ] && say "  [ok]      config.gz" || say "  [empty]   config.gz"
fi

say "== logs / reset evidence =="
grab dmesg            'dmesg'
grab last_kmsg        'cat /proc/last_kmsg'
grab pstore_list      'ls -l /sys/fs/pstore/'
grab pstore_dump      'for f in /sys/fs/pstore/*; do echo "=== $f"; cat "$f"; done'
grab reset_reason     'dmesg | grep -i -E "pon |power.?on reason|restart reason|reboot reason|warm.?reset|pmic.*reset|hard.?reset"'
grab rtc              'ls -l /dev/rtc* ; dmesg | grep -i rtc'

say "== cpu / frequency =="
grab cpu_present      'cat /sys/devices/system/cpu/present /sys/devices/system/cpu/possible'
grab cpufreq          'for c in /sys/devices/system/cpu/cpu*/cpufreq; do echo "=== $c"; for f in "$c"/*; do echo "$(basename $f): $(cat $f 2>/dev/null)"; done; done'
grab cpu_topology     'for c in /sys/devices/system/cpu/cpu*/topology; do echo "=== $c"; for f in "$c"/*; do echo "$(basename $f): $(cat $f 2>/dev/null)"; done; done'

say "== thermal =="
grab thermal_zones    'for z in /sys/class/thermal/thermal_zone*; do echo "=== $z"; for f in "$z"/type "$z"/temp "$z"/policy "$z"/mode "$z"/trip_point_*; do echo "$(basename $f): $(cat $f 2>/dev/null)"; done; done'
grab cooling_devices  'for c in /sys/class/thermal/cooling_device*; do echo "=== $c"; for f in "$c"/*; do echo "$(basename $f): $(cat $f 2>/dev/null)"; done; done'
grab thermal_params   'for f in /sys/module/*thermal*/parameters/*; do echo "$f: $(cat $f 2>/dev/null)"; done'
grab thermal_conf     'cat /vendor/etc/thermal-engine.conf /system/etc/thermal-engine.conf /etc/thermal-engine.conf 2>/dev/null'

say "== debugfs state (rails, clocks, power domains) =="
dev 'mount -t debugfs none /sys/kernel/debug 2>/dev/null; mount -t debugfs none /d 2>/dev/null' >/dev/null
grab regulator_summary 'cat /sys/kernel/debug/regulator/regulator_summary /d/regulator/regulator_summary 2>/dev/null'
grab regulators_tree   'ls -R /sys/kernel/debug/regulator /d/regulator 2>/dev/null'
grab clk_summary       'cat /sys/kernel/debug/clk/clk_summary /d/clk/clk_summary 2>/dev/null'
grab clk_enabled       'cat /sys/kernel/debug/clk/enabled_clocks /d/clk/enabled_clocks 2>/dev/null'
grab genpd_summary     'cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null'
grab rpm_stats         'cat /d/rpm_stats /sys/kernel/debug/rpm_stats 2>/dev/null'
grab rpm_master_stats  'cat /d/rpm_master_stats /sys/kernel/debug/rpm_master_stats 2>/dev/null'
grab suspend_stats     'cat /sys/kernel/debug/suspend_stats 2>/dev/null'

say "== memory map =="
grab iomem            'cat /proc/iomem'
grab meminfo          'cat /proc/meminfo'
grab reserved_mem     'ls -R /proc/device-tree/reserved-memory 2>/dev/null'

say "== die-scoped values (DO NOT transfer to the DUT - re-read there) =="
grab die_fuses        'dmesg | grep -i -E "pvs|speed.?bin|speedbin|efuse|qfprom|bin:|calib"'

# ---------------------------------------------------------------------------
# Derive the profile. Only fields we can actually read are emitted; anything
# absent is left out rather than guessed, so a consumer can detect gaps.
# ---------------------------------------------------------------------------
say "== deriving profile =="

p() { # p <key> <value>   (skip empties)
    [ -n "${2:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$PROFILE"
}
prop() { sed -n "s/^\[$1\]: \[\(.*\)\]$/\1/p" "$RAW/props" 2>/dev/null | head -1; }
soc()  { sed -n "s|^/sys/devices/soc0/$1: ||p" "$RAW/soc0" 2>/dev/null | head -1; }

: > "$PROFILE"
{
    echo "# target profile derived from oracle device"
    echo "# probe=$STAMP  raw=$RAW"
    echo "# scope: MODEL unless marked die_*; die_* must be re-read on the DUT"
} >> "$PROFILE"

p PROFILE_SOURCE       "oracle-probe/$STAMP"
p TARGET_NAME          "$TARGET"
p ORACLE_ROOT          "$ROOT"

p VENDOR               "$(prop ro.product.manufacturer)"
p MODEL                "$(prop ro.product.model)"
p CODENAME             "$(prop ro.product.device)"
p BOARD_PLATFORM       "$(prop ro.board.platform)"
p HARDWARE             "$(prop ro.hardware)"
p ARCH_ABI             "$(prop ro.product.cpu.abi)"
p BOOTLOADER           "$(prop ro.bootloader)"
p VENDOR_OS_BUILD      "$(prop ro.build.fingerprint)"

p SOC_ID               "$(soc soc_id)"
p SOC_FAMILY           "$(soc family)"
p SOC_MACHINE          "$(soc machine)"
p SOC_REVISION         "$(soc revision)"
p SOC_RAW_ID           "$(soc raw_id)"
p SOC_HW_PLATFORM      "$(soc hw_platform)"
p PMIC_MODEL           "$(soc pmic_model)"
p PMIC_DIE_REVISION    "$(soc pmic_die_revision)"

# Console: take the vendor's own cmdline as the authority for device and baud.
if [ -f "$RAW/cmdline" ]; then
    _con=$(tr ' ' '\n' < "$RAW/cmdline" | sed -n 's/^console=//p' | grep -v '^$' | head -1)
    p CONSOLE_RAW "$_con"
    p CONSOLE_DEV "$(printf '%s' "$_con" | cut -d, -f1)"
    p CONSOLE_BAUD "$(printf '%s' "$_con" | cut -d, -f2 | tr -dc '0-9')"
    p KERNEL_CMDLINE_VENDOR "\"$(cat "$RAW/cmdline")\""
fi

p VENDOR_KERNEL        "$(head -1 "$RAW/version" 2>/dev/null | cut -d' ' -f3)"

# Search keys used to resolve the two kernel trees (LAB-OPERATIONS.md 2.4) when no
# source was supplied. The -g<sha> suffix is `git describe` output from the vendor
# build: if that commit resolves in a candidate repository, that repository is the
# vendor tree (or a very close fork). It is the strongest single check available.
if [ -f "$RAW/version" ]; then
    _gsfx=$(sed -n 's/.*-g\([0-9a-f]\{6,\}\).*/\1/p' "$RAW/version" | head -1)
    p VENDOR_KERNEL_GIT_SUFFIX "$_gsfx"
fi
p SEARCH_KEY_CODENAME  "$(prop ro.product.device)"
p SEARCH_KEY_PLATFORM  "$(prop ro.board.platform)"
p SEARCH_KEY_ANDROID   "$(prop ro.build.version.release)"
p SEARCH_KEY_BUILD_ID  "$(prop ro.build.id)"

# Capability flags that change the evidence strategy materially.
[ -s "$RAW/pstore_list" ]   && p HAS_PSTORE yes      || p HAS_PSTORE no
[ -s "$RAW/last_kmsg" ]     && p HAS_LAST_KMSG yes   || p HAS_LAST_KMSG no
[ -s "$RAW/rtc" ]           && p HAS_RTC likely      || p HAS_RTC unknown
[ -d "$RAW/device-tree" ]   && p HAS_VENDOR_DT yes   || p HAS_VENDOR_DT no
[ -s "$RAW/config.gz" ]     && p HAS_VENDOR_CONFIG yes || p HAS_VENDOR_CONFIG no

# Partition names, from the by-name symlink farm when available.
if [ -s "$RAW/by-name" ]; then
    _parts=$(sed -n 's/.* \([A-Za-z0-9_.-]*\) -> .*/\1/p' "$RAW/by-name" | sort -u | tr '\n' ' ')
    p PARTITIONS_BY_NAME "\"$_parts\""
fi

# Frequency envelope of the working vendor stack: the realistic ceiling for the port.
if [ -s "$RAW/cpufreq" ]; then
    p VENDOR_CPUINFO_MAX_FREQ "$(sed -n 's/^cpuinfo_max_freq: //p' "$RAW/cpufreq" | sort -n | tail -1)"
    p VENDOR_CPUINFO_MIN_FREQ "$(sed -n 's/^cpuinfo_min_freq: //p' "$RAW/cpufreq" | sort -n | head -1)"
fi

# Die-scoped: recorded for reference only, explicitly namespaced so it cannot be
# mistaken for a model-level fact.
[ -s "$RAW/die_fuses" ] && p die_FUSE_LINES_PRESENT yes

say ""
say "profile written: $PROFILE"
say ""
sed -n '1,200p' "$PROFILE"
say ""
say "NEXT STEPS"
say "  1. Review the [empty] entries above; anything important that is empty usually"
say "     means missing root or a different path on this platform family - extend the"
say "     probe lists rather than hand-entering the value."
say "  2. Copy the profile to <BR2_EXTERNAL>/board/<target>/target-profile.env"
say "  3. Re-read every die_* value on the DUT; never transfer them from the oracle."
say "  4. Capture a second run under load if you need the vendor's rail/thermal"
say "     policy curve rather than just its idle state."
say "  5. If no kernel source was supplied, resolve BOTH trees now using the"
say "     SEARCH_KEY_* fields and VENDOR_KERNEL_GIT_SUFFIX above, per"
say "     LAB-OPERATIONS.md 2.4: (a) a mainline base to develop on, usually named by"
say "     the pmaports linux-* package for this codename, and (b) the downstream"
say "     vendor tree as the register-level reference. Validate the vendor tree by"
say "     resolving VENDOR_KERNEL_GIT_SUFFIX in it, and record remote/branch/commit"
say "     plus how each was validated."

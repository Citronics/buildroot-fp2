# Lemon RAUC A/B Partitioning Example

This document describes the use of the RAUC A/B update system for the Lemon system based on Fairphone 2.

## Overview

This configuration implements a robust A/B update system using RAUC (Robust Auto-Update Controller) with a modified version of lk2nd that supports U-Boot environment variables. The system has two complete slots (A and B), each containing a boot partition and a rootfs partition.

### Prerequisites: Modified lk2nd

⚠️ **IMPORTANT**: This configuration requires a modified version of lk2nd with U-Boot environment variable support for RAUC.

The modified lk2nd must implement:
- Read/write U-Boot variables from the userdata partition
- Support for `BOOT_ORDER`, `BOOT_A_LEFT`, `BOOT_B_LEFT` variables
- Automatic slot selection based on `BOOT_ORDER`
- Automatic decrement of `BOOT_X_LEFT` counter on each boot
- Automatic rollback to previous slot if counter reaches 0

Configuration in extlinux.conf:
```
rauc_uboot_part userdata
rauc_uboot_offset 0x10000
rauc_uboot_size 0x20000
```

**Boot flow:**
```
lk2nd starts
  ↓
Reads BOOT_ORDER from U-Boot env (e.g., "B A")
  ↓
Reads boot configuration (U-Boot env location and boot slot offsets) from extlinux.conf
  ↓
If BOOT_ORDER starts with "B": scan for partition labeled "boot-b"
If BOOT_ORDER starts with "A": scan for partition labeled "boot-a"
  ↓
Mounts the selected boot partition (e.g., /dev/mmcblk0p20p2 for boot-b)
  ↓
Reads /extlinux/extlinux.conf from THAT partition
  ↓
Loads kernel, dtb, initramfs from THE SELECTED boot partition
  ↓
Boots with bootpart=/rootfs= parameters from the extlinux.conf:
  - boot-a/extlinux.conf → bootpart=/dev/mmcblk0p20p1, rootfs=/dev/mmcblk0p20p5 (rootfs-a)
  - boot-b/extlinux.conf → bootpart=/dev/mmcblk0p20p2, rootfs=/dev/mmcblk0p20p6 (rootfs-b)
```

**This means:**
- ✅ Each slot has **truly independent** kernel, dtb, and initramfs
- ✅ boot-a and boot-b can contain **different kernel versions**
- ✅ Each boot partition has its own extlinux.conf with appropriate rootfs= parameter
- ✅ lk2nd automatically selects the correct partition based on BOOT_ORDER
- ✅ True A/B redundancy at both boot and rootfs levels

### Partitioning Architecture

```
| Image Layout                                      | Offset       | Size  |
|---------------------------------------------------|--------------|-------|
| U-Boot Environment (reserved space)               | 0x10000      | 128KB |
| Partition table (MBR)                             | 0x100000     | -     |
| p1: boot-a partition (ext2)                       | 1MB          | 64M   |
| p2: boot-b partition (ext2)                       | -            | 64M   |
| p3: filler primary (type 0x83, forces extended)   | -            | 1M    |
| p4: extended container                            | -            | -     |
| p5: rootfs-a (ext4, logical)                      | -            | 300M  |
| p6: rootfs-b (ext4, logical)                      | -            | 300M  |
| p7: data (ext4, logical) - persistent storage     | -            | 512M  |
```

**Important notes**:
- As described in `docs/partitioning.md`, this complete image is flashed onto the existing userdata partition (`/dev/mmcblk0p20`) of the Fairphone 2
- The U-Boot environment is stored at offset 0x10000 (64KB) in the raw image, before any partitions
- Partitions start at 1MB offset to leave space for U-Boot environment and boot sector

## Building

### 1. Initial Configuration

```bash
cd buildroot
make BR2_EXTERNAL=../buildroot-external lemon_rauc_defconfig
```

### 2. Generate Test Certificates

**WARNING**: Generated certificates are for testing only. Generate proper certificates for production use.

```bash
../buildroot-external/board/lemon_rauc/scripts/generate-certs.sh
```

### 3. Build

```bash
make
```

### Build Outputs

After building, you'll find in `output/images/`:
- `sdcard.img` - Complete image with A/B partitioning (to flash on userdata)
- `boot-a.ext2` - Boot partition for slot A (with slot-specific extlinux.conf)
- `boot-b.ext2` - Boot partition for slot B (with slot-specific extlinux.conf)
- `rootfs-a.ext4` - Rootfs partition for slot A (initially used)
- `rootfs-b.ext4` - Rootfs partition for slot B
- `data.ext4` - Persistent data partition
- `update.raucb` - RAUC bundle for updates

### How RAUC Bundle Updates Work

The update bundle contains a **generic boot.ext2** with a placeholder `extlinux.conf`. During installation:

1. **RAUC extracts the bundle** and detects the target slot (e.g., rootfs.1/boot.1 for Slot B)
2. **RAUC calls the install hook** (`install-hook.sh`) with `RAUC_SLOT_NAME` environment variable
3. **The hook modifies extlinux.conf** to set the correct devices:
  - For Slot A (rootfs.0/boot.0): `bootpart=/dev/mmcblk0p20p1 rootfs=/dev/mmcblk0p20p5`
  - For Slot B (rootfs.1/boot.1): `bootpart=/dev/mmcblk0p20p2 rootfs=/dev/mmcblk0p20p6`
4. **The hook also updates rauc.slot** kernel parameter for identification
5. **RAUC writes the modified boot image** to the target boot partition

This approach allows a **single generic bundle** to work for both slots, with slot-specific configuration applied at installation time rather than build time.

**Key files involved**:
- `board/lemon_rauc/extlinux/extlinux.conf.bundle`: Generic template in bundle
- `board/lemon_rauc/overlay/etc/rauc/install-hook.sh`: Hook that modifies extlinux.conf
- `board/lemon_rauc/scripts/create-rauc-bundle.sh`: Creates bundle with hook reference

## Initial Installation

### Flash Image to Device

The `sdcard.img` image must be flashed to the Fairphone 2 userdata partition:

```bash
# Via fastboot (after booting into fastboot mode)
fastboot flash userdata output/images/sdcard.img
```

## Using RAUC

### Check Current Status

```bash
# Display RAUC status and U-Boot variables
/etc/init.d/S99rauc status
```

This command displays:
- The currently active slot (A or B)
- Status of each slot (good, bad, being tested)
- Version installed on each slot
- U-Boot variables (BOOT_ORDER, BOOT_A_LEFT, BOOT_B_LEFT)

### Understanding the A/B System

The system uses U-Boot environment variables to manage boot:

- **BOOT_ORDER**: Slot priority order (e.g., "A B" or "B A")
- **BOOT_A_LEFT**: Remaining attempts for slot A (0-3)
- **BOOT_B_LEFT**: Remaining attempts for slot B (0-3)

**Automatic boot flow:**

1. lk2nd reads `BOOT_ORDER` from U-Boot environment
2. lk2nd attempts to boot the first slot in the list
3. lk2nd automatically decrements `BOOT_X_LEFT`
4. If system boots successfully, userspace calls `rauc status mark-good`
5. RAUC resets `BOOT_X_LEFT` to 3 (slot confirmed as good)
6. If counter reaches 0 without confirmation, lk2nd switches to next slot

### Install an Update

1. **Transfer the bundle to the device**:

```bash
scp output/images/update.raucb root@lemon:/tmp/
```

2. **Install the bundle**:

```bash
# Use direct mode (bypass D-Bus):
rauc --conf=/etc/rauc/system.conf install /tmp/update.raucb

# Or use the helper script:
rauc-install /tmp/update.raucb
```

RAUC will:
- Determine the inactive slot (B if A is active, or A if B is active)
- Extract and write boot and rootfs images to the inactive slot
- Update `BOOT_ORDER` to prioritize the new slot
- Set `BOOT_X_LEFT` to 3 for the new slot
- Current slot remains available as automatic fallback

3. **Reboot**:

```bash
reboot
```

The system will now:
- lk2nd reads `BOOT_ORDER` and boots the new slot
- lk2nd decrements `BOOT_X_LEFT` (goes to 2)
- If boot fails 3 times, lk2nd automatically reverts to previous slot

4. **After booting, confirm successful boot**:

```bash
# Use direct mode:
rauc --conf=/etc/rauc/system.conf status mark-good

# Or use the helper script:
rauc-mark-good
```

**Important**: If you don't mark the slot as good, after 3 boot attempts, lk2nd will automatically revert to the previous slot.

### Manually Revert to Previous Slot

If you encounter issues and want to force a return to the previous slot:

```bash
# Mark current slot as bad
rauc status mark-bad

# Or directly manipulate U-Boot variables
fw_setenv BOOT_ORDER "A B"  # Force slot A
fw_setenv BOOT_A_LEFT "3"

# Reboot
reboot
```

### Manually Inspect U-Boot Variables

```bash
# Display all variables
fw_printenv

# Display a specific variable
fw_printenv BOOT_ORDER
fw_printenv BOOT_A_LEFT
fw_printenv BOOT_B_LEFT

# Set a variable (use with caution!)
fw_setenv BOOT_ORDER "B A"
```

## Complete Update Flow

```
┌─────────────────────────────────────────────────────────┐
│ Initial state: Slot A active                            │
│ BOOT_ORDER="A B", BOOT_A_LEFT=3, BOOT_B_LEFT=0          │
│ lk2nd boots slot A                                      │
└─────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────┐
│ rauc-install update.raucb (or rauc --conf=... install) │
│ → Writes to Slot B (boot-b + rootfs-b)                 │
│ → fw_setenv BOOT_ORDER "B A"                            │
│ → fw_setenv BOOT_B_LEFT "3"                             │
└─────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────┐
│ reboot                                                  │
│ → lk2nd reads BOOT_ORDER="B A"                          │
│ → lk2nd decrements BOOT_B_LEFT (3→2)                    │
│ → lk2nd boots from linux_B (extlinux.conf)              │
│ → Kernel starts with rootfs=/dev/mmcblk0p20p6           │
└─────────────────────────────────────────────────────────┘
                    │
                    ▼
         ┌──────────┴──────────────────────────────┐
         ▼                                         ▼
┌────────────────────┐                  ┌──────────────────────┐
│ Boot successful    │                  │ Boot failed          │
│ rauc mark-good     │                  │ (panic, timeout...)  │
│ → BOOT_B_LEFT=3    │                  │ → Retry (LEFT: 2→1)  │
│ → B confirmed      │                  │ → If LEFT=0:         │
└────────────────────┘                  │   lk2nd boots slot A │
                                        │   (auto rollback)    │
                                        └──────────────────────┘
```

## Advanced Configuration

### Key Configuration Files

- **`/etc/rauc/system.conf`** - RAUC slot configuration with custom backend
- **`/etc/rauc/ca.cert.pem`** - CA certificate for bundle verification
- **`/etc/fw_env.config`** - Configuration for fw_printenv/fw_setenv (U-Boot env access)
- **`/usr/lib/rauc/bootloader-custom-backend.sh`** - RAUC backend script for lk2nd
- **`/data/rauc/slot.status`** - Slot status (persistent across boots)
- **Userdata partition offset 0x10000** - U-Boot environment (128KB)

### U-Boot Environment Variables

Stored at offset 0x10000 of the complete sdcard.img image (before partitions):

| Variable | Description | Values |
|----------|-------------|---------|
| `BOOT_ORDER` | Slot priority order | "A B" or "B A" |
| `BOOT_A_LEFT` | Remaining attempts for slot A | 0-3 (3=good, 0=bad) |
| `BOOT_B_LEFT` | Remaining attempts for slot B | 0-3 (3=good, 0=bad) |

**Environment storage details:**
- Location: Raw offset 0x10000 (64KB) in the image
- Size: 0x20000 (128KB)
- Format: U-Boot environment with CRC32 checksum
- Initialization: Created by `init-uboot-env.sh` script during build
- Runtime access: Via fw_printenv/fw_setenv at `/dev/mmcblk0p20` offset 0x10000

### Slot Lifecycle

1. **Installation**: `BOOT_X_LEFT=3` (new slot installed)
2. **First boot**: lk2nd decrements → `BOOT_X_LEFT=2`
3. **Unconfirmed**: lk2nd continues to decrement on each boot
4. **If `LEFT=0`**: lk2nd switches to next slot in `BOOT_ORDER`
5. **Confirmed**: `rauc mark-good` → `BOOT_X_LEFT=3` (stable)

### Custom Bundle Creation

The `create-rauc-bundle.sh` script can be modified to include additional components:

```bash
# Example: add a configuration file
cp my-config.conf "${BUNDLE_DIR}/"

# In manifest.raucm, add:
[file.config]
filename=my-config.conf
path=/etc/my-config.conf
```

## Integration with Modified lk2nd

### How lk2nd Works with RAUC

The modified lk2nd implements the RAUC bootloader interface natively:

**On lk2nd startup:**

1. Reads configuration from `extlinux.conf`:
   ```
   rauc_uboot_part userdata
   rauc_uboot_offset 0x10000
   rauc_uboot_size 0x20000
   rauc_boot_part_a boot-a
   rauc_boot_part_b boot-b
   ```

2. Opens userdata partition (`/dev/mmcblk0p20`)
3. Reads U-Boot environment at offset 0x10000 (64KB)
4. Extracts `BOOT_ORDER` (e.g., "B A")
5. Extracts `BOOT_B_LEFT` (e.g., 2)

**Partition and slot selection:**

1. Determines active slot from `BOOT_ORDER` (B in the example)
2. Checks that `BOOT_B_LEFT > 0`
3. If yes, decrements `BOOT_B_LEFT` (2 → 1) in U-Boot env
4. **Searches for partition with label "boot-b"** (based on rauc_boot_part_b config)
5. Mounts that partition (`/dev/mmcblk0p20p2`)
6. Reads `/extlinux/extlinux.conf` from boot-b partition
7. Boots using the `linux` label with `rootfs=/dev/mmcblk0p20p6` (rootfs-b)

**If boot fails:**

- After 3 attempts, `BOOT_B_LEFT=0`
- lk2nd tries next slot in `BOOT_ORDER` (A)
- **Searches for partition with label "boot-a"**
- Automatic boot on slot A (rollback)

### Key Configuration Points

**extlinux.conf settings** (present in both boot-a and boot-b partitions):
```
rauc_uboot_part userdata       # Partition containing U-Boot environment
rauc_uboot_offset 0x10000      # Offset within partition (64KB)
rauc_uboot_size 0x20000        # Environment size (128KB)
rauc_boot_part_a boot-a        # Label of boot partition for slot A
rauc_boot_part_b boot-b        # Label of boot partition for slot B
```

**extlinux.conf differences between slots**:
- boot-a: `bootpart=/dev/mmcblk0p20p1 rootfs=/dev/mmcblk0p20p5` (rootfs-a)
- boot-b: `bootpart=/dev/mmcblk0p20p2 rootfs=/dev/mmcblk0p20p6` (rootfs-b)

## Resources

- [Official RAUC Documentation](https://rauc.readthedocs.io/)
- [Partitioning Notes](../../docs/partitioning.md)
- [Fairphone 2 Documentation](../../docs/fairphone2.md)
- [Bootloader Documentation](../../docs/bootloader.md)

## License

This project is part of buildroot-fp2. See LICENSE at the project root.

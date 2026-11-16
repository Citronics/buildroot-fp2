################################################################################
#
# limeboard-io-firmware
#
################################################################################

LIMEBOARD_IO_FIRMWARE_VERSION = fefb5c426adaeaaf631302efba1a0c729f5091cd
LIMEBOARD_IO_FIRMWARE_SITE = https://github.com/Citronics/limeboard-firmware.git
LIMEBOARD_IO_FIRMWARE_SITE_METHOD = git
LIMEBOARD_IO_FIRMWARE_GIT_SUBMODULES = YES
LIMEBOARD_IO_FIRMWARE_LICENSE = MIT, MIT (TinyUSB), Apache-2.0 (CMSIS)
LIMEBOARD_IO_FIRMWARE_LICENSE_FILES = LICENSE lib/tinyusb/LICENSE \
	lib/cmsis-device-f4/LICENSE.md lib/cmsis-core/LICENSE.md
LIMEBOARD_IO_FIRMWARE_DEPENDENCIES = host-arm-gnu-toolchain

define LIMEBOARD_IO_FIRMWARE_BUILD_CMDS
	$(MAKE) -C $(@D) CROSS=$(HOST_DIR)/bin/arm-none-eabi-
endef

# The version file holds what src/version.h reports over USB: 0xMMmm in BCD
define LIMEBOARD_IO_FIRMWARE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/build/limeboard-io.bin \
		$(TARGET_DIR)/usr/share/limeboard/limeboard-io.bin
	awk '/define FIRMWARE_VERSION/ { v = substr($$3, 3); \
		printf "%d.%d\n", substr(v, 1, 2), substr(v, 3, 2) }' \
		$(@D)/src/version.h > $(TARGET_DIR)/usr/share/limeboard/limeboard-io.version
endef

$(eval $(generic-package))

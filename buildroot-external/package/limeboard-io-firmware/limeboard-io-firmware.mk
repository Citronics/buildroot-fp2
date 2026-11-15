################################################################################
#
# limeboard-io-firmware
#
################################################################################

LIMEBOARD_IO_FIRMWARE_VERSION = c394d0ead1508423e2e0f63a87ec6555eb73d7b5
LIMEBOARD_IO_FIRMWARE_SITE = file:///var/home/marc/Projects/citronics/limeboard-firmware
LIMEBOARD_IO_FIRMWARE_SITE_METHOD = git
LIMEBOARD_IO_FIRMWARE_GIT_SUBMODULES = YES
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

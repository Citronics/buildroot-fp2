################################################################################
#
# modem-boot
#
################################################################################

MODEM_BOOT_VERSION = 1.0
MODEM_BOOT_SITE_METHOD = local
MODEM_BOOT_SITE = $(BR2_EXTERNAL_CITRONICS_PATH)/package/modem-boot
MODEM_BOOT_LICENSE = GPL-3.0-or-later

define MODEM_BOOT_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 755 $(BR2_EXTERNAL_CITRONICS_PATH)/package/modem-boot/S37modem-boot \
		$(TARGET_DIR)/etc/init.d/S37modem-boot
endef

$(eval $(generic-package))

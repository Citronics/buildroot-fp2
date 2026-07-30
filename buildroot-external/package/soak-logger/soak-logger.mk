################################################################################
#
# soak-logger - fsync'd device-side telemetry sampler (observability family)
#
################################################################################

SOAK_LOGGER_VERSION = 1.0
SOAK_LOGGER_SITE = $(BR2_EXTERNAL_CITRONICS_PATH)/package/soak-logger
SOAK_LOGGER_SITE_METHOD = local

define SOAK_LOGGER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/soak-logger.sh $(TARGET_DIR)/usr/bin/soak-logger
	$(INSTALL) -D -m 0755 $(@D)/S90soak-logger $(TARGET_DIR)/etc/init.d/S90soak-logger
endef

$(eval $(generic-package))

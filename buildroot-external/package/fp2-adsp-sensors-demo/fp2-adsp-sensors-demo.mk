################################################################################
#
# fp2-adsp-sensors-demo
#
################################################################################

FP2_ADSP_SENSORS_DEMO_VERSION = 1.0
FP2_ADSP_SENSORS_DEMO_SITE = $(BR2_EXTERNAL_CITRONICS_PATH)/package/fp2-adsp-sensors-demo
FP2_ADSP_SENSORS_DEMO_SITE_METHOD = local

define FP2_ADSP_SENSORS_DEMO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/adsp_sensors_demo.sh $(TARGET_DIR)/usr/bin/adsp_sensors_demo
endef

$(eval $(generic-package))

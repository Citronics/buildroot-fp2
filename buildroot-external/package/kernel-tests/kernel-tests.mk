################################################################################
#
# kernel-tests
#
################################################################################

KERNEL_TESTS_VERSION = 1.0
KERNEL_TESTS_SITE = $(BR2_EXTERNAL_CITRONICS_PATH)/package/kernel-tests
KERNEL_TESTS_SITE_METHOD = local

define KERNEL_TESTS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/kernel-test-dvfs.sh $(TARGET_DIR)/usr/bin/kernel-test-dvfs
	$(INSTALL) -D -m 0755 $(@D)/kernel-test-thermal.sh $(TARGET_DIR)/usr/bin/kernel-test-thermal
	$(INSTALL) -D -m 0755 $(@D)/kernel-test-iommu.sh $(TARGET_DIR)/usr/bin/kernel-test-iommu
	$(INSTALL) -D -m 0755 $(@D)/kernel-test-voltage.sh $(TARGET_DIR)/usr/bin/kernel-test-voltage
	$(INSTALL) -D -m 0755 $(@D)/kernel-tests-run.sh $(TARGET_DIR)/usr/bin/kernel-tests-run
endef

$(eval $(generic-package))

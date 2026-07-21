################################################################################
#
# kernel-tests
#
################################################################################

KERNEL_TESTS_VERSION = 1.1
KERNEL_TESTS_SITE = $(BR2_EXTERNAL_CITRONICS_PATH)/package/kernel-tests
KERNEL_TESTS_SITE_METHOD = local

# gpu-iommu-submit is a tiny raw-ioctl drm/msm client used by the IOMMU test
# to submit real work to the GPU and prove DMA goes through the SMMU.
define KERNEL_TESTS_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(@D)/gpu-iommu-submit $(@D)/gpu-iommu-submit.c
endef

define KERNEL_TESTS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/kernel-test-dvfs.sh $(TARGET_DIR)/usr/bin/kernel-test-dvfs
	$(INSTALL) -D -m 0755 $(@D)/kernel-test-thermal.sh $(TARGET_DIR)/usr/bin/kernel-test-thermal
	$(INSTALL) -D -m 0755 $(@D)/kernel-test-iommu.sh $(TARGET_DIR)/usr/bin/kernel-test-iommu
	$(INSTALL) -D -m 0755 $(@D)/kernel-test-voltage.sh $(TARGET_DIR)/usr/bin/kernel-test-voltage
	$(INSTALL) -D -m 0755 $(@D)/kernel-tests-run.sh $(TARGET_DIR)/usr/bin/kernel-tests-run
	$(INSTALL) -D -m 0755 $(@D)/gpu-iommu-submit $(TARGET_DIR)/usr/bin/gpu-iommu-submit
endef

$(eval $(generic-package))

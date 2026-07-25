################################################################################
#
# msm8974-diag
#
# Diagnostics for the MSM8974 CPU power/clock path: read-only register probes,
# DVFS stressors, and resumable soak harnesses. Built while chasing the silent
# resets on the 6.18 fork (see README.md), where every reset left no kernel
# output at all and the only usable evidence came from fsync'd device-side logs
# and the PMIC's own power-off reason.
#
################################################################################

MSM8974_DIAG_VERSION = 1.0
MSM8974_DIAG_SITE = $(BR2_EXTERNAL_CITRONICS_PATH)/package/msm8974-diag
MSM8974_DIAG_SITE_METHOD = local
MSM8974_DIAG_DEPENDENCIES = python3

define MSM8974_DIAG_INSTALL_TARGET_CMDS
	# read-only probes
	$(INSTALL) -D -m 0755 $(@D)/pon-reason.sh    $(TARGET_DIR)/usr/bin/msm8974-pon-reason
	$(INSTALL) -D -m 0755 $(@D)/hfpll-rates.py   $(TARGET_DIR)/usr/bin/msm8974-hfpll-rates
	$(INSTALL) -D -m 0755 $(@D)/saw-mv.py        $(TARGET_DIR)/usr/bin/msm8974-saw-mv
	$(INSTALL) -D -m 0755 $(@D)/apc-state.py     $(TARGET_DIR)/usr/bin/msm8974-apc-state
	$(INSTALL) -D -m 0755 $(@D)/apc-full.py      $(TARGET_DIR)/usr/bin/msm8974-apc-full
	$(INSTALL) -D -m 0755 $(@D)/apc-smps.sh      $(TARGET_DIR)/usr/bin/msm8974-apc-smps
	$(INSTALL) -D -m 0755 $(@D)/hfpll-probe.py   $(TARGET_DIR)/usr/bin/msm8974-hfpll-probe
	# stressors
	$(INSTALL) -D -m 0755 $(@D)/hammer-full.sh   $(TARGET_DIR)/usr/bin/msm8974-hammer-full
	$(INSTALL) -D -m 0755 $(@D)/hammer-small.sh  $(TARGET_DIR)/usr/bin/msm8974-hammer-small
	# soak harnesses
	$(INSTALL) -D -m 0755 $(@D)/soak-log.sh      $(TARGET_DIR)/usr/bin/msm8974-soak-log
	$(INSTALL) -D -m 0755 $(@D)/pinned-soak.py   $(TARGET_DIR)/usr/bin/msm8974-pinned-soak
	$(INSTALL) -D -m 0755 $(@D)/descend-validate.py $(TARGET_DIR)/usr/bin/msm8974-descend-validate
	$(INSTALL) -D -m 0755 $(@D)/ceiling-sweep.sh $(TARGET_DIR)/usr/bin/msm8974-ceiling-sweep
	$(INSTALL) -D -m 0755 $(@D)/load-cycle.sh    $(TARGET_DIR)/usr/bin/msm8974-load-cycle
	# deployment / safe-state helper
	$(INSTALL) -D -m 0755 $(@D)/msm8974-diag-deploy.sh $(TARGET_DIR)/usr/bin/msm8974-diag-deploy
endef

$(eval $(generic-package))

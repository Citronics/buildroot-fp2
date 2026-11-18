################################################################################
#
# qbootctl
#
################################################################################

QBOOTCTL_VERSION = 0.2.2
QBOOTCTL_SITE = $(call github,linux-msm,qbootctl,$(QBOOTCTL_VERSION))
QBOOTCTL_LICENSE = GPL-3.0
QBOOTCTL_LICENSE_FILES = LICENSE

define QBOOTCTL_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(QBOOTCTL_PKGDIR)/S99mark-boot-successful \
		$(TARGET_DIR)/etc/init.d/S99mark-boot-successful
endef

$(eval $(meson-package))

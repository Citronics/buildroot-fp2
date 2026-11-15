################################################################################
#
# limeboard-io
#
################################################################################

LIMEBOARD_IO_DEPENDENCIES = dfu-util

define LIMEBOARD_IO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/90-limeboard-io.rules \
		$(TARGET_DIR)/usr/lib/udev/rules.d/90-limeboard-io.rules
endef

ifeq ($(BR2_PACKAGE_LIMEBOARD_IO_GPIOZERO),y)
LIMEBOARD_IO_DEPENDENCIES += python3 python-gpiozero python-lgpio
LIMEBOARD_IO_SITE_PACKAGES = $(TARGET_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR)/site-packages
LIMEBOARD_IO_DIST_INFO = limeboard_gpiozero-1.0.dist-info

define LIMEBOARD_IO_INSTALL_GPIOZERO
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/limeboard_gpiozero.py \
		$(LIMEBOARD_IO_SITE_PACKAGES)/limeboard_gpiozero.py
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/$(LIMEBOARD_IO_DIST_INFO)/METADATA \
		$(LIMEBOARD_IO_SITE_PACKAGES)/$(LIMEBOARD_IO_DIST_INFO)/METADATA
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/$(LIMEBOARD_IO_DIST_INFO)/entry_points.txt \
		$(LIMEBOARD_IO_SITE_PACKAGES)/$(LIMEBOARD_IO_DIST_INFO)/entry_points.txt
endef
LIMEBOARD_IO_POST_INSTALL_TARGET_HOOKS += LIMEBOARD_IO_INSTALL_GPIOZERO
endif

$(eval $(generic-package))

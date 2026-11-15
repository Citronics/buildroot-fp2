################################################################################
#
# limeboard-io
#
################################################################################

LIMEBOARD_IO_DEPENDENCIES = dfu-util

define LIMEBOARD_IO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/90-limeboard-io.rules \
		$(TARGET_DIR)/usr/lib/udev/rules.d/90-limeboard-io.rules
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/limeboard-spi.conf \
		$(TARGET_DIR)/etc/modprobe.d/limeboard-spi.conf
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

ifeq ($(BR2_PACKAGE_LIMEBOARD_IO_PI_COMPAT),y)
LIMEBOARD_IO_DEPENDENCIES += python-rpi-lgpio python-spidev

define LIMEBOARD_IO_INSTALL_PI_COMPAT
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/compat/limeboard_compat.py \
		$(LIMEBOARD_IO_SITE_PACKAGES)/limeboard_compat.py
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/compat/limeboard_compat.pth \
		$(LIMEBOARD_IO_SITE_PACKAGES)/limeboard_compat.pth
	for f in __init__.py board.py microcontroller/__init__.py microcontroller/pin.py; do \
		$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/compat/limeboard_blinka/$$f \
			$(LIMEBOARD_IO_SITE_PACKAGES)/limeboard_blinka/$$f || exit 1; \
	done
endef
LIMEBOARD_IO_POST_INSTALL_TARGET_HOOKS += LIMEBOARD_IO_INSTALL_PI_COMPAT
endif

$(eval $(generic-package))

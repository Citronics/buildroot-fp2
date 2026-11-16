################################################################################
#
# limeboard-io
#
################################################################################

LIMEBOARD_IO_VERSION = v1.0.1
LIMEBOARD_IO_SITE = https://github.com/Citronics/limeboard-extras.git
LIMEBOARD_IO_SITE_METHOD = git
LIMEBOARD_IO_LICENSE = MIT
LIMEBOARD_IO_LICENSE_FILES = LICENSE
LIMEBOARD_IO_DEPENDENCIES = dfu-util

define LIMEBOARD_IO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/udev/90-limeboard-io.rules \
		$(TARGET_DIR)/usr/lib/udev/rules.d/90-limeboard-io.rules
	$(INSTALL) -D -m 0644 $(@D)/limeboard-config/config.txt \
		$(TARGET_DIR)/etc/limeboard/config.txt
	$(INSTALL) -D -m 0644 $(LIMEBOARD_IO_PKGDIR)/limeboard.conf \
		$(TARGET_DIR)/etc/modprobe.d/limeboard.conf
	$(INSTALL) -D -m 0755 $(@D)/limeboard-config/limeboard-serial-console \
		$(TARGET_DIR)/usr/libexec/limeboard-serial-console
endef

define LIMEBOARD_IO_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(@D)/limeboard-config/limeboard-serial-console.service \
		$(TARGET_DIR)/usr/lib/systemd/system/limeboard-serial-console.service
	$(INSTALL) -D -m 0644 $(@D)/limeboard-config/limeboard-firmware-update.service \
		$(TARGET_DIR)/usr/lib/systemd/system/limeboard-firmware-update.service
	$(INSTALL) -D -m 0644 $(@D)/limeboard-config/limeboard-config.service \
		$(TARGET_DIR)/usr/lib/systemd/system/limeboard-config.service
	mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants
	ln -sf ../../../../usr/lib/systemd/system/limeboard-config.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/limeboard-config.service
endef

# At boot, config.txt applies and the STM32 gets a newer packaged firmware
# (limeboard-config)
ifeq ($(BR2_PACKAGE_PYTHON3),y)
define LIMEBOARD_IO_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(LIMEBOARD_IO_PKGDIR)/S11limeboard \
		$(TARGET_DIR)/etc/init.d/S11limeboard
endef
endif

ifeq ($(BR2_PACKAGE_PYTHON3),y)
LIMEBOARD_IO_DEPENDENCIES += python3

define LIMEBOARD_IO_INSTALL_CONFIG_TOOL
	$(INSTALL) -D -m 0755 $(@D)/limeboard-config/limeboard-config \
		$(TARGET_DIR)/usr/bin/limeboard-config
	$(INSTALL) -D -m 0755 $(@D)/limeboard-config/raspi-config \
		$(TARGET_DIR)/usr/bin/raspi-config
endef
LIMEBOARD_IO_POST_INSTALL_TARGET_HOOKS += LIMEBOARD_IO_INSTALL_CONFIG_TOOL
endif

ifeq ($(BR2_PACKAGE_LIMEBOARD_IO_GPIOZERO),y)
LIMEBOARD_IO_DEPENDENCIES += python3 python-gpiozero python-lgpio
LIMEBOARD_IO_SITE_PACKAGES = $(TARGET_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR)/site-packages
LIMEBOARD_IO_DIST_INFO = limeboard_gpiozero-1.0.dist-info

define LIMEBOARD_IO_INSTALL_GPIOZERO
	$(INSTALL) -D -m 0644 $(@D)/limeboard-gpiozero/limeboard_gpiozero.py \
		$(LIMEBOARD_IO_SITE_PACKAGES)/limeboard_gpiozero.py
	$(INSTALL) -D -m 0644 $(@D)/limeboard-gpiozero/$(LIMEBOARD_IO_DIST_INFO)/METADATA \
		$(LIMEBOARD_IO_SITE_PACKAGES)/$(LIMEBOARD_IO_DIST_INFO)/METADATA
	$(INSTALL) -D -m 0644 $(@D)/limeboard-gpiozero/$(LIMEBOARD_IO_DIST_INFO)/entry_points.txt \
		$(LIMEBOARD_IO_SITE_PACKAGES)/$(LIMEBOARD_IO_DIST_INFO)/entry_points.txt
endef
LIMEBOARD_IO_POST_INSTALL_TARGET_HOOKS += LIMEBOARD_IO_INSTALL_GPIOZERO
endif

ifeq ($(BR2_PACKAGE_LIMEBOARD_IO_PI_COMPAT),y)
LIMEBOARD_IO_DEPENDENCIES += python-rpi-lgpio python-spidev

define LIMEBOARD_IO_INSTALL_PI_COMPAT
	$(INSTALL) -D -m 0644 $(@D)/limeboard-compat/limeboard_compat.py \
		$(LIMEBOARD_IO_SITE_PACKAGES)/limeboard_compat.py
	$(INSTALL) -D -m 0644 $(@D)/limeboard-compat/limeboard_compat.pth \
		$(LIMEBOARD_IO_SITE_PACKAGES)/limeboard_compat.pth
	for f in __init__.py board.py microcontroller/__init__.py microcontroller/pin.py; do \
		$(INSTALL) -D -m 0644 $(@D)/limeboard-compat/limeboard_blinka/$$f \
			$(LIMEBOARD_IO_SITE_PACKAGES)/limeboard_blinka/$$f || exit 1; \
	done
endef
LIMEBOARD_IO_POST_INSTALL_TARGET_HOOKS += LIMEBOARD_IO_INSTALL_PI_COMPAT
endif

$(eval $(generic-package))

################################################################################
#
# limeboard-ha
#
################################################################################

LIMEBOARD_HA_VERSION = v1.0
LIMEBOARD_HA_SITE = https://github.com/Citronics/limeboard-extras.git
LIMEBOARD_HA_SITE_METHOD = git
LIMEBOARD_HA_LICENSE = MIT
LIMEBOARD_HA_LICENSE_FILES = LICENSE
LIMEBOARD_HA_DEPENDENCIES = python3 python-paho-mqtt python-psutil limeboard-io

define LIMEBOARD_HA_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/limeboard-ha/limeboard-ha $(TARGET_DIR)/usr/bin/limeboard-ha
	$(INSTALL) -D -m 0600 $(@D)/limeboard-ha/limeboard-ha.conf $(TARGET_DIR)/etc/limeboard-ha.conf
endef

define LIMEBOARD_HA_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(LIMEBOARD_HA_PKGDIR)/S95limeboard-ha $(TARGET_DIR)/etc/init.d/S95limeboard-ha
endef

$(eval $(generic-package))

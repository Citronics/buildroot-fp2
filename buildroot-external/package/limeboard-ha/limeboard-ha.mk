################################################################################
#
# limeboard-ha
#
################################################################################

LIMEBOARD_HA_DEPENDENCIES = python3 python-paho-mqtt limeboard-io

define LIMEBOARD_HA_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(LIMEBOARD_HA_PKGDIR)/limeboard-ha $(TARGET_DIR)/usr/bin/limeboard-ha
	$(INSTALL) -D -m 0600 $(LIMEBOARD_HA_PKGDIR)/limeboard-ha.conf $(TARGET_DIR)/etc/limeboard-ha.conf
endef

define LIMEBOARD_HA_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(LIMEBOARD_HA_PKGDIR)/S95limeboard-ha $(TARGET_DIR)/etc/init.d/S95limeboard-ha
endef

$(eval $(generic-package))

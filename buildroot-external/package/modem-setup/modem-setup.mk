################################################################################
#
# modem-setup
#
################################################################################

define MODEM_SETUP_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(MODEM_SETUP_PKGDIR)/msm-modem-attach-apn $(TARGET_DIR)/usr/libexec/msm-modem-attach-apn
	$(INSTALL) -D -m 0755 $(MODEM_SETUP_PKGDIR)/msm-modem-lte-once $(TARGET_DIR)/usr/libexec/msm-modem-lte-once
	$(INSTALL) -D -m 0755 $(MODEM_SETUP_PKGDIR)/S43modem-setup $(TARGET_DIR)/etc/init.d/S43modem-setup
	$(INSTALL) -D -m 0755 $(MODEM_SETUP_PKGDIR)/S46lte-once $(TARGET_DIR)/etc/init.d/S46lte-once
endef

$(eval $(generic-package))

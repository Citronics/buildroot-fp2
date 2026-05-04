################################################################################
#
# GPS assist
#
################################################################################

define GPS_ASSIST_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(BR2_EXTERNAL)/package/gps-assist/gps-assist $(TARGET_DIR)/usr/bin/gps-assist
	$(INSTALL) -D -m 0744 $(BR2_EXTERNAL)/package/gps-assist/S45gps-assist $(TARGET_DIR)/etc/init.d/S45gps-assist
	$(INSTALL) -d $(TARGET_DIR)/var/cache/gps
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL)/package/gps-assist/gps-assist.cron $(TARGET_DIR)/etc/cron.d/gps-assist
	$(INSTALL) -D -m 0755 $(BR2_EXTERNAL)/package/gps-assist/50-gps-assist $(TARGET_DIR)/etc/NetworkManager/dispatcher.d/50-gps-assist
	$(INSTALL) -D -m 0755 $(BR2_EXTERNAL)/package/gps-assist/S01fakeclock $(TARGET_DIR)/etc/init.d/S01fakeclock
endef

$(eval $(generic-package))

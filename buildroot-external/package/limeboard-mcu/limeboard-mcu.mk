################################################################################
#
# limeboard-mcu
#
################################################################################

LIMEBOARD_MCU_DEPENDENCIES = dfu-util

define LIMEBOARD_MCU_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(LIMEBOARD_MCU_PKGDIR)/limeboard-mcu $(TARGET_DIR)/usr/bin/limeboard-mcu
	$(INSTALL) -D -m 0644 $(LIMEBOARD_MCU_PKGDIR)/boot.py $(TARGET_DIR)/usr/share/limeboard-mcu/boot.py
	$(INSTALL) -D -m 0644 $(LIMEBOARD_MCU_PKGDIR)/code.py $(TARGET_DIR)/usr/share/limeboard-mcu/code.py
endef

$(eval $(generic-package))

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

$(eval $(generic-package))

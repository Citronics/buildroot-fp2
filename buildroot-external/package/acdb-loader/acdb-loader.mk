################################################################################
#
# acdb-loader - Qualcomm Audio Calibration Database Loader
#
################################################################################

ACDB_LOADER_VERSION = HEAD
ACDB_LOADER_SITE = $(call github,merlinxcy,msm8937-8953_vendor_qcom_proprietary,$(ACDB_LOADER_VERSION))
ACDB_LOADER_LICENSE = Qualcomm proprietary
ACDB_LOADER_INSTALL_STAGING = YES

AUDCAL_SRC = $(@D)/mm-audio/audcal/family-b
LOADER_SRC = $(@D)/mm-audio/audio-acdb-util/acdb-loader

AUDCAL_SRCS = \
	$(AUDCAL_SRC)/acdb/src/acdb.c \
	$(AUDCAL_SRC)/acdb/src/acdb_command.c \
	$(AUDCAL_SRC)/acdb/src/acdb_data_mgr.c \
	$(AUDCAL_SRC)/acdb/src/acdb_delta_file_mgr.c \
	$(AUDCAL_SRC)/acdb/src/acdb_delta_parser.c \
	$(AUDCAL_SRC)/acdb/src/acdb_file_mgr.c \
	$(AUDCAL_SRC)/acdb/src/acdb_init.c \
	$(AUDCAL_SRC)/acdb/src/acdb_linked_list.c \
	$(AUDCAL_SRC)/acdb/src/acdb_parser.c \
	$(AUDCAL_SRC)/acdb/src/acdb_translation.c \
	$(AUDCAL_SRC)/acdb/src/acdb_utility.c \
	$(AUDCAL_SRC)/acdb_hlos/src/acdb_init_utility.c \
	$(AUDCAL_SRC)/acdb/src/acdb_override.c \
	$(AUDCAL_SRC)/acph/src/acph.c

LOADER_SRCS = $(LOADER_SRC)/src/family-b/acdb-loader.c

STUBS_DIR = $(BR2_EXTERNAL_CITRONICS_PATH)/package/acdb-loader/stubs

ACDB_LOADER_INCLUDES = \
	-I$(STUBS_DIR) \
	-I$(AUDCAL_SRC)/acdb/inc \
	-I$(AUDCAL_SRC)/acdb/src \
	-I$(AUDCAL_SRC)/acdb_hlos/inc \
	-I$(AUDCAL_SRC)/acph/inc \
	-I$(AUDCAL_SRC)/acph_online/inc \
	-I$(AUDCAL_SRC)/actp/inc \
	-I$(AUDCAL_SRC)/audtp/inc \
	-I$(LOADER_SRC)/inc \
	-I$(@D)/mm-audio/audio-acdb-util/acdb-rtac/inc \
	-I$(@D)/mm-audio/audio-acdb-util/adie-rtac/inc \
	-I$(@D)/mm-audio/audio-acdb-util/acdb-fts/inc \
	-I$(@D)/mm-audio/audio-acdb-util/acdb-mcs/inc \
	-I$(@D)/mm-audio/audio-acdb-util/acdb-mapper/inc \
	-I$(LOADER_SRC)/inc/8974

ACDB_LOADER_CFLAGS = \
	$(ACDB_LOADER_INCLUDES) \
	-D_LINUX_ \
	-Wno-unused-parameter \
	-Wno-sign-compare \
	-Wno-implicit-function-declaration \
	-Wno-pointer-sign \
	-include stdint.h \
	-DDEFAULT_BOARD='"MTP"' \
	-DACDB_BIN_PATH='"/mnt/vendor/etc/acdbdata"' \
	-DETC_ROOT_PATH='"/mnt/vendor/etc"' \
	-D__packed='__attribute__((packed))' \
	-DMSM_SNDDEV_CAP_RX=0x1 \
	-DMSM_SNDDEV_CAP_TX=0x2 \
	-DALOGE='LOGE' \
	-DALOGD='LOGD' \
	-DALOGV='LOGV' \
	-Wno-incompatible-pointer-types \
	-Wno-error

define ACDB_LOADER_BUILD_CMDS
	# Fix GCC packing issue in acdb_end_pack.h
	sed -i 's|__attribute__((aligned (1)));||g' $(AUDCAL_SRC)/acdb/inc/acdb_end_pack.h
	# Fix macro collision: ACPH_CMD_RTC_SET_CAL_DATA conflicts with _req typedef
	sed -i 's|^#define ACPH_CMD_RTC_SET_CAL_DATA .*|/* FIXED: macro removed to prevent _req collision */|' $(AUDCAL_SRC)/acph/inc/acph.h $(AUDCAL_SRC)/acph/inc/acph_update_for_rtc.h
	# Also fix GET variant
	sed -i 's|^#define ACPH_CMD_RTC_GET_CAL_DATA .*|/* FIXED: macro removed to prevent _req collision */|' $(AUDCAL_SRC)/acph/inc/acph.h $(AUDCAL_SRC)/acph/inc/acph_update_for_rtc.h
	# Fix the ACPH header pack issue: remove all #include of acdb_begin/end_pack.h
	# from acph.h and replace struct definitions with simple packed structs
	sed -i 's|#include "acdb_begin_pack.h"||g; s|#include "acdb_end_pack.h"||g' $(AUDCAL_SRC)/acph/inc/acph.h $(AUDCAL_SRC)/acph/inc/acph_update_for_rtc.h
	# Remove ALL conflicting macro defines of ACPH_CMD_RTC_SET/GET_CAL_DATA
	sed -i '/^#define ACPH_CMD_RTC_SET_CAL_DATA[[:space:]]/d' $(AUDCAL_SRC)/acph/inc/acph.h $(AUDCAL_SRC)/acph/inc/acph_update_for_rtc.h
	sed -i '/^#define ACPH_CMD_RTC_GET_CAL_DATA[[:space:]]/d' $(AUDCAL_SRC)/acph/inc/acph.h $(AUDCAL_SRC)/acph/inc/acph_update_for_rtc.h
	# Fix struct closing: the removed acdb_end_pack.h left "}\n\n;" which GCC can't parse
	perl -i -0pe 's/\}\s*\n\s*;/};/g' $(AUDCAL_SRC)/acph/inc/acph.h $(AUDCAL_SRC)/acph/inc/acph_update_for_rtc.h
	# Add missing numeric macro defines
	sed -i '/^#include "acdb-loader.h"/a #ifndef ACPH_CMD_RTC_SET_CAL_DATA\n#define ACPH_CMD_RTC_SET_CAL_DATA 0x0102\n#endif\n#ifndef ACPH_CMD_RTC_GET_CAL_DATA\n#define ACPH_CMD_RTC_GET_CAL_DATA 0x0101\n#endif' $(LOADER_SRC)/src/family-b/acdb-loader.c
	# Replace offsetof() with hardcoded values (module_id is at offset 12 in both structs)
	sed -i 's/offsetof(ACPH_CMD_RTC_SET_CAL_DATA_req, module_id)/12/g' $(LOADER_SRC)/src/family-b/acdb-loader.c
	sed -i 's/offsetof(ACPH_CMD_RTC_GET_CAL_DATA_req, module_id)/12/g' $(LOADER_SRC)/src/family-b/acdb-loader.c
	# Replace sizeof with hardcoded values
	sed -i 's/sizeof(ACPH_CMD_RTC_SET_CAL_DATA_req)/28/g' $(LOADER_SRC)/src/family-b/acdb-loader.c
	sed -i 's/sizeof(ACPH_CMD_RTC_GET_CAL_DATA_req)/20/g' $(LOADER_SRC)/src/family-b/acdb-loader.c

	# Create stubs BEFORE any compilation
	echo '#include <stdint.h>' > $(@D)/stubs.c
	echo 'void acdb_rtac_init(void) {}' >> $(@D)/stubs.c
	echo 'void acdb_rtac_exit(void) {}' >> $(@D)/stubs.c
	echo 'int32_t acdb_rtac_callback(uint16_t cmd, uint8_t *req, uint32_t req_len, uint8_t *resp, uint32_t resp_len, uint32_t *filled) { return -1; }' >> $(@D)/stubs.c
	echo 'int32_t get_audio_copp_id(uint32_t a, uint32_t b, uint32_t c, uint32_t *d) { return -1; }' >> $(@D)/stubs.c
	echo 'int32_t get_audio_popp_id(uint32_t a, uint32_t b, uint32_t c, uint32_t *d) { return -1; }' >> $(@D)/stubs.c
	echo 'void adie_rtac_init(void) {}' >> $(@D)/stubs.c
	echo 'void adie_rtac_exit(void) {}' >> $(@D)/stubs.c
	echo 'int acdb_fts_init(void) { return 0; }' >> $(@D)/stubs.c
	echo 'int acph_online_init(void) { return 0; }' >> $(@D)/stubs.c
	echo 'void acph_online_deinit(void) {}' >> $(@D)/stubs.c
	echo 'int actp_diag_init(void) { return 0; }' >> $(@D)/stubs.c
	echo 'int anc_conversion(void *a, void *b) { return 0; }' >> $(@D)/stubs.c
	echo 'int vbat_conversion(void *a, void *b) { return 0; }' >> $(@D)/stubs.c
	echo 'int parse_codec_type(int a) { return 0; }' >> $(@D)/stubs.c

	# Build libaudcal
	$(TARGET_CC) $(TARGET_CFLAGS) $(ACDB_LOADER_CFLAGS) \
		-shared -fPIC -o $(@D)/libaudcal.so \
		$(AUDCAL_SRCS) $(@D)/stubs.c \
		-lpthread

	# Build libacdbloader (with stubbed rtac/fts functions)
	$(TARGET_CC) $(TARGET_CFLAGS) $(ACDB_LOADER_CFLAGS) \
		-I$(@D) \
		-shared -fPIC -o $(@D)/libacdbloader.so \
		$(LOADER_SRCS) $(@D)/stubs.c \
		-L$(@D) -laudcal -lpthread

	# Build mm-audio-send-cal test binary
	$(TARGET_CC) $(TARGET_CFLAGS) $(ACDB_LOADER_CFLAGS) \
		-o $(@D)/mm-audio-send-cal \
		$(AUDCAL_SRC)/test/sendcal.c \
		-L$(@D) -lacdbloader -laudcal -lpthread

	# Build acdb-init-test (simple init with explicit card name)
	$(TARGET_CC) $(TARGET_CFLAGS) \
		-o $(@D)/acdb-init-test \
		$(BR2_EXTERNAL_CITRONICS_PATH)/package/acdb-loader/acdb-init-test.c \
		-L$(@D) -ldl
endef

define ACDB_LOADER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libaudcal.so $(TARGET_DIR)/usr/lib/libaudcal.so
	$(INSTALL) -D -m 0755 $(@D)/libacdbloader.so $(TARGET_DIR)/usr/lib/libacdbloader.so
	$(INSTALL) -D -m 0755 $(@D)/mm-audio-send-cal $(TARGET_DIR)/usr/bin/mm-audio-send-cal
	$(INSTALL) -D -m 0755 $(@D)/acdb-init-test $(TARGET_DIR)/usr/bin/acdb-init-test
endef

define ACDB_LOADER_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libaudcal.so $(STAGING_DIR)/usr/lib/libaudcal.so
	$(INSTALL) -D -m 0755 $(@D)/libacdbloader.so $(STAGING_DIR)/usr/lib/libacdbloader.so
endef

$(eval $(generic-package))

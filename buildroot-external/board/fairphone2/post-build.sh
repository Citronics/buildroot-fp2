#!/bin/sh
# Write build timestamp so S01fakeclock can set the clock at boot.
date +%s > "${TARGET_DIR}/etc/build-timestamp"

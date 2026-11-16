# libqmi 1.38.0, for the QMI LOC injection API that gps-assist and the
# ModemManager patches use. Buildroot has already set up libqmi's build steps
# for its own version when this file is read, so only the source changes; the
# build directory keeps Buildroot's version in its name. The 1.38.0 hash is in
# patches/libqmi/libqmi.hash.
LIBQMI_SITE = https://gitlab.freedesktop.org/mobile-broadband/libqmi/-/archive/1.38.0
LIBQMI_SOURCE = libqmi-1.38.0.tar.gz

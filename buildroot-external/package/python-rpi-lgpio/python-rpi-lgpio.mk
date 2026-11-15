################################################################################
#
# python-rpi-lgpio
#
################################################################################

PYTHON_RPI_LGPIO_VERSION = 0.6
PYTHON_RPI_LGPIO_SOURCE = rpi_lgpio-$(PYTHON_RPI_LGPIO_VERSION).tar.gz
PYTHON_RPI_LGPIO_SITE = https://files.pythonhosted.org/packages/6e/6d/7b6cb0def16abda6af89d16a3363d4036501bf042f9c67668aad3b34927f
PYTHON_RPI_LGPIO_SETUP_TYPE = setuptools
PYTHON_RPI_LGPIO_LICENSE = BSD-3-Clause
PYTHON_RPI_LGPIO_LICENSE_FILES = LICENSE.txt

$(eval $(python-package))

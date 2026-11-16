# SPDX-License-Identifier: MIT
"""Raspberry Pi GPIO libraries on the Limeboard.

At Python startup (through limeboard_compat.pth), and only when the
Limeboard I/O firmware's GPIO chip is present, setup():

- selects gpiozero's "limeboard" pin factory (GPIOZERO_PIN_FACTORY);
- points RPi.GPIO, as provided by rpi-lgpio, at the Limeboard's GPIO chip
  (RPI_LGPIO_CHIP) and lets it start (RPI_LGPIO_REVISION). Without these,
  rpi-lgpio would open gpiochip0, which on the phone is the SoC's own pins;
- makes Adafruit Blinka's `board`, `microcontroller` and
  `microcontroller.pin` the Limeboard's (limeboard_blinka), on Blinka's
  generic Linux I2C and lgpio pin code (BLINKA_FORCEBOARD).

Settings already in the environment are kept. LIMEBOARD_COMPAT=0 turns it
all off.
"""
# This module is imported by every Python program at startup: it imports
# only os and sys there (importlib.abc or glob would add 0.3 s on the phone).
import os
import sys

# The revision rpi-lgpio reports in RPI_INFO: a Raspberry Pi 4 Model B, the
# same 40-pin header
PI_REVISION = "a03111"


def _entries(directory, prefix):
    try:
        return [name for name in os.listdir(directory) if name.startswith(prefix)]
    except OSError:
        return []


def gpio_chip():
    """Return N of the Limeboard's /dev/gpiochipN, or None."""
    for name in _entries("/sys/bus/gpio/devices", "gpiochip"):
        if "/citronics-dln2-gpio." in os.path.realpath("/sys/bus/gpio/devices/" + name):
            return int(name[len("gpiochip"):])
    return None


def i2c_bus(port=0):
    """Return N of /dev/i2c-N for the Limeboard's I2C port, or None.

    Port 0 is SDA GPIO2/SCL GPIO3, port 1 SDA GPIO0/SCL GPIO1.
    """
    for name in _entries("/sys/bus/i2c/devices", "i2c-"):
        try:
            with open(f"/sys/bus/i2c/devices/{name}/name") as f:
                adapter = f.read().strip()
        except OSError:
            continue
        # "citronics-dln2-i2c-<usb device>-<port>"
        if adapter.startswith("citronics-dln2-i2c") and adapter.endswith(f"-{port}"):
            return int(name[len("i2c-"):])
    return None


def spi_bus(port=0):
    """Return B of /dev/spidevB.C for the Limeboard's SPI port, or None.

    Port 0 is GPIO9-11 (CE0 GPIO8, CE1 GPIO7), port 1 GPIO19-21 (CE0 GPIO18,
    CE1 GPIO17, CE2 GPIO16).
    """
    buses = []
    for name in _entries("/sys/class/spi_master", "spi"):
        path = os.path.realpath("/sys/class/spi_master/" + name)
        cell = [part for part in path.split("/") if part.startswith("citronics-dln2-spi.")]
        if cell:
            # The ports' devices are numbered in port order: citronics-dln2-spi.<id>.auto
            buses.append((int(cell[0].split(".")[1]), int(name[len("spi"):])))
    buses.sort()
    return buses[port][1] if port < len(buses) else None


class _AliasLoader:
    """Import a module under another name: the same module object."""

    def __init__(self, target):
        self.target = target

    def create_module(self, spec):
        import importlib
        return importlib.import_module(self.target)

    def exec_module(self, module):
        pass


class _PatchLoader:
    """Run a module's own loader, then set some of its attributes."""

    def __init__(self, loader, patch):
        self.loader, self.patch = loader, patch

    def create_module(self, spec):
        return self.loader.create_module(spec)

    def exec_module(self, module):
        self.loader.exec_module(module)
        self.patch(module)


def _set_digitalio_pin(module):
    from limeboard_blinka.microcontroller.pin import Pin
    module.Pin = Pin


class BlinkaFinder:
    """Gives Blinka the Limeboard's board and microcontroller modules.

    Only when Blinka is installed: otherwise `import board` is left alone.
    """
    ALIASES = {
        "board": "limeboard_blinka.board",
        "microcontroller": "limeboard_blinka.microcontroller",
        "microcontroller.pin": "limeboard_blinka.microcontroller.pin",
    }

    def __init__(self):
        self._blinka = None

    def _has_blinka(self):
        if self._blinka is None:
            from importlib.machinery import PathFinder
            self._blinka = PathFinder.find_spec("adafruit_blinka") is not None
        return self._blinka

    def find_spec(self, name, path, target=None):
        if name not in self.ALIASES and name != "digitalio":
            return None
        import importlib.machinery
        import importlib.util
        if name in self.ALIASES and self._has_blinka():
            return importlib.util.spec_from_loader(
                name, _AliasLoader(self.ALIASES[name]),
                is_package=name == "microcontroller")
        if name == "digitalio" and self._has_blinka():
            # Blinka picks digitalio's Pin class by the detected chip, which
            # it does not know: give it the Limeboard's
            spec = importlib.machinery.PathFinder.find_spec(name, path)
            if spec is not None and spec.loader is not None:
                spec.loader = _PatchLoader(spec.loader, _set_digitalio_pin)
            return spec
        return None


def setup():
    """Apply the settings when the Limeboard I/O firmware is present."""
    try:
        if os.environ.get("LIMEBOARD_COMPAT") == "0":
            return
        chip = gpio_chip()
        if chip is None:
            return
        env = os.environ
        env.setdefault("GPIOZERO_PIN_FACTORY", "limeboard")
        env.setdefault("RPI_LGPIO_CHIP", str(chip))
        env.setdefault("RPI_LGPIO_REVISION", PI_REVISION)
        env.setdefault("BLINKA_FORCEBOARD", "GENERIC_LINUX_PC")
        if not any(isinstance(f, BlinkaFinder) for f in sys.meta_path):
            sys.meta_path.insert(0, BlinkaFinder())
    except Exception:  # never break Python's startup
        pass

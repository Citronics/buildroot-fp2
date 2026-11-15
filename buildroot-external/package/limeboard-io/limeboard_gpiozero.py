"""gpiozero pin factory for the Limeboard header.

The Limeboard I/O firmware on the board's STM32 makes the header a Linux
GPIO chip labelled "dln2", with lines numbered like a Raspberry Pi's BCM
GPIOs. This factory is gpiozero's own lgpio factory (the default on a
Raspberry Pi 5) opened on that chip, with a description of the Limeboard's
header instead of a Pi's. Raspberry Pi gpiozero code then runs unchanged:

    GPIOZERO_PIN_FACTORY=limeboard python3 script.py

or, in Python:

    from gpiozero import Device
    from limeboard_gpiozero import LimeboardFactory
    Device.pin_factory = LimeboardFactory()

Pins are named as on a Pi (17, "GPIO17", "BCM17", "BOARD11", "J8:11"). The
onboard RGB LED and user button are "LED_R", "LED_G", "LED_B" and "BUTTON"
(GPIO28-31).
"""
import glob
from collections import defaultdict
from threading import Lock

import lgpio
from gpiozero.pins import BoardInfo, HeaderInfo
from gpiozero.pins import data as _data
from gpiozero.pins.data import GND, V3_3, V5
from gpiozero.pins.lgpio import LGPIOFactory, LGPIOPin
from gpiozero.pins.local import LocalPiFactory
from gpiozero.pins.pi import PiBoardInfo

CHIP_LABEL = "dln2"

# gpiozero's hardware SPI knows only the Pi's spi0. The Limeboard also has
# spi1, as /dev/spidev1.x: register its pins so SPI devices can use port=1.
_data.SPI_HARDWARE_PINS.setdefault(1, {
    "clock": "GPIO21",
    "mosi": "GPIO20",
    "miso": "GPIO19",
    "select": ("GPIO18", "GPIO17", "GPIO16"),
})

# Pin functions in gpiozero's header data format: {interface: name}
def gpiof(gpio, interface=None, name=None):
    return {"gpio": gpio, interface: name} if interface else {"gpio": gpio}


# The 40-pin header: the Raspberry Pi layout, with the functions the
# Limeboard I/O firmware provides: i2c0, i2c1, spi0, spi1 and one UART, in
# the Pi's positions (no PWM, PCM or GPCLK).
_G = {n: gpiof(f"GPIO{n}") for n in range(28)}
_G[0] = gpiof("GPIO0", "i2c", "I2C0 SDA")
_G[1] = gpiof("GPIO1", "i2c", "I2C0 SCL")
_G[2] = gpiof("GPIO2", "i2c", "I2C1 SDA")
_G[3] = gpiof("GPIO3", "i2c", "I2C1 SCL")
_G[7] = gpiof("GPIO7", "spi", "SPI0 CE1")
_G[8] = gpiof("GPIO8", "spi", "SPI0 CE0")
_G[9] = gpiof("GPIO9", "spi", "SPI0 MISO")
_G[10] = gpiof("GPIO10", "spi", "SPI0 MOSI")
_G[11] = gpiof("GPIO11", "spi", "SPI0 SCLK")
_G[14] = gpiof("GPIO14", "uart", "UART0 TXD")
_G[15] = gpiof("GPIO15", "uart", "UART0 RXD")
_G[16] = gpiof("GPIO16", "spi", "SPI1 CE2")
_G[17] = gpiof("GPIO17", "spi", "SPI1 CE1")
_G[18] = gpiof("GPIO18", "spi", "SPI1 CE0")
_G[19] = gpiof("GPIO19", "spi", "SPI1 MISO")
_G[20] = gpiof("GPIO20", "spi", "SPI1 MOSI")
_G[21] = gpiof("GPIO21", "spi", "SPI1 SCLK")

J8 = (20, 2, {
    1: V3_3, 2: V5,
    3: _G[2], 4: V5,
    5: _G[3], 6: GND,
    7: _G[4], 8: _G[14],
    9: GND, 10: _G[15],
    11: _G[17], 12: _G[18],
    13: _G[27], 14: GND,
    15: _G[22], 16: _G[23],
    17: V3_3, 18: _G[24],
    19: _G[10], 20: GND,
    21: _G[9], 22: _G[25],
    23: _G[11], 24: _G[8],
    25: GND, 26: _G[7],
    27: _G[0], 28: _G[1],
    29: _G[5], 30: GND,
    31: _G[6], 32: _G[12],
    33: _G[13], 34: GND,
    35: _G[19], 36: _G[16],
    37: _G[26], 38: _G[20],
    39: GND, 40: _G[21],
})

# The board's own RGB LED and button, lines 28-31 of the same chip
ONBOARD = (4, 1, {n - 27: gpiof(f"GPIO{n}") for n in range(28, 32)})
ONBOARD_NAMES = {28: "LED_R", 29: "LED_G", 30: "LED_B", 31: "BUTTON"}

BOARD_ART = """\
{style:white on green}+---------------------------------+{style:reset}
{style:white on green}| {style:on black}J8 (Raspberry Pi style header){style:on green}  |{style:reset}
{style:white on green}|  Citronics Limeboard            |{style:reset}
{style:white on green}|  {style:bold}LED_R LED_G LED_B BUTTON{style:normal}       |{style:reset}
{style:white on green}+---------------------------------+{style:reset}"""


class LimeboardInfo(BoardInfo):
    __slots__ = ()

    @property
    def description(self):
        return "Citronics Limeboard (Limeboard I/O firmware)"


def _headers():
    headers = {}
    for name, (rows, columns, pins) in (("J8", J8), ("ONBOARD", ONBOARD)):
        infos = {}
        for number, functions in pins.items():
            row, col = divmod(number - 1, columns)
            info = PiBoardInfo._make_pin(name, number, row + 1, col + 1, functions)
            if name == "ONBOARD":
                info = info._replace(names=info.names | {ONBOARD_NAMES[int(info.name[4:])]})
            infos[number] = info
        headers[name] = HeaderInfo(name=name, rows=rows, columns=columns, pins=infos)
    return headers


def _memory_mb():
    """The RAM size in MB: MemTotal rounded up to a power of two."""
    with open("/proc/meminfo") as f:
        mb = int(f.readline().split()[1]) // 1024
    return 1 << (mb - 1).bit_length()


def find_chip(label=CHIP_LABEL):
    """Return the number N of the /dev/gpiochipN labelled *label*."""
    for path in sorted(glob.glob("/dev/gpiochip*")):
        number = int(path[len("/dev/gpiochip"):])
        try:
            handle = lgpio.gpiochip_open(number)
        except lgpio.error:
            continue
        try:
            if lgpio.gpio_get_chip_info(handle)[3] == label:
                return number
        finally:
            lgpio.gpiochip_close(handle)
    raise OSError(f"no GPIO chip labelled {label!r}: is the Limeboard I/O firmware running?")


class LimeboardPin(LGPIOPin):
    def close(self):
        try:
            super().close()
        except lgpio.error:
            pass  # the chip has gone with a reset or replug of the STM32


class LimeboardFactory(LGPIOFactory):
    """gpiozero's lgpio factory on the Limeboard I/O firmware's GPIO chip."""

    def __init__(self, chip=None):
        # LGPIOFactory.__init__ is not called: gpiozero 2.0.1 ignores its
        # chip argument and opens gpiochip0 (gpiochip4 on a Raspberry Pi 5).
        LocalPiFactory.__init__(self)
        # Pins of this chip only: LocalPiFactory shares one pin cache between
        # all its factories, which would hand stale pins to a factory opened
        # after the STM32 has been reset or replugged.
        self.pins = {}
        self._reservations = defaultdict(list)
        self._res_lock = Lock()
        if chip is None:
            chip = find_chip()
        self._handle = lgpio.gpiochip_open(chip)
        self._chip = chip
        self.pin_class = LimeboardPin
        label = lgpio.gpio_get_chip_info(self._handle)[3]
        if label != CHIP_LABEL:
            self.close()
            raise OSError(f"gpiochip{chip} is {label!r}, not the Limeboard's {CHIP_LABEL!r}")

    def close(self):
        """Release the pins and the chip, also when the chip has already gone."""
        for pin in list(self.pins.values()):
            pin.close()
        self.pins.clear()
        if self._handle is not None:
            try:
                lgpio.gpiochip_close(self._handle)
            except lgpio.error:
                pass
            self._handle = None

    def _get_revision(self):
        return 0

    def _get_board_info(self):
        if self._info is None:
            self._info = LimeboardInfo(
                revision="limeboard", model="Limeboard", pcb_revision="",
                released="", soc="Fairphone CiSoM + STM32F401 (Limeboard I/O)",
                manufacturer="Citronics", memory=_memory_mb(), storage="eMMC",
                usb=0, usb3=0, ethernet=1, eth_speed=0,
                wifi=True, bluetooth=True, csi=0, dsi=0,
                headers=_headers(), board=BOARD_ART)
        return self._info

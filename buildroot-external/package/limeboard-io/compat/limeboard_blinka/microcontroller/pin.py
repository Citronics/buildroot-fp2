"""Pins of the Limeboard header for Adafruit Blinka.

Blinka's own lgpio Pin class, on the GPIO chip of the Limeboard I/O firmware.
Line numbers are the Raspberry Pi's BCM numbers; lines 28-31 are the onboard
RGB LED and the user button.
"""
import lgpio
from adafruit_blinka.microcontroller.generic_linux import lgpio_pin

from limeboard_compat import gpio_chip, i2c_bus

_chip = gpio_chip()
if _chip is None:
    raise RuntimeError("no Limeboard GPIO chip: is the Limeboard I/O firmware running?")
# lgpio_pin opens a Raspberry Pi GPIO chip when it is imported, or gpiochip0,
# which on the phone is the SoC's own pins. Its Pin class uses the module's
# CHIP handle: replace it with the Limeboard's chip before any pin is used.
_other = lgpio_pin.CHIP
lgpio_pin.CHIP = lgpio.gpiochip_open(_chip)
if lgpio.gpio_get_chip_info(lgpio_pin.CHIP)[3] != "dln2":
    raise RuntimeError(f"gpiochip{_chip} is not the Limeboard's GPIO chip")
if _other is not None and _other >= 0:
    lgpio.gpiochip_close(_other)

Pin = lgpio_pin.Pin

D0, D1, D2, D3, D4, D5, D6, D7, D8, D9 = (Pin(n) for n in range(10))
D10, D11, D12, D13, D14, D15, D16, D17, D18, D19 = (Pin(n) for n in range(10, 20))
D20, D21, D22, D23, D24, D25, D26, D27 = (Pin(n) for n in range(20, 28))

SDA, SCL = D2, D3
SCLK, MOSI, MISO, CE0, CE1 = D11, D10, D9, D8, D7
TXD, RXD = D14, D15

# Onboard: one RGB LED (a line per colour channel) and the user button
LED_R, LED_G, LED_B, BUTTON = Pin(28), Pin(29), Pin(30), Pin(31)

_bus = i2c_bus()
i2cPorts = ((_bus, SCL, SDA),) if _bus is not None else ()
# No /dev/spidev exists for the Limeboard's SPI bus yet. The UART is a USB
# serial port (/dev/ttyACM*): open it with pyserial.
spiPorts = ((0, SCLK, MOSI, MISO),)
uartPorts = ()

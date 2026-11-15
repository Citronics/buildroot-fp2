"""`microcontroller` for the Limeboard: the STM32 behind the header, reached
through the citronics-dln2 driver."""
import time

from . import pin  # noqa: F401
from .pin import Pin  # noqa: F401


def delay_us(delay):
    """Sleep for delay microseconds (at least: GPIO takes about 1 ms over USB)."""
    time.sleep(delay / 1e6)

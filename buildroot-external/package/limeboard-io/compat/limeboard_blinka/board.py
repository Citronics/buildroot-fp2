"""`board` for the Limeboard: Raspberry Pi pin names (D0-D27, SDA, SCL, ...)
plus the onboard LED_R, LED_G, LED_B and BUTTON."""
from microcontroller import pin

board_id = "LIMEBOARD"

D0, D1, D2, D3, D4, D5, D6, D7 = pin.D0, pin.D1, pin.D2, pin.D3, pin.D4, pin.D5, pin.D6, pin.D7
D8, D9, D10, D11, D12, D13, D14 = pin.D8, pin.D9, pin.D10, pin.D11, pin.D12, pin.D13, pin.D14
D15, D16, D17, D18, D19, D20, D21 = pin.D15, pin.D16, pin.D17, pin.D18, pin.D19, pin.D20, pin.D21
D22, D23, D24, D25, D26, D27 = pin.D22, pin.D23, pin.D24, pin.D25, pin.D26, pin.D27

SDA, SCL = pin.SDA, pin.SCL
SCLK = SCK = pin.SCLK
MOSI, MISO, CE0, CE1 = pin.MOSI, pin.MISO, pin.CE0, pin.CE1
CE0_1 = CE0
TXD, RXD = pin.TXD, pin.RXD
TX, RX = TXD, RXD

# The second I2C bus (GPIO0/1) and SPI bus (GPIO19-21, chip selects 18/17/16)
SDA0, SCL0, ID_SD, ID_SC = pin.SDA0, pin.SCL0, pin.ID_SD, pin.ID_SC
SCLK_1 = SCK_1 = pin.SCLK_1
MOSI_1, MISO_1 = pin.MOSI_1, pin.MISO_1
CE0_1, CE1_1, CE2_1 = pin.CE0_1, pin.CE1_1, pin.CE2_1

LED_R, LED_G, LED_B, BUTTON = pin.LED_R, pin.LED_G, pin.LED_B, pin.BUTTON

_i2c = None


def I2C():
    """The board's I2C bus (header pins 3 and 5), shared."""
    global _i2c
    if _i2c is None:
        import busio
        _i2c = busio.I2C(SCL, SDA)
    return _i2c


def SPI():
    """The board's SPI bus (header pins 19, 21, 23; chip selects 24 and 26)."""
    import busio
    return busio.SPI(SCLK, MOSI, MISO)

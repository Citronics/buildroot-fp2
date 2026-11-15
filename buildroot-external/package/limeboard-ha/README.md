# limeboard-ha

`limeboard-ha` makes a Citronics Limeboard a Home Assistant device. It is
one Python script that publishes the board through
[MQTT discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery):
Home Assistant creates the device and its entities by itself, with no
integration to install.

## What it publishes

| Home Assistant section | Entities |
|---|---|
| Sensors | Acceleration x/y/z, Tilt, Rotation x/y/z, Magnetic field x/y/z, Illuminance and Proximity (when the phone has them) |
| Controls | LED (the board's RGB LED) |
| Sensors (binary) | Button (the board's user button) |
| Diagnostics | CPU temperature, CPU frequency, Load, Supply voltage, RAM usage, Disk space left, Uptime, IP address |
| Configuration | Reboot |

- The phone's motion and light sensors update every `SENSOR_INTERVAL`
  seconds (default 1). The system values update every `INTERVAL` seconds
  (default 30).
- Home Assistant computes the tilt angle from the accelerometer.
- The LED and the button need the
  [Limeboard I/O firmware](https://github.com/Citronics/limeboard-firmware)
  on the board's STM32. Without it they show as unavailable, and the rest
  of the device works normally.

## Built on standard Raspberry Pi libraries

The script uses the same Python libraries as Raspberry Pi projects. Only the
phone-specific parts are its own code:

| Part | Library | Notes |
|---|---|---|
| MQTT | [paho-mqtt](https://pypi.org/project/paho-mqtt/) | versions 1 and 2 |
| System values | [psutil](https://pypi.org/project/psutil/) | temperatures, CPU frequency, load, RAM, disk, uptime |
| RGB LED and button | [gpiozero](https://gpiozero.readthedocs.io/) `RGBLED` and `Button` | through the `limeboard` pin factory, see below |
| GPIO access | [lgpio](https://abyz.me.uk/lg/py_lgpio.html) | gpiozero's backend on a Raspberry Pi 5 |
| Motion and light sensors | Linux IIO buffers | the phone's sensor hub (ADSP). There is no Raspberry Pi equivalent |
| Supply voltage | Linux IIO | the PM8941 ADC of the phone |
| Home Assistant discovery | about 30 lines of JSON | [ha-mqtt-discoverable](https://pypi.org/project/ha-mqtt-discoverable/) would need pydantic, whose core is a heavy Rust build on 32-bit ARM |

### The `limeboard` pin factory

The Limeboard I/O firmware turns the header into a Linux GPIO chip labelled
`citronics-dln2`. Its line numbers are the Raspberry Pi's BCM numbers: 0-27 are the
header's GPIO0-27, and 28-31 are the onboard LED's red, green and blue
channels and the user button.

`limeboard_gpiozero.py` (installed by the `limeboard-io` package) is a
gpiozero pin factory. It takes gpiozero's own lgpio factory and points it at
that chip, with a description of the Limeboard header instead of a Pi's. Any
gpiozero code then runs on the Limeboard:

```sh
GPIOZERO_PIN_FACTORY=limeboard python3 my_script.py
GPIOZERO_PIN_FACTORY=limeboard pinout     # the header, as on a Pi
```

```python
from gpiozero import RGBLED, Button

led = RGBLED("LED_R", "LED_G", "LED_B", pwm=False)   # the onboard LED
button = Button("BUTTON", pull_up=None, active_state=True)
led.color = (1, 0, 1)                                # magenta
```

Header pins take the usual names: `17`, `"GPIO17"`, `"BCM17"`, `"BOARD11"`.

The factory differs from gpiozero's own lgpio factory in three ways:
- It finds the chip by its label, because its number changes when the
  STM32 is reset.
- It opens that chip itself. gpiozero 2.0.1 ignores the `chip` argument of
  `LGPIOFactory` and always opens gpiochip0, the phone's own pins.
- It keeps its pins to itself, so a factory opened after a reset of the
  STM32 does not get the previous chip's dead pins back.

## The LED: 8 colours, no brightness

Each colour channel of the RGB LED is one GPIO line, on or off. The firmware
has no PWM, and switching the lines from Linux over USB would flicker. So
the LED shows 8 colours: off, red, green, blue, yellow, cyan, magenta and
white.

From Home Assistant's colour picker, a channel is on when its value is 128
or more. "On" restores the last colour.

## Installation

**Buildroot (buildroot-fp2):** enable `BR2_PACKAGE_LIMEBOARD_HA`. It forces
everything the agent needs:

- `limeboard-io` with its gpiozero option (`BR2_PACKAGE_LIMEBOARD_IO_GPIOZERO`):
  the udev rule for the firmware, dfu-util, the `limeboard` pin factory;
- python-gpiozero and python-colorzero;
- python-lgpio, built with its C library linked in and patched to wake every
  10 ms (see below). Its build uses a copy of the kernel's GPIO v2 header,
  for toolchains that declare kernel headers older than 5.10;
- python-psutil, python-paho-mqtt, and Python's `ssl` module, which
  paho-mqtt imports.

The kernel needs `CONFIG_MFD_DLN2`, `CONFIG_GPIO_DLN2` and the GPIO
character device (`CONFIG_GPIO_CDEV`, on by default).

**Debian and Ubuntu (debos-citronics):** the Lime carrier's setup script
installs:
- paho-mqtt, psutil and dfu-util from the distribution;
- gpiozero 2.0.1 and colorzero from PyPI, pinned by hash. Debian packages
  gpiozero 1.6.2, which has no lgpio factory;
- lgpio 0.2.2.0, built from source with the same patch.

The overlay installs the script, its systemd unit, the pin factory and the
udev rule.

### lgpio's alert thread

As soon as a line watches for edges (here, the button), lgpio's alert
thread wakes every 0.5 ms. On the phone's CPU that takes about 16% of a
core. Both images patch it to wake every 10 ms:
- edge events still wake it immediately;
- debounce and watchdog timings get 10 ms resolution;
- the whole agent then uses about 2-3% of a core.

## Configuration

`/etc/limeboard-ha.conf` (mode 600, it holds the MQTT password):

| Setting | Default | |
|---|---|---|
| `MQTT_HOST` | empty | broker address. The agent stays idle while it is empty |
| `MQTT_PORT` | 1883 | |
| `MQTT_USER`, `MQTT_PASSWORD` | empty | |
| `DISCOVERY_PREFIX` | `homeassistant` | Home Assistant's MQTT discovery prefix |
| `INTERVAL` | 30 | seconds between system value updates |
| `SENSOR_INTERVAL` | 1 | seconds between motion and light sensor updates |
| `NODE_ID` | `limeboard_<eMMC serial>` | MQTT and Home Assistant identifier |
| `DEVICE_NAME` | `Limeboard <eMMC serial>` | device name in Home Assistant |

In Home Assistant:
1. Install the Mosquitto broker add-on.
2. Add the MQTT integration.
3. Create a Home Assistant user for the board. Do not use `homeassistant`
   or `addons`, which the add-on reserves.

Then set `MQTT_HOST`, `MQTT_USER` and `MQTT_PASSWORD`, and restart the
agent:

```sh
systemctl restart limeboard-ha            # Debian, Ubuntu
/etc/init.d/S95limeboard-ha restart       # Buildroot
```

The board appears under Settings > Devices & services > MQTT.

## MQTT topics

`<node>` is `NODE_ID`. All state messages are retained.

| Topic | Content |
|---|---|
| `limeboard/<node>/status` | `online`, or `offline` (also the last will) |
| `limeboard/<node>/state` | JSON: `cpu_temp`, `cpu_freq`, `load`, `mem_used`, `disk_free`, `supply_voltage`, `uptime`, `ip` |
| `limeboard/<node>/sensors` | JSON: `accel_x`... `mag_z`, `light`, `prox` |
| `limeboard/<node>/io` | JSON: `led`, `r`, `g`, `b` (0 or 255), `btn` |
| `limeboard/<node>/io/status` | `online` while the LED and button are usable |
| `limeboard/<node>/cmd/led` | `on`, `off`, or `rgb <r> <g> <b>` (0-255) |
| `limeboard/<node>/cmd/reboot` | any payload reboots the phone |

## Resets of the STM32

The `citronics-dln2` chip disappears when the STM32 resets, for example during a
firmware update or a USB reset, and comes back under a new number:
- the agent checks the chip 5 times a second;
- when the chip is gone, it releases the LED and button and reports them
  offline;
- when the firmware is back, it opens the new chip.

lgpio's C library logs a line for every failed read of a removed chip. The
agent sends what C code writes to stderr to `/dev/null`, and keeps its own
messages.

## Using the LED or button from your own programs

The agent holds lines 28-31 while it runs. A second program that requests
them gets `Device or resource busy`. Control the LED from Home Assistant, or
stop the agent first. The header's GPIO0-27 are free.

## Troubleshooting

- **The LED and button are unavailable.** Check that the firmware is present
  (`lsusb | grep 1209:0001`) and that the driver created its chip
  (`gpiodetect | grep citronics-dln2`). The log says why: `journalctl -u limeboard-ha`
  on Debian, `/var/log/limeboard-ha.log` on Buildroot.
- **An entity stays in the wrong section after an update.** Home Assistant
  keeps an existing entity's category when its discovery message changes.
  Reload the MQTT integration: Settings > Devices & services > MQTT > ⋮ >
  Reload.

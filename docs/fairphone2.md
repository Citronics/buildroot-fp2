# Fairphone 2

The Fairphone 2 is the smartphone powering the Lemon board from Citronics.

| Feature              | Description                                                       |
| -------------------- | ----------------------------------------------------------------- |
| CPU                  | 4x2.26 Ghz Qualcomm Snapdragon 801 (ARMv7)                        |
| GPU                  | Qualcomm Adreno 330 GPU @ 578 Mhz                                 |
| Memory               | 2 GB LPDDR3 RAM                                                   |
| Storage              | eMMC ~20 GB on userdata partition                                 |
| Linux kernel         | 6.1x.y linux-msm8x74 mainline fork                                |
| IEx terminal         | Built-in screen or USB keyboard                                   |
| GPIO, I2C, SPI       | Limited (led, vibration motor, but no external capabilities)      |
| ADC                  | No                                                                |
| PWM                  | No                                                                |
| UART                 | [See UART](#uart)                                                 |
| Display              | 5" IPS LCD 1080x1920px HD 446 ppi                                 |
| Camera               | Yes but not supported                                             |
| Ethernet             | No                                                                |
| WiFi                 | Yes                                                               |
| Bluetooth            | Yes, but no Elixir support [See Bluetooth](#bluetooth)            |
| Audio                | Yes but not supported                                             |
| Modem                | Yes 2G/3G/LTE dual SIM, but no Elixir support [See Modem](#modem) |

## WiFi devices

The base image includes firmware and drivers for the wcn36xx wifi device onboard.

1. Make sure you can access your FP2 via ssh or UART
2. Use `nmcli --ask dev wifi connect <YOURSSID>`

## UART

A UART port is available (`ttyMSM0`) but requires disassembling the phone and soldering wires on the motherboard. For more information, please refer to this [discussion thread](https://forum.fairphone.com/t/information-about-the-debug-connector-on-the-fp2/23746/2)

## Bluetooth

Bluetooth is supported through the BlueZ stack. This requires to start dbus and bluetoothd in an Elixir application. More Elixir testing is required.

## Modem

The modem is a qmi compatible device and is not yet fully supported in Nerves.

It requires udevd to be launched for the remoteproc to be detected. It also requires the rmtfs daemon to be launched in order to allow communication with the modem. The device is properly detected, works in buildroot itself, but still requires more work in order to be supported by Nerves.

1. Make sure you can access your FP2 via ssh or UART
2. Use `nmcli connection add type gsm ifname '*' con-name gsm apn <YOUR APN>`
3. Then type `nmcli connection up gsm`

## Limeboard STM32

The Limeboard's STM32F401 runs CircuitPython. It drives the RGB LED, reads the user button and the header pins (`GPIO0` to `GPIO27`), and can press the phone's keys. `limeboard-mcu` talks to it:

- `limeboard-mcu info`, `limeboard-mcu exec '<python>'`, `limeboard-mcu repl`
- `limeboard-mcu deploy` installs the bridge (`/usr/share/limeboard-mcu/code.py`), which answers commands such as `limeboard-mcu send get` or `limeboard-mcu send rgb 0 255 0`.
- `limeboard-mcu backup <file.bin>` and `limeboard-mcu flash <file.bin>` read and write its whole flash, firmware and CIRCUITPY drive, through the ROM bootloader (USB DFU). No jumper is needed. Keep a backup before flashing anything else.

## Home Assistant

`limeboard-ha` makes the board a Home Assistant device through MQTT discovery. It covers the phone's temperature, CPU frequency, load, memory, supply voltage, uptime and address, its accelerometer (with a tilt angle), gyroscope and magnetometer, and its light and proximity sensors when present, all sampled once per interval, plus a reboot button. Once the bridge is deployed, it adds the STM32's temperature, button, RGB LED (a light with 8 colours: only blue has PWM), key presses and the header pins listed in the configuration.

1. Set `MQTT_HOST` (and `MQTT_USER`/`MQTT_PASSWORD` if your broker needs them) in `/etc/limeboard-ha.conf`.
2. Run `/etc/init.d/S95limeboard-ha restart`.
3. The board appears in Home Assistant under Settings > Devices > MQTT.

## GPS

The Qualcomm modem includes a GPS receiver. The `gps-assist` package handles downloading and injecting XTRA predicted orbit data to reduce time-to-first-fix (TTFF).

### How it works

On Android, Qualcomm's GPS HAL automatically injects assistance data (XTRA predicted orbits, reference time, approximate position) into the modem at every GPS session start. Without this, the modem performs a cold start which can take several minutes or fail entirely.

The `gps-assist` service replicates this on buildroot:

- **At boot**: downloads XTRA data from Qualcomm's servers and injects it into the modem via ModemManager
- **Every 12 hours**: a cron job refreshes XTRA data (valid for ~7 days, refreshed after 3 days)
- **Cache**: XTRA data is cached at `/var/cache/gps-assist/xtra3grc.bin` and survives reboots

XTRA data is stored in modem RAM only (not persisted in the modem's EFS). It must be re-injected after every reboot.

### Usage

```sh
# Check GPS and XTRA status
gps-assist status

# Manually trigger XTRA download and injection
gps-assist inject

# Refresh XTRA data (re-downloads if stale)
gps-assist refresh
```

### Reading GPS data

```sh
# Enable GPS and get NMEA output via ModemManager
mmcli -m any --location-enable-gps-raw --location-enable-gps-nmea
mmcli -m any --location-get
```

### Using GPS without a SIM card

GPS works independently of the cellular network — no SIM card is required to acquire a satellite fix. However there are two caveats when running without a SIM:

1. **Internet for XTRA download**: the phone needs internet connectivity to download XTRA assistance data. Without a SIM, connect to WiFi first:
   ```sh
   nmcli --ask dev wifi connect <YOURSSID>
   ```

2. **XTRA injection limitation**: on MSM8974 firmware, ModemManager reports the modem as `failed` (reason: `sim-missing`) when no SIM is inserted. In this state, XTRA data injection via `mmcli --location-inject-assistance-data` times out due to the QMI LOC service not responding. GPS will still work, but without XTRA it performs a cold start (slower TTFF). The `gps-assist` service detects this and skips XTRA injection gracefully.

3. **Enabling GPS still works**: despite the modem being in `failed` state, enabling GPS location sources works fine:
   ```sh
   mmcli -m any --location-enable-gps-raw --location-enable-gps-nmea
   mmcli -m any --location-get
   ```

### Troubleshooting

- **GPS never locks**: make sure the phone has a clear view of the sky. Indoor GPS reception is very weak on the FP2. Try near a window or outside.
- **XTRA injection fails**: check `cat /var/log/gps-assist.log` for details. If the modem is in `failed` state (no SIM), XTRA injection is expected to fail.
- **No NMEA output**: verify that the modem is detected with `mmcli -L` and that GPS is enabled with `mmcli -m any --location-status`.

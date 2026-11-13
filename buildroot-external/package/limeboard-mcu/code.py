# Limeboard MCU bridge.
#
# Serves the phone on the USB console: one command per line in, one JSON
# object per line out. Lines that do not start with "{" are CircuitPython's
# own messages. The STM32F401 has no USB endpoints left for a second serial
# channel next to the console and the CIRCUITPY drive.
#
# Ctrl-C stops the bridge and gives the REPL; Ctrl-D starts it again.
#
#   ping                      {"t": "pong", "version": N}
#   get                       {"t": "state", ...}
#   rgb <r> <g> <b>           RGB LED colour, 0-255 per channel; answers with
#                             the state
#   led <on|off>              RGB LED on (last colour, white at first) or off
#   set <GPIOn> <0|1>         header pin in output mode; answers with the
#                             state
#   mode <GPIOn> <mode>       header pin: in, in_up, in_down, out or off
#   press <key> <ms>          hold a phone key: vol_up, vol_down, camera,
#                             power (driving the line high presses it)
#
# {"t": "hello"} is sent when the bridge starts, and a state object
# whenever the user button or a header input changes. Errors come back as
# {"t": "error", "msg": ...}.
#
# Only the blue LED pin has a PWM timer, so each channel is simply on or off
# (on from 128): eight colours. The state reports the colour as shown, with
# r, g and b at 0 or 255.
import json
import sys
import time

import board
import digitalio
import microcontroller
import supervisor

VERSION = 1
MAX_PRESS_MS = 15000

KEYS = {
    "vol_up": board.FP_BUT_UP,
    "vol_down": board.FP_BUT_DWN,
    "camera": board.FP_CAM_BUT,
    "power": board.FP_PWRKEY,
}
HEADER = {name: getattr(board, name) for name in dir(board) if name.startswith("GPIO")}

leds = []
for pin in (board.LED_R, board.LED_G, board.LED_B):
    io = digitalio.DigitalInOut(pin)
    io.switch_to_output(value=False)
    leds.append(io)
# Colour restored by "led on"
last_rgb = (True, True, True)


def set_rgb(rgb):
    global last_rgb
    for io, on in zip(leds, rgb):
        io.value = on
    if any(rgb):
        last_rgb = rgb

button = digitalio.DigitalInOut(board.BTN)
button.switch_to_input()

# header pin name -> (DigitalInOut, mode)
header = {}


def state():
    s = {
        "t": "state",
        "temp": round(microcontroller.cpu.temperature, 1),
        "vdd": round(microcontroller.cpu.voltage, 3),
        "btn": int(button.value),
    }
    s["led"] = int(any(io.value for io in leds))
    for name, io in zip(("r", "g", "b"), leds):
        s[name] = 255 if io.value else 0
    for name, (io, mode) in header.items():
        s[name] = int(io.value)
    return s


def inputs():
    return (button.value,) + tuple(io.value for io, mode in header.values() if mode != "out")


def set_mode(name, mode):
    if name not in HEADER:
        raise ValueError("unknown pin " + name)
    if name in header:
        header.pop(name)[0].deinit()
    if mode == "off":
        return
    io = digitalio.DigitalInOut(HEADER[name])
    if mode == "out":
        io.switch_to_output(value=False)
    elif mode == "in":
        io.switch_to_input()
    elif mode == "in_up":
        io.switch_to_input(pull=digitalio.Pull.UP)
    elif mode == "in_down":
        io.switch_to_input(pull=digitalio.Pull.DOWN)
    else:
        io.deinit()
        raise ValueError("unknown mode " + mode)
    header[name] = (io, mode)


def press(key, ms):
    if key not in KEYS:
        raise ValueError("unknown key " + key)
    io = digitalio.DigitalInOut(KEYS[key])
    try:
        io.switch_to_output(value=True)
        time.sleep(min(max(ms, 1), MAX_PRESS_MS) / 1000)
    finally:
        # Released and undriven, as the line is when nobody presses
        io.switch_to_input()
        io.deinit()


def handle(line):
    words = line.split()
    if not words:
        return None
    cmd = words[0]
    if cmd == "ping":
        return {"t": "pong", "version": VERSION}
    if cmd == "get":
        return state()
    if cmd == "rgb" and len(words) == 4:
        set_rgb(tuple(int(w) >= 128 for w in words[1:]))
        return state()
    if cmd == "led" and len(words) == 2 and words[1] in ("on", "off"):
        set_rgb(last_rgb if words[1] == "on" else (False, False, False))
        return state()
    if cmd == "set" and len(words) == 3:
        name, value = words[1], words[2] == "1"
        if name in header and header[name][1] == "out":
            header[name][0].value = value
        else:
            raise ValueError("not an output: " + name)
        return state()
    if cmd == "mode" and len(words) == 3:
        set_mode(words[1], words[2])
        return state()
    if cmd == "press" and len(words) == 3:
        press(words[1], int(words[2]))
        return {"t": "pressed", "key": words[1]}
    raise ValueError("bad command: " + line)


def send(obj):
    # Output to a console nobody has open is dropped, never blocks
    print(json.dumps(obj))


send({"t": "hello", "version": VERSION})
buf = ""
last = inputs()
while True:
    n = supervisor.runtime.serial_bytes_available
    if n:
        buf += sys.stdin.read(n)
        while "\n" in buf or "\r" in buf:
            cut = min(i for i in (buf.find("\n"), buf.find("\r")) if i >= 0)
            raw, buf = buf[:cut], buf[cut + 1:]
            try:
                reply = handle(raw.strip())
            except Exception as e:
                reply = {"t": "error", "msg": str(e)}
            if reply is not None:
                send(reply)
        if len(buf) > 256:
            buf = ""
    now = inputs()
    if now != last:
        last = now
        send(state())
    time.sleep(0.01)

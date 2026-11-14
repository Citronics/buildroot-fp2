# Limeboard bridge for limeboard-ha: copy to the STM32's CIRCUITPY drive.
#
# One command per line on the USB console, one JSON object per line back:
#   get                       {"t": "state", ...}
#   rgb <r> <g> <b>           LED colour, 0-255 per channel (on from 128:
#                             only the blue pin has PWM, so 8 colours)
#   led <on|off>              LED on (last colour) or off
#   press <key> <ms>          hold a phone key: vol_up, vol_down, camera,
#                             power (driving the line high presses it)
# A state is also sent when the button changes; {"t": "hello"} at start.
# Ctrl-C gives the REPL, Ctrl-D starts the bridge again.
import json
import sys
import time

import board
import digitalio
import microcontroller
import supervisor

KEYS = {"vol_up": board.FP_BUT_UP, "vol_down": board.FP_BUT_DWN,
        "camera": board.FP_CAM_BUT, "power": board.FP_PWRKEY}

leds = [digitalio.DigitalInOut(p) for p in (board.LED_R, board.LED_G, board.LED_B)]
for io in leds:
    io.switch_to_output(value=False)
last_rgb = (True, True, True)
button = digitalio.DigitalInOut(board.BTN)


def state():
    rgb = [255 if io.value else 0 for io in leds]
    return {"t": "state", "temp": round(microcontroller.cpu.temperature, 1),
            "btn": int(button.value), "led": int(any(rgb)), "r": rgb[0], "g": rgb[1], "b": rgb[2]}


def set_rgb(rgb):
    global last_rgb
    for io, on in zip(leds, rgb):
        io.value = on
    if any(rgb):
        last_rgb = rgb


def press(key, ms):
    io = digitalio.DigitalInOut(KEYS[key])
    io.switch_to_output(value=True)
    time.sleep(min(int(ms), 15000) / 1000)
    io.deinit()  # released and undriven, as when nobody presses


def handle(words):
    if words[0] == "rgb":
        set_rgb(tuple(int(w) >= 128 for w in words[1:4]))
    elif words[0] == "led":
        set_rgb(last_rgb if words[1] == "on" else (False, False, False))
    elif words[0] == "press":
        press(words[1], words[2])
    return state()


print(json.dumps({"t": "hello"}))
buf, last_btn = "", button.value
while True:
    if supervisor.runtime.serial_bytes_available:
        buf += sys.stdin.read(supervisor.runtime.serial_bytes_available)
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            if line.split():
                try:
                    print(json.dumps(handle(line.split())))
                except Exception as e:
                    print(json.dumps({"t": "error", "msg": str(e)}))
    if button.value != last_btn:
        last_btn = button.value
        print(json.dumps(state()))
    time.sleep(0.01)

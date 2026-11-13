# Limeboard MCU: the bridge in code.py talks on the USB console, so keep
# CircuitPython's status bar (terminal title escapes) off it.
import supervisor

supervisor.status_bar.console = False

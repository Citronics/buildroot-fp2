# Sourced by U-Boot from /boot/boot.scr of the image in userdata.
#
# Makes the phone drivable without physical access. U-Boot waits in USB
# fastboot at every start; on "fastboot continue" it runs the U-Boot script
# staged in the fastboot buffer ("fastboot stage"), so the host decides what
# happens: "run boot_linux" boots this system with the KPSS watchdog armed
# (30 s), so that a kernel that hangs brings the phone back here. Console
# output is read back with "fastboot oem console".
#
# autoloop_go is set by boot_linux and never saved: without it this script
# was reached by a plain autoboot, and enters the loop instead of booting.
if test "${autoloop_go}" = "1"; then
	echo "autoloop: booting Linux"
else
	echo "autoloop: entering the fastboot loop"
	setenv wdt_arm 'mw.l 0xf9017004 1; mw.l 0xf9017010 0xe0000; mw.l 0xf9017014 0xf0000; mw.l 0xf9017008 1'
	setenv boot_linux 'setenv autoloop_go 1; run wdt_arm; run boot_os'
	setenv bootcmd 'while true; do fastboot usb 0; source 0x40000000 || echo "autoloop: nothing staged"; mw.l 0x40000000 0; done'
	run bootcmd
fi

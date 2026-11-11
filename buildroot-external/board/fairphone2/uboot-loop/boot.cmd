# Sourced by U-Boot from /boot/boot.scr of the image in userdata.
#
# Makes the phone drivable without physical access: U-Boot waits in USB
# fastboot at every start and boots this system on "fastboot continue", with
# the KPSS watchdog armed (30 s) so that a kernel that hangs brings the phone
# back to fastboot.
#
# autoloop_go is set by the loop itself and never saved: without it this
# script was reached by a plain autoboot, and enters the loop instead of
# booting. That holds whether or not saveenv works on this U-Boot.
if test "${autoloop_go}" = "1"; then
	echo "autoloop: booting Linux"
else
	echo "autoloop: entering the fastboot loop"
	setenv wdt_arm 'mw.l 0xf9017004 1; mw.l 0xf9017010 0xe0000; mw.l 0xf9017014 0xf0000; mw.l 0xf9017008 1'
	setenv bootcmd 'while true; do fastboot usb 0; setenv autoloop_go 1; run wdt_arm; run boot_os; done'
	if test "${autoloop}" != "4"; then
		setenv autoloop 4
		saveenv
	fi
	run bootcmd
fi

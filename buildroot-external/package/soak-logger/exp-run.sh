#!/bin/sh
# exp-run - the ONLY sanctioned way to start an experiment on the DUT.
#
#   exp-run <script> [args...]   start <script> detached, as a singleton
#   exp-run stop                 stop the running experiment (whole group)
#   exp-run status               show what is running
#
# Guarantees, earned the hard way (2026-08-02 double-schedule night):
#  - singleton: refuses to start while another experiment is alive;
#  - whole-group lifecycle: the experiment runs in its own session, so
#    stop kills the script AND all its children (spinners, flip loops);
#  - no private samplers: telemetry belongs to soak-logger (one recorder,
#    one format, per-boot files + BOOTS registry) - experiment scripts
#    only generate load and write $SOAK/.phase markers;
#  - load never survives the experiment: on stop, governors go back to
#    schedutil and stray spin processes are killed.
SOAK=/root/soak
PIDFILE=$SOAK/exp.pid
CPUFREQ=/sys/devices/system/cpu/cpufreq

mkdir -p "$SOAK"

alive() {
	[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

cleanup_load() {
	killall spin 2>/dev/null
	for p in $CPUFREQ/policy*; do
		echo schedutil > "$p/scaling_governor" 2>/dev/null
	done
	echo - > "$SOAK/.phase"
}

case "$1" in
stop)
	if alive; then
		PID=$(cat "$PIDFILE")
		kill -TERM -"$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null
		sleep 1
		kill -KILL -"$PID" 2>/dev/null
		echo "experiment $PID stopped"
	else
		echo "no experiment running"
	fi
	rm -f "$PIDFILE"
	cleanup_load
	;;
status)
	if alive; then
		echo "running: pid $(cat "$PIDFILE") phase=$(cat "$SOAK/.phase" 2>/dev/null)"
	else
		echo "idle"
	fi
	;;
"")
	echo "usage: exp-run <script> [args...] | stop | status" >&2
	exit 1
	;;
*)
	if alive; then
		echo "REFUSED: experiment $(cat "$PIDFILE") is already running (exp-run stop first)" >&2
		exit 1
	fi
	[ -x "$1" ] || { echo "not executable: $1" >&2; exit 1; }
	setsid "$@" </dev/null >/dev/null 2>&1 &
	echo $! > "$PIDFILE"
	sync "$PIDFILE" 2>/dev/null || sync
	echo "started: $* (pid $(cat "$PIDFILE"))"
	;;
esac

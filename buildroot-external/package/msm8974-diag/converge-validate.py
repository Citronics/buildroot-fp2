#!/usr/bin/env python3
"""Find the highest CPU operating point this board survives under load.

Unattended, resumable, and deliberately one-variable: the kernel and its
voltage table are fixed, and the only thing this harness changes is the
frequency ceiling.

It starts at START (default 1036800 kHz - the measured death point: that rung
under 4-core load reset the board in 5 minutes) and then bisects. A rung that
survives HOLD seconds of continuous load raises the lower bound; a rung that
resets the board lowers the upper bound. Starting at the known failure rather
than at the top of the table means the first result is the direct A/B against
the recorded death, instead of ~20 near-certain failures first.

State is fsync'd before each step, so a silent reset is itself the measurement:
the next boot reads the state, records that the rung failed, and picks the next
candidate. Nothing is ever inferred from "the board is still up" alone - the
PMIC power-off reason is logged at every start.

Thermal safety is by suspending the *load*, never by lowering the frequency, so
a PASS can never be an artifact of throttling. A separate service
(msm8974-thermal-guard) is the backstop and is intentionally not this script's
job: an experiment must not be the only thing standing between the board and
its 105 C critical trip.
"""
import os
import signal
import subprocess
import time

DIAG = os.environ.get("DIAG_DIR", "/var/log/msm8974-diag")
CPUFREQ = "/sys/devices/system/cpu/cpufreq"
STATE = DIAG + "/converge-state"
LOG = DIAG + "/converge.log"

HOLD = int(os.environ.get("HOLD", "2700"))       # seconds a rung must survive
START = int(os.environ.get("START", "1036800"))  # first rung: the measured death
FLOOR = int(os.environ.get("FLOOR", "729600"))   # scaling_min while testing
HOT = int(os.environ.get("HOT", "85000"))        # suspend load above this
COOL = int(os.environ.get("COOL", "75000"))      # resume load below this

log = open(LOG, "a", buffering=1)


def say(msg):
    line = "%s %s" % (open("/proc/uptime").read().split()[0], msg)
    log.write(line + "\n")
    os.fsync(log.fileno())
    print(line, flush=True)


def ladder():
    """Rungs the running kernel actually exposes, ascending.

    Read from the kernel rather than hardcoded: the OPP table is gated by the
    speed-bin fuse (this die reads speed1-pvs12-v1, so the three 2.3 GHz+ rungs
    that require speed bin 3 are correctly absent), and a hardcoded list would
    silently test rungs the kernel never offered.
    """
    try:
        raw = open(CPUFREQ + "/policy0/scaling_available_frequencies").read()
        return sorted({int(x) for x in raw.split()})
    except Exception:
        khz = set()
        for root, _dirs, files in os.walk("/sys/kernel/debug/opp"):
            if "rate_hz" in files and "available" in files:
                try:
                    if open(os.path.join(root, "available")).read().strip() in ("Y", "1"):
                        khz.add(int(open(os.path.join(root, "rate_hz")).read()) // 1000)
                except Exception:
                    pass
        return sorted(khz)


LADDER = ladder()


def policies():
    return [os.path.join(CPUFREQ, p) for p in os.listdir(CPUFREQ)
            if p.startswith("policy")]


def set_range(ceil_khz):
    """Ceiling under test, floor left free so DVFS is genuinely active."""
    for p in policies():
        open(p + "/scaling_max_freq", "w").write(str(ceil_khz))
        open(p + "/scaling_min_freq", "w").write(str(min(FLOOR, ceil_khz)))


DEFAULTS = {"i": -1, "inflight": 0, "soaking": 0, "elapsed": 0, "lo": -1,
            "hi": -1, "fresh": 1, "boot": 0}


def bootnum():
    """An integer identifying this boot.

    Recorded in the state file so a *process* restart (a crash, a systemd
    Restart=) is never mistaken for a *board* reset. Without this, any harness
    bug would silently be charged to the rung under test and fake a failure.
    """
    try:
        raw = open("/proc/sys/kernel/random/boot_id").read().strip().replace("-", "")
        return int(raw[:8], 16)
    except Exception:
        return 0


def read_state():
    st = dict(DEFAULTS)
    try:
        for line in open(STATE):
            k, _, v = line.strip().partition("=")
            if k in st:
                st[k] = int(v)
        st["fresh"] = 0
    except Exception:
        pass
    if st["hi"] < 0:
        st["hi"] = len(LADDER)          # no failure known yet
    return st


def write_state(**kw):
    kw.setdefault("boot", bootnum())
    with open(STATE, "w") as f:
        f.write("".join("%s=%d\n" % (k, v) for k, v in kw.items()))
        f.flush()
        os.fsync(f.fileno())


def tmax():
    t = 0
    for z in os.listdir("/sys/class/thermal"):
        if z.startswith("thermal_zone"):
            try:
                t = max(t, int(open("/sys/class/thermal/%s/temp" % z).read()))
            except Exception:
                pass
    return t


def loadavg():
    return float(open("/proc/loadavg").read().split()[0])


def have(cmd):
    return subprocess.run(["sh", "-c", "command -v " + cmd],
                          capture_output=True).returncode == 0


def load_on():
    if have("boinccmd"):
        subprocess.run(["boinccmd", "--set_run_mode", "auto"], capture_output=True)
    running = subprocess.run(["pgrep", "-x", "stress-ng"], capture_output=True).returncode == 0
    if loadavg() < 2.0 and not running and have("stress-ng"):
        subprocess.Popen(["stress-ng", "--cpu", "4", "--cpu-method", "matrixprod"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def load_off():
    if have("boinccmd"):
        subprocess.run(["boinccmd", "--set_run_mode", "never"], capture_output=True)
    subprocess.run(["pkill", "-x", "stress-ng"], capture_output=True)


def bail(signum, _frame):
    """Clean stop: drop the load and clear inflight.

    Without this a deliberate restart would look exactly like a silent reset on
    the next boot and be recorded as a rung failure - and, worse, the stress-ng
    children would outlive the supervisor holding the thermal logic, which is
    how a board once ran unguarded into its 105 C critical trip.
    """
    load_off()
    write_state(i=st["i"], inflight=0, soaking=0, elapsed=0, lo=st["lo"], hi=st["hi"])
    say("stopped by signal %d: load off, rung %s left unjudged"
        % (signum, LADDER[st["i"]] if 0 <= st["i"] < len(LADDER) else "?"))
    raise SystemExit(0)


def pon():
    for path in (DIAG + "/pon-reason.sh", "/usr/bin/msm8974-pon-reason"):
        if os.path.exists(path):
            try:
                out = subprocess.run([path], capture_output=True, text=True).stdout
                return " | ".join(l.strip() for l in out.splitlines() if l.strip())[:300]
            except Exception:
                pass
    return "(no pon-reason tool)"


def wait_for_subsystems(timeout=180):
    """Don't start judging a rung until the remoteprocs have finished booting.

    Modem bring-up (MBA then mpss) is itself a suspect: one reset landed
    mid-mpss-load while the CPUs were pinned at the safe floor. If the harness
    marked a rung "under test" before that finished, a boot-time modem reset
    would be silently charged to the frequency rung and corrupt the result.
    """
    base = "/sys/class/remoteproc"
    deadline = time.time() + timeout
    while time.time() < deadline:
        states = {}
        try:
            for d in sorted(os.listdir(base)):
                p = os.path.join(base, d, "state")
                if os.path.exists(p):
                    states[d] = open(p).read().strip()
        except Exception:
            return "no remoteproc sysfs"
        if states and all(v == "running" for v in states.values()):
            return "all up: " + ", ".join("%s=%s" % kv for kv in states.items())
        time.sleep(5)
    return "TIMEOUT waiting for remoteprocs: " + ", ".join("%s=%s" % kv for kv in states.items())


if not LADDER:
    print("no cpufreq ladder exposed - is this kernel driving DVFS at all?")
    raise SystemExit(1)

st = read_state()
signal.signal(signal.SIGTERM, bail)
signal.signal(signal.SIGINT, bail)

say("=== start: kernel=%s ladder=%d rungs (%d..%d kHz) HOLD=%ds"
    % (os.uname().release, len(LADDER), LADDER[0], LADDER[-1], HOLD))
say("PMIC previous power-off: " + pon())

if st["fresh"]:
    # Begin at the recorded death point (or the nearest rung the kernel offers).
    st["i"] = min(range(len(LADDER)), key=lambda k: abs(LADDER[k] - START))
    say("fresh run: first rung %d kHz (nearest to START=%d)" % (LADDER[st["i"]], START))
elif st["boot"] == bootnum():
    # Same boot as the last state write: the board never went down, so this is
    # a process restart. Re-test the same rung from zero and judge nothing.
    say("restarted within the same boot (not a board reset): re-testing rung "
        "%d kHz from zero, no verdict recorded"
        % (LADDER[st["i"]] if 0 <= st["i"] < len(LADDER) else -1))
else:
    prev = LADDER[st["i"]] if 0 <= st["i"] < len(LADDER) else -1
    if st["inflight"]:
        say("RESET while validating %d kHz after %ds of %ds -> rung FAILS"
            % (prev, st["elapsed"], HOLD))
        st["hi"] = min(st["hi"], st["i"])
    elif st["soaking"]:
        # It survived HOLD and then died anyway: a longer-duration failure,
        # which is strictly worse news than failing fast. Treat the rung as
        # failed and keep converging downward.
        say("RESET during the post-PASS soak at %d kHz -> that rung is NOT stable "
            "at longer duration; treating as FAILED" % prev)
        st["hi"] = min(st["hi"], st["i"])
    else:
        say("resuming after a clean stop at rung %d kHz" % prev)

    # Bisect between the highest PASS (lo) and the lowest FAIL (hi).
    if st["hi"] - st["lo"] <= 1:
        if st["lo"] < 0:
            say("EVERY rung down to %d kHz failed under load: this is not a "
                "ceiling problem - DVFS itself is not survivable as configured."
                % LADDER[0])
            set_range(FLOOR)
            load_off()
            while True:
                time.sleep(300)
                say("parked at %d kHz, no load (all rungs failed)" % FLOOR)
        st["i"] = st["lo"]
        say("converged: highest surviving rung is %d kHz (next rung up, %d kHz, "
            "fails). Soaking it to accumulate evidence."
            % (LADDER[st["lo"]], LADDER[min(st["hi"], len(LADDER) - 1)]))
    else:
        st["i"] = (st["lo"] + st["hi"]) // 2
        say("bisect: PASS<=%s FAIL>=%s -> next rung %d kHz"
            % (LADDER[st["lo"]] if st["lo"] >= 0 else "none",
               LADDER[st["hi"]] if st["hi"] < len(LADDER) else "none",
               LADDER[st["i"]]))

say("remoteprocs: " + wait_for_subsystems())

ceil = LADDER[st["i"]]
set_range(ceil)
write_state(i=st["i"], inflight=1, soaking=0, elapsed=0, lo=st["lo"], hi=st["hi"])
say("validating %d kHz (floor %d) under continuous 4-core load for %ds"
    % (ceil, min(FLOOR, ceil), HOLD))
load_on()

t0 = time.time()
loaded = True
while True:
    time.sleep(15)
    el = int(time.time() - t0)
    t = tmax()
    if loaded and t > HOT:
        load_off()
        loaded = False
        say("thermal %d mC: load suspended (frequency untouched)" % t)
    elif not loaded and t < COOL:
        load_on()
        loaded = True
        say("thermal %d mC: load resumed" % t)
    elif loaded:
        load_on()   # no-op unless the load died on us
    write_state(i=st["i"], inflight=1, soaking=0, elapsed=el, lo=st["lo"], hi=st["hi"])
    say("rung=%d t=%ds/%ds cur=%s trans=%s tmax=%d load=%.2f"
        % (ceil, el, HOLD,
           open(CPUFREQ + "/policy0/scaling_cur_freq").read().strip(),
           open(CPUFREQ + "/policy0/stats/total_trans").read().strip(),
           t, loadavg()))
    if el >= HOLD:
        break

st["lo"] = st["i"]
write_state(i=st["i"], inflight=0, soaking=1, elapsed=0, lo=st["lo"], hi=st["hi"])
say("PASS: %d kHz survived %ds of continuous 4-core load" % (ceil, HOLD))
say("holding this rung under load; a reset from here means it only *looked* stable")
while True:
    time.sleep(60)
    say("post-PASS soak rung=%d tmax=%d load=%.2f trans=%s"
        % (ceil, tmax(), loadavg(),
           open(CPUFREQ + "/policy0/stats/total_trans").read().strip()))

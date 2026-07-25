#!/bin/sh
# Re-deploy the diagnostics onto a freshly flashed device, and leave it in a
# SAFE state.
#
# "Safe" means: every boot pins the CPUs to the 729.6 MHz floor before
# userspace can ramp the governor, and no load or experiment service is
# enabled. On the reference FP2 that is the only configuration never observed
# to reset; anything above it must be enabled deliberately, by hand.
#
# Two hard-won rules are enforced here:
#   - never offline a CPU (it panics in teo_select via arch_cpu_idle_dead)
#   - never leave scaling_min_freq pinned high unattended (thermal throttling
#     becomes impossible and the board can reach its 105 C critical trip)
#
# Usage (as root, on the device):
#     msm8974-diag-deploy            # safe state + units installed, nothing running
#     DIAG_DIR=/home/citro msm8974-diag-deploy
set -e
DIAG=${DIAG_DIR:-/var/log/msm8974-diag}
BIN=${BIN_DIR:-/usr/bin}
FLOOR=${FLOOR:-729600}

mkdir -p "$DIAG"

cat > /usr/local/sbin/pin-opp.sh <<'EOF'
#!/bin/sh
# Pin every policy to one OPP: scaling_min == scaling_max means the governor
# cannot request a transition at all.
F=${1:-729600}
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$p" ] || continue
  echo "$F" > "$p/scaling_max_freq" 2>/dev/null || true
  echo "$F" > "$p/scaling_min_freq" 2>/dev/null || true
done
EOF
chmod 755 /usr/local/sbin/pin-opp.sh

cat > /etc/systemd/system/pin-early.service <<EOF
[Unit]
Description=Pin the CPUs to the safe OPP before userspace ramps the governor
DefaultDependencies=no
After=sysinit.target
Before=basic.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pin-opp.sh $FLOOR

[Install]
WantedBy=sysinit.target
EOF

cat > /etc/systemd/system/msm8974-soak-logger.service <<EOF
[Unit]
Description=msm8974 soak logger (fsync'd vitals, survives a silent reset)
After=multi-user.target

[Service]
Type=simple
Environment=DIAG_DIR=$DIAG
ExecStart=$BIN/msm8974-soak-log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pin-early.service >/dev/null
systemctl enable msm8974-soak-logger.service >/dev/null
systemctl start pin-early.service
systemctl restart msm8974-soak-logger.service

# Anything that applies load or raises the ceiling stays disabled by default.
for u in msm8974-pinned-soak msm8974-validate; do
  systemctl disable --now "$u" >/dev/null 2>&1 || true
done

echo "deployed. logs in $DIAG"
echo "pinned: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq 2>/dev/null)-$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)"
echo "previous boot ended with: $($BIN/msm8974-pon-reason 2>/dev/null || echo 'unknown')"

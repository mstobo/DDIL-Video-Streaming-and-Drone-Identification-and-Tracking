#!/usr/bin/env bash
# 01-shaper-setup.sh — run ON THE SHAPER HOST. Encodes Phase 02 (Shape the
# link): installs iproute2, applies the tc/netem ceiling+delay+jitter+loss
# profile from .env, and writes out blackout.sh for the intermittent-outage
# variant. Safe to rerun — `tc qdisc replace` (not `add`) means reapplying
# just updates the existing rule instead of erroring.
#
# Copy this whole infra/ directory (and your filled-in .env) to the shaper
# host first, e.g.:
#   scp -r -i ~/Downloads/your-key.pem infra ubuntu@<shaper-public-ip>:~/

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var SHAPE_RATE_KBIT
require_var SHAPE_DELAY_MS
require_var SHAPE_JITTER_MS
require_var SHAPE_LOSS_PCT
require_var SHAPE_LOSS_CORRELATION_PCT

log "installing iproute2"
sudo apt-get update -qq
sudo apt-get install -y -qq iproute2

IFACE=$(ip -o -4 route show to default | awk '{print $5}')
log "shaping interface: $IFACE"

sudo tc qdisc replace dev "$IFACE" root handle 1: htb default 10
sudo tc class replace dev "$IFACE" parent 1: classid 1:10 htb \
  rate "${SHAPE_RATE_KBIT}kbit" ceil "${SHAPE_RATE_KBIT}kbit"
sudo tc qdisc replace dev "$IFACE" parent 1:10 handle 10: netem \
  delay "${SHAPE_DELAY_MS}ms" "${SHAPE_JITTER_MS}ms" "${SHAPE_LOSS_CORRELATION_PCT}%" distribution normal \
  loss "${SHAPE_LOSS_PCT}%" "${SHAPE_LOSS_CORRELATION_PCT}%"

log "current shaping state:"
tc -s qdisc show dev "$IFACE"

cat <<EOF > ~/blackout.sh
#!/bin/bash
# Intermittent full-loss cycling — the DIL "comms window" variant. Ctrl-C to stop.
IFACE=\$(ip -o -4 route show to default | awk '{print \$5}')
while true; do
  sudo tc qdisc change dev "\$IFACE" parent 1:10 handle 10: netem \\
    delay ${SHAPE_DELAY_MS}ms ${SHAPE_JITTER_MS}ms ${SHAPE_LOSS_CORRELATION_PCT}% \\
    loss ${SHAPE_LOSS_PCT}% ${SHAPE_LOSS_CORRELATION_PCT}%
  sleep 45
  sudo tc qdisc change dev "\$IFACE" parent 1:10 handle 10: netem loss 100%
  sleep 8
done
EOF
chmod +x ~/blackout.sh

log "done. Reset any time with: sudo tc qdisc del dev $IFACE root"
log "Note: tc rules do not survive a reboot/stop-start — rerun this script after either."

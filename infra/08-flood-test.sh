#!/usr/bin/env bash
# 08-flood-test.sh — run ON THE SOURCE HOST (Phase 06/13's "Inject & compare").
# Starts an iperf3 flood against the receiver, well past the shaper's ceiling,
# so the direct-UDP window/viewer freezes while the Solace-bridged one stalls
# and recovers. Run 'iperf3 -s' on the receiver first (or pass
# START_SERVER=remote to have this script SSH there and start it for you).

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var IP_RCV_PRIV
require_var FLOOD_BW
require_var FLOOD_DURATION_SEC

if [ "${START_SERVER:-}" = "remote" ]; then
  require_var IP_RCV_PUB
  require_var SSH_KEY_PATH
  log "starting iperf3 server on the receiver over SSH"
  # shellcheck disable=SC2086
  ssh -i ${SSH_KEY_PATH/#\~/$HOME} -o StrictHostKeyChecking=accept-new "ubuntu@${IP_RCV_PUB}" \
    "nohup iperf3 -s >/tmp/iperf3-server.log 2>&1 &"
  sleep 1
fi

log "flooding $IP_RCV_PRIV with $FLOOD_BW UDP for ${FLOOD_DURATION_SEC}s — watch the Direct UDP and Via Solace windows now"
iperf3 -c "$IP_RCV_PRIV" -u -b "$FLOOD_BW" -t "$FLOOD_DURATION_SEC"

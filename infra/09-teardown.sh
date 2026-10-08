#!/usr/bin/env bash
# 09-teardown.sh — run ON EACH HOST individually, with which role that host
# is as the one argument: source | shaper | receiver | gpu. Stops the
# software running on that host (docker stacks, track_gen.sh, the direct-UDP
# comparison stream, the Phase 11C RTMP push) without touching AWS itself —
# run 00-aws-teardown.sh from local afterward for the instances/VPC.
#
# Usage:
#   ./09-teardown.sh source
#   ./09-teardown.sh receiver
#   ./09-teardown.sh shaper
#   ./09-teardown.sh gpu

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

ROLE="${1:-}"
case "$ROLE" in
  source)
    log "stopping the direct-UDP comparison stream, track_gen.sh, and the Phase 11C RTMP push"
    pkill -f "ffmpeg.*5004" 2>/dev/null || true
    pkill -f track_gen.sh 2>/dev/null || true
    READER_CONTAINER=$(sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -i reader | head -1 || true)
    [ -n "$READER_CONTAINER" ] && sudo docker exec "$READER_CONTAINER" pkill -f "rtmp://" 2>/dev/null || true
    log "docker compose down"
    sudo docker compose down
    ;;
  receiver)
    log "stopping viewers and bringing the receiver stack down"
    pkill -f vlc 2>/dev/null || true
    pkill -f "ffmpeg -rtsp_transport" 2>/dev/null || true
    pkill -f mosquitto_sub 2>/dev/null || true
    sudo docker compose down
    ;;
  shaper)
    log "resetting tc rules"
    IFACE=$(ip -o -4 route show to default | awk '{print $5}')
    sudo tc qdisc del dev "$IFACE" root 2>/dev/null || warn "no qdisc to remove (already reset?)"
    pkill -f blackout.sh 2>/dev/null || true
    ;;
  gpu)
    log "stopping any running detection script"
    pkill -f detect_drone 2>/dev/null || true
    ;;
  *)
    die "usage: $0 {source|shaper|receiver|gpu}"
    ;;
esac

log "done on this host. Once every host is stopped, run 00-aws-teardown.sh from local to release AWS resources."

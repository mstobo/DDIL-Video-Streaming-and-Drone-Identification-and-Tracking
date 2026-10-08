#!/usr/bin/env bash
# 06-start-video-feed.sh — run ON THE SOURCE HOST, after both 02/03 setup
# scripts have already brought their stacks up. Encodes the Phase 11C
# workaround: rather than relying on the legacy reader/server UDP-to-RTSP
# chain (which mislabels its video as mpeg4 and shows a black picture in a
# browser), push a freshly, correctly-encoded copy of the same source clip
# straight into the receiver's rtsp_bridge over RTMP.
#
# Safe to run more than once — it kills any previous push of its own before
# starting a new one, without touching Phase 00's separate direct-UDP stream.

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var IP_RCV_PRIV
require_var RTSP_BRIDGE_RTMP_PORT
require_var CAM_NAME

READER_CONTAINER="${READER_CONTAINER:-$(sudo docker ps --format '{{.Names}}' | grep -i reader | head -1)}"
if [ -z "$READER_CONTAINER" ]; then
  die "couldn't find a running 'reader' container — did 02-source-setup.sh finish successfully?"
fi
log "using container: $READER_CONTAINER"

TARGET="rtmp://${IP_RCV_PRIV}:${RTSP_BRIDGE_RTMP_PORT}/${CAM_NAME}"
log "stopping any previous push to this target (leaves Phase 00's own UDP stream alone)"
sudo docker exec "$READER_CONTAINER" pkill -f "$IP_RCV_PRIV" 2>/dev/null || true

log "starting RTMP push -> $TARGET"
sudo docker exec -d "$READER_CONTAINER" ffmpeg -re -stream_loop -1 -i src/video.mp4 -an \
  -vf scale=640:360 -c:v libx264 -preset veryfast -tune zerolatency \
  -pix_fmt yuv420p -profile:v baseline -b:v 200k \
  -f flv "$TARGET"

log "done. Give it a few seconds, then click any camera pin on the live map."
log "If the picture doesn't match a newly-swapped clip, this container may still hold a stale file handle —"
log "rerun this script (it stops its own old push first) and, if that's not enough, 'docker compose restart reader'."

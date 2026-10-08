#!/usr/bin/env bash
# 03-receiver-setup.sh — run ON THE RECEIVER HOST. Encodes the receiver half
# of Phase 03 (broker-b + sink_cascade, persistent volume) plus Phase 11C
# (rtsp_bridge / MediaMTX for the live map's camera video panel). One
# docker-compose.yml, one mediamtx.yml, then the stack comes up.
#
# Copy this whole infra/ directory (and your filled-in .env) to the receiver
# host first:
#   scp -r -i ~/Downloads/your-key.pem infra ubuntu@<receiver-public-ip>:~/

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var BROKER_ADMIN_PASS
require_var VIDEO_DEMO_USER
require_var VIDEO_DEMO_PASS
require_var BROKER_MQTT_PORT
require_var BROKER_MQTT_WS_PORT
require_var RTSP_BRIDGE_HTTP_PORT
require_var RTSP_BRIDGE_RTMP_PORT

log "installing docker + ffmpeg/iperf3/vlc/mosquitto-clients"
sudo apt-get update -qq
sudo apt-get install -y -qq ffmpeg iperf3 vlc mosquitto-clients python3
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  sudo usermod -aG docker "$USER"
  warn "added $USER to the docker group — log out/in (or 'newgrp docker') if you run docker compose by hand later"
fi

log "writing docker-compose.yml"
cat <<EOF > docker-compose.yml
services:
  broker-b:
    image: solace/solace-pubsub-standard
    shm_size: 2gb
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - username_admin_globalaccesslevel=admin
      - username_admin_password=${BROKER_ADMIN_PASS}
    ports:
      - ${BROKER_SMF_PORT}:55555
      - ${BROKER_B_SEMP_PORT}:8080
      - ${BROKER_MQTT_PORT}:1883
      - ${BROKER_MQTT_WS_PORT}:8000
    volumes:
      - broker-b-data:/var/lib/solace
  sink_cascade:
    depends_on:
      - broker-b
    image: paulusgunadi512/solace2rtsp:1.0.260915
    environment:
      - SOLACE_HOST=broker-b:55555
      - SOLACE_VPN=${BROKER_MSGVPN}
      - SOLACE_USERNAME=${VIDEO_DEMO_USER}
      - SOLACE_PASSWORD=${VIDEO_DEMO_PASS}
      - SERVER_PORT=8554
      - MEDIA_MESSAGING_MODE=GUARANTEED_NON_DURABLE
    ports:
      - 8554:8554
      - 8000:8000/udp
      - 8001:8001/udp
  rtsp_bridge:
    image: bluenviron/mediamtx:latest
    restart: unless-stopped
    volumes:
      - ./mediamtx.yml:/mediamtx.yml:ro
    ports:
      - ${RTSP_BRIDGE_HTTP_PORT}:8888
      - ${RTSP_BRIDGE_RTMP_PORT}:1935
    depends_on:
      - sink_cascade

volumes:
  broker-b-data:
EOF

log "writing mediamtx.yml (accepts a push — see Phase 11C for the RTMP-push workaround)"
cat <<'EOF' > mediamtx.yml
paths:
  c01:
EOF

log "bringing the receiver stack up"
sudo docker compose up -d

wait_for_tcp 127.0.0.1 "$BROKER_B_SEMP_PORT" 30 || true
log "Broker B Manager: http://<receiver-public-ip>:${BROKER_B_SEMP_PORT} (admin/${BROKER_ADMIN_PASS})"
log "done. Next: 04-configure-brokers.sh from local, then 05-check-bridges.sh to verify."
log "To feed the camera video panel, run 06-start-video-feed.sh on the SOURCE host (Phase 11C)."

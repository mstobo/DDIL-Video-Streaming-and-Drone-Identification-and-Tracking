#!/usr/bin/env bash
# 02-source-setup.sh — run ON THE SOURCE HOST. Encodes the source half of
# Phase 03: installs docker + the CLI tools Phase 05/06 need, writes the
# docker-compose.yml for server/reader/broker-a/src_cascade (with a
# persistent volume for the broker, per the Rev.5 disk-space lesson), makes
# sure a video file is in place, and brings the stack up.
#
# Copy this whole infra/ directory (and your filled-in .env) to the source
# host first:
#   scp -r -i ~/Downloads/your-key.pem infra ubuntu@<source-public-ip>:~/
# If you have your own clip, upload it BEFORE running this script:
#   scp -i ~/Downloads/your-key.pem /path/to/your-video.mp4 ubuntu@<source-public-ip>:~/infra/src/video.mp4
# Otherwise this script falls back to the Big Buck Bunny stand-in automatically.

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var BROKER_ADMIN_USER
require_var BROKER_ADMIN_PASS
require_var VIDEO_DEMO_USER
require_var VIDEO_DEMO_PASS
require_var CAM_NAME
require_var BROKER_MQTT_PORT

log "installing docker + ffmpeg/iperf3/vlc"
sudo apt-get update -qq
sudo apt-get install -y -qq ffmpeg iperf3 vlc mosquitto-clients python3
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  sudo usermod -aG docker "$USER"
  warn "added $USER to the docker group — log out/in (or 'newgrp docker') before running docker compose commands directly, this script uses sudo where it matters"
fi

mkdir -p src

if [ ! -s src/video.mp4 ]; then
  warn "src/video.mp4 not found (or empty) — did you scp your own clip up first?"
  log "falling back to the Big Buck Bunny stand-in clip"
  sudo apt-get install -y -qq unzip
  wget -q -O src/video.mp4.zip https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4.zip
  unzip -o -j src/video.mp4.zip -d src
  mv src/BigBuckBunny_320x180.mp4 src/video.mp4
else
  log "using existing src/video.mp4 ($(du -h src/video.mp4 | cut -f1))"
fi
ls -la src/video.mp4

log "writing docker-compose.yml"
cat <<EOF > docker-compose.yml
services:
  server:
    image: bluenviron/mediamtx
  reader:
    depends_on:
      - server
    image: selenium/ffmpeg
    command: ffmpeg -re -stream_loop -1 -i /src/video.mp4 -f rtsp rtsp://server:8554/mystream
    volumes:
      - ./src:/src
  broker-a:
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
      - ${BROKER_A_SEMP_PORT}:8080
      - ${BROKER_MQTT_PORT}:1883
    volumes:
      - broker-a-data:/var/lib/solace
  src_cascade:
    depends_on:
      - reader
      - broker-a
    image: paulusgunadi512/rtsp2solace:1.0.260915
    environment:
      - SOLACE_HOST=broker-a:55555
      - SOLACE_VPN=${BROKER_MSGVPN}
      - SOLACE_USERNAME=${VIDEO_DEMO_USER}
      - SOLACE_PASSWORD=${VIDEO_DEMO_PASS}
      - RTSP_URL=rtsp://server:8554/mystream
      - CAM_NAME=${CAM_NAME}
      - ENABLE_RTCP=0

volumes:
  broker-a-data:
EOF

log "bringing the source stack up"
sudo docker compose up -d

wait_for_tcp 127.0.0.1 "$BROKER_A_SEMP_PORT" 30 || true
log "Broker A Manager: http://<source-public-ip>:${BROKER_A_SEMP_PORT} (admin/${BROKER_ADMIN_PASS})"
log "done. Next: run 03-receiver-setup.sh on the receiver, then 04-configure-brokers.sh from local."

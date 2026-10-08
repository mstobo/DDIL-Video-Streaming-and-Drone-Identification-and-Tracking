#!/usr/bin/env bash
# 07-gpu-setup.sh — run ON THE GPU INSTANCE (Part Two / Phase 08-09). Assumes
# the Deep Learning AMI (NVIDIA drivers + PyTorch already installed). Installs
# ultralytics, downloads the drone-detection weights, and writes both the
# console-only and live-window detection scripts, filled in with this
# stack's receiver private IP so you don't have to hand-edit them.
#
# Copy this whole infra/ directory (and your filled-in .env) to the GPU
# instance first:
#   scp -r -i ~/Downloads/your-key.pem infra ubuntu@<gpu-public-ip>:~/

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var IP_RCV_PRIV
require_var CAM_NAME
require_var YOLO_WEIGHTS_URL

log "confirming GPU + PyTorch are visible"
nvidia-smi || warn "nvidia-smi failed — is this really the Deep Learning AMI / GPU instance type?"
source /opt/pytorch/bin/activate
python -c "import torch; print('torch', torch.__version__, 'cuda available:', torch.cuda.is_available())"

log "installing ultralytics"
pip install -q ultralytics

mkdir -p ~/drone-detect && cd ~/drone-detect
if [ ! -f best.pt ]; then
  log "downloading YOLO weights"
  wget -q -O best.pt "$YOLO_WEIGHTS_URL"
else
  log "best.pt already present, skipping download"
fi

RTSP_URL="rtsp://${IP_RCV_PRIV}:8554/${CAM_NAME}"
log "target stream: $RTSP_URL"

cat > detect_drone.py <<EOF
import os
os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = "rtsp_transport;tcp"

from ultralytics import YOLO

model = YOLO("best.pt")

results = model.predict(
    source="${RTSP_URL}",
    conf=0.3,
    stream=True,
    verbose=False,
    device=0,
)

for r in results:
    if len(r.boxes) > 0:
        confs = [round(c, 2) for c in r.boxes.conf.tolist()]
        print(f"DRONE DETECTED — confidence: {confs}")
        r.save(filename="last_detection.jpg")
EOF

cat > detect_drone_live.py <<EOF
import os
os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = "rtsp_transport;tcp"

import cv2
from ultralytics import YOLO

model = YOLO("best.pt")
RTSP_URL = "${RTSP_URL}"
PROCESS_EVERY_N = 1

cap = cv2.VideoCapture(RTSP_URL)
if not cap.isOpened():
    raise RuntimeError("Could not open RTSP stream")

cv2.namedWindow("Drone Detection", cv2.WINDOW_NORMAL)
cv2.resizeWindow("Drone Detection", 640, 360)

frame_count = 0
last_annotated = None

while True:
    ret, frame = cap.read()
    if not ret:
        print("Stream dropped, reconnecting...")
        cap.release()
        cap = cv2.VideoCapture(RTSP_URL)
        continue

    frame_count += 1
    if frame_count % PROCESS_EVERY_N == 0:
        results = model.predict(frame, conf=0.3, verbose=False, device=0)
        last_annotated = results[0].plot()
        if len(results[0].boxes) > 0:
            confs = [round(c, 2) for c in results[0].boxes.conf.tolist()]
            print(f"DRONE DETECTED — confidence: {confs}")

    cv2.imshow("Drone Detection", last_annotated if last_annotated is not None else frame)
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()
EOF

log "done. Console-only: python detect_drone.py"
log "Live window (needs ssh -Y and xauth/x11-apps installed): python detect_drone_live.py"
log "First 'import torch' on a cold instance can take 15-30s — that's normal, not a hang."

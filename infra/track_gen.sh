#!/usr/bin/env bash
# track_gen.sh — simulated sensor/track publisher. A single drone roams across
# the combined coverage area of one or more "camera" sites — stand-ins for
# anything from a fixed CCTV camera to someone's phone on a carrier network
# filming the sky — and is only reported while at least one of them currently
# has it in range. That's deliberate: it's the AT&T/Ericsson "the network
# itself senses the drone" story Part Three is about. As the drone moves
# between sites' coverage, the reporting `site` in the topic changes (a
# handoff) while `track_id` stays constant the whole time, and the drone can
# go briefly unreported in the gaps between coverage zones — no retained
# messages or special broker config required, since every camera "enters"
# the map the same way a track always has: by publishing.
#
# Bundled here (run ON THE SOURCE HOST, Phase 11) so it travels with the rest
# of infra/. It reads plain env vars, same as always — to pull CELL/BROKER
# defaults from .env instead of retyping them, run:
#   set -a; source ../.env; set +a; SITE=alpha TRACK_ID=trk-042 ./track_gen.sh
#
# Env vars (all optional, defaults shown):
#   SITE       site1        used only to name the DEFAULT camera roster below;
#                            ignored if CAMERAS is set explicitly
#   TRACK_ID   trk-042      track id, included in the JSON payload — constant
#                            across the whole run regardless of which camera
#                            is currently reporting it
#   LAT        32.7473      starting/roaming-center latitude (decimal degrees)
#   LON        -97.0945     starting/roaming-center longitude (decimal degrees)
#   ALT        450          starting altitude, meters
#   CAMERAS    (see below)  camera roster as a Python literal list of
#                            (name, lat, lon, range_m) tuples — the candidate
#                            sites that can "spot" the drone. Defaults to three
#                            points scattered ~1-1.5km around LAT/LON, each
#                            with an 800m detection range, so a default run
#                            already demonstrates handoffs and coverage gaps
#                            with no extra configuration. Example custom
#                            roster (two witnesses, different ranges):
#                            CAMERAS="[('phone-1',32.7473,-97.0945,600),('phone-2',32.7540,-97.1020,900)]"
#   MARGIN_M   500          how far past the outermost camera's own coverage
#                            edge the drone is still allowed to roam before
#                            being steered back toward the roster's centroid —
#                            this is what keeps it circulating through the
#                            covered area instead of wandering off forever
#   CELL       0.01         geo-cell size in degrees — MUST match the map's
#                            Cell Size field exactly or the geofence won't
#                            catch this track
#   BROKER     localhost    MQTT broker host
#   PORT       1883         MQTT broker port
#   RATE       1            publish interval, seconds (also the simulation
#                            step interval — coverage is checked every step)
#
# Publishes to: sensor/track/<reporting-camera>/cell/<latIdx>/<lonIdx>
#   Nothing is published for a step where no camera currently covers the
#   drone — that gap is the point, not a bug. The map's own dead-track
#   pruning shows it as the track going stale, then dropping, then a fresh
#   pin and trail appearing once a camera picks it back up.
#
# Example — three independently-running drones, each with its own roster:
#   SITE=alpha TRACK_ID=trk-042 LAT=32.7473 LON=-97.0945 ./track_gen.sh &
#   SITE=bravo TRACK_ID=trk-108 LAT=32.7900 LON=-97.1400 ./track_gen.sh &
#
# To stop this (and only this) generator: pkill -f track_gen.sh — the
# marker passed to python3 below is what makes that reliably kill the actual
# worker process too, not just this bash wrapper.

set -euo pipefail

SITE="${SITE:-site1}"
TRACK_ID="${TRACK_ID:-trk-042}"
LAT="${LAT:-32.7473}"
LON="${LON:--97.0945}"
ALT="${ALT:-450}"
CAMERAS="${CAMERAS:-}"
MARGIN_M="${MARGIN_M:-500}"
CELL="${CELL:-0.01}"
BROKER="${BROKER:-localhost}"
PORT="${PORT:-1883}"
RATE="${RATE:-1}"

echo "track_gen: track=$TRACK_ID roam-center=($LAT,$LON) cell=$CELL -> $BROKER:$PORT"

SITE="$SITE" TRACK_ID="$TRACK_ID" LAT="$LAT" LON="$LON" ALT="$ALT" \
CAMERAS="$CAMERAS" MARGIN_M="$MARGIN_M" CELL="$CELL" \
BROKER="$BROKER" PORT="$PORT" RATE="$RATE" \
python3 - "track_gen.sh:$SITE:$TRACK_ID" <<'PYEOF'
import os, math, random, subprocess, datetime, ast, sys, time

SITE = os.environ["SITE"]
TRACK_ID = os.environ["TRACK_ID"]
LAT = float(os.environ["LAT"])
LON = float(os.environ["LON"])
ALT = float(os.environ["ALT"])
MARGIN_M = float(os.environ["MARGIN_M"])
CELL = float(os.environ["CELL"])
BROKER = os.environ["BROKER"]
PORT = os.environ["PORT"]
RATE = float(os.environ["RATE"])

cameras_raw = os.environ.get("CAMERAS", "").strip()
if cameras_raw:
    cameras = ast.literal_eval(cameras_raw)
else:
    # Default roster: three points scattered around the start position, each
    # spaced further apart than any one camera's own range, so the drone
    # genuinely passes out of coverage between them rather than always being
    # seen by someone.
    cameras = [
        (SITE + "-cam1", LAT, LON, 800.0),
        (SITE + "-cam2", round(LAT + 0.0070, 6), round(LON - 0.0080, 6), 800.0),
        (SITE + "-cam3", round(LAT - 0.0060, 6), round(LON + 0.0090, 6), 800.0),
    ]

def meters(lat_a, lon_a, lat_b, lon_b):
    dlat_m = (lat_a - lat_b) * 111320.0
    dlon_m = (lon_a - lon_b) * 111320.0 * math.cos(math.radians(lat_b))
    return math.hypot(dlat_m, dlon_m)

centroid_lat = sum(c[1] for c in cameras) / len(cameras)
centroid_lon = sum(c[2] for c in cameras) / len(cameras)
operating_radius = max(meters(c[1], c[2], centroid_lat, centroid_lon) + c[3] for c in cameras) + MARGIN_M

print("track_gen: %d camera(s) in roster, roaming radius ~%.0fm around (%.5f, %.5f)" % (
    len(cameras), operating_radius, centroid_lat, centroid_lon), file=sys.stderr)
for c in cameras:
    print("  camera %-16s (%.5f, %.5f) range %.0fm" % (c[0], c[1], c[2], c[3]), file=sys.stderr)

lat, lon = LAT, LON
heading = random.uniform(0, 360)
speed = random.uniform(15, 40)

while True:
    heading = (heading + random.uniform(-8, 8)) % 360
    speed = max(5, min(60, speed + random.uniform(-2, 2)))

    # Leash to the roster's combined footprint, not any single camera — the
    # drone should circulate through the covered area, not fly off past it.
    dist_from_centroid = meters(lat, lon, centroid_lat, centroid_lon)
    if dist_from_centroid > operating_radius:
        east = -(lon - centroid_lon) * math.cos(math.radians(centroid_lat))
        north = -(lat - centroid_lat)
        bearing_home = math.degrees(math.atan2(east, north)) % 360
        heading = (bearing_home + random.uniform(-20, 20)) % 360

    dist_deg = speed * RATE * 0.00003
    dlat = dist_deg * math.cos(math.radians(heading))
    dlon = dist_deg * math.sin(math.radians(heading)) / math.cos(math.radians(lat))
    lat = round(lat + dlat, 7)
    lon = round(lon + dlon, 7)

    # Which camera(s), if any, currently have it in range? Nearest wins if more than one.
    covering = None
    best_dist = None
    for (name, clat, clon, crange) in cameras:
        d = meters(lat, lon, clat, clon)
        if d <= crange and (best_dist is None or d < best_dist):
            covering = (name, clat, clon)
            best_dist = d

    lat_idx = math.floor(lat / CELL)
    lon_idx = math.floor(lon / CELL)
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    confidence = round(random.uniform(0.75, 0.99), 2)

    if covering is None:
        print("-- no camera in range, drone unreported this tick")
    else:
        cam_name, cam_lat, cam_lon = covering
        payload = (
            '{"site":"%s","track_id":"%s","lat":%s,"lon":%s,'
            '"home_lat":%s,"home_lon":%s,"alt_m":%s,"speed_mps":%s,'
            '"heading_deg":%s,"confidence":%s,"ts":"%s"}'
        ) % (cam_name, TRACK_ID, lat, lon, cam_lat, cam_lon, ALT, speed, heading, confidence, ts)
        topic = "sensor/track/%s/cell/%d/%d" % (cam_name, lat_idx, lon_idx)
        subprocess.run(["mosquitto_pub", "-h", BROKER, "-p", PORT, "-t", topic, "-m", payload], check=True)
        print("-> %s  %s" % (topic, payload))

    time.sleep(RATE)
PYEOF

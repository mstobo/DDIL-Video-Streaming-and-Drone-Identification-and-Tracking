# DDIL Video Streaming and Drone Identification & Tracking

A live demo of Solace PubSub+'s resilience over a **DDIL** (Degraded, Disconnected, Intermittent, Limited) tactical link — the kind of network condition a forward unit, a ship, or a disaster-response team actually operates under, not a clean data-center connection.

The core claim: when a video or sensor feed is carried through Solace as a Guaranteed-messaging bridge, it survives a shaped, lossy, intermittently-blacked-out link — arriving late rather than not at all. A feed sent the conventional way (raw UDP, plain RTMP) over the same link just breaks. The demo puts both side by side so the difference is visible, not asserted.

## The three parts

**Part One — Video resilience.** A video source publishes into a local Solace broker; a bridge carries it across a deliberately shaped and intermittently blacked-out link to a second broker, which reconstructs the stream on the far side. Run side-by-side against a direct UDP stream over the same link, the bridged path keeps delivering (delayed, not dropped) while the direct path drops frames or stalls outright whenever the link degrades.

**Part Two — Drone detection.** A GPU instance runs a YOLO model against the reconstructed video feed in real time, detecting a drone in frame and printing (or showing, in an annotated live window) each detection with a confidence score — proving the resilient feed is good enough for a real downstream analytic, not just a picture.

**Part Three — Sensor fusion / tracking.** One or more simulated camera sites publish drone track updates (position, heading, confidence) over MQTT into the same Solace mesh, crossing the same shaped link via a second Guaranteed bridge subscription. A live browser map plots every active track, shows coverage handoffs between sites, and supports drawing a geofence to filter what it subscribes to — standing in for "the network itself senses the drone," whether the sensor is a fixed camera or a phone on a carrier network.

Full build-and-run instructions for all three parts are in **[`tactical-field-manual.html`](./tactical-field-manual.html)** — open it in a browser. It's the single source of truth; everything else in this repo either automates a piece of it or is a focused excerpt of it.

## Architecture

```
  SOURCE  ───────────▶  SHAPER  ───────────▶  RECEIVER
 (Broker A,              (tc/netem:            (Broker B,
  src_cascade,            rate cap, delay,       sink_cascade,
  direct-UDP feed)        jitter, loss,          rtsp_bridge,
                          blackout cycling)      live map's video panel)
                                                        │
                                             (optional)  ▼
                                                     GPU instance
                                                (YOLO drone detection)
```

Every flow — video and sensor-track traffic alike — is forced through the shaper instance via route-table changes, so the shaping is real network degradation, not a simulated delay inside the application. The shaper itself runs nothing but `iproute2`; it's a deliberately minimal, single-purpose instance.

## Repo layout

| Path | What it is |
|---|---|
| `tactical-field-manual.html` | The full manual — every phase, every command, in build order. Start here. |
| `tactical-bridge-runbook.html` | Focused runbook: just the two-broker bridge setup. |
| `tactical-link-runbook.html` | Focused runbook: just the shaped-link / shaper setup. |
| `tactical-relay-diagrams.html` | Standalone architecture diagrams (video path and sensor-track path, both crossing the shaper). |
| `tactical-range-card.html` | A one-page cheat sheet / "say this, do this" card for presenting the demo live. |
| `tactical-demo-brief.pptx` | Slide deck version of the brief. |
| `track-fusion-map.html` | The live sensor-fusion map viewer (Part Three) — open directly in a browser, no server needed. |
| `track-fusion-map-sap-ca.html` | Same viewer, pre-configured for a second demo region (Ottawa-area coordinates). |
| `infra/` | `.env`-driven shell scripts that automate everything the manual walks through by hand — see **[`infra/README.md`](./infra/README.md)** for the run order. |

## Getting started

If you want the scripted path:

```bash
cd infra
cp .env.example .env
# edit .env — fill in AWS_REGION, KEY_NAME, and your own values;
# .env is gitignored, so your real credentials never get committed
```

then follow `infra/README.md`'s run order.

If you want to build it by hand (or understand what the scripts are actually doing), work through `tactical-field-manual.html` phase by phase.

## A note on credentials

Nothing in this repo contains a real password, API key, or infrastructure identifier. `infra/.env.example` uses placeholder values only (`changeme`) — your actual broker passwords and AWS details belong in your own local `.env`, which `.gitignore` excludes from version control. Don't commit a filled-in `.env`, and don't paste real IPs or credentials into the HTML docs if you fork or extend them.

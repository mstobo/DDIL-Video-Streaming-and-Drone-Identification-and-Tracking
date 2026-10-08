# DIL demo infra scripts

Everything the Tactical Field Manual walks through by hand, as a set of
`.env`-driven scripts — one config file instead of re-typing IPs and
credentials into a dozen SSH sessions. Each script says at the top which
host it runs on and which manual phase it encodes.

## First time setup

```bash
cp .env.example .env
# edit .env: at minimum set AWS_REGION and KEY_NAME before provisioning
```

## Run order

| # | Script | Runs on | Manual phase |
|---|---|---|---|
| 00 | `00-aws-provision.sh` | local | Phase 00/01 — VPC, subnets, SG, instances, routing through the shaper. Set `BUILD_PART_TWO=true` in `.env` first if you want the GPU instance too. |
| — | `00-aws-teardown.sh` | local | Phase 07/10 AWS-side teardown — run this last, not now |
| 01 | `01-shaper-setup.sh` | shaper | Phase 02 — tc/netem shaping + `blackout.sh` |
| 02 | `02-source-setup.sh` | source | Phase 03 (source half) — docker, docker-compose.yml, video file |
| 03 | `03-receiver-setup.sh` | receiver | Phase 03 (receiver half) + Phase 11C — broker-b, sink_cascade, rtsp_bridge, mediamtx.yml |
| 04 | `04-configure-brokers.sh` | local | Phase 04/12 — client usernames, client profile, both bridges, Direct subscriptions (see caveat below) |
| 05 | `05-check-bridges.sh` | local | Verifies both bridge directions are actually Up with a real remote address |
| 06 | `06-start-video-feed.sh` | source | Phase 11C — the RTMP-push workaround that feeds the live map's camera video panel |
| 07 | `07-gpu-setup.sh` | gpu | Phase 08/09 — YOLO drone detection (optional, Part Two) |
| — | `track_gen.sh` | source | Phase 11 — sensor track simulator (optional, Part Three; run as many instances as you want simultaneous drones) |
| 08 | `08-flood-test.sh` | source | Phase 06/13 — the iperf3 flood that makes the whole demo's point |
| 09 | `09-teardown.sh <role>` | each host | Phase 07/10/14 — stops docker/processes on that one host |

The live map (`track-fusion-map.html`) and the manual itself
(`tactical-field-manual.html`) aren't part of this bundle — they're plain
files you already have; open the map locally in a browser once `track_gen.sh`
and the SSH tunnel from Phase 11B are up.

## Getting each script onto its host

You still need to physically get this `infra/` folder (with your filled-in
`.env`) onto each EC2 instance — these are local shell scripts, not a
remote-execution tool:

```bash
scp -r -i ~/Downloads/your-key.pem infra ubuntu@<source-public-ip>:~/
scp -r -i ~/Downloads/your-key.pem infra ubuntu@<receiver-public-ip>:~/
scp -r -i ~/Downloads/your-key.pem infra ubuntu@<shaper-public-ip>:~/
```

If you have your own video clip, upload it to the source host BEFORE running
`02-source-setup.sh`, at `infra/src/video.mp4` — otherwise the script falls
back to downloading a stand-in automatically:

```bash
scp -i ~/Downloads/your-key.pem /path/to/your-video.mp4 \
  ubuntu@<source-public-ip>:~/infra/src/video.mp4
```

## The one thing that isn't automated

`04-configure-brokers.sh` creates both bridges and their Direct subscriptions
via Solace's SEMP v2 API, but deliberately does **not** attempt the one
Guaranteed/queue-bound subscription (`s/v/c01/>` on Broker B's bridge, bound
to queue `bridge2bQ`) — that corner of the SEMP schema wasn't something we
could verify with confidence, and guessing at it risked a worse outcome than
just doing it once by hand. The script prints the exact three-click
instructions for that one step when it finishes. Everything else it does —
usernames, client profile flags, bridge creation, the two Direct
subscriptions — prints its own HTTP status per call, so a failure is visible
immediately rather than silent; if anything reports 4xx, finish that specific
step in Broker Manager (Phase 04 has the exact fields) and move on, the rest
of the script's steps don't depend on it.

## Rerunning

Every setup script is written to be safe to run again: docker-compose
files get rewritten and re-applied, `tc qdisc replace` (not `add`) updates
shaping in place, and the AWS provisioning script skips anything whose id
is already recorded in `.env`. `04-configure-brokers.sh`'s create calls will
report 400/409 on already-existing objects on a rerun, which is expected,
not a failure.

#!/usr/bin/env bash
# 05-check-bridges.sh — run on your LOCAL machine. Read-only SEMP v2 monitor
# calls (GET only — nothing here can misconfigure anything) that automate
# the exact manual check this whole build kept coming back to: is a bridge
# direction actually Up, with a real remote address and growing uptime, or
# is it stuck at 0.0.0.0:0 (the "remote VPN address is a v:<hash>, not a real
# IP" footgun from Phase 04)?
#
# Uses python3's json module to pull out the fields that matter, since a raw
# SEMP response is fairly deep and not fun to eyeball.

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var IP_SRC_PUB
require_var IP_RCV_PUB
require_var BROKER_MSGVPN

check_bridge() {
  local label="$1" host="$2" port="$3" bridge_name="$4"
  echo
  log "== $label: $bridge_name @ $host:$port =="
  local resp
  resp=$(semp_monitor "$host" "$port" "/msgVpns/${BROKER_MSGVPN}/bridges/${bridge_name},primary" 2>/dev/null) || {
    warn "couldn't reach $host:$port — is the broker up and this port reachable from here?"
    return
  }
  python3 - "$resp" <<'PYEOF'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception as e:
    print("  couldn't parse SEMP response:", e)
    sys.exit(0)
d = data.get("data", {})
if not d:
    print("  no data returned — bridge may not exist yet, or the msgVpn/name is wrong")
    print("  raw:", json.dumps(data)[:300])
    sys.exit(0)
up = d.get("up")
if up is None:
    up = d.get("enabled")
remote = d.get("remoteAddress") or "?"
uptime = d.get("uptime")
print(f"  enabled/up: {up}")
print(f"  remote address: {remote}")
print(f"  uptime (s): {uptime}")
if str(remote).startswith("0.0.0.0") or uptime in (0, None):
    print("  >>> looks DOWN — check the Remote Message VPN address isn't a v:<hash>, it must be the real private IP")
else:
    print("  >>> looks healthy")
PYEOF
}

check_bridge "Broker A" "$IP_SRC_PUB" "$BROKER_A_SEMP_PORT" bridge-to-b
check_bridge "Broker B" "$IP_RCV_PUB" "$BROKER_B_SEMP_PORT" bridge-to-a

echo
log "If either looks DOWN, see Phase 04's 'VPN address footgun' callout in the manual, or the SEMP field"
log "names printed by 04-configure-brokers.sh may not exactly match this broker version — finish that one"
log "bridge by hand in Broker Manager and re-run this check."

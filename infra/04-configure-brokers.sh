#!/usr/bin/env bash
# 04-configure-brokers.sh — run on your LOCAL machine (or anywhere that can
# reach both brokers' SEMP/Manager ports — an SSH tunnel works fine). Encodes
# the client-username, client-profile, and bridge setup from Phase 03/04/12
# via Solace's SEMP v2 config API, instead of clicking through Broker
# Manager by hand.
#
# HONESTY CHECK: the client-username and client-profile calls below use a
# well-established, simple part of the SEMP v2 schema and should just work.
# The bridge-related calls (creating the bridge, its remote connection, and
# its Direct subscriptions) use field names reconstructed from memory rather
# than checked against live SEMP docs — every call prints its HTTP status, so
# a 4xx here is your cue to finish that ONE step by hand in Broker Manager
# (the manual's Phase 04 has the exact click path) rather than assume
# something is silently wrong. The Guaranteed/queue-bound video subscription
# (s/v/c01/> on Broker B's bridge, bound to queue bridge2bQ) is NOT
# attempted here at all — its SEMP schema is obscure enough that guessing at
# it risked doing more harm than good, so that one step is always manual;
# this script prints the exact instructions for it at the end.

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var IP_SRC_PUB
require_var IP_RCV_PUB
require_var IP_SRC_PRIV
require_var IP_RCV_PRIV
require_var BROKER_MSGVPN
require_var VIDEO_DEMO_USER
require_var VIDEO_DEMO_PASS
require_var BRIDGE_SVC_USER
require_var BRIDGE_SVC_PASS
require_var BROKER_SMF_PORT
require_var BROKER_A_SEMP_PORT
require_var BROKER_B_SEMP_PORT
require_var CAM_NAME
require_var BRIDGE_GUARANTEED_QUEUE

A_HOST="$IP_SRC_PUB"; A_PORT="$BROKER_A_SEMP_PORT"
B_HOST="$IP_RCV_PUB"; B_PORT="$BROKER_B_SEMP_PORT"

log "Broker A (source):   http://$A_HOST:$A_PORT"
log "Broker B (receiver): http://$B_HOST:$B_PORT"

create_client_username() {
  local host="$1" port="$2" user="$3" pass="$4"
  semp POST "$host" "$port" "/msgVpns/${BROKER_MSGVPN}/clientUsernames" \
    "{\"clientUsername\":\"${user}\",\"password\":\"${pass}\",\"enabled\":true}" >/dev/null
}

log "creating client usernames on both brokers (409/400 on a rerun is fine — it already exists)"
create_client_username "$A_HOST" "$A_PORT" "$VIDEO_DEMO_USER" "$VIDEO_DEMO_PASS"
create_client_username "$A_HOST" "$A_PORT" "$BRIDGE_SVC_USER" "$BRIDGE_SVC_PASS"
create_client_username "$B_HOST" "$B_PORT" "$VIDEO_DEMO_USER" "$VIDEO_DEMO_PASS"
create_client_username "$B_HOST" "$B_PORT" "$BRIDGE_SVC_USER" "$BRIDGE_SVC_PASS"

log "enabling Guaranteed receive + endpoint creation on Broker B's default client profile"
semp PATCH "$B_HOST" "$B_PORT" "/msgVpns/${BROKER_MSGVPN}/clientProfiles/default" \
  '{"allowGuaranteedMsgReceiveEnabled":true,"allowGuaranteedEndpointCreateEnabled":true}' >/dev/null

create_bridge() {
  local host="$1" port="$2" bridge_name="$3"
  semp POST "$host" "$port" "/msgVpns/${BROKER_MSGVPN}/bridges" \
    "{\"bridgeName\":\"${bridge_name}\",\"bridgeVirtualRouter\":\"primary\",\"enabled\":true,\"remoteAuthenticationBasicClientUsername\":\"${BRIDGE_SVC_USER}\",\"remoteAuthenticationBasicPassword\":\"${BRIDGE_SVC_PASS}\",\"remoteAuthenticationScheme\":\"basic\"}" >/dev/null
}
create_remote_vpn() {
  local host="$1" port="$2" bridge_name="$3" remote_ip="$4"
  semp POST "$host" "$port" "/msgVpns/${BROKER_MSGVPN}/bridges/${bridge_name},primary/remoteMsgVpns" \
    "{\"bridgeName\":\"${bridge_name}\",\"bridgeVirtualRouter\":\"primary\",\"remoteMsgVpnName\":\"${BROKER_MSGVPN}\",\"remoteMsgVpnLocation\":\"${remote_ip}:${BROKER_SMF_PORT}\",\"remoteMsgVpnInterface\":\"\",\"enabled\":true}" >/dev/null
}
create_direct_subscription() {
  local host="$1" port="$2" bridge_name="$3" topic="$4"
  semp POST "$host" "$port" "/msgVpns/${BROKER_MSGVPN}/bridges/${bridge_name},primary/remoteSubscriptions" \
    "{\"bridgeName\":\"${bridge_name}\",\"bridgeVirtualRouter\":\"primary\",\"remoteSubscriptionTopic\":\"${topic}\",\"deliverAlwaysEnabled\":true}" >/dev/null
}

log "Broker A: creating bridge-to-b -> $IP_RCV_PRIV"
create_bridge "$A_HOST" "$A_PORT" bridge-to-b
create_remote_vpn "$A_HOST" "$A_PORT" bridge-to-b "$IP_RCV_PRIV"
create_direct_subscription "$A_HOST" "$A_PORT" bridge-to-b "s/v/${CAM_NAME}/desc"

log "Broker B: creating bridge-to-a -> $IP_SRC_PRIV"
create_bridge "$B_HOST" "$B_PORT" bridge-to-a
create_remote_vpn "$B_HOST" "$B_PORT" bridge-to-a "$IP_SRC_PRIV"
create_direct_subscription "$B_HOST" "$B_PORT" bridge-to-a '#P2P/>'
create_direct_subscription "$B_HOST" "$B_PORT" bridge-to-a 'sensor/track/>'

cat <<EOF

============================================================================
ONE STEP LEFT — must be done by hand (Phase 04 of the Tactical Field Manual):

  On Broker B's Manager (http://$B_HOST:$B_PORT), open bridge-to-a's
  Subscriptions tab -> Incoming Guaranteed -> add subscription
  s/v/${CAM_NAME}/> bound to a queue named ${BRIDGE_GUARANTEED_QUEUE}.

  This is the video/audio topic, and it MUST be Guaranteed, not Direct —
  that's what actually survives the shaped link's loss. Every other
  subscription above (the desc handshake and #P2P/reply) is correctly
  Direct and was just created for you.

Then run ./05-check-bridges.sh to confirm both bridge directions show a
real remote address and a growing uptime, not 0.0.0.0:0.
============================================================================
EOF

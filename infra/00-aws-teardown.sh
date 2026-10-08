#!/usr/bin/env bash
# 00-aws-teardown.sh — run on your LOCAL machine. Encodes Phase 07/10's AWS-side
# teardown: terminates every instance recorded in .env (source, shaper,
# receiver, and the GPU instance if Part Two was built), then removes the
# networking around them. Run the per-host `08-teardown.sh` on each box FIRST
# to stop docker/track_gen cleanly, though it doesn't strictly matter once
# you're about to terminate the instance anyway.
#
# Safe to run with only some instances present (e.g. Part Two never built) —
# each step is skipped if its id isn't set in .env.

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env
require_var AWS_REGION

aws_ec2() { aws ec2 "$@" --region "$AWS_REGION"; }

echo "About to terminate:"
for v in INSTANCE_SRC INSTANCE_SHAPE INSTANCE_RCV INSTANCE_GPU; do
  [ -n "${!v:-}" ] && echo "  $v = ${!v}"
done
read -r -p "Type 'yes' to continue: " confirm
[ "$confirm" = "yes" ] || { log "aborted"; exit 1; }

ids=()
for v in INSTANCE_SRC INSTANCE_SHAPE INSTANCE_RCV INSTANCE_GPU; do
  [ -n "${!v:-}" ] && ids+=("${!v}")
done
if [ "${#ids[@]}" -gt 0 ]; then
  log "terminating instances: ${ids[*]}"
  aws_ec2 terminate-instances --instance-ids "${ids[@]}"
  aws_ec2 wait instance-terminated --instance-ids "${ids[@]}"
else
  warn "no instance ids found in .env, nothing to terminate"
fi

if [ -n "${SG_ID:-}" ]; then
  log "deleting security group $SG_ID"
  aws_ec2 delete-security-group --group-id "$SG_ID" || warn "couldn't delete SG (still in use? retry in a minute)"
fi

for pair in "SUBNET_SRC:RTB_SRC" "SUBNET_SHAPE:RTB_SHAPE" "SUBNET_RCV:RTB_RCV"; do
  sn_var="${pair%%:*}"; rtb_var="${pair##*:}"
  sn="${!sn_var:-}"; rtb="${!rtb_var:-}"
  # subnets first — a route table can't be deleted while still associated with one
  [ -n "$sn" ] && { aws_ec2 delete-subnet --subnet-id "$sn" || warn "couldn't delete $sn_var"; }
  [ -n "$rtb" ] && { aws_ec2 delete-route-table --route-table-id "$rtb" || warn "couldn't delete $rtb_var"; }
done

if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  log "detaching/deleting internet gateway"
  aws_ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" || warn "couldn't detach IGW"
  aws_ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" || warn "couldn't delete IGW"
fi

if [ -n "${VPC_ID:-}" ]; then
  log "deleting VPC $VPC_ID"
  aws_ec2 delete-vpc --vpc-id "$VPC_ID" || warn "couldn't delete VPC (something still attached? check the console)"
fi

log "done. Clearing the discovered ids out of .env so a rerun of 00-aws-provision.sh starts fresh."
for v in INSTANCE_SRC INSTANCE_SHAPE INSTANCE_RCV INSTANCE_GPU IP_SRC_PUB IP_SRC_PRIV \
         IP_SHAPE_PUB IP_RCV_PUB IP_RCV_PRIV IP_GPU_PUB ENI_SHAPE VPC_ID SUBNET_SRC \
         SUBNET_SHAPE SUBNET_RCV SG_ID IGW_ID RTB_SRC RTB_SHAPE RTB_RCV; do
  write_env_value "$v" ""
done

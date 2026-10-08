#!/usr/bin/env bash
# 00-aws-provision.sh — run on your LOCAL machine (needs the AWS CLI configured).
# Encodes Tactical Field Manual Phase 00 (Provision) and Phase 01 (Force the
# route): one VPC, three subnets, a security group, three instances, and the
# routes that send source<->receiver traffic through the shaper. Idempotent
# in the sense that it skips any resource whose id is already recorded in
# .env — safe to rerun if it fails partway through.
#
# Writes every discovered id/IP back into .env so the other scripts (and a
# human reading it later) don't have to go hunting through the AWS console.

cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
load_env

require_var AWS_REGION
require_var KEY_NAME
AZ="${AWS_REGION}a"

aws_ec2() { aws ec2 "$@" --region "$AWS_REGION"; }

# ---- VPC / IGW ------------------------------------------------------------
if [ -z "${VPC_ID:-}" ]; then
  log "creating VPC"
  VPC_ID=$(aws_ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
  aws_ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=dil-demo
  write_env_value VPC_ID "$VPC_ID"
else
  log "VPC_ID already set ($VPC_ID), skipping"
fi

if [ -z "${IGW_ID:-}" ]; then
  log "creating internet gateway"
  IGW_ID=$(aws_ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
  aws_ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
  write_env_value IGW_ID "$IGW_ID"
else
  log "IGW_ID already set ($IGW_ID), skipping"
fi

# ---- Subnets ----------------------------------------------------------------
create_subnet_if_needed() {
  local var="$1" cidr="$2"
  local current="${!var:-}"
  if [ -z "$current" ]; then
    log "creating subnet $var ($cidr)"
    current=$(aws_ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
      --availability-zone "$AZ" --query 'Subnet.SubnetId' --output text)
    aws_ec2 modify-subnet-attribute --subnet-id "$current" --map-public-ip-on-launch
    write_env_value "$var" "$current"
    printf '%s' "$current"
  else
    log "$var already set ($current), skipping"
    printf '%s' "$current"
  fi
}
SUBNET_SRC=$(create_subnet_if_needed SUBNET_SRC 10.0.1.0/24)
SUBNET_SHAPE=$(create_subnet_if_needed SUBNET_SHAPE 10.0.2.0/24)
SUBNET_RCV=$(create_subnet_if_needed SUBNET_RCV 10.0.3.0/24)

# ---- Route tables (one per subnet, each with a route to the internet) ----
create_rtb_if_needed() {
  local var="$1" subnet="$2"
  local current="${!var:-}"
  if [ -z "$current" ]; then
    log "creating route table $var"
    current=$(aws_ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
    aws_ec2 create-route --route-table-id "$current" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
    aws_ec2 associate-route-table --route-table-id "$current" --subnet-id "$subnet"
    write_env_value "$var" "$current"
    printf '%s' "$current"
  else
    log "$var already set ($current), skipping"
    printf '%s' "$current"
  fi
}
RTB_SRC=$(create_rtb_if_needed RTB_SRC "$SUBNET_SRC")
RTB_SHAPE=$(create_rtb_if_needed RTB_SHAPE "$SUBNET_SHAPE")
RTB_RCV=$(create_rtb_if_needed RTB_RCV "$SUBNET_RCV")

# ---- Security group ---------------------------------------------------------
if [ -z "${SG_ID:-}" ]; then
  log "creating security group"
  SG_ID=$(aws_ec2 create-security-group --group-name "dil-demo-sg-$(date +%s)" \
    --description "DIL demo" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
  MY_IP="$(curl -4 -s ifconfig.me)/32"
  aws_ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP"
  aws_ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol -1 --cidr 10.0.0.0/16
  write_env_value SG_ID "$SG_ID"
else
  log "SG_ID already set ($SG_ID), skipping"
fi

# ---- Instances --------------------------------------------------------------
AMI_ID=$(aws ssm get-parameters --region "$AWS_REGION" --names \
  /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
  --query 'Parameters[0].Value' --output text)

launch_if_needed() {
  local var="$1" subnet="$2" name="$3" itype="$4"
  local current="${!var:-}"
  if [ -z "$current" ]; then
    log "launching $name ($itype) in $subnet"
    current=$(aws_ec2 run-instances --image-id "$AMI_ID" --instance-type "$itype" \
      --key-name "$KEY_NAME" --subnet-id "$subnet" --security-group-ids "$SG_ID" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
      --query 'Instances[0].InstanceId' --output text)
    write_env_value "$var" "$current"
  else
    log "$var already set ($current), skipping"
  fi
  printf '%s' "$current"
}
INSTANCE_SRC=$(launch_if_needed INSTANCE_SRC "$SUBNET_SRC" dil-source t3.medium)
INSTANCE_SHAPE=$(launch_if_needed INSTANCE_SHAPE "$SUBNET_SHAPE" dil-shaper t3.small)
INSTANCE_RCV=$(launch_if_needed INSTANCE_RCV "$SUBNET_RCV" dil-receiver t3.medium)

log "waiting for instances to reach running state..."
aws_ec2 wait instance-running --instance-ids "$INSTANCE_SRC" "$INSTANCE_SHAPE" "$INSTANCE_RCV"

# ---- Discover IPs and write them back --------------------------------------
read_ip() {
  local instance="$1" field="$2"
  aws_ec2 describe-instances --instance-ids "$instance" \
    --query "Reservations[0].Instances[0].$field" --output text
}
write_env_value IP_SRC_PUB   "$(read_ip "$INSTANCE_SRC" PublicIpAddress)"
write_env_value IP_SRC_PRIV  "$(read_ip "$INSTANCE_SRC" PrivateIpAddress)"
write_env_value IP_SHAPE_PUB "$(read_ip "$INSTANCE_SHAPE" PublicIpAddress)"
write_env_value IP_RCV_PUB   "$(read_ip "$INSTANCE_RCV" PublicIpAddress)"
write_env_value IP_RCV_PRIV  "$(read_ip "$INSTANCE_RCV" PrivateIpAddress)"
ENI_SHAPE=$(aws_ec2 describe-instances --instance-ids "$INSTANCE_SHAPE" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
write_env_value ENI_SHAPE "$ENI_SHAPE"

# ---- Phase 01: force the route through the shaper --------------------------
log "disabling source/dest check on the shaper"
aws_ec2 modify-instance-attribute --instance-id "$INSTANCE_SHAPE" --no-source-dest-check

log "routing source<->receiver traffic through the shaper's ENI"
aws_ec2 create-route --route-table-id "$RTB_SRC" --destination-cidr-block 10.0.3.0/24 \
  --network-interface-id "$ENI_SHAPE" 2>/dev/null || warn "route may already exist on RTB_SRC"
aws_ec2 create-route --route-table-id "$RTB_RCV" --destination-cidr-block 10.0.1.0/24 \
  --network-interface-id "$ENI_SHAPE" 2>/dev/null || warn "route may already exist on RTB_RCV"

log "done. Re-run 'source .env' or re-open a shell before using the other scripts."
log "Source:   ssh -i $SSH_KEY_PATH ubuntu@$(read_ip "$INSTANCE_SRC" PublicIpAddress)"
log "Shaper:   ssh -i $SSH_KEY_PATH ubuntu@$(read_ip "$INSTANCE_SHAPE" PublicIpAddress)"
log "Receiver: ssh -i $SSH_KEY_PATH ubuntu@$(read_ip "$INSTANCE_RCV" PublicIpAddress)"

# ---- Optional: Part Two's GPU instance (Phase 08) --------------------------
if [ "${BUILD_PART_TWO:-false}" = "true" ] && [ -z "${INSTANCE_GPU:-}" ]; then
  log "BUILD_PART_TWO=true — provisioning the drone-detection GPU instance too"
  AMI_GPU=$(aws ssm get-parameter --region "$AWS_REGION" \
    --name /aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-pytorch-2.7-ubuntu-22.04/latest/ami-id \
    --query "Parameter.Value" --output text)
  INSTANCE_GPU=$(aws_ec2 run-instances --image-id "$AMI_GPU" --instance-type "${GPU_INSTANCE_TYPE:-g4dn.xlarge}" \
    --key-name "$KEY_NAME" --subnet-id "$SUBNET_RCV" --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=drone-detect-gpu}]' \
    --query 'Instances[0].InstanceId' --output text)
  write_env_value INSTANCE_GPU "$INSTANCE_GPU"
  aws_ec2 wait instance-running --instance-ids "$INSTANCE_GPU"
  write_env_value IP_GPU_PUB "$(read_ip "$INSTANCE_GPU" PublicIpAddress)"
  log "GPU:      ssh -i $SSH_KEY_PATH ubuntu@$(read_ip "$INSTANCE_GPU" PublicIpAddress)"
elif [ -n "${INSTANCE_GPU:-}" ]; then
  log "INSTANCE_GPU already set ($INSTANCE_GPU), skipping"
fi

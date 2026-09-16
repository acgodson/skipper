#!/usr/bin/env bash
# Additive, idempotent AWS setup: our inbound SG rules + an Elastic IP.
# Never modifies or deletes an existing rule.
set -euo pipefail
cd "$(dirname "$0")"
source ./_ssm.sh

SG=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --profile "$PROFILE" \
     --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
echo "Security group: $SG"

authorize() { # proto from to desc
  if aws ec2 authorize-security-group-ingress --group-id "$SG" --region "$REGION" --profile "$PROFILE" \
      --ip-permissions "IpProtocol=$1,FromPort=$2,ToPort=$3,IpRanges=[{CidrIp=0.0.0.0/0,Description='$4'}]" \
      >/dev/null 2>&1; then
    echo "  added   $1/$2-$3  ($4)"
  else
    echo "  exists  $1/$2-$3  ($4)"
  fi
}
echo "Adding inbound rules (additive only):"
authorize tcp 8443  8443  "rc-signal WSS"
authorize tcp 3478  3478  "rc coturn TURN"
authorize udp 3478  3478  "rc coturn TURN"
authorize udp 49160 49200 "rc coturn relay range"

CURRENT=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --profile "$PROFILE" \
          --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ASSOC=$(aws ec2 describe-addresses --region "$REGION" --profile "$PROFILE" \
        --query "Addresses[?InstanceId=='$INSTANCE_ID'].PublicIp" --output text)

if [[ -n "$ASSOC" && "$ASSOC" != "None" ]]; then
  echo "Elastic IP already associated: $ASSOC"
  EIP="$ASSOC"
else
  echo
  echo "!! The instance's public IP ($CURRENT) is dynamic and will change on stop/start."
  echo "!! Allocating and associating an Elastic IP. This changes the public IP."
  echo "!! Safe: gptc egresses via an outbound cloudflared tunnel and has no inbound dependency."
  read -r -p "Proceed? [y/N] " ok; [[ "$ok" == "y" ]] || { echo "Skipped."; exit 0; }
  ALLOC=$(aws ec2 allocate-address --domain vpc --region "$REGION" --profile "$PROFILE" \
          --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=rc-signal}]' \
          --query AllocationId --output text)
  aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC" \
      --region "$REGION" --profile "$PROFILE" >/dev/null
  EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --region "$REGION" --profile "$PROFILE" \
        --query 'Addresses[0].PublicIp' --output text)
  echo "Elastic IP associated: $EIP"
fi
echo
echo "RC_SERVER_IP=$EIP   # use this for gen-cert.sh and the app config"

#!/bin/sh -x

TOKEN="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")"
region="$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/placement/availability-zone" | sed 's/.$//')"
eth1_addr="$(ip -f inet -o addr show dev eth1 | cut -d' ' -f 7 | cut -d/ -f 1)"

get_instance_private_ip_by_name() {
  name="$1"
  aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=running" |
    jq -r .Reservations[0].Instances[0].PrivateIpAddress
}

run_iptables() {
  action="$1"
  iptables -t nat "$action" PREROUTING 1 -m tcp -p tcp \
    --dst "$eth1_addr" --dport 80 \
    -j DNAT --to-destination "$(get_instance_private_ip_by_name ${ec2_name}):80"
}

run_iptables -I
while true; do
  sleep 30
  run_iptables -R
done

#!/bin/sh -x

apk update && apk upgrade --no-cache
apk add --no-cache bash curl aws-cli iptables amazon-ssm-agent amazon-ssm-agent-openrc

rc-update add amazon-ssm-agent default
rc-service amazon-ssm-agent start

TOKEN="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")"
imds() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }

INSTANCE_ID="$(imds instance-id)"
REGION="$(imds placement/availability-zone | sed 's/.$//')"

# Disable Source/Destination Check for the instance default interface
aws ec2 modify-instance-attribute --region "$REGION" --instance-id "$INSTANCE_ID" --no-source-dest-check

# try to attach the ENI
max_attempts=10
attempt=0

while true; do
    aws ec2 attach-network-interface \
        --region "$REGION" \
        --instance-id "$INSTANCE_ID" \
        --device-index 1 \
        --network-interface-id "${eni_id}" && break

    attempt=$((attempt + 1))

    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "Maximum attempts reached. Initiating reboot."
        reboot
        break
    fi

    echo "Attempt $attempt failed. Retrying..."
    sleep 5 # waits for 5 seconds before retrying
done

# start SNAT
rc-update add snat default
rc-service snat start

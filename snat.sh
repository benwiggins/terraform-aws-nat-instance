#!/bin/bash -x

# wait for ens6
while ! ip link show dev ens6; do
  sleep 1
done

#  make this a nat instance
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

for IFACE in ens5 ens6; do
  until ip -4 addr show dev "$IFACE" | grep -q 'inet '; do sleep 1; done
done
ENS6_IP=$(ip -4 -o addr show dev ens6 | awk '{print $4}' | cut -d/ -f1 || true)
ENS6_GW=$(ip -4 route show dev ens6 default 2>/dev/null | awk '{print $3}' | head -n1 || true)
ENS5_GW=$(ip -4 route show dev ens5 default 2>/dev/null | awk '{print $3}' | head -n1 || true)

# NAT box essentials
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=2
grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
grep -q '^net.ipv4.conf.all.rp_filter' /etc/sysctl.conf || echo 'net.ipv4.conf.all.rp_filter = 2' >> /etc/sysctl.conf

if [ -n "${ENS6_GW:-}" ]; then
  ip route replace default via "$ENS6_GW" dev ens6 metric 50
fi
if [ -n "${ENS5_GW:-}" ]; then
  ip route replace default via "$ENS5_GW" dev ens5 metric 500 || true
fi

iptables -t nat -F POSTROUTING
iptables -t nat -I POSTROUTING -o ens6 -j SNAT --to-source "$ENS6_IP"
iptables -F FORWARD
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i ens5 -o ens6 -j ACCEPT

echo "@reboot root iptables-restore < /etc/sysconfig/iptables" | sudo tee -a /etc/crontab

# wait for network connection
curl --retry 10 https://google.com

# re-establish connections
systemctl restart amazon-ssm-agent

#!/bin/sh -x

# wait for eth1 to be attached
while ! ip link show dev eth1 >/dev/null 2>&1; do
  sleep 1
done

# Alpine doesn't auto-configure a hot-attached ENI the way Amazon Linux does,
# so bring it up and get a lease ourselves.
ip link set dev eth1 up
until ip -4 addr show dev eth1 | grep -q 'inet '; do
  udhcpc -i eth1 -n -q
  ip -4 addr show dev eth1 | grep -q 'inet ' || sleep 1
done

#  make this a nat instance
echo "net.ipv4.ip_forward = 1" | tee -a /etc/sysctl.conf
sysctl -p

for IFACE in eth0 eth1; do
  until ip -4 addr show dev "$IFACE" | grep -q 'inet '; do sleep 1; done
done
ETH1_IP=$(ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1 || true)
ETH1_GW=$(ip -4 route show dev eth1 default 2>/dev/null | awk '{print $3}' | head -n1 || true)
ETH0_GW=$(ip -4 route show dev eth0 default 2>/dev/null | awk '{print $3}' | head -n1 || true)

# NAT box essentials
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=2
grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
grep -q '^net.ipv4.conf.all.rp_filter' /etc/sysctl.conf || echo 'net.ipv4.conf.all.rp_filter = 2' >> /etc/sysctl.conf

if [ -n "$ETH1_GW" ]; then
  ip route replace default via "$ETH1_GW" dev eth1 metric 50
fi
if [ -n "$ETH0_GW" ]; then
  ip route replace default via "$ETH0_GW" dev eth0 metric 500 || true
fi

iptables -t nat -F POSTROUTING
iptables -t nat -I POSTROUTING -o eth1 -j SNAT --to-source "$ETH1_IP"
iptables -F FORWARD
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -j ACCEPT

# wait for network connection
curl --retry 10 https://google.com

# re-establish connections
rc-service amazon-ssm-agent restart

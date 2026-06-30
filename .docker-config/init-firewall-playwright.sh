#!/bin/bash
# Egress firewall for the playwright container.
#
# The interactive Chromium here is driven by the claude container, whose own
# egress is allowlisted by init-firewall.sh — an unrestricted browser would be
# a complete bypass of that firewall (arbitrary fetch + exfil via navigation).
# Everything this container legitimately talks to lives in private address
# space: the docker dev/proxy subnets, the host-gateway (WORKTREE_HOST / S3
# routes), published-port clients on the host, and Docker's embedded DNS on
# loopback. So: allow loopback + RFC1918, reject the internet.
set -euo pipefail

iptables -F
iptables -X

# Loopback: Xvfb/x11vnc/websockify/CDP socat and Docker's embedded DNS (127.0.0.11).
# The DNS NAT redirect lives in the nat table, which is left untouched.
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  iptables -A INPUT -s "$net" -j ACCEPT
  iptables -A OUTPUT -d "$net" -j ACCEPT
done

# Allow outbound HTTPS to the JS CDNs the Rails importmap pins load from
# (ga.jspm.io: sortablejs/stimulus-sortable; cdn.jsdelivr.net: pdfjs-dist).
# The browser fetches these modules when rendering app pages, so its egress
# must reach them. No dig here (no dnsutils), so resolve via getent and pin
# the resolved IPv4s on 443. CDN IPs rotate; re-run this script if a fetch
# starts failing.
for domain in \
  "ga.jspm.io" \
  "cdn.jsdelivr.net"; do
  echo "Resolving $domain..."
  ips=$(getent ahosts "$domain" | awk '/STREAM/ && $1 ~ /^[0-9.]+$/ {print $1}' | sort -u || true)
  if [ -z "$ips" ]; then
    echo "WARN: Failed to resolve $domain, skipping"
    continue
  fi
  while read -r ip; do
    [ -z "$ip" ] && continue
    echo "Allowing $ip:443 for $domain"
    iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
  done < <(echo "$ips")
done

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# REJECT (not silently drop) so browsers fail fast instead of hanging on timeouts.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# No IPv6 on these networks; close that path too in case the daemon enables it.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -P OUTPUT DROP 2>/dev/null || true
fi

echo "Firewall: egress restricted to loopback + private ranges"
if curl --connect-timeout 5 -s -o /dev/null https://example.com 2>/dev/null; then
  echo "ERROR: Firewall verification failed - was able to reach https://example.com"
  exit 1
fi
echo "Firewall verification passed - unable to reach https://example.com as expected"

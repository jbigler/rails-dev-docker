#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# DNS: only Docker's embedded resolver (127.0.0.11; resolv.conf points there
# on user-defined networks). Its NAT redirect was restored above and the
# post-DNAT packets ride loopback, which is allowed below — these scoped rules
# just make the intent explicit and cover direct queries. A blanket port-53
# accept would be an exfiltration channel (DNS tunneling).
iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT
# No blanket SSH rule: the allowed-domains ipset matches all ports, and it
# includes GitHub's git ranges — so `git@github.com` still works while SSH
# to arbitrary hosts (an exfiltration channel) is blocked.
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s --max-time 15 https://api.github.com/meta || true)
if [ -z "$gh_ranges" ]; then
    echo "WARN: Failed to fetch GitHub IP ranges, skipping"
elif ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    echo "WARN: GitHub API response missing required fields, skipping"
else
    echo "Processing GitHub IPs..."
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "WARN: Invalid CIDR range from GitHub meta: $cidr, skipping"
            continue
        fi
        echo "Adding GitHub range $cidr"
        ipset add allowed-domains "$cidr" -exist
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[] | select(test("^[0-9.]+/[0-9]+$"))' | aggregate -q)
fi

# Fetch Datadog US5 IP ranges and add them
echo "Fetching Datadog US5 IP ranges..."
dd_ranges=$(curl -s --max-time 15 https://ip-ranges.us5.datadoghq.com/api.json || true)
if [ -z "$dd_ranges" ]; then
    echo "WARN: Failed to fetch Datadog US5 IP ranges, skipping"
elif ! echo "$dd_ranges" | jq -e '.api.prefixes_ipv4' >/dev/null 2>&1; then
    echo "WARN: Datadog API response missing required fields, skipping"
else
    echo "Processing Datadog US5 IPs..."
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "WARN: Invalid CIDR range from Datadog US5: $cidr, skipping"
            continue
        fi
        echo "Adding Datadog US5 range $cidr"
        ipset add allowed-domains "$cidr" -exist
    done < <(echo "$dd_ranges" | jq -r '.api.prefixes_ipv4[]')
fi

# Resolve and add other allowed domains
for domain in \
    "registry.npmjs.org" \
    "codeload.github.com" \
    "api.githubcopilot.com" \
    "claude.ai" \
    "api.anthropic.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    "mcp.datadoghq.com" \
    "ga.jspm.io" \
    "cdn.jsdelivr.net" \
    "api.rubyonrails.org"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}' || true)
    if [ -z "$ips" ]; then
        echo "WARN: Failed to resolve $domain, skipping"
        continue
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "WARN: Invalid IP from DNS for $domain: $ip, skipping"
            continue
        fi
        echo "Adding $ip for $domain"
        ipset add allowed-domains "$ip" -exist
    done < <(echo "$ips" | sort -u)
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Allow traffic to host MCP servers (e.g. Pencil via supergateway)
echo "Allowing host MCP proxy on port 8089..."
iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport 8089 -j ACCEPT

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# No IPv6 on these networks; close that path too (as init-firewall-playwright.sh
# does) so the v4 allowlist can't be bypassed if the daemon ever enables it.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -P INPUT DROP 2>/dev/null || true
  ip6tables -P FORWARD DROP 2>/dev/null || true
  ip6tables -P OUTPUT DROP 2>/dev/null || true
fi

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

exec "$@"

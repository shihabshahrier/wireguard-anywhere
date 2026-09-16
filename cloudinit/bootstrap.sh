#!/bin/sh
# Bootstraps a hardened WireGuard server. Rendered by lib/common.sh:build_user_data,
# which substitutes the __PLACEHOLDER__ tokens, then passed to the instance as
# user-data / startup-script.
#
# Two deliberate constraints, both learned the hard way:
#
#  1. This is a plain shell script, not a #cloud-config document. Lightsail hands
#     user-data to cloud-init's *script* handler, so a YAML payload gets executed
#     line by line by dash and silently does nothing.
#
#  2. It is POSIX sh, not bash. Lightsail concatenates its own bootstrap script
#     with the user's, so this file's shebang is not necessarily the one that
#     runs -- the combined script may execute under dash. Bash-isms such as
#     `set -o pipefail` or `exec > >(tee ...)` abort the whole run at line one,
#     leaving a booted instance with nothing installed on it.
set -eu

exec >> /var/log/vpn-bootstrap.log 2>&1
echo "=== vpn bootstrap starting $(date -u +%FT%TZ) ==="

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- packages --
# Retry: on a fresh instance the archive can briefly be unreachable, and other
# boot-time agents may still hold the dpkg lock.
apt_retry() {
  for i in 1 2 3 4 5; do
    if apt-get "$@"; then return 0; fi
    echo "apt-get $* failed (attempt $i), retrying in 10s"
    sleep 10
  done
  return 1
}

apt_retry update
# Deliberately no dist-upgrade: it delays a usable tunnel by minutes, which
# matters when instances are created on demand. unattended-upgrades handles
# security patches continuously instead.
apt_retry install -y wireguard iptables curl ca-certificates unattended-upgrades

# ------------------------------------------------------------------ sysctl --
cat > /etc/sysctl.d/99-wireguard.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
# BBR + fq materially improve TCP throughput for traffic traversing the tunnel,
# especially on long-haul links with any packet loss.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
EOF
sysctl --system >/dev/null

# -------------------------------------------------------------- NAT helper --
# Kept out of wg0.conf so the rules can be inspected and re-run by hand. The WAN
# interface is detected at runtime: it differs across clouds (ens5 on AWS, ens4
# on GCP, eth0 on Azure and Oracle).
cat > /usr/local/sbin/wg-nat <<'EOF'
#!/bin/sh
set -eu
WAN="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[ -n "$WAN" ] || { echo "wg-nat: no default route interface" >&2; exit 1; }
V4="__NET_V4__"
V6="__NET_V6__"
HAS_V6GLOBAL=0
ip -6 addr show dev "$WAN" scope global 2>/dev/null | grep -q 'inet6' && HAS_V6GLOBAL=1

case "${1:-}" in
  up)
    iptables -t nat -C POSTROUTING -s "$V4" -o "$WAN" -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s "$V4" -o "$WAN" -j MASQUERADE
    iptables -C FORWARD -i wg0 -o "$WAN" -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i wg0 -o "$WAN" -j ACCEPT
    iptables -C FORWARD -i "$WAN" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i "$WAN" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    # Clamp TCP MSS so large packets are not silently dropped by paths with a
    # smaller PMTU than the tunnel assumes (common on mobile networks).
    iptables -t mangle -C FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
      || iptables -t mangle -A FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    if [ "$HAS_V6GLOBAL" = 1 ]; then
      ip6tables -t nat -C POSTROUTING -s "$V6" -o "$WAN" -j MASQUERADE 2>/dev/null \
        || ip6tables -t nat -A POSTROUTING -s "$V6" -o "$WAN" -j MASQUERADE
      ip6tables -C FORWARD -i wg0 -o "$WAN" -j ACCEPT 2>/dev/null \
        || ip6tables -A FORWARD -i wg0 -o "$WAN" -j ACCEPT
      ip6tables -C FORWARD -i "$WAN" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || ip6tables -A FORWARD -i "$WAN" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ip6tables -t mangle -C FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || ip6tables -t mangle -A FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    else
      # No global IPv6 upstream. Reject rather than blackhole so clients fail
      # over to IPv4 immediately instead of stalling on every connection.
      ip6tables -C FORWARD -i wg0 -j REJECT 2>/dev/null \
        || ip6tables -A FORWARD -i wg0 -j REJECT
    fi
    ;;
  down)
    iptables -t nat -D POSTROUTING -s "$V4" -o "$WAN" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i wg0 -o "$WAN" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$WAN" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -t nat -D POSTROUTING -s "$V6" -o "$WAN" -j MASQUERADE 2>/dev/null || true
    ip6tables -D FORWARD -i wg0 -o "$WAN" -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -i "$WAN" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    ip6tables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -D FORWARD -i wg0 -j REJECT 2>/dev/null || true
    ;;
  *) echo "usage: wg-nat up|down" >&2; exit 2 ;;
esac
EOF
chmod 755 /usr/local/sbin/wg-nat

# --------------------------------------------------------- peer sync helper --
# Reads a peer block on stdin and replaces everything from the first [Peer] to
# end of file. Living on the server avoids quoting a multi-line sed program
# through ssh from the client side.
cat > /usr/local/sbin/wg-setpeers <<'EOF'
#!/bin/sh
set -eu
CONF=/etc/wireguard/wg0.conf
NEW="$(cat)"
[ -n "$NEW" ] || { echo "wg-setpeers: empty peer list on stdin, refusing" >&2; exit 1; }
TMP="$(mktemp)"
awk '/^\[Peer\]/{exit} {print}' "$CONF" > "$TMP"
printf '%s\n' "$NEW" >> "$TMP"
install -m 0600 -o root -g root "$TMP" "$CONF"
rm -f "$TMP"
systemctl restart wg-quick@wg0
wg show wg0
EOF
chmod 755 /usr/local/sbin/wg-setpeers

# ---------------------------------------------------------------- wg0.conf --
mkdir -p /etc/wireguard
umask 077
cat > /etc/wireguard/wg0.conf <<'EOF'
[Interface]
Address = __SERVER_V4__/24, __SERVER_V6__/64
ListenPort = __PORT__
PrivateKey = __SERVER_PRIVKEY__
MTU = __MTU__
PostUp = /usr/local/sbin/wg-nat up
PostDown = /usr/local/sbin/wg-nat down
__PEERS__
EOF
chmod 600 /etc/wireguard/wg0.conf

# ------------------------------------------------- unattended security --
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ------------------------------------------------------------ bring it up --
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0 || true

# ------------------------------------------------------- resolver setup --
case "__DNS_MODE__" in
  unbound)
    apt_retry install -y unbound
    cat > /etc/unbound/unbound.conf.d/wireguard.conf <<'EOF'
server:
  interface: __SERVER_V4__
  interface: __SERVER_V6__
  access-control: 0.0.0.0/0 refuse
  access-control: __NET_V4__ allow
  access-control: __NET_V6__ allow
  hide-identity: yes
  hide-version: yes
  qname-minimisation: yes
  harden-glue: yes
  harden-dnssec-stripped: yes
  prefetch: yes
  cache-min-ttl: 60
  num-threads: 2
  so-reuseport: yes
EOF
    # unbound must not start before wg0 exists, or it cannot bind its address.
    mkdir -p /etc/systemd/system/unbound.service.d
    cat > /etc/systemd/system/unbound.service.d/override.conf <<'EOF'
[Unit]
After=wg-quick@wg0.service
Requires=wg-quick@wg0.service
[Service]
Restart=on-failure
RestartSec=5
EOF
    systemctl daemon-reload
    systemctl enable --now unbound
    ;;
  adguard)
    curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
    echo "AdGuard Home installed. Finish setup at http://__SERVER_V4__:3000 once connected to the VPN." \
      > /root/ADGUARD-SETUP.txt
    ;;
  *)
    : # a public resolver was chosen; nothing to install
    ;;
esac

# ------------------------------------------------ readiness marker / heal --
# If the interface did not come up first time, retry before giving up, and
# record why so `vpn.sh ssh ... cat /var/lib/wg-failed` explains it.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if wg show wg0 >/dev/null 2>&1; then
    date -u +%FT%TZ > /var/lib/wg-ready
    echo "=== vpn bootstrap complete, wg0 is up ==="
    exit 0
  fi
  echo "wg0 not up yet (attempt $i), restarting wg-quick@wg0"
  systemctl restart wg-quick@wg0 || true
  sleep 5
done

journalctl -u wg-quick@wg0 --no-pager -n 50 > /var/lib/wg-failed 2>&1 || true
echo "=== vpn bootstrap FAILED: wg0 never came up, see /var/lib/wg-failed ==="
exit 1

# Create a VPN Server on AWS (manual)

The console-and-terminal version of what [`vpn.sh`](../vpn.sh) automates. Follow this if you
want to understand each step, or if you would rather not run a script against your account.

Uses **Amazon Lightsail** rather than EC2. For a VPN, Lightsail is roughly half the price: a
$5/month bundle includes the public IPv4 address and 1 TB of transfer, while EC2 bills the
address at $0.005/hour and egress at $0.09/GB past the first 100 GB.

---

## 1. Create the instance

1. Open the [Lightsail console](https://lightsail.aws.amazon.com/).
2. **Create instance**.
3. **Instance location** — pick the region physically closest to you. Latency is what makes a
   VPN feel fast.
4. **Platform**: Linux/Unix. **Blueprint**: *OS Only* → **Ubuntu 24.04 LTS**.
5. **Instance plan**: the **$5/month** plan (2 vCPU, 512 MB, 1 TB transfer). The $3.50 IPv6-only
   plan is cheaper but unreachable from IPv4-only networks.
6. Name it `vpn-<region>` and **Create instance**.

---

## 2. Open the firewall

On the instance page → **Networking** tab → **IPv4 Firewall**:

1. **Add rule** → Application: *Custom*, Protocol: **UDP**, Port: **51820**, source anywhere.
2. **Delete the default SSH rule** once you have finished section 4. You will reach SSH over the
   tunnel instead, which leaves exactly one port facing the internet.

---

## 3. Install and configure WireGuard

Connect with the browser SSH button, then:

```bash
sudo apt update && sudo apt install -y wireguard
```

Generate the server keypair:

```bash
umask 077
wg genkey | sudo tee /etc/wireguard/server.key | wg pubkey | sudo tee /etc/wireguard/server.pub
```

Generate a keypair for each client, on **your own machine** — private keys should never be
created on the server:

```bash
wg genkey | tee laptop.key | wg pubkey > laptop.pub
wg genpsk > laptop.psk
```

Write `/etc/wireguard/wg0.conf` on the server:

```ini
[Interface]
Address = 10.66.66.1/24, fd66:66:66::1/64
ListenPort = 51820
PrivateKey = <contents of /etc/wireguard/server.key>
MTU = 1420
PostUp   = iptables  -t nat -A POSTROUTING -s 10.66.66.0/24    -o ens5 -j MASQUERADE; ip6tables -t nat -A POSTROUTING -s fd66:66:66::/64 -o ens5 -j MASQUERADE
PostDown = iptables  -t nat -D POSTROUTING -s 10.66.66.0/24    -o ens5 -j MASQUERADE; ip6tables -t nat -D POSTROUTING -s fd66:66:66::/64 -o ens5 -j MASQUERADE

[Peer]
PublicKey = <contents of laptop.pub>
PresharedKey = <contents of laptop.psk>
AllowedIPs = 10.66.66.2/32, fd66:66:66::2/128
```

Confirm the interface name matches — it is `ens5` on Lightsail, `ens4` on GCE, `eth0` on Azure:

```bash
ip -4 route show default
```

---

## 4. Enable forwarding and start it

```bash
sudo tee /etc/sysctl.d/99-wireguard.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sudo sysctl --system

sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

`wg show` should list the interface, its public key, and your peer.

The `fq` and `bbr` settings are not required, but they measurably improve TCP throughput
through the tunnel on long-haul links with any packet loss.

---

## 5. Write the client config

On your own machine, as `laptop.conf`:

```ini
[Interface]
PrivateKey = <contents of laptop.key>
Address = 10.66.66.2/32, fd66:66:66::2/128
DNS = 1.1.1.2, 1.0.0.2
MTU = 1420

[Peer]
PublicKey = <contents of /etc/wireguard/server.pub>
PresharedKey = <contents of laptop.psk>
Endpoint = <your instance's public IP>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

`AllowedIPs` must include `::/0` even if you do not use IPv6 — otherwise native IPv6 traffic
routes around the tunnel and leaks.

Import it, or turn it into a QR code for a phone:

```bash
qrencode -t ansiutf8 < laptop.conf
```

---

## 6. Verify

Visit [ifconfig.me](https://ifconfig.me) — it should show your instance's IP. On the server,
`sudo wg show` should report a recent handshake and non-zero transfer in both directions.

---

## 7. Stop the billing

Lightsail charges for a **stopped** instance as well as a running one. To stop paying you must
**delete** it: instance page → **Manage** → **Delete**.

# Security

## Reporting a vulnerability

Open a [GitHub security advisory](https://github.com/shihabshahrier/wireguard-anywhere/security/advisories/new)
rather than a public issue. Include the command you ran, what you expected, and what happened.

## What this tool does

- Exposes exactly one port to the internet: **UDP 51820**. `sshd` is not published; it is
  reachable only across the tunnel at `10.66.66.1` unless you pass `--ssh-public`.
- Generates all key material locally with OpenSSL's X25519 implementation. Only the *server's*
  private key is transmitted, inside the instance's user-data. Client private keys never leave
  your machine.
- Issues a **preshared key per client-server pair** in addition to the X25519 handshake.
- Routes `::/0` as well as `0.0.0.0/0` into the tunnel so native IPv6 cannot leak around it. When
  the server has no global IPv6, forwarded IPv6 is **rejected** rather than blackholed, so clients
  fail over to IPv4 immediately instead of stalling.
- Enables `unattended-upgrades` on the server.
- Stores `.vpn/` with mode `700`, key files `600`, and gitignores the directory.

## What it does not do

- **It is not anonymity.** Traffic leaving the server is attributable to your cloud account.
- **`.vpn/state.json` holds every private key in plaintext.** Anyone who reads that file can
  impersonate any of your clients. Back it up encrypted or not at all.
- **`--ssh-public` re-exposes TCP 22.** It is restricted to `--ssh-cidr`, but it is still a second
  port facing the internet. Prefer reaching SSH over the tunnel.
- The tool does not rotate keys. To rotate, `./vpn.sh client rm <name>`, add it again, and `sync`
  or recreate each server.

## Threat model

Protects against: passive monitoring on the local network, an untrusted ISP or hotel/cafe Wi-Fi,
and DNS interception on the path.

Does not protect against: a compromised client device, an adversary with access to your cloud
account, or anyone who can compel your cloud provider to hand over logs.

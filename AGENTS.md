# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Cursor, Copilot, Gemini CLI,
OpenClaw, Aider) working in or *with* this repository.

This file has two halves:

- **Part 1 — Operating the tool.** How to provision a VPN for a user, end to end,
  without asking them to do anything you can do yourself.
- **Part 2 — Contributing to the tool.** Conventions to follow when changing code.

---

# Part 1 — Operating the tool

## What this repo does

`vpn.sh` provisions a WireGuard VPN server in a cloud region, writes client
configuration files, and deletes the server again. All key material is generated
locally with OpenSSL; only the server's private key is transmitted, inside
instance user-data.

## Prerequisites you must verify first

```bash
./vpn.sh doctor
```

Required: `openssl` (3.x, for X25519), `jq`, and the target cloud's CLI
(`aws` / `gcloud` / `az`). Optional: `qrencode` for QR codes.

`wireguard-tools` is **not** required locally. Do not install it or tell the user
to. Keys are derived with OpenSSL; this is verified in CI against the RFC 7748
test vector and against `wg pubkey` itself.

## End-to-end provisioning

```bash
# 1. Confirm the cloud CLI is authenticated. Do not proceed if this fails.
aws sts get-caller-identity --profile <profile>

# 2. Launch. Takes ~60-90s; the command returns before the server finishes booting.
./vpn.sh up aws us-west-2 --profile <profile> --clients laptop,phone

# 3. Hand the user their config.
./vpn.sh qr aws us-west-2 phone          # QR in the terminal
# or point them at .vpn/clients/aws-us-west-2/phone.conf
```

Choose the region **physically closest to the user**. Latency dominates perceived
VPN speed; bandwidth almost never does. Ask where they are if you do not know.

## Verifying it actually works

Do not tell a user it works until you have checked. A running instance proves
nothing — the instance can boot fine with nothing installed on it.

**Preferred check** — the readiness marker:

```bash
./vpn.sh up aws us-west-2 --ssh-public --ssh-cidr "$(./vpn.sh pool)"
./vpn.sh logs aws us-west-2
```

`logs` prints the bootstrap log, `wg show`, and the `/var/lib/wg-ready` marker.
A healthy server shows `wg0` with one `[Peer]` per client.

**Without SSH** — instance network volume is a reliable proxy. The bootstrap
downloads roughly **35-40 MB** of packages. Anything under ~1 MB means the
bootstrap never ran:

```bash
aws lightsail get-instance-metric-data --region <region> \
  --instance-name vpn-<region> --metric-name NetworkIn --period 300 \
  --start-time <iso8601> --end-time <iso8601> --unit Bytes --statistics Sum \
  --query 'max(metricData[].sum)' --output text
```

Note this metric lags roughly 5 minutes. Do not conclude failure before then.

**Definitive check** — a real handshake. Zero means nothing has connected yet:

```bash
./vpn.sh ssh aws us-west-2 "sudo wg show wg0 dump | tail -n +2"
# fields: pubkey, psk, endpoint, allowed-ips, last-handshake, rx, tx
```

## Cost — state this to the user before you launch anything

Lightsail bills **hourly and prorated**, and a *stopped* instance is still
billed. Only `./vpn.sh down` (which deletes) stops the meter.

| Usage | Cost/month |
|---|---|
| 2 h/day | ~$0.42 |
| 8 h/day | ~$1.67 |
| Always on | $5.00 |

A user can only be connected to one region at a time, so **the number of regions
does not drive cost — connected hours do.** Deploying ten regions on demand costs
the same as deploying one. Say so; it changes what people ask for.

Always tell the user how to stop paying:

```bash
./vpn.sh down aws <region>
```

## Things that will waste your time if you do not know them

- **Lightsail runs user-data as a shell script, not cloud-config.** A
  `#cloud-config` YAML payload is executed line by line by `dash` and silently
  does nothing — you get a running instance with no VPN on it. `cloudinit/bootstrap.sh`
  is a script for this reason.
- **It must stay POSIX `sh`.** Lightsail concatenates its own bootstrap with
  yours, so the file's shebang may not be the one that runs. A bash-ism such as
  `set -o pipefail` aborts the whole script at line one.
- **SSH is not exposed by default.** It is reachable over the tunnel at
  `10.66.66.1`. `./vpn.sh ssh` timing out is expected unless the VPN is connected
  or you passed `--ssh-public`.
- **Lightsail authenticates SSH with a short-lived certificate**, not just a key.
  If its in-guest agent failed, fall back to
  `aws lightsail download-default-key-pair`.
- **The server public key is stable across destroy/recreate**, because it is
  stored locally and re-injected. Only the endpoint changes, and `up` rewrites the
  configs. Do not regenerate client keys on redeploy.
- **Home ISPs behind CGNAT rotate the source address per connection.** Pinning
  SSH to a single `/32` will lock the user out. Use `./vpn.sh pool` to enumerate
  the addresses and pass them all to `--ssh-cidr`.

## Never do these

- Do not commit `.vpn/` or anything inside it. It contains every client's private
  key in plaintext. It is gitignored; keep it that way.
- Do not print a user's private key into a shared channel, PR, or issue.
- Do not widen `--ssh-cidr` to `0.0.0.0/0`, and do not suggest it as a fix.
- Do not claim the VPN works based on instance state alone.
- Do not tell a user this makes them anonymous. It does not — traffic leaving the
  server is attributable to their cloud account.

---

# Part 2 — Contributing to the tool

## Layout

```
vpn.sh                    CLI entry point and command dispatch
lib/common.sh             state, key generation, config rendering, logging
lib/provider-aws.sh       Amazon Lightsail (primary)
lib/provider-gcp.sh       Google Compute Engine
lib/provider-azure.sh     Azure Virtual Machines
cloudinit/bootstrap.sh    server bootstrap, POSIX sh, placeholder-substituted
```

## Hard constraints

1. **`vpn.sh` and `lib/*.sh` must run on bash 3.2.** macOS still ships it. No
   associative arrays, no `${var,,}`, no `mapfile`. Note that bash 3.2 *prints* a
   `local` that is re-declared inside a loop — declare locals once at the top of a
   function.
2. **`cloudinit/bootstrap.sh` must be POSIX `sh`.** CI enforces this with
   `dash -n`. See the reason above.
3. **`shellcheck -S warning -x vpn.sh lib/*.sh` must be clean.** No new
   suppressions without a comment explaining why.
4. **Never set `IFS` for a whole function.** It leaks into every function called
   from there and breaks word splitting inside them. This has caused a real bug
   here.

## Adding a provider

Implement these functions in `lib/provider-<name>.sh`, matching the AWS file:

| Function | Contract |
|---|---|
| `<name>_check` | Verify CLI present and authenticated; `die` if not |
| `<name>_regions` | Print `region<TAB>description` lines |
| `<name>_state` | Print `running`, `absent`, or a provider state |
| `<name>_up` | Create the instance, then record the endpoint in state |
| `<name>_down` | Delete it and null the endpoint in state |
| `<name>_open_ports` | Apply firewall rules |
| `<name>_ssh` | Run a command on the server |

Then add the name to `source_provider` in `vpn.sh`. The bootstrap script is
shared and needs no changes.

A provider must set `can-ip-forward` (GCP) or NIC IP forwarding (Azure) where the
platform requires it, or forwarded packets are dropped by the network fabric
regardless of the in-guest `sysctl`.

## Testing

```bash
bash -n vpn.sh && shellcheck -S warning -x vpn.sh lib/*.sh
dash -n cloudinit/bootstrap.sh

# Render the bootstrap without touching a cloud:
export VPN_STATE_DIR=/tmp/vpn-test
./vpn.sh client add test
ROOT_DIR="$PWD"; . lib/common.sh
priv="$(wg_genkey)"
state_set '.servers["aws/us-west-2"] = {provider:"aws",region:"us-west-2",priv:$p,pub:$u,port:51820,dns:"1.1.1.2",psk:{},endpoint:"203.0.113.1"}' \
  --arg p "$priv" --arg u "$(wg_pubkey "$priv")"
build_user_data aws us-west-2 cloudflare
```

CI runs all of the above plus a check that OpenSSL-derived keys match
`wg pubkey` and the RFC 7748 test vector.

## Commit style

Imperative subject under 72 characters. Explain *why* in the body when the reason
is not obvious from the diff. This codebase has several fixes whose rationale is
impossible to guess — keep documenting them.

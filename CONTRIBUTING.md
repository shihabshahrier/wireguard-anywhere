# Contributing

Thanks for considering it. This is a small project and every contribution — a
typo fix, a bug report, a whole new cloud provider — is genuinely useful.

## Good first contributions

| What | Difficulty | Why it matters |
| --- | --- | --- |
| **Oracle Cloud provider** (`lib/provider-oracle.sh`) | Medium | Oracle Always Free is the only forever-free tier with real bandwidth (10 TB/month). This is the most-requested missing piece. |
| **Hetzner / DigitalOcean / Vultr providers** | Medium | Cheaper than any hyperscaler; ~€4/month with 20 TB traffic. |
| **DNS integration** (Route53 / Cloudflare) | Medium | Point a record at the server so client configs never change when a region is recreated. |
| **Linux host testing** | Easy | Developed on macOS. Bug reports from Linux are valuable. |
| **Docs, typos, clearer errors** | Easy | Always welcome. |

## Before you open a PR

```bash
bash -n vpn.sh
shellcheck -S warning -x vpn.sh lib/*.sh
dash -n cloudinit/bootstrap.sh
```

All three must pass. CI runs them plus a check that OpenSSL-derived keys match
`wg pubkey` and the RFC 7748 test vector.

## Three hard constraints

These are not style preferences — breaking any of them causes silent failures
that are painful to diagnose. Each one has already cost real debugging time here.

**1. `vpn.sh` and `lib/*.sh` must run on bash 3.2.**
macOS still ships bash 3.2 as `/bin/bash`. No associative arrays, no `${var,,}`,
no `mapfile`. Also note bash 3.2 *prints* a `local` that is re-declared inside a
loop, so declare locals once at the top of a function.

**2. `cloudinit/bootstrap.sh` must be POSIX `sh`.**
Lightsail concatenates its own bootstrap script with yours into one file, so this
file's shebang is not necessarily the one that runs. A bash-ism such as
`set -o pipefail` or `exec > >(tee ...)` aborts the entire script at line one and
you get a booted instance with nothing installed on it. CI enforces this with
`dash -n`.

**3. Never set `IFS` for a whole function.**
It leaks into every function called from there and silently breaks word splitting
inside them. This caused a real bug in the client IP allocator.

## Adding a cloud provider

Create `lib/provider-<name>.sh` implementing this interface, then add the name to
`source_provider` in `vpn.sh`. The bootstrap script is shared — you should not
need to touch it.

| Function | Contract |
| --- | --- |
| `<name>_check` | Verify the CLI is present and authenticated; `die` if not |
| `<name>_regions` | Print `region<TAB>description` lines |
| `<name>_state` | Print `running`, `absent`, or a provider-specific state |
| `<name>_up` | Create the instance, then record the endpoint in state |
| `<name>_down` | Delete it and null the endpoint in state |
| `<name>_open_ports` | Apply firewall rules |
| `<name>_ssh` | Run a command on the server |

Watch for platform-specific forwarding requirements: GCP needs
`--can-ip-forward`, Azure needs IP forwarding enabled on the NIC resource. Without
them the fabric drops forwarded packets no matter what the in-guest `sysctl` says.

`lib/provider-aws.sh` is the reference implementation.

## Reporting a bug

Include:

- The exact command you ran (redact `--profile` names if you like)
- What you expected and what happened
- `./vpn.sh doctor` output
- If the server came up but the VPN did not work: `./vpn.sh logs <provider> <region>`

**Never paste the contents of `.vpn/state.json`, a `.conf` file, or anything
containing a `PrivateKey` or `PresharedKey` line.** Those are live credentials.

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).

## Commit style

Imperative subject under 72 characters. Explain *why* in the body when it is not
obvious from the diff — this codebase contains several fixes whose rationale is
impossible to guess from the code alone.

```
Make bootstrap POSIX sh so Lightsail does not abort it

Lightsail concatenates its own bootstrap with the user's, so our
shebang is not the one that runs. `set -o pipefail` aborted the
script at line one and every instance came up with no VPN on it.
```

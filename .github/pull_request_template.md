## What this changes

## Why

<!-- Especially important here. Several fixes in this repo have rationale that is
impossible to guess from the diff. -->

## Checklist

- [ ] `bash -n vpn.sh` passes
- [ ] `shellcheck -S warning -x vpn.sh lib/*.sh` is clean
- [ ] `dash -n cloudinit/bootstrap.sh` passes (if the bootstrap changed)
- [ ] No bash-only syntax in `cloudinit/bootstrap.sh`
- [ ] Nothing in `vpn.sh` or `lib/` requires bash 4+
- [ ] No credentials, keys, or `.vpn/` contents in the diff

## Tested on

- Provider and region:
- Local OS and shell:

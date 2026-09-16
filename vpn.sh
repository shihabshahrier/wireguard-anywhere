#!/usr/bin/env bash
# vpn.sh — spin a personal WireGuard server up and down, in any cloud region.
#
#   ./vpn.sh up aws us-west-2        launch a server and write client configs
#   ./vpn.sh down aws us-west-2      delete it and stop the billing
#
# Every key is generated locally and injected through cloud-init, so a region
# can be destroyed and recreated without any client config changing except the
# endpoint address. See README.md for the full command reference.

set -euo pipefail

# macOS still ships bash 3.2, so this tool stays 3.2-compatible: no associative
# arrays, no ${var,,}, no mapfile. Guard anyway so a truly ancient shell fails
# with a readable message instead of a syntax error.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
  echo "vpn.sh needs bash 3.2 or newer. Run it with: bash ./vpn.sh ..." >&2
  exit 1
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

# ---------------------------------------------------------------- defaults --

AWS_PROFILE="${AWS_PROFILE:-default}"
GCP_PROJECT="${GCP_PROJECT:-}"
AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:-}"
DNS_MODE="cloudflare"
SSH_CIDR=""
SSH_PUBLIC=0
IPV6_ONLY=0
CLIENTS=""

usage() {
  cat <<'EOF'
vpn.sh — your own WireGuard VPN, in any region, billed by the hour.

USAGE
  ./vpn.sh <command> [args] [flags]

COMMANDS
  up <provider> <region>       Launch a server; write client configs
  down <provider> <region>     Delete the server; billing stops immediately
  status                       Show every known server and whether it is live
  sync <provider> <region>     Push the current client list to a running server
  config <provider> <region> [client]   Print a client config to stdout
  qr <provider> <region> [client]       Print a scannable QR code
  client add <name>            Create a new client keypair
  client list                  List clients
  client rm <name>             Remove a client (run `sync` afterwards)
  regions <provider>           List regions the provider supports
  ssh <provider> <region>      Open a shell on the server (connect the VPN first)
  logs <provider> <region>     Show the server's bootstrap log and WireGuard state
  unlock <provider> <region>   Re-apply firewall rules (use with --ssh-public)
  doctor                       Check local prerequisites
  pool [n]                     Print your egress addresses as /32s for --ssh-cidr

PROVIDERS
  aws      Amazon Lightsail  (primary, fully supported)
  gcp      Google Compute Engine
  azure    Azure Virtual Machines

FLAGS
  --profile <name>     AWS CLI profile              (default: $AWS_PROFILE, or AWS_PROFILE)
  --project <id>       GCP project id               (or GCP_PROJECT)
  --subscription <id>  Azure subscription id        (or AZURE_SUBSCRIPTION)
  --clients a,b,c      Client names to create       (default: existing, else "laptop,phone")
  --dns <mode>         cloudflare | quad9 | google | unbound | adguard | <ip,ip>
                       Default is cloudflare (1.1.1.2 — malware-blocking, no logs)
  --ssh-public         Expose TCP 22 to the internet, restricted to --ssh-cidr.
                       Off by default: SSH is reachable over the tunnel instead,
                       so only one UDP port faces the internet.
  --ssh-cidr <list>    Used with --ssh-public. Comma-separated CIDRs; default is
                       your current IP as a /32. Behind CGNAT, run `./vpn.sh pool`
                       and pass the list rather than widening to a /24.
  --ipv6-only          Use the cheaper IPv6-only bundle. AWS only. See README caveat.
  --port <n>           UDP listen port              (default: 51820)
  -h, --help           This message

EXAMPLES
  ./vpn.sh up aws us-west-2 --profile myvpn --clients laptop,phone
  ./vpn.sh qr aws us-west-2 phone
  ./vpn.sh down aws us-west-2
EOF
}

# ------------------------------------------------------------ flag parsing --

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      AWS_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --project)      GCP_PROJECT="${2:?--project needs a value}"; shift 2 ;;
    --subscription) AZURE_SUBSCRIPTION="${2:?--subscription needs a value}"; shift 2 ;;
    --clients)      CLIENTS="${2:?--clients needs a value}"; shift 2 ;;
    --dns)          DNS_MODE="${2:?--dns needs a value}"; shift 2 ;;
    --ssh-cidr)     SSH_CIDR="${2:?--ssh-cidr needs a value}"; shift 2 ;;
    --ssh-public)   SSH_PUBLIC=1; shift ;;
    --port)         VPN_PORT="${2:?--port needs a value}"; shift 2 ;;
    --ipv6-only)    IPV6_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; POSITIONAL+=("$@"); break ;;
    -*)             die "unknown flag: $1 (try --help)" ;;
    *)              POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

[[ $# -eq 0 || -z "${1:-}" ]] && { usage; exit 1; }

# ------------------------------------------------------------- dispatching --

# Sourcing and credential-checking are separate: `status` wants the functions
# without aborting the whole run when one provider's CLI is absent.
source_provider() {
  # shellcheck source=/dev/null
  case "$1" in
    aws|gcp|azure) source "$ROOT_DIR/lib/provider-$1.sh" ;;
    *) die "unknown provider: $1 (expected aws, gcp, or azure)" ;;
  esac
}

load_provider() {
  # Exported so the provider libraries read the same values regardless of how
  # they are invoked; also tells shellcheck these are used elsewhere.
  export SSH_CIDR SSH_PUBLIC AWS_PROFILE GCP_PROJECT AZURE_SUBSCRIPTION
  source_provider "$1"
  "${1}_check"
}

require_region() {
  [[ -n "${1:-}" ]] || die "missing region. Try: ./vpn.sh regions $2"
}

# Create the server keypair and per-client preshared keys once, and keep them.
# Regenerating a region therefore produces an identical server public key, so
# previously issued client configs stay valid apart from the endpoint line.
server_ensure() {
  local prov="$1" region="$2" skey priv
  skey="$(server_key "$prov" "$region")"
  if [[ "$(state_get ".servers[\"$skey\"] // empty")" == "" ]]; then
    priv="$(wg_genkey)"
    state_set '.servers[$k] = {provider:$p, region:$r, priv:$priv, pub:$pub,
                               port:($port|tonumber), dns:$dns, psk:{}, created:$t}' \
      --arg k "$skey" --arg p "$prov" --arg r "$region" \
      --arg priv "$priv" --arg pub "$(wg_pubkey "$priv")" \
      --arg port "$VPN_PORT" --arg dns "$(resolve_dns "$DNS_MODE")" \
      --arg t "$(date -u +%FT%TZ)"
    ok "created server keypair for $skey"
  else
    # Keep the resolver and port in step with the flags given on this run.
    state_set '.servers[$k].dns = $dns | .servers[$k].port = ($port|tonumber)' \
      --arg k "$skey" --arg dns "$(resolve_dns "$DNS_MODE")" --arg port "$VPN_PORT"
  fi
  # A preshared key per client-server pair adds a symmetric layer on top of
  # the X25519 handshake. Cheap, and hedges against future cryptanalysis.
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if [[ "$(state_get ".servers[\"$skey\"].psk[\"$c\"] // empty")" == "" ]]; then
      state_set '.servers[$k].psk[$c] = $v' \
        --arg k "$skey" --arg c "$c" --arg v "$(wg_genpsk)"
    fi
  done < <(state_get '.clients | keys[]')
}

ensure_clients_exist() {
  local list="${CLIENTS:-}"
  if [[ -z "$list" ]]; then
    [[ "$(state_get '.clients | length')" -gt 0 ]] && return 0
    list="laptop,phone"
    log "no clients yet — creating defaults: $list"
  fi
  # Split on commas without setting IFS for the whole function: a modified IFS
  # leaks into every function called from here, which silently breaks word
  # splitting inside them.
  local c
  while IFS= read -r c; do
    c="$(echo "$c" | tr -d '[:space:]')"
    [[ -z "$c" ]] && continue
    [[ "$c" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid client name '$c' (use letters, digits, - and _)"
    client_ensure "$c"
  done < <(printf '%s\n' "$list" | tr ',' '\n')   # trailing newline: read drops an unterminated final field
}

cmd="$1"; shift || true
check_base_deps
state_init

case "$cmd" in

  up)
    prov="${1:?usage: ./vpn.sh up <provider> <region>}"; require_region "${2:-}" "$prov"; region="$2"
    load_provider "$prov"
    ensure_clients_exist
    server_ensure "$prov" "$region"
    case "$prov" in
      aws)   aws_up   "$region" "$DNS_MODE" "$IPV6_ONLY" ;;
      gcp)   gcp_up   "$region" "$DNS_MODE" ;;
      azure) azure_up "$region" "$DNS_MODE" ;;
    esac
    emit_configs "$prov" "$region"
    echo
    ok "server is booting. WireGuard usually answers 60-90s after launch."
    echo "  Import a config:  $CLIENT_DIR/$prov-$region/<client>.conf"
    echo "  Scan a QR code:   ./vpn.sh qr $prov $region phone"
    echo "  Stop paying:      ./vpn.sh down $prov $region"
    ;;

  down)
    prov="${1:?usage: ./vpn.sh down <provider> <region>}"; require_region "${2:-}" "$prov"; region="$2"
    load_provider "$prov"
    case "$prov" in
      aws)   aws_down   "$region" ;;
      gcp)   gcp_down   "$region" ;;
      azure) azure_down "$region" ;;
    esac
    ;;

  sync)
    prov="${1:?usage: ./vpn.sh sync <provider> <region>}"; require_region "${2:-}" "$prov"; region="$2"
    load_provider "$prov"
    server_ensure "$prov" "$region"
    skey="$(server_key "$prov" "$region")"
    log "pushing current peer list to $skey"
    peers=""
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      peers+=$'\n'"# client: $name"$'\n'"[Peer]"$'\n'
      peers+="PublicKey = $(state_get ".clients[\"$name\"].pub")"$'\n'
      psk="$(state_get ".servers[\"$skey\"].psk[\"$name\"] // empty")"
      [[ -n "$psk" ]] && peers+="PresharedKey = $psk"$'\n'
      peers+="AllowedIPs = $(state_get ".clients[\"$name\"].ipv4")/32, $(state_get ".clients[\"$name\"].ipv6")/128"$'\n'
    done < <(state_get '.clients | keys[]')
    printf '%s\n' "$peers" | "${prov}_ssh" "$region" "sudo /usr/local/sbin/wg-setpeers"
    emit_configs "$prov" "$region"
    ok "peers synced and configs rewritten"
    ;;

  status)
    printf '%-22s %-16s %-10s %s\n' "SERVER" "ENDPOINT" "STATE" "DNS"
    while IFS= read -r skey; do
      [[ -z "$skey" ]] && continue
      p="${skey%%/*}"; r="${skey##*/}"
      ep="$(state_get ".servers[\"$skey\"].endpoint // \"-\"")"
      dns="$(state_get ".servers[\"$skey\"].dns")"
      st="unknown"
      source_provider "$p"
      # Run the credential check in a subshell: it calls die() on failure, and
      # die() exits, which would otherwise abort the whole status table.
      if ( "${p}_check" ) >/dev/null 2>&1; then
        st="$("${p}_state" "$r" 2>/dev/null || echo absent)"
      else
        st="no-creds"
      fi
      [[ "$st" == "running" ]] && st="${C_GRN}running${C_RST}"
      [[ "$st" == "absent"  ]] && st="${C_DIM}absent${C_RST}"
      printf '%-22s %-16s %-20b %s\n' "$skey" "$ep" "$st" "$dns"
    done < <(state_get '.servers | keys[]')
    echo
    echo "clients: $(state_get '.clients | keys | join(", ")')"
    ;;

  config)
    prov="${1:?usage: ./vpn.sh config <provider> <region> [client]}"
    require_region "${2:-}" "$prov"; region="$2"
    client="${3:-$(state_get '.clients | keys[0]')}"
    render_client_config "$client" "$prov" "$region"
    ;;

  qr)
    prov="${1:?usage: ./vpn.sh qr <provider> <region> [client]}"
    require_region "${2:-}" "$prov"; region="$2"
    client="${3:-$(state_get '.clients | keys[0]')}"
    [[ "$(state_get ".clients[\"$client\"] // empty")" != "" ]] || die "unknown client: $client"
    [[ "$(state_get ".servers[\"$prov/$region\"].endpoint // \"null\"")" != "null" ]] \
      || die "$prov/$region is not up. Run: ./vpn.sh up $prov $region"
    mkdir -p "$CLIENT_DIR/$prov-$region"; chmod 700 "$CLIENT_DIR/$prov-$region"
    f="$CLIENT_DIR/$prov-$region/$client.conf"
    render_client_config "$client" "$prov" "$region" > "$f.tmp"
    chmod 600 "$f.tmp"; mv "$f.tmp" "$f"
    echo "  $prov/$region — $client"
    show_qr "$f"
    ;;

  client)
    sub="${1:-list}"; shift || true
    case "$sub" in
      add)  client_ensure "${1:?usage: ./vpn.sh client add <name>}" ;;
      list) state_get '.clients | to_entries[] | "\(.key)\t\(.value.ipv4)"' | column -t ;;
      rm)   name="${1:?usage: ./vpn.sh client rm <name>}"
            state_set 'del(.clients[$n]) | .servers |= map_values(.psk |= del(.[$n]))' --arg n "$name"
            ok "removed client $name — run 'vpn.sh sync' on each live server" ;;
      *)    die "unknown client subcommand: $sub" ;;
    esac
    ;;

  logs)
    # The bootstrap script keeps a log on the server. This is the first thing to
    # look at when an instance is running but nothing answers on the VPN port.
    prov="${1:?usage: ./vpn.sh logs <provider> <region>}"
    require_region "${2:-}" "$prov"; region="$2"
    load_provider "$prov"
    "${prov}_ssh" "$region" \
      "sudo tail -60 /var/log/vpn-bootstrap.log 2>/dev/null || echo '(no bootstrap log — the script never started)';
       echo; echo '--- wg ---'; sudo wg show 2>&1 | head -20;
       echo '--- markers ---'; ls -l /var/lib/wg-ready /var/lib/wg-failed 2>&1;
       echo '--- failure detail ---'; sudo cat /var/lib/wg-failed 2>/dev/null | tail -20"
    ;;

  unlock)
    prov="${1:?usage: ./vpn.sh unlock <provider> <region>}"
    require_region "${2:-}" "$prov"; region="$2"
    load_provider "$prov"
    # Home ISPs hand out a new address regularly, which locks you out of SSH
    # because the allow-rule still names the old one. Re-pin it.
    "${prov}_open_ports" "$region"
    ok "SSH re-pinned to your current address"
    ;;

  regions)
    prov="${1:?usage: ./vpn.sh regions <provider>}"
    load_provider "$prov"
    "${prov}_regions"
    ;;

  ssh)
    prov="${1:?usage: ./vpn.sh ssh <provider> <region>}"
    require_region "${2:-}" "$prov"; region="$2"; shift 2
    load_provider "$prov"
    "${prov}_ssh" "$region" "$@"
    ;;

  pool)
    # Print the set of addresses this machine exits from, ready to paste into
    # --ssh-cidr. Useful when your ISP rotates you between several.
    log "sampling egress addresses (this takes a few seconds)"
    egress_pool "${1:-40}"
    ;;

  doctor)
    log "checking local prerequisites"
    ok "openssl $(openssl version | awk '{print $2}') — X25519 available"
    ok "jq $(jq --version)"
    command -v aws       >/dev/null && ok "aws $(aws --version 2>&1 | awk '{print $1}')" || warn "aws CLI not found (needed for --provider aws)"
    command -v gcloud    >/dev/null && ok "gcloud present" || warn "gcloud not found (needed for gcp)"
    command -v az        >/dev/null && ok "az present"     || warn "az not found (needed for azure)"
    command -v qrencode  >/dev/null && ok "qrencode present" || warn "qrencode not found — QR codes unavailable (brew install qrencode)"
    ;;

  -h|--help|help) usage ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac

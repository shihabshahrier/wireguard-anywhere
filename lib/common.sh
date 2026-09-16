#!/usr/bin/env bash
# common.sh — shared helpers: logging, state, key generation, config rendering.
# Sourced by vpn.sh and the provider libraries. Not executable on its own.

# ---------------------------------------------------------------- constants --

VPN_NET_V4="${VPN_NET_V4:-10.66.66.0/24}"
VPN_NET_V6="${VPN_NET_V6:-fd66:66:66::/64}"
VPN_SERVER_V4="${VPN_SERVER_V4:-10.66.66.1}"
VPN_SERVER_V6="${VPN_SERVER_V6:-fd66:66:66::1}"
VPN_PORT="${VPN_PORT:-51820}"
VPN_MTU="${VPN_MTU:-1420}"
VPN_KEEPALIVE="${VPN_KEEPALIVE:-25}"

STATE_DIR="${VPN_STATE_DIR:-$ROOT_DIR/.vpn}"
STATE_FILE="$STATE_DIR/state.json"
CLIENT_DIR="$STATE_DIR/clients"

# ------------------------------------------------------------------ logging --

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RST=''; C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''
fi

log()   { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
ok()    { printf '%s  ✓%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn()  { printf '%s  !%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
step()  { printf '%s  ·%s %s\n' "$C_DIM" "$C_RST" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# Spinner-free progress for long waits; prints a dot every poll.
wait_dot() { printf '.' >&2; }
wait_end() { printf '\n' >&2; }

# ------------------------------------------------------------ prerequisites --

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

check_base_deps() {
  need_cmd openssl "Install it: https://openssl.org (macOS: brew install openssl)"
  need_cmd jq      "Install it: https://jqlang.github.io/jq (macOS: brew install jq)"
  # openssl must support X25519 for key generation.
  openssl genpkey -algorithm X25519 -out /dev/null 2>/dev/null \
    || die "your openssl lacks X25519 support (need OpenSSL 1.1.1+). macOS: brew install openssl"
}

# -------------------------------------------------------------- key material --

# WireGuard keys are raw 32-byte X25519 values, base64-encoded. OpenSSL can
# produce them without the wireguard-tools package being installed locally:
# take the last 32 bytes of the DER encoding, which is the raw scalar / point.
wg_genkey() {
  openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null \
    | tail -c 32 | base64 | tr -d '\n'
}

wg_pubkey() {
  # $1 = base64 private key. Rebuild a DER private key and extract the public.
  local der_prefix='MC4CAQAwBQYDK2VuBCIEIA=='
  { printf '%s' "$der_prefix" | base64 -d; printf '%s' "$1" | base64 -d; } \
    | openssl pkey -inform DER -pubout -outform DER 2>/dev/null \
    | tail -c 32 | base64 | tr -d '\n'
}

wg_genpsk() { openssl rand -base64 32 | tr -d '\n'; }

# --------------------------------------------------------------------- state --

state_init() {
  mkdir -p "$STATE_DIR" "$CLIENT_DIR"
  chmod 700 "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || echo '{"version":1,"clients":{},"servers":{}}' > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

state_get() { jq -r "$1" "$STATE_FILE"; }

# Atomic read-modify-write so an interrupted run cannot truncate the state.
state_set() {
  local filter="$1"; shift
  local tmp; tmp="$(mktemp "$STATE_DIR/.state.XXXXXX")"
  jq "$@" "$filter" "$STATE_FILE" > "$tmp" || { rm -f "$tmp"; die "state update failed"; }
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

server_key() { printf '%s/%s' "$1" "$2"; }   # provider/region

# ------------------------------------------------------------------- clients --

# Assign the lowest free host address in the tunnel subnet, starting at .2
# (.1 is the server). Reuses an existing assignment if the client is known.
client_next_ip() {
  # Pin IFS locally so word splitting here cannot be broken by a caller.
  local used i
  local IFS=$' \t\n'
  used="$(state_get '[.clients[].ipv4] | join(" ")')"
  for i in $(seq 2 254); do
    [[ " $used " == *" 10.66.66.$i "* ]] || { echo "10.66.66.$i"; return; }
  done
  die "tunnel subnet exhausted (254 clients)"
}

client_ensure() {
  local name="$1" priv pub ip idx
  if [[ "$(state_get ".clients[\"$name\"] // empty")" != "" ]]; then
    return 0
  fi
  priv="$(wg_genkey)"; pub="$(wg_pubkey "$priv")"; ip="$(client_next_ip)"
  idx="${ip##*.}"
  state_set '.clients[$n] = {priv:$p, pub:$u, ipv4:$i, ipv6:$s, created:$t}' \
    --arg n "$name" --arg p "$priv" --arg u "$pub" --arg i "$ip" \
    --arg s "fd66:66:66::$idx" --arg t "$(date -u +%FT%TZ)"
  ok "created client key: $name ($ip)"
}

# ------------------------------------------------------------ config render --

resolve_dns() {
  case "${1:-cloudflare}" in
    cloudflare) echo "1.1.1.2, 1.0.0.2" ;;          # malware-blocking resolver
    quad9)      echo "9.9.9.9, 149.112.112.112" ;;
    google)     echo "8.8.8.8, 8.8.4.4" ;;
    unbound|adguard) echo "$VPN_SERVER_V4" ;;        # resolver runs on the server
    *)          echo "$1" ;;                          # caller passed literal IPs
  esac
}

# render_client_config <client> <provider> <region>
render_client_config() {
  local name="$1" prov="$2" region="$3" skey
  skey="$(server_key "$prov" "$region")"
  local cpriv cipv4 cipv6 spub psk endpoint port dns
  cpriv="$(state_get ".clients[\"$name\"].priv")"
  cipv4="$(state_get ".clients[\"$name\"].ipv4")"
  cipv6="$(state_get ".clients[\"$name\"].ipv6")"
  spub="$(state_get ".servers[\"$skey\"].pub")"
  psk="$(state_get ".servers[\"$skey\"].psk[\"$name\"] // empty")"
  endpoint="$(state_get ".servers[\"$skey\"].endpoint")"
  port="$(state_get ".servers[\"$skey\"].port")"
  dns="$(state_get ".servers[\"$skey\"].dns")"

  cat <<EOF
[Interface]
PrivateKey = $cpriv
Address = $cipv4/32, $cipv6/128
DNS = $dns
MTU = $VPN_MTU

[Peer]
PublicKey = $spub
$([[ -n "$psk" ]] && echo "PresharedKey = $psk")
Endpoint = $endpoint:$port
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = $VPN_KEEPALIVE
EOF
}

# Write every known client's config for one server, plus a QR code if possible.
emit_configs() {
  local prov="$1" region="$2" name outdir f
  outdir="$CLIENT_DIR/$prov-$region"
  mkdir -p "$outdir"; chmod 700 "$outdir"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    f="$outdir/$name.conf"
    render_client_config "$name" "$prov" "$region" > "$f"
    chmod 600 "$f"
    ok "config: ${f#$ROOT_DIR/}"
  done < <(state_get '.clients | keys[]')
}

show_qr() {
  local file="$1"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$file"
  else
    warn "qrencode not installed — cannot print QR. Install: brew install qrencode"
    warn "Or import the file directly into the WireGuard app."
  fi
}

# --------------------------------------------------------------- user-data --

# Build the bootstrap script for a server: read cloudinit/bootstrap.sh and
# substitute the placeholders. Kept dependency-free (no envsubst).
#
# The payload is a shell script, not a #cloud-config document, because Lightsail
# routes user-data to cloud-init's script handler -- a YAML payload there is
# executed line by line by dash and silently does nothing.
#
# The peer list is injected separately from the scalar values: awk -v cannot
# carry a multi-line value, and the block sits inside a YAML block scalar, so
# every line has to be re-indented to match the placeholder's own indentation.
build_user_data() {
  # All locals are declared once here: bash 3.2 (still the default on macOS)
  # echoes a local that is re-declared inside a loop.
  local prov="$1" region="$2" dns_mode="$3" skey priv peers_file
  local name cpub cip cip6 psk
  skey="$(server_key "$prov" "$region")"
  priv="$(state_get ".servers[\"$skey\"].priv")"
  [[ -n "$priv" && "$priv" != "null" ]] || die "no server key for $skey"

  peers_file="$(mktemp)"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    cpub="$(state_get ".clients[\"$name\"].pub")"
    cip="$(state_get ".clients[\"$name\"].ipv4")"
    cip6="$(state_get ".clients[\"$name\"].ipv6")"
    psk="$(state_get ".servers[\"$skey\"].psk[\"$name\"] // empty")"
    {
      echo "# client: $name"
      echo "[Peer]"
      echo "PublicKey = $cpub"
      [[ -n "$psk" ]] && echo "PresharedKey = $psk"
      echo "AllowedIPs = $cip/32, $cip6/128"
      echo
    } >> "$peers_file"
  done < <(state_get '.clients | keys[]')

  [[ -s "$peers_file" ]] || { rm -f "$peers_file"; die "no clients defined — run: ./vpn.sh client add <name>"; }

  # Base64 keys only ever contain [A-Za-z0-9+/=], so '|' is a safe sed
  # delimiter and no replacement-side escaping is needed.
  sed -e "s|__SERVER_PRIVKEY__|$priv|g" \
      -e "s|__PORT__|$VPN_PORT|g" \
      -e "s|__MTU__|$VPN_MTU|g" \
      -e "s|__SERVER_V4__|$VPN_SERVER_V4|g" \
      -e "s|__SERVER_V6__|$VPN_SERVER_V6|g" \
      -e "s|__NET_V4__|$VPN_NET_V4|g" \
      -e "s|__NET_V6__|$VPN_NET_V6|g" \
      -e "s|__DNS_MODE__|$dns_mode|g" \
      "$ROOT_DIR/cloudinit/bootstrap.sh" \
  | awk -v pf="$peers_file" '
      /__PEERS__/ {
        match($0, /^[ \t]*/)
        indent = substr($0, 1, RLENGTH)
        while ((getline line < pf) > 0) print indent line
        close(pf)
        next
      }
      { print }
    '
  rm -f "$peers_file"
}

# ----------------------------------------------------------------- my public IP --

# The CIDR(s) allowed to reach SSH. Defaults to the caller's current address as
# a /32. --ssh-cidr accepts a comma-separated list, which is the right answer
# for a connection behind carrier-grade NAT: enumerate the handful of addresses
# the ISP actually uses and pin each one, rather than widening to a whole /24.
#
# `./vpn.sh pool` prints that list by sampling your egress address repeatedly.
ssh_cidr() {
  if [[ -n "${SSH_CIDR:-}" ]]; then
    echo "$SSH_CIDR"
  else
    echo "$(my_ip)/32"
  fi
}

# Sample the public address this machine exits from, repeatedly, and print each
# distinct one as a /32. Connections behind CGNAT rotate between several.
egress_pool() {
  local n="${1:-40}" i
  for ((i=0; i<n; i++)); do
    curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null
  done | tr -d "\r" | sort -u | sed "s|$|/32|" | paste -sd, -
}

my_ip() {
  local ip
  ip="$(curl -fsS --max-time 8 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')" || true
  [[ -z "$ip" ]] && ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')" || true
  [[ -n "$ip" ]] || die "could not determine your public IP (needed to lock down SSH)"
  echo "$ip"
}

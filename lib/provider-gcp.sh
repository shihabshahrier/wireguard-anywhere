#!/usr/bin/env bash
# provider-gcp.sh — Google Compute Engine backend.
#
# Note on cost: GCP's Always Free e2-micro includes only 1 GB of egress per
# month, which is far too little for a VPN. Treat GCE as a paid option; the
# cheapest practical shape is an e2-micro on a Spot/preemptible-free tier in
# us-west1/us-central1/us-east1 plus metered egress at ~$0.085-0.12/GB.

GCP_MACHINE="${GCP_MACHINE:-e2-micro}"
GCP_IMAGE_FAMILY="${GCP_IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
GCP_IMAGE_PROJECT="${GCP_IMAGE_PROJECT:-ubuntu-os-cloud}"
GCP_FIREWALL="vpn-wireguard-allow"

gcp_check() {
  need_cmd gcloud "Install it: https://cloud.google.com/sdk/docs/install"
  [[ -n "$GCP_PROJECT" ]] || GCP_PROJECT="$(gcloud config get-value project 2>/dev/null)"
  [[ -n "$GCP_PROJECT" && "$GCP_PROJECT" != "(unset)" ]] \
    || die "no GCP project set. Pass --project <id> or run: gcloud config set project <id>"
  gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q . \
    || die "not logged in to gcloud. Run: gcloud auth login"
}

gcp_instance_name() { echo "vpn-$1"; }
gcp_zone() { echo "$1-a"; }   # every GCE region has an -a zone

gcp_() { gcloud --project "$GCP_PROJECT" "$@"; }

gcp_regions() {
  gcp_ compute regions list --format='value(name,description)' 2>/dev/null
}

gcp_state() {
  local s
  s="$(gcp_ compute instances describe "$(gcp_instance_name "$1")" \
        --zone "$(gcp_zone "$1")" --format='value(status)' 2>/dev/null)" || { echo absent; return; }
  [[ "$s" == "RUNNING" ]] && echo running || echo "$s" | tr '[:upper:]' '[:lower:]'
}

gcp_public_ip() {
  gcp_ compute instances describe "$(gcp_instance_name "$1")" --zone "$(gcp_zone "$1")" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null
}

# One project-wide firewall rule, scoped by target tag, rather than one per region.
gcp_open_ports() { gcp_ensure_firewall; }

gcp_ensure_firewall() {
  if gcp_ compute firewall-rules describe "$GCP_FIREWALL" >/dev/null 2>&1; then
    gcp_ compute firewall-rules update "$GCP_FIREWALL" \
      --allow "udp:$VPN_PORT" --source-ranges 0.0.0.0/0 >/dev/null
  else
    step "creating firewall rule $GCP_FIREWALL (UDP $VPN_PORT from anywhere)"
    gcp_ compute firewall-rules create "$GCP_FIREWALL" \
      --allow "udp:$VPN_PORT" --source-ranges 0.0.0.0/0 \
      --target-tags wireguard-vpn --description "WireGuard VPN (managed by vpn.sh)" >/dev/null
  fi
  # SSH is restricted to the operator's current address.
  local cidr; cidr="$(ssh_cidr)"
  if gcp_ compute firewall-rules describe "${GCP_FIREWALL}-ssh" >/dev/null 2>&1; then
    gcp_ compute firewall-rules update "${GCP_FIREWALL}-ssh" \
      --allow tcp:22 --source-ranges "$cidr" >/dev/null
  else
    gcp_ compute firewall-rules create "${GCP_FIREWALL}-ssh" \
      --allow tcp:22 --source-ranges "$cidr" --target-tags wireguard-vpn >/dev/null
  fi
}

gcp_up() {
  local region="$1" dns_mode="$2" name zone ip
  name="$(gcp_instance_name "$region")"; zone="$(gcp_zone "$region")"
  gcp_ensure_firewall

  if [[ "$(gcp_state "$region")" != "absent" ]]; then
    warn "instance $name already exists in $zone"
  else
    local ud; ud="$(mktemp)"
    build_user_data gcp "$region" "$dns_mode" > "$ud"
    log "launching $name in $zone ($GCP_MACHINE)"
    # can-ip-forward is mandatory: without it GCE drops forwarded packets.
    gcp_ compute instances create "$name" \
      --zone "$zone" \
      --machine-type "$GCP_MACHINE" \
      --image-family "$GCP_IMAGE_FAMILY" \
      --image-project "$GCP_IMAGE_PROJECT" \
      --boot-disk-size 10GB --boot-disk-type pd-standard \
      --can-ip-forward \
      --tags wireguard-vpn \
      --metadata-from-file "startup-script=$ud" \
      --labels "project=create-your-own-vpn,managed-by=vpn-sh" \
      >/dev/null || { rm -f "$ud"; die "instance creation failed in $zone"; }
    rm -f "$ud"
  fi

  log "waiting for instance to boot"
  local tries=0
  until [[ "$(gcp_state "$region")" == "running" ]]; do
    (( ++tries > 60 )) && { wait_end; die "instance did not reach RUNNING within 5 minutes"; }
    wait_dot; sleep 5
  done
  wait_end

  ip="$(gcp_public_ip "$region")"
  [[ -n "$ip" ]] || die "instance has no external IP"
  state_set '.servers[$k].endpoint = $e | .servers[$k].instance = $n | .servers[$k].updated = $t' \
    --arg k "$(server_key gcp "$region")" --arg e "$ip" --arg n "$name" --arg t "$(date -u +%FT%TZ)"
  ok "$region is up at $ip"
}

gcp_down() {
  local region="$1" name zone
  name="$(gcp_instance_name "$region")"; zone="$(gcp_zone "$region")"
  if [[ "$(gcp_state "$region")" == "absent" ]]; then
    warn "no instance in $region — nothing to delete"; return 0
  fi
  log "deleting $name in $zone"
  gcp_ compute instances delete "$name" --zone "$zone" --quiet >/dev/null \
    || die "instance deletion failed"
  state_set '.servers[$k].endpoint = null | .servers[$k].instance = null | .servers[$k].updated = $t' \
    --arg k "$(server_key gcp "$region")" --arg t "$(date -u +%FT%TZ)"
  ok "$region deleted — billing for it has stopped"
}

gcp_ssh() {
  local region="$1"; shift
  gcp_ compute ssh "$(gcp_instance_name "$region")" --zone "$(gcp_zone "$region")" \
    --tunnel-through-iap=false --command "$*"
}

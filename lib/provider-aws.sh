#!/usr/bin/env bash
# provider-aws.sh — Amazon Lightsail backend.
#
# Lightsail is used instead of EC2 because a personal VPN is an egress-heavy,
# tiny-compute workload. A $5 Lightsail bundle includes a public IPv4 address
# and 1 TB of transfer; the equivalent EC2 t3.micro costs ~$11.90/mo once the
# hourly public-IPv4 charge and EBS volume are counted, and bills egress from
# the first GB past the 100 GB account-wide free allowance.

AWS_BUNDLE_IPV4="${AWS_BUNDLE_IPV4:-nano_3_0}"
AWS_BUNDLE_IPV6="${AWS_BUNDLE_IPV6:-nano_ipv6_3_0}"
AWS_BLUEPRINT="${AWS_BLUEPRINT:-ubuntu_24_04}"

aws_() { aws --profile "$AWS_PROFILE" --region "$1" "${@:2}"; }

aws_check() {
  need_cmd aws "Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1 \
    || die "AWS profile '$AWS_PROFILE' is not usable. Run: aws configure --profile $AWS_PROFILE"
}

aws_instance_name() { echo "vpn-$1"; }

aws_regions() {
  aws lightsail get-regions --profile "$AWS_PROFILE" --region us-east-1 \
    --query 'regions[].[name,displayName]' --output text
}

# Bundle availability differs per region: Lightsail suffixes the bundle id
# (_3_0 in most regions, _3_1 where the transfer allowance is halved), so the
# id is resolved against the live API rather than hardcoded.
aws_resolve_bundle() {
  local region="$1" want="$2" family id
  family="$(echo "$want" | sed 's/_[0-9]*_[0-9]*$//')"
  id="$(aws_ "$region" lightsail get-bundles \
    --query "bundles[?isActive && starts_with(bundleId, \`${family}_\`) && supportedPlatforms[0]=='LINUX_UNIX'].bundleId | [0]" \
    --output text 2>/dev/null)"
  [[ -n "$id" && "$id" != "None" ]] || die "no '$family' bundle available in $region"
  echo "$id"
}

aws_exists() {
  aws_ "$1" lightsail get-instance --instance-name "$(aws_instance_name "$1")" \
    >/dev/null 2>&1
}

aws_state() {
  aws_ "$1" lightsail get-instance --instance-name "$(aws_instance_name "$1")" \
    --query 'instance.state.name' --output text 2>/dev/null || echo "absent"
}

aws_public_ip() {
  aws_ "$1" lightsail get-instance --instance-name "$(aws_instance_name "$1")" \
    --query 'instance.publicIpAddress' --output text 2>/dev/null
}

# Only the VPN port is exposed. SSH is deliberately NOT opened to the internet:
# it is reachable over the tunnel at the server's VPN address instead, so the
# instance presents a single UDP port to the world and there is no allow-rule
# to keep chasing when a home ISP rotates its address pool.
#
# --ssh-public re-opens TCP 22, restricted to --ssh-cidr (your current /32 by
# default), for the case where the tunnel itself is what needs debugging.
aws_open_ports() {
  local region="$1" name cidr
  name="$(aws_instance_name "$region")"

  if [[ "${SSH_PUBLIC:-0}" == "1" ]]; then
    cidr="$(ssh_cidr)"
    step "UDP $VPN_PORT open to the internet; SSH exposed to $cidr"
    aws_ "$region" lightsail put-instance-public-ports \
      --instance-name "$name" \
      --port-infos \
        "fromPort=$VPN_PORT,toPort=$VPN_PORT,protocol=UDP,cidrs=0.0.0.0/0,ipv6Cidrs=::/0" \
        "fromPort=22,toPort=22,protocol=TCP,cidrs=$cidr" \
      >/dev/null
  else
    step "UDP $VPN_PORT open to the internet; SSH reachable only over the tunnel ($VPN_SERVER_V4)"
    aws_ "$region" lightsail put-instance-public-ports \
      --instance-name "$name" \
      --port-infos \
        "fromPort=$VPN_PORT,toPort=$VPN_PORT,protocol=UDP,cidrs=0.0.0.0/0,ipv6Cidrs=::/0" \
      >/dev/null
  fi
}

aws_up() {
  local region="$1" dns_mode="$2" ipv6_only="${3:-0}"
  local name bundle skey ip
  name="$(aws_instance_name "$region")"
  skey="$(server_key aws "$region")"

  if aws_exists "$region"; then
    warn "instance $name already exists in $region (state: $(aws_state "$region"))"
  else
    if [[ "$ipv6_only" == "1" ]]; then
      bundle="$(aws_resolve_bundle "$region" "$AWS_BUNDLE_IPV6")"
      warn "IPv6-only bundle: unreachable from IPv4-only networks (some hotel wifi, some carriers)"
    else
      bundle="$(aws_resolve_bundle "$region" "$AWS_BUNDLE_IPV4")"
    fi
    step "bundle $bundle, blueprint $AWS_BLUEPRINT"

    local ud; ud="$(mktemp)"
    build_user_data aws "$region" "$dns_mode" > "$ud"

    local az
    az="$(aws_ "$region" lightsail get-regions --include-availability-zones \
      --query "regions[?name=='$region'].availabilityZones[0].zoneName | [0]" --output text)"

    log "launching $name in $region ($az)"
    aws_ "$region" lightsail create-instances \
      --instance-names "$name" \
      --availability-zone "$az" \
      --blueprint-id "$AWS_BLUEPRINT" \
      --bundle-id "$bundle" \
      --user-data "file://$ud" \
      --tags "key=project,value=create-your-own-vpn" "key=managed-by,value=vpn.sh" \
      >/dev/null || { rm -f "$ud"; die "create-instances failed in $region"; }
    rm -f "$ud"
  fi

  # Wait for the instance to reach 'running' and receive a public address.
  log "waiting for instance to boot"
  local tries=0
  until [[ "$(aws_state "$region")" == "running" ]]; do
    (( ++tries > 60 )) && { wait_end; die "instance did not reach 'running' within 5 minutes"; }
    wait_dot; sleep 5
  done
  wait_end

  ip="$(aws_public_ip "$region")"
  [[ -n "$ip" && "$ip" != "None" ]] || die "instance has no public IPv4 address"

  aws_open_ports "$region"

  state_set '.servers[$k].endpoint = $e | .servers[$k].instance = $n | .servers[$k].updated = $t' \
    --arg k "$skey" --arg e "$ip" --arg n "$name" --arg t "$(date -u +%FT%TZ)"

  ok "$region is up at $ip"
}

aws_down() {
  local region="$1" name
  name="$(aws_instance_name "$region")"
  if ! aws_exists "$region"; then
    warn "no instance in $region — nothing to delete"
    return 0
  fi
  log "deleting $name in $region"
  aws_ "$region" lightsail delete-instance --instance-name "$name" >/dev/null \
    || die "delete-instance failed in $region"
  state_set '.servers[$k].endpoint = null | .servers[$k].instance = null | .servers[$k].updated = $t' \
    --arg k "$(server_key aws "$region")" --arg t "$(date -u +%FT%TZ)"
  ok "$region deleted — billing for it has stopped"
}

# Lightsail hands out a short-lived SSH key on demand, so the tool never has to
# create, store, or rotate a key pair of its own.
aws_ssh() {
  local region="$1"; shift
  local name tmp ip user rc=0
  name="$(aws_instance_name "$region")"
  tmp="$(mktemp -d)"
  # These are credentials on disk: remove them however this function exits,
  # including when ssh fails under `set -e`.
  trap 'rm -rf "$tmp"' RETURN

  # One call for everything: Lightsail hands out a short-lived key AND a signed
  # certificate, so the tool never creates or stores a key pair of its own.
  aws_ "$region" lightsail get-instance-access-details --instance-name "$name" \
    --output json > "$tmp/access.json" 2>/dev/null \
    || die "could not get access details for $name"

  jq -r '.accessDetails.privateKey' "$tmp/access.json" > "$tmp/key"
  chmod 600 "$tmp/key"
  user="$(jq -r '.accessDetails.username' "$tmp/access.json")"

  # Lightsail authenticates with a certificate; without it sshd rejects the
  # key outright with "Permission denied (publickey)".
  local certopt=()
  if [[ "$(jq -r '.accessDetails.certKey // empty' "$tmp/access.json")" != "" ]]; then
    jq -r '.accessDetails.certKey' "$tmp/access.json" > "$tmp/key-cert.pub"
    chmod 600 "$tmp/key-cert.pub"
    certopt=(-o "CertificateFile=$tmp/key-cert.pub")
  fi

  if [[ "${SSH_PUBLIC:-0}" == "1" ]]; then
    ip="$(jq -r '.accessDetails.ipAddress' "$tmp/access.json")"
  else
    # SSH is not published to the internet; reach it across the VPN.
    ip="$VPN_SERVER_V4"
  fi

  ssh -i "$tmp/key" "${certopt[@]}" \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=15 "$user@$ip" "$@" || rc=$?
  if [[ $rc -ne 0 && "${SSH_PUBLIC:-0}" != "1" ]]; then
    warn "SSH is reachable only over the tunnel ($VPN_SERVER_V4) — connect the VPN first,"
    warn "or relaunch with --ssh-public to expose port 22 to your own address."
  fi
  return $rc
}

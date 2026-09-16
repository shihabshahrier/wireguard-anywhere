#!/usr/bin/env bash
# provider-azure.sh — Azure Virtual Machines backend.
#
# Cost note: Azure bills the VM, the managed disk, and the public IP address
# separately, so the all-in monthly figure lands well above an equivalent
# Lightsail bundle. Azure is worth it mainly for the 12-month free B1s
# allowance on a new account (750 h/month — enough for one always-on server).

AZ_SIZE="${AZ_SIZE:-Standard_B1ls}"
AZ_IMAGE="${AZ_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
AZ_ADMIN="${AZ_ADMIN:-azureuser}"

azure_check() {
  need_cmd az "Install it: https://learn.microsoft.com/cli/azure/install-azure-cli"
  az account show >/dev/null 2>&1 || die "not logged in to Azure. Run: az login"
  if [[ -n "$AZURE_SUBSCRIPTION" ]]; then
    az account set --subscription "$AZURE_SUBSCRIPTION" \
      || die "could not select subscription $AZURE_SUBSCRIPTION"
  fi
}

azure_rg()   { echo "vpn-$1-rg"; }
azure_name() { echo "vpn-$1"; }

azure_regions() {
  az account list-locations --query '[].[name,displayName]' --output tsv 2>/dev/null
}

azure_state() {
  local s
  s="$(az vm get-instance-view --resource-group "$(azure_rg "$1")" --name "$(azure_name "$1")" \
       --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" \
       --output tsv 2>/dev/null)" || { echo absent; return; }
  [[ -z "$s" ]] && { echo absent; return; }
  [[ "$s" == "VM running" ]] && echo running || echo "$s" | tr '[:upper:]' '[:lower:]'
}

azure_public_ip() {
  az vm list-ip-addresses --resource-group "$(azure_rg "$1")" --name "$(azure_name "$1")" \
    --query '[0].virtualMachine.network.publicIpAddresses[0].ipAddress' --output tsv 2>/dev/null
}

# Re-apply the NSG rules, including pinning SSH to the caller's current address.
azure_open_ports() {
  local region="$1" rg name cidr
  rg="$(azure_rg "$region")"; name="$(azure_name "$region")"; cidr="$(ssh_cidr)"
  az network nsg rule update --resource-group "$rg" --nsg-name "${name}NSG" \
    --name allow-ssh --source-address-prefixes "$cidr" >/dev/null \
    || die "could not update NSG rule allow-ssh in $rg"
  step "SSH restricted to $cidr"
}

azure_up() {
  local region="$1" dns_mode="$2" rg name ip cidr
  rg="$(azure_rg "$region")"; name="$(azure_name "$region")"

  if [[ "$(azure_state "$region")" != "absent" ]]; then
    warn "VM $name already exists in $region"
  else
    step "ensuring resource group $rg"
    az group create --name "$rg" --location "$region" \
      --tags project=create-your-own-vpn managed-by=vpn.sh >/dev/null \
      || die "could not create resource group $rg"

    local ud; ud="$(mktemp)"
    build_user_data azure "$region" "$dns_mode" > "$ud"

    log "launching $name in $region ($AZ_SIZE)"
    # --generate-ssh-keys reuses ~/.ssh/id_rsa if present, otherwise creates it.
    az vm create \
      --resource-group "$rg" --name "$name" \
      --image "$AZ_IMAGE" --size "$AZ_SIZE" \
      --admin-username "$AZ_ADMIN" --generate-ssh-keys \
      --public-ip-sku Standard --public-ip-address-allocation static \
      --os-disk-size-gb 30 --storage-sku StandardSSD_LRS \
      --custom-data "$ud" \
      --nsg-rule NONE \
      --tags project=create-your-own-vpn managed-by=vpn.sh \
      >/dev/null || { rm -f "$ud"; die "vm create failed in $region"; }
    rm -f "$ud"

    # Azure does not forward packets for a NIC unless IP forwarding is enabled
    # on the NIC resource itself, independent of the in-guest sysctl.
    local nic
    nic="$(az vm show --resource-group "$rg" --name "$name" \
           --query 'networkProfile.networkInterfaces[0].id' --output tsv)"
    az network nic update --ids "$nic" --ip-forwarding true >/dev/null
  fi

  cidr="$(ssh_cidr)"
  step "opening UDP $VPN_PORT to the internet, SSH to $cidr"
  az network nsg rule create --resource-group "$rg" --nsg-name "${name}NSG" \
    --name allow-wireguard --priority 1000 --protocol Udp \
    --destination-port-ranges "$VPN_PORT" --source-address-prefixes '*' \
    --access Allow --direction Inbound >/dev/null 2>&1 || \
  az network nsg rule update --resource-group "$rg" --nsg-name "${name}NSG" \
    --name allow-wireguard --destination-port-ranges "$VPN_PORT" >/dev/null
  az network nsg rule create --resource-group "$rg" --nsg-name "${name}NSG" \
    --name allow-ssh --priority 1001 --protocol Tcp \
    --destination-port-ranges 22 --source-address-prefixes "$cidr" \
    --access Allow --direction Inbound >/dev/null 2>&1 || \
  az network nsg rule update --resource-group "$rg" --nsg-name "${name}NSG" \
    --name allow-ssh --source-address-prefixes "$cidr" >/dev/null

  log "waiting for VM to boot"
  local tries=0
  until [[ "$(azure_state "$region")" == "running" ]]; do
    (( ++tries > 60 )) && { wait_end; die "VM did not reach running within 5 minutes"; }
    wait_dot; sleep 5
  done
  wait_end

  ip="$(azure_public_ip "$region")"
  [[ -n "$ip" ]] || die "VM has no public IP"
  state_set '.servers[$k].endpoint = $e | .servers[$k].instance = $n | .servers[$k].updated = $t' \
    --arg k "$(server_key azure "$region")" --arg e "$ip" --arg n "$name" --arg t "$(date -u +%FT%TZ)"
  ok "$region is up at $ip"
}

azure_down() {
  local region="$1" rg
  rg="$(azure_rg "$region")"
  if ! az group show --name "$rg" >/dev/null 2>&1; then
    warn "no resource group $rg — nothing to delete"; return 0
  fi
  log "deleting resource group $rg (VM, disk, NIC, public IP, NSG)"
  az group delete --name "$rg" --yes --no-wait \
    || die "resource group deletion failed"
  state_set '.servers[$k].endpoint = null | .servers[$k].instance = null | .servers[$k].updated = $t' \
    --arg k "$(server_key azure "$region")" --arg t "$(date -u +%FT%TZ)"
  ok "$region deletion started — billing stops as resources are removed"
}

azure_ssh() {
  local region="$1"; shift
  local ip; ip="$(azure_public_ip "$region")"
  [[ -n "$ip" ]] || die "no public IP for $region"
  ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "$AZ_ADMIN@$ip" "$@"
}

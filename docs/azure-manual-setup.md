# Create a VPN Server on Azure (manual)

The console version of what `./vpn.sh up azure <region>` automates.

Azure bills the VM, the managed disk, and the public IP address as three separate line items,
so the all-in monthly cost lands well above an equivalent Lightsail bundle. Azure is worth
choosing mainly for the **12-month free B1s allowance on a new account** — 750 hours per month,
which is enough for one always-on server for a year.

---

## 1. Create the VM

1. [Azure Portal](https://portal.azure.com) → **Virtual machines** → **Create**.
2. **Resource group**: new, named `vpn-<region>-rg`.
3. **Image**: Ubuntu Server 24.04 LTS.
4. **Size**: `Standard_B1ls` (cheapest) or `Standard_B1s` (covered by the free allowance).
5. **Authentication**: SSH public key.
6. **Inbound ports**: select **None**. The rules are added deliberately in step 2.
7. **Create**, and download the key if Azure generates one.

---

## 2. Network security group

VM → **Networking** → **Add inbound port rule**:

| Setting | Value |
| --- | --- |
| Source | `Any` |
| Destination port ranges | `51820` |
| Protocol | **UDP** |
| Priority | `1000` |
| Name | `allow-wireguard` |

Add a second rule for TCP 22 with **Source: My IP address** only while you are setting up, then
delete it once the tunnel works.

---

## 3. Enable IP forwarding on the NIC

This step has no equivalent on AWS and is the most common thing people miss. Azure drops
forwarded packets at the network fabric regardless of the in-guest `sysctl` setting.

**Networking** → click the network interface → **IP configurations** → set **IP forwarding** to
**Enabled** → **Save**.

Or with the CLI:

```bash
az network nic update --ids <nic-id> --ip-forwarding true
```

---

## 4. Install WireGuard

SSH in, then follow [sections 3 to 5 of the AWS guide](aws-manual-setup.md#3-install-and-configure-wireguard).
Everything is identical except the WAN interface name — on Azure it is usually `eth0`:

```bash
ip -4 route show default
```

Substitute that name into the `PostUp` and `PostDown` lines of `wg0.conf`.

---

## 5. Assign a static IP

By default Azure hands out a dynamic public IP that changes when the VM is deallocated, which
breaks every client config. **Networking** → the public IP resource → **Configuration** →
**Assignment: Static**.

---

## 6. Stop the billing

Deallocating the VM stops compute charges but you continue paying for the disk and the public
IP. To stop paying entirely, **delete the whole resource group**:

```bash
az group delete --name vpn-<region>-rg --yes
```

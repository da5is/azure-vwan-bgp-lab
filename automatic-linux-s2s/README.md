# Automatic Linux S2S — VWAN BGP demo, fully automated (azd)

End-to-end Azure Developer CLI (`azd`) template that demonstrates **Azure Virtual WAN site-to-site VPN with BGP** using a Linux VM (strongSwan + FRR) as a simulated on-premises edge. Includes a small test VM on each side that automatically validates Layer-3/4 connectivity.

No nested virtualization. No portal clicks. `azd up` to deploy, `azd down` to destroy.

## What gets deployed

```
                     ┌─────────────────────────────────────────────┐
   Azure cloud       │  rg-<env>-core                              │
                     │  ┌──────────┐    ┌────────────────────────┐ │
                     │  │ vwan +   │    │  Azure spoke VNet      │ │
                     │  │ vhub +   │═══▶│  10.30.0.0/16          │ │
                     │  │ vpn gw   │    │  ┌──────────────────┐  │ │
                     │  └────┬─────┘    │  │ azure test VM    │  │ │
                     │       ║          │  │ 10.30.100.4      │  │ │
                     │       ║          │  └──────────────────┘  │ │
                     └───────╫──────────┴────────────────────────┴─┘
              IPsec + BGP    ║   (dual tunnels, instance0/1)
                     ┌───────╫─────────────────────────────────────┐
                     │  rg-<env>-customer                          │
                     │  ┌────╨─────────┐    ┌────────────────────┐ │
                     │  │ Linux edge   │    │ customer test VM   │ │
                     │  │ VM (B2s)     │    │ 172.30.0.5         │ │
                     │  │ strongSwan   │    │ (edge subnet)      │ │
                     │  │ + FRR (BGP)  │    └────────────────────┘ │
                     │  │ 172.30.0.4   │   UDR 10.30.0.0/16 →edge  │
                     │  └──────────────┘   customer VNet           │
                     │   edge subnet 172.30.0.0/24                 │
                     │                      172.30.0.0/16          │
                     └─────────────────────────────────────────────┘
```

- **Hub side (`rg-<env>-core`)**: VWAN, Virtual Hub (`10.254.254.0/24`), VPN Gateway (active/active, ASN 65515), Azure spoke VNet (`10.30.0.0/16`) connected to the hub, an Azure test VM.
- **Customer side (`rg-<env>-customer`)**: VNet (`172.30.0.0/16`), Linux edge VM running strongSwan + FRR (ASN 65001) and the customer test VM, **both in the edge subnet** (`172.30.0.0/24`). A UDR on that subnet steers `10.30.0.0/16` to the edge. Co-locating the test VM with the edge is deliberate: Azure delivers NVA-forwarded packets with a non-VNet source only within the same subnet, so this avoids any need for SNAT.
- **Test VMs (B1s Ubuntu)**: each runs `iperf3`, `nginx`, and a systemd timer that pings/curls/iperfs the peer every 2 minutes and writes to `/var/log/s2s-validation.log`.

## How it stays automatic

Bicep extracts the VPN gateway's BGP/tunnel addresses **as outputs** of the `Microsoft.Network/vpnGateways` resource (`bgpSettings.bgpPeeringAddresses[*].tunnelIpAddresses` / `defaultBgpIpAddresses`). Those flow into `infra/cloud-init/edge.yaml.tmpl` via `loadTextContent` + `replace()` and get base64-encoded into the edge VM's `customData`. On first boot the edge VM:

1. Installs `strongswan`, `frr`, `iperf3`.
2. Enables IP forwarding, relaxes `rp_filter` for VTI.
3. Creates two VTI interfaces (`vti10`, `vti11`) with marks 100/200 — one per Azure gateway instance.
4. Brings strongSwan up against both Azure tunnel public IPs.
5. Starts FRR with two eBGP neighbors (one per VTI), advertising `172.30.0.0/16`.

## Prerequisites

- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) (`azd version` >= 1.5).
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (used by post-provision validation hints).
- An SSH public key (e.g. `~/.ssh/id_ed25519.pub`).

## Deploy

```powershell
cd automatic-linux-s2s

# One-time: create env, set required values
azd env new lns2s-dev                               # any name
azd env set SSH_PUBLIC_KEY "$((Get-Content $HOME\.ssh\id_ed25519.pub -Raw).Trim())"
azd env set VPN_SHARED_KEY (-join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | % {[char]$_}))

# Optional overrides
azd env set SSH_SOURCE_PREFIX "203.0.113.42/32"     # tighten SSH (default: *)
azd env set ADMIN_USERNAME    "azureuser"
azd env set LOCAL_ASN         "65001"

# Provision (azd will prompt for region/subscription on first run)
azd up
```

Bash equivalent:

```bash
cd automatic-linux-s2s
azd env new lns2s-dev
azd env set SSH_PUBLIC_KEY "$(cat ~/.ssh/id_ed25519.pub)"
azd env set VPN_SHARED_KEY "$(openssl rand -base64 32)"
azd up
```

Expect ~25-35 min total — VWAN VPN gateway provisioning is the long pole. After provisioning, BGP needs another 1-3 minutes to converge before the test VMs start showing successful runs.

## Verify

```powershell
# Tail the Azure-side test VM's validation log
az vm run-command invoke `
  -g (azd env get-value CORE_RESOURCE_GROUP) `
  -n (azd env get-value AZURE_TEST_VM_NAME) `
  --command-id RunShellScript `
  --scripts "tail -n 80 /var/log/s2s-validation.log"
```

You should see ping/HTTP/iperf3 succeeding to `172.30.0.5`. Run the same against `CUSTOMER_TEST_VM_NAME` in `CUSTOMER_RESOURCE_GROUP` for the reverse direction.

Inspect strongSwan + FRR on the edge:

```powershell
az vm run-command invoke `
  -g (azd env get-value CUSTOMER_RESOURCE_GROUP) `
  -n (azd env get-value EDGE_VM_NAME) `
  --command-id RunShellScript `
  --scripts "ipsec status; echo ---; vtysh -c 'show ip bgp summary'; echo ---; ip route | head -40"
```

In the portal: the VWAN hub's **VPN (Site to site) → BGP Dashboard** should show two connected BGP peers learning `172.30.0.0/16`.

## Tear down

```powershell
azd down --purge --force
```

`azd down` finds all resources by their `azd-env-name` tag and deletes both resource groups in parallel.

## Cost

Dominant cost is the VWAN VPN gateway scale unit (~$0.40/hr) + VWAN hub (~$0.25/hr). VMs (B1s × 2 + B2s × 1) are pennies. Run `azd down` between sessions.

## File layout

```
automatic-linux-s2s/
├── README.md
├── azure.yaml                              # azd entry point
└── infra/
    ├── main.bicep                          # subscription-scope deployment
    ├── main.parameters.json                # azd env var bindings
    ├── cloud-init/
    │   ├── edge.yaml.tmpl                  # strongSwan + FRR config
    │   └── testvm.yaml.tmpl                # iperf3/nginx + validation timer
    └── modules/
        ├── publicip.bicep
        ├── virtualwan.bicep
        ├── virtualhub.bicep
        ├── vhubconnection.bicep
        ├── vpngateway.bicep                # exposes Azure BGP IPs as outputs
        ├── vpnsite.bicep
        ├── vpnsiteconnection.bicep
        ├── routetable.bicep
        ├── vnet.bicep
        ├── linuxedge.bicep                 # B2s edge VM (strongSwan + FRR)
        └── testvm.bicep                    # B1s test VM
```

## azd env vars

Required (set with `azd env set ...`):

| Name | Description |
| --- | --- |
| `SSH_PUBLIC_KEY` | Single-line OpenSSH public key for all Linux VMs |
| `VPN_SHARED_KEY` | IPsec PSK (any 16+ char string) |

Optional:

| Name | Default | Description |
| --- | --- | --- |
| `SSH_SOURCE_PREFIX` | `*` | CIDR allowed to SSH to the edge VM |
| `ADMIN_USERNAME` | `azureuser` | Linux admin user |
| `LOCAL_ASN` | `65001` | Customer-side BGP ASN |

Outputs surfaced in `.azure/<env>/.env`:

| Name | Description |
| --- | --- |
| `AZURE_LOCATION` | Region |
| `AZURE_RESOURCE_GROUP` / `CORE_RESOURCE_GROUP` | Hub-side RG |
| `CUSTOMER_RESOURCE_GROUP` | Customer-side RG |
| `EDGE_VM_NAME`, `EDGE_VM_PUBLIC_IP`, `EDGE_VM_PRIVATE_IP` | Edge appliance |
| `AZURE_TEST_VM_NAME`, `AZURE_TEST_VM_IP` | Hub-side test VM |
| `CUSTOMER_TEST_VM_NAME`, `CUSTOMER_TEST_VM_IP` | Customer-side test VM |
| `AZURE_TUNNEL_IP_0/1`, `AZURE_BGP_IP_0/1` | VPN gateway BGP plane |
| `VALIDATION_COMMAND` | Ready-to-run `az vm run-command` line |

## Notes / caveats

- The edge VM has a public IP open on UDP/500, UDP/4500, and ESP from the Internet. Required for VWAN to reach it. SSH defaults to `*` for lab convenience; tighten `SSH_SOURCE_PREFIX` for anything real.
- The PSK is interpolated into the VM's `customData`. ARM stores `customData` per VM; treat it as data, not a secret. For production-grade hygiene, replace with a Key Vault reference + an `az keyvault secret show` call from the VM's managed identity.
- IPsec proposals: `aes256-sha256-modp2048` for IKE and ESP. Matches Azure VPN's default IKEv2 policy.
- FRR advertises only `172.30.0.0/16`. Edit `infra/cloud-init/edge.yaml.tmpl` to add more.

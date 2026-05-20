# Automatic Linux S2S — VWAN BGP demo, fully automated

End-to-end Bicep deployment that demonstrates **Azure Virtual WAN site-to-site VPN with BGP** using a Linux VM (strongSwan + FRR) as a simulated on-premises edge device. Includes a small test VM on each side that automatically validates Layer-3/4 connectivity over the tunnel.

No nested virtualization. No manual portal clicks. One `az deployment sub create` and you have working dual-tunnel IPsec + active/active BGP between two VNets.

## What it deploys

```
                     ┌─────────────────────────────────────────────┐
   Azure cloud       │  rg-lns2s-core                              │
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
                     │  rg-lns2s-customer                          │
                     │  ┌────╨─────────┐    ┌────────────────────┐ │
                     │  │ Linux edge   │    │ customer test VM   │ │
                     │  │ VM (B2s)     │◀───│ 172.30.100.4       │ │
                     │  │ strongSwan   │UDR │                    │ │
                     │  │ + FRR (BGP)  │    └────────────────────┘ │
                     │  │ 172.30.0.4   │                           │
                     │  └──────────────┘   customer VNet           │
                     │                      172.30.0.0/16          │
                     └─────────────────────────────────────────────┘
```

- **Hub side (`rg-lns2s-core`)**: VWAN, Virtual Hub (`10.254.254.0/24`), VPN Gateway (active/active, ASN 65515), Azure spoke VNet (`10.30.0.0/16`) with hub connection, Azure test VM.
- **Customer side (`rg-lns2s-customer`)**: VNet (`172.30.0.0/16`) with edge subnet + workload subnet, Linux edge VM running strongSwan + FRR (ASN 65001), customer test VM, route table sending workload traffic via the edge.
- **Test VMs (B1s Ubuntu)**: each runs an `iperf3` server, `nginx`, and a systemd timer that pings/curls/iperfs the peer every 2 minutes and writes the results to `/var/log/s2s-validation.log`.

## How it stays automatic

The painful parts of a customer-edge VPN config are: discovering the Azure VPN Gateway tunnel public IPs, the BGP peer addresses, and the gateway ASN. Bicep exposes all of these as outputs of the `Microsoft.Network/vpnGateways` resource directly, so we render them into the edge VM's `cloud-init` **at deploy time** — no post-deploy script, no managed identity, no run-once hand-off.

```
vpnGateway.properties.bgpSettings.bgpPeeringAddresses[0|1].tunnelIpAddresses[0]
vpnGateway.properties.bgpSettings.bgpPeeringAddresses[0|1].defaultBgpIpAddresses[0]
vpnGateway.properties.bgpSettings.asn
```

These flow into `cloud-init/edge.yaml.tmpl` via Bicep `loadTextContent` + `replace()`, and the resulting cloud-init is base64-encoded into `customData` for the edge VM. On first boot, the VM:

1. Installs `strongswan`, `frr`, `iperf3`.
2. Enables IP forwarding and relaxes `rp_filter` for VTI.
3. Creates two VTI interfaces (`vti10`, `vti11`) with marks 100/200 — one per Azure gateway instance.
4. Brings strongSwan up against both Azure tunnel public IPs.
5. Starts FRR with two eBGP neighbors (one per VTI), advertising `172.30.0.0/16`.

## Prerequisites

- Azure CLI logged in to the target subscription (`az login`).
- An SSH public key (e.g. `~/.ssh/id_ed25519.pub`).
- Bicep CLI (`az bicep install` if needed).

## Deploy

```powershell
$env:LAB_SSH_PUBLIC_KEY = (Get-Content $HOME\.ssh\id_ed25519.pub -Raw).Trim()
$env:LAB_VPN_PSK        = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | % {[char]$_})

Copy-Item .\automatic-linux-s2s.bicepparam.sample .\automatic-linux-s2s.bicepparam
# edit the file: set location + location_abbr (e.g. 'eastus2' / 'eus2')

az deployment sub create `
  --location eastus2 `
  --template-file .\automatic-linux-s2s.bicep `
  --parameters .\automatic-linux-s2s.bicepparam
```

Expect ~25–35 min total — VWAN VPN gateway provisioning is the long pole.

## Verify

The deployment outputs include a one-shot validation command:

```powershell
az deployment sub show -n <deployment-name> --query properties.outputs.validationCommand.value -o tsv
```

Or directly:

```powershell
# Read the validation log from the Azure-side test VM (no SSH key needed)
az vm run-command invoke `
  -g rg-lns2s-core-eus2-001 `
  -n vm-lns2s-aztest-eus2 `
  --command-id RunShellScript `
  --scripts "tail -n 80 /var/log/s2s-validation.log"
```

You should see ping/HTTP/iperf3 succeeding to `172.30.100.4`. Run the same against the customer-side test VM (`vm-lns2s-custtest-*` in `rg-lns2s-customer-*`) for the reverse direction.

To inspect tunnel/BGP state on the edge:

```powershell
az vm run-command invoke `
  -g rg-lns2s-customer-eus2-001 `
  -n vm-lns2s-edge-eus2 `
  --command-id RunShellScript `
  --scripts "ipsec status; echo ---; vtysh -c 'show ip bgp summary'; echo ---; ip route | head -40"
```

In the portal, the VWAN hub's **VPN (Site to site) → BGP Dashboard** should show two connected BGP peers learning `172.30.0.0/16`.

## Cost

Dominant cost is the VWAN VPN gateway scale unit (~$0.40/hr) + VWAN hub (~$0.25/hr). VMs (B1s × 2 + B2s × 1) are pennies. Tear down with:

```powershell
az group delete -n rg-lns2s-core-eus2-001 --yes --no-wait
az group delete -n rg-lns2s-customer-eus2-001 --yes --no-wait
```

## Files

```
automatic-linux-s2s/
├── README.md
├── automatic-linux-s2s.bicep            # subscription-scope entry
├── automatic-linux-s2s.bicepparam.sample
├── cloud-init/
│   ├── edge.yaml.tmpl                   # strongSwan + FRR config
│   └── testvm.yaml.tmpl                 # iperf3/nginx + validation timer
└── modules/
    ├── publicip.bicep
    ├── virtualwan.bicep
    ├── virtualhub.bicep
    ├── vhubconnection.bicep
    ├── vpngateway.bicep                 # exposes Azure BGP IPs as outputs
    ├── vpnsite.bicep
    ├── vpnsiteconnection.bicep
    ├── routetable.bicep
    ├── linuxedge.bicep                  # B2s edge VM (strongSwan + FRR)
    └── testvm.bicep                     # B1s test VM
```

## Notes / caveats

- The edge VM has a public IP open on UDP/500, UDP/4500, and ESP from the Internet. That's required for VWAN to reach it — IKE source IPs are not fixed. SSH defaults to `*` for lab convenience; tighten `sshSourcePrefix` for anything real.
- The PSK is interpolated into the VM's `customData`. ARM stores `customData` per VM; treat it as data, not a secret. For production-grade hygiene, replace with a Key Vault reference + an `az keyvault secret show` call from the VM's managed identity.
- FRR is set to redistribute the static `172.30.0.0/16` network only. To advertise additional ranges, edit the `network` lines in `cloud-init/edge.yaml.tmpl` (or pass them as a parameter — easy extension).
- IPsec proposals are `aes256-sha256-modp2048` for both phases. That matches Azure VPN's default IKEv2 policy and is meaningfully stronger than the `01-core-network` lab's `aes256-sha1-modp1024`.

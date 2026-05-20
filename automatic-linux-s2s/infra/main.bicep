targetScope = 'subscription'

// ============================================================================
// Parameters (azd injects environmentName + location)
// ============================================================================
@minLength(1)
@maxLength(32)
@description('azd environment name. Used to scope and tag all resources.')
param environmentName string

@minLength(1)
@description('Azure region for the deployment.')
param location string

@description('Optional extra tags merged onto every resource.')
param tags object = {}

param adminUsername string = 'azureuser'

@description('SSH public key for all Linux VMs. Required.')
param sshPublicKey string

@secure()
@description('Pre-shared key for the IPsec tunnels. Required.')
param vpnSharedKey string

@description('CIDR allowed to SSH to the edge VM. Default open; tighten for non-lab use.')
param sshSourcePrefix string = '*'

@description('BGP ASN for the simulated customer side. Must not equal Azure VWAN ASN (65515).')
param localAsn int = 65001

param deploymentTimestamp string = utcNow('yyyy-MM-dd HH:mm:ss')

// ============================================================================
// Naming + address plan
// ============================================================================
var coreRgName = 'rg-${environmentName}-core'
var custRgName = 'rg-${environmentName}-customer'

var vwanName = 'vwan-${environmentName}'
var vhubName = 'vhub-${environmentName}'
var vhubAddressPrefix = '10.254.254.0/24'
var vpnGatewayName = 'vpngw-${environmentName}'

// Azure-side workload VNet (spoke)
var azVnetName = 'vnet-${environmentName}-azure'
var azVnetCidr = '10.30.0.0/16'
var azWorkloadSubnetName = 'snet-workload'
var azWorkloadSubnetCidr = '10.30.100.0/24'
var azTestVmName = take('vm-${environmentName}-aztest', 64)
var azTestVmIp = '10.30.100.4'
var vhubConnectionName = 'vhubconn-${azVnetName}'

// Customer-side simulated VNet
var custVnetName = 'vnet-${environmentName}-customer'
var custVnetCidr = '172.30.0.0/16'
var custEdgeSubnetName = 'snet-edge'
var custEdgeSubnetCidr = '172.30.0.0/24'
var custWorkloadSubnetName = 'snet-workload'
var custWorkloadSubnetCidr = '172.30.100.0/24'
var edgeVmName = take('vm-${environmentName}-edge', 64)
var edgeVmIp = '172.30.0.4'
var custTestVmName = take('vm-${environmentName}-custtest', 64)
var custTestVmIp = '172.30.100.4'
var custRouteTableName = 'rt-${environmentName}-customer-workload'

// VPN site / VTI BGP plan
var vpnSiteName = 'vpnsite-${environmentName}'
var vpnConnectionName = 'vpnconn-${environmentName}'
var vti10Addr = '169.254.21.2'
var vti11Addr = '169.254.21.6'
var vpnSiteBgpAddress = vti10Addr

var mergedTags = union(tags, {
  'azd-env-name': environmentName
  deployedAt: deploymentTimestamp
  lab: 'automatic-linux-s2s'
})

// ============================================================================
// Resource Groups
// ============================================================================
resource coreRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: coreRgName
  location: location
  tags: mergedTags
}

resource custRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: custRgName
  location: location
  tags: mergedTags
}

// ============================================================================
// VWAN + Hub + VPN Gateway
// ============================================================================
module vwan 'modules/virtualwan.bicep' = {
  scope: coreRg
  name: 'vwan-deploy'
  params: {
    vwanName: vwanName
    location: location
    tags: mergedTags
  }
}

module vhub 'modules/virtualhub.bicep' = {
  scope: coreRg
  name: 'vhub-deploy'
  params: {
    vhubName: vhubName
    location: location
    vwanId: vwan.outputs.vwanId
    addressPrefix: vhubAddressPrefix
    tags: mergedTags
  }
}

module vpnGateway 'modules/vpngateway.bicep' = {
  scope: coreRg
  name: 'vpngw-deploy'
  params: {
    vpnGatewayName: vpnGatewayName
    location: location
    vhubId: vhub.outputs.vhubId
    tags: mergedTags
  }
}

// ============================================================================
// Azure-side workload VNet + spoke connection
// ============================================================================
module azVnet 'modules/vnet.bicep' = {
  scope: coreRg
  name: 'azvnet-deploy'
  params: {
    name: azVnetName
    location: location
    addressPrefixes: [
      azVnetCidr
    ]
    subnets: [
      {
        name: azWorkloadSubnetName
        properties: {
          addressPrefix: azWorkloadSubnetCidr
        }
      }
    ]
    tags: mergedTags
  }
}

module vhubConnection 'modules/vhubconnection.bicep' = {
  scope: coreRg
  name: 'vhubconn-deploy'
  params: {
    connectionName: vhubConnectionName
    vhubName: vhub.outputs.vhubName
    vhubId: vhub.outputs.vhubId
    vnetId: azVnet.outputs.vnetId
  }
}

// ============================================================================
// Customer-side route table (default route -> edge VM)
// ============================================================================
module custRouteTable 'modules/routetable.bicep' = {
  scope: custRg
  name: 'rt-deploy'
  params: {
    name: custRouteTableName
    location: location
    edgePrivateIp: edgeVmIp
    tags: mergedTags
  }
}

// ============================================================================
// Customer-side VNet (edge subnet + workload subnet w/ UDR)
// ============================================================================
module custVnet 'modules/vnet.bicep' = {
  scope: custRg
  name: 'custvnet-deploy'
  params: {
    name: custVnetName
    location: location
    addressPrefixes: [
      custVnetCidr
    ]
    subnets: [
      {
        name: custEdgeSubnetName
        properties: {
          addressPrefix: custEdgeSubnetCidr
        }
      }
      {
        name: custWorkloadSubnetName
        properties: {
          addressPrefix: custWorkloadSubnetCidr
          routeTable: {
            id: custRouteTable.outputs.routeTableId
          }
        }
      }
    ]
    tags: mergedTags
  }
}

// ============================================================================
// Linux Edge VM (strongSwan + FRR)
// cloud-init has Azure VPN gateway BGP info baked in at deploy time.
// ============================================================================
// Build cloud-init from template + deployment-time values.
// The PSK is interpolated into customData; ARM treats VM customData as data.
#disable-next-line outputs-should-not-contain-secrets
var edgeCloudInit = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
  loadTextContent('cloud-init/edge.yaml.tmpl'),
  '__EDGE_PUBLIC_IP__', '__EDGE_PUBLIC_IP_PLACEHOLDER__'),
  '__AZ_PUB_IP_0__', vpnGateway.outputs.azureTunnelIp0),
  '__AZ_PUB_IP_1__', vpnGateway.outputs.azureTunnelIp1),
  '__AZ_BGP_IP_0__', vpnGateway.outputs.azureBgpIp0),
  '__AZ_BGP_IP_1__', vpnGateway.outputs.azureBgpIp1),
  '__AZ_ASN__', string(vpnGateway.outputs.azureAsn)),
  '__VTI10_ADDR__', vti10Addr),
  '__VTI11_ADDR__', vti11Addr),
  '__LOCAL_ASN__', string(localAsn)),
  '__CUSTOMER_CIDR__', custVnetCidr)

// Public IP for edge VM is needed BEFORE VPN site references it; allocate inside the
// linuxedge module. We resolve __EDGE_PUBLIC_IP_PLACEHOLDER__ at the module by passing
// the actual public IP back via outputs, but cloud-init needs it pre-render. To keep
// a single deployment, we allocate the PIP in this parent module first.
module edgePip 'modules/publicip.bicep' = {
  scope: custRg
  name: 'edge-pip-deploy'
  params: {
    publicIpName: '${edgeVmName}-pip'
    location: location
    tags: mergedTags
  }
}

#disable-next-line outputs-should-not-contain-secrets
var edgeCloudInitFinal = replace(replace(
  edgeCloudInit,
  '__EDGE_PUBLIC_IP_PLACEHOLDER__', edgePip.outputs.publicIpAddress),
  '__VPN_PSK__', vpnSharedKey)

module edgeVm 'modules/linuxedge.bicep' = {
  scope: custRg
  name: 'edge-vm-deploy'
  params: {
    vmName: edgeVmName
    location: location
    subnetId: '${custVnet.outputs.vnetId}/subnets/${custEdgeSubnetName}'
    staticPrivateIp: edgeVmIp
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    customData: edgeCloudInitFinal
    sshSourcePrefix: sshSourcePrefix
    existingPublicIpId: edgePip.outputs.publicIpId
    tags: mergedTags
  }
}

// ============================================================================
// VPN Site + Site Connection (BGP)
// ============================================================================
module vpnSite 'modules/vpnsite.bicep' = {
  scope: coreRg
  name: 'vpnsite-deploy'
  params: {
    vpnSiteName: vpnSiteName
    location: location
    vwanId: vwan.outputs.vwanId
    publicIpAddress: edgePip.outputs.publicIpAddress
    addressPrefixes: [
      custVnetCidr
    ]
    bgpAsn: localAsn
    bgpPeeringAddress: vpnSiteBgpAddress
    tags: mergedTags
  }
}

module vpnConnection 'modules/vpnsiteconnection.bicep' = {
  scope: coreRg
  name: 'vpnconn-deploy'
  params: {
    connectionName: vpnConnectionName
    vpnGatewayName: vpnGateway.outputs.vpnGatewayName
    vpnSiteId: vpnSite.outputs.vpnSiteId
    vpnSiteName: vpnSite.outputs.vpnSiteName
    vhubId: vhub.outputs.vhubId
    sharedKey: vpnSharedKey
    enableBgp: true
  }
}

// ============================================================================
// Test VMs (one each side) - cloud-init runs validation against the peer.
// ============================================================================
var azTestCloudInit = replace(replace(replace(
  loadTextContent('cloud-init/testvm.yaml.tmpl'),
  '__SIDE_NAME__', 'azure'),
  '__LOCAL_IP__', azTestVmIp),
  '__PEER_IP__', custTestVmIp)

var custTestCloudInit = replace(replace(replace(
  loadTextContent('cloud-init/testvm.yaml.tmpl'),
  '__SIDE_NAME__', 'customer'),
  '__LOCAL_IP__', custTestVmIp),
  '__PEER_IP__', azTestVmIp)

module azTestVm 'modules/testvm.bicep' = {
  scope: coreRg
  name: 'aztestvm-deploy'
  params: {
    vmName: azTestVmName
    location: location
    subnetId: '${azVnet.outputs.vnetId}/subnets/${azWorkloadSubnetName}'
    staticPrivateIp: azTestVmIp
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    customData: azTestCloudInit
    tags: mergedTags
  }
  dependsOn: [
    vhubConnection
  ]
}

module custTestVm 'modules/testvm.bicep' = {
  scope: custRg
  name: 'custtestvm-deploy'
  params: {
    vmName: custTestVmName
    location: location
    subnetId: '${custVnet.outputs.vnetId}/subnets/${custWorkloadSubnetName}'
    staticPrivateIp: custTestVmIp
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    customData: custTestCloudInit
    tags: mergedTags
  }
  dependsOn: [
    edgeVm
  ]
}

// ============================================================================
// Outputs (azd writes these to .azure/<env>/.env as AZURE_* env vars)
// ============================================================================
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = coreRg.name
output CORE_RESOURCE_GROUP string = coreRg.name
output CUSTOMER_RESOURCE_GROUP string = custRg.name
output EDGE_VM_NAME string = edgeVmName
output EDGE_VM_PUBLIC_IP string = edgePip.outputs.publicIpAddress
output EDGE_VM_PRIVATE_IP string = edgeVmIp
output AZURE_TEST_VM_NAME string = azTestVmName
output AZURE_TEST_VM_IP string = azTestVmIp
output CUSTOMER_TEST_VM_NAME string = custTestVmName
output CUSTOMER_TEST_VM_IP string = custTestVmIp
output AZURE_TUNNEL_IP_0 string = vpnGateway.outputs.azureTunnelIp0
output AZURE_TUNNEL_IP_1 string = vpnGateway.outputs.azureTunnelIp1
output AZURE_BGP_IP_0 string = vpnGateway.outputs.azureBgpIp0
output AZURE_BGP_IP_1 string = vpnGateway.outputs.azureBgpIp1
output VALIDATION_COMMAND string = 'az vm run-command invoke -g ${coreRg.name} -n ${azTestVmName} --command-id RunShellScript --scripts "tail -n 80 /var/log/s2s-validation.log"'

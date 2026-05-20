// VPN Gateway Module
// Exposes Azure BGP peering data so downstream modules (edge VM cloud-init)
// can be parameterized at deploy time without any post-deploy scripting.
param vpnGatewayName string
param location string
param vhubId string
param tags object = {}

resource vpnGateway 'Microsoft.Network/vpnGateways@2023-11-01' = {
  name: vpnGatewayName
  location: location
  properties: {
    virtualHub: {
      id: vhubId
    }
    bgpSettings: {
      asn: 65515
    }
    vpnGatewayScaleUnit: 1
  }
  tags: tags
}

output vpnGatewayId string = vpnGateway.id
output vpnGatewayName string = vpnGateway.name
output azureAsn int = vpnGateway.properties.bgpSettings.asn
output azureTunnelIp0 string = vpnGateway.properties.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]
output azureTunnelIp1 string = vpnGateway.properties.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]
output azureBgpIp0 string = vpnGateway.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
output azureBgpIp1 string = vpnGateway.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]

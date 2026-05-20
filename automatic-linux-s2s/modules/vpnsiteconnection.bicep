// VPN Site Connection Module
param connectionName string
param vpnGatewayName string
param vpnSiteId string
param vpnSiteName string
param vhubId string
@secure()
param sharedKey string
param enableBgp bool = true

resource vpnGateway 'Microsoft.Network/vpnGateways@2023-11-01' existing = {
  name: vpnGatewayName
}

resource vpnConnection 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: vpnGateway
  name: connectionName
  properties: {
    remoteVpnSite: {
      id: vpnSiteId
    }
    vpnConnectionProtocolType: 'IKEv2'
    ipsecPolicies: []
    vpnLinkConnections: [
      {
        name: '${connectionName}-link0'
        properties: {
          vpnSiteLink: {
            id: '${vpnSiteId}/vpnSiteLinks/${vpnSiteName}-link0'
          }
          sharedKey: sharedKey
          enableBgp: enableBgp
          vpnConnectionProtocolType: 'IKEv2'
          connectionBandwidth: 100
        }
      }
    ]
    routingConfiguration: {
      associatedRouteTable: {
        id: '${vhubId}/hubRouteTables/defaultRouteTable'
      }
      propagatedRouteTables: {
        labels: [
          'default'
        ]
        ids: [
          {
            id: '${vhubId}/hubRouteTables/defaultRouteTable'
          }
        ]
      }
    }
  }
}

output connectionId string = vpnConnection.id
output connectionName string = vpnConnection.name

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
          // Pin strong, deterministic crypto instead of negotiating Azure's
          // default policy (which settled on weak DH Group 2 / MODP_1024).
          // Must match the edge ipsec.conf ike=/esp= lines exactly or the
          // tunnels won't establish. Azure fixes the IKE (phase 1) SA lifetime
          // at 28800s when a custom policy is used; only saLifeTimeSeconds
          // (the IPsec/phase 2 lifetime) is configurable here.
          ipsecPolicies: [
            {
              saLifeTimeSeconds: 27000
              saDataSizeKilobytes: 102400000
              ipsecEncryption: 'GCMAES256'
              ipsecIntegrity: 'GCMAES256'
              ikeEncryption: 'AES256'
              ikeIntegrity: 'SHA256'
              dhGroup: 'DHGroup14'
              pfsGroup: 'None'
            }
          ]
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

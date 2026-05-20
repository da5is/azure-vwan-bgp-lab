// Virtual Hub VNet Connection Module
param connectionName string
param vhubName string
param vhubId string
param vnetId string
param enableInternetSecurity bool = false
param allowHubToRemoteVnetTransit bool = true
param allowRemoteVnetToUseHubVnetGateways bool = true

resource vhub 'Microsoft.Network/virtualHubs@2023-11-01' existing = {
  name: vhubName
}

resource vhubConnection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  parent: vhub
  name: connectionName
  properties: {
    remoteVirtualNetwork: {
      id: vnetId
    }
    enableInternetSecurity: enableInternetSecurity
    allowHubToRemoteVnetTransit: allowHubToRemoteVnetTransit
    allowRemoteVnetToUseHubVnetGateways: allowRemoteVnetToUseHubVnetGateways
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

output connectionId string = vhubConnection.id

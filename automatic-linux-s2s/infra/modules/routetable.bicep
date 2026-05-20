// Route table for the customer workload subnet, sending east-west traffic to the edge VM.
param name string
param location string
param edgePrivateIp string
param tags object = {}

resource rt 'Microsoft.Network/routeTables@2023-11-01' = {
  name: name
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-via-edge'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: edgePrivateIp
        }
      }
    ]
  }
  tags: tags
}

output routeTableId string = rt.id

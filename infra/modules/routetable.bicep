// Route table that steers traffic destined for the Azure side to the edge VM.
// Applied to the edge subnet so the co-located customer test VM reaches Azure via
// the edge. Azure routes by destination + subnet routes (it ignores a VM's chosen
// next hop), so a UDR is required. The prefix is scoped to the Azure side only, so
// it does not disturb the edge's own ESP tunnel (which targets the gateway's
// public IP) or its Internet/apt path.
param name string
param location string
param edgePrivateIp string
param routePrefix string = '0.0.0.0/0'
param tags object = {}

resource rt 'Microsoft.Network/routeTables@2023-11-01' = {
  name: name
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-azure-via-edge'
        properties: {
          addressPrefix: routePrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: edgePrivateIp
        }
      }
    ]
  }
  tags: tags
}

output routeTableId string = rt.id

// Public IP Address Module
param publicIpName string
param location string
param tags object = {}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
  tags: tags
}

output publicIpId string = publicIp.id
output publicIpAddress string = publicIp.properties.ipAddress

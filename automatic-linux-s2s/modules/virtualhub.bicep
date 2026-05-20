// Virtual Hub Module
param vhubName string
param location string
param vwanId string
param addressPrefix string
param tags object = {}

resource vhub 'Microsoft.Network/virtualHubs@2023-11-01' = {
  name: vhubName
  location: location
  properties: {
    virtualWan: {
      id: vwanId
    }
    addressPrefix: addressPrefix
    sku: 'Standard'
  }
  tags: tags
}

output vhubId string = vhub.id
output vhubName string = vhub.name

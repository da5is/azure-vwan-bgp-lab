// Virtual Network module - simple wrapper to allow subscription-scope deployment.
param name string
param location string
param addressPrefixes array
param subnets array
param tags object = {}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: addressPrefixes
    }
    subnets: subnets
  }
  tags: tags
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetIds array = [for (s, i) in subnets: vnet.properties.subnets[i].id]

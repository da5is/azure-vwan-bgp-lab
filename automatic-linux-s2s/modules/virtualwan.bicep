// Virtual WAN Module
param vwanName string
param location string
param tags object = {}

resource vwan 'Microsoft.Network/virtualWans@2023-11-01' = {
  name: vwanName
  location: location
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: true
    disableVpnEncryption: false
  }
  tags: tags
}

output vwanId string = vwan.id

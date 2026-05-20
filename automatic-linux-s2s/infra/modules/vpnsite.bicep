// VPN Site - represents the customer-edge Linux VM as the on-prem device.
param vpnSiteName string
param location string
param vwanId string
param publicIpAddress string
param addressPrefixes array
param bgpAsn int = 65001
param bgpPeeringAddress string = '169.254.21.2'
param tags object = {}

resource vpnSite 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: vpnSiteName
  location: location
  properties: {
    virtualWan: {
      id: vwanId
    }
    deviceProperties: {
      deviceVendor: 'Linux'
      deviceModel: 'strongSwan-FRR'
      linkSpeedInMbps: 100
    }
    addressSpace: {
      addressPrefixes: addressPrefixes
    }
    vpnSiteLinks: [
      {
        name: '${vpnSiteName}-link0'
        properties: {
          ipAddress: publicIpAddress
          linkProperties: {
            linkProviderName: 'Microsoft'
            linkSpeedInMbps: 100
          }
          bgpProperties: {
            asn: bgpAsn
            bgpPeeringAddress: bgpPeeringAddress
          }
        }
      }
    ]
  }
  tags: tags
}

output vpnSiteId string = vpnSite.id
output vpnSiteName string = vpnSite.name

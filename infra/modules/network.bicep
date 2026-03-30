// Network module: VNet, Subnet, NSG, Public IP

@description('Azure region for all resources')
param location string

@description('Operating system type, controls NSG inbound rules')
@allowed([
  'Ubuntu'
  'Windows'
])
param osType string

@description('Enable public HTTPS access via Caddy reverse proxy')
param enablePublicHttps bool = true

// --- Network Security Group ---

var sshRule = {
  name: 'Allow-SSH'
  properties: {
    priority: 1000
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourcePortRange: '*'
    destinationPortRange: '22'
    sourceAddressPrefix: '*'
    destinationAddressPrefix: '*'
  }
}

var rdpRule = {
  name: 'Allow-RDP'
  properties: {
    priority: 1000
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourcePortRange: '*'
    destinationPortRange: '3389'
    sourceAddressPrefix: '*'
    destinationAddressPrefix: '*'
  }
}

// WARNING: This opens the Gateway port to the public internet.
// Consider restricting sourceAddressPrefix or using Tailscale after deployment.
var gatewayRule = {
  name: 'Allow-Gateway'
  properties: {
    priority: 1100
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourcePortRange: '*'
    destinationPortRange: '18789'
    sourceAddressPrefix: '*'
    destinationAddressPrefix: '*'
  }
}

// HTTPS rule for Caddy reverse proxy (port 443)
var httpsRule = {
  name: 'Allow-HTTPS'
  properties: {
    priority: 1200
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourcePortRange: '*'
    destinationPortRange: '443'
    sourceAddressPrefix: '*'
    destinationAddressPrefix: '*'
  }
}

// HTTP rule for Let's Encrypt HTTP-01 challenge (port 80)
var httpChallengeRule = {
  name: 'Allow-HTTP-Challenge'
  properties: {
    priority: 1300
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourcePortRange: '*'
    destinationPortRange: '80'
    sourceAddressPrefix: '*'
    destinationAddressPrefix: '*'
  }
}

// When HTTPS is enabled, expose 443 + 80 (for cert) instead of 18789
var nsgRules = osType == 'Ubuntu'
  ? (enablePublicHttps ? [sshRule, httpsRule, httpChallengeRule] : [sshRule, gatewayRule])
  : (enablePublicHttps ? [rdpRule, httpsRule, httpChallengeRule] : [rdpRule, gatewayRule])

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'openclaw-nsg'
  location: location
  properties: {
    securityRules: nsgRules
  }
}

// --- Virtual Network ---

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'openclaw-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'openclaw-subnet'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// --- Public IP ---

// DNS label for Azure VM FQDN (used by Caddy for Let's Encrypt certificate)
var dnsLabel = 'openclaw-${uniqueString(resourceGroup().id)}'

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'openclaw-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

// --- Outputs ---

output subnetId string = vnet.properties.subnets[0].id
output publicIpId string = publicIp.id
output publicIpAddress string = publicIp.properties.ipAddress
output fqdn string = publicIp.properties.dnsSettings.fqdn

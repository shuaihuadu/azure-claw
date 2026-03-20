// Main entry template: dispatches to Ubuntu or Windows VM based on osType

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Operating system type')
@allowed([
  'Ubuntu'
  'Windows'
])
param osType string = 'Ubuntu'

@description('VM size SKU')
param vmSize string = 'Standard_B2s'

@description('Admin username')
param adminUsername string = 'azureclaw'

@description('Admin password (password authentication)')
@secure()
param adminPassword string

@description('Enable public HTTPS access via Caddy + Let\'s Encrypt (uses Azure VM DNS name)')
param enablePublicHttps bool = false

@description('Gateway password for authentication (required when enablePublicHttps is true)')
@secure()
param gatewayPassword string = ''

// --- Script URLs ---
// Raw GitHub URLs for install scripts; adjust branch/tag as needed
var repoBaseUrl = 'https://raw.githubusercontent.com/shuaihuadu/azure-claw/main/scripts'
var ubuntuScriptUrl = '${repoBaseUrl}/install-openclaw-ubuntu.sh'
var windowsScriptUrl = '${repoBaseUrl}/install-openclaw-windows.ps1'

// --- Network Module ---

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    osType: osType
    enablePublicHttps: enablePublicHttps
  }
}

// --- Ubuntu VM Module ---

module vmUbuntu 'modules/vm-ubuntu.bicep' = if (osType == 'Ubuntu') {
  name: 'vm-ubuntu'
  params: {
    location: location
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: network.outputs.subnetId
    publicIpId: network.outputs.publicIpId
    scriptUrl: ubuntuScriptUrl
    enablePublicHttps: enablePublicHttps
    gatewayPassword: gatewayPassword
    fqdn: network.outputs.fqdn
  }
}

// --- Windows VM Module ---

module vmWindows 'modules/vm-windows.bicep' = if (osType == 'Windows') {
  name: 'vm-windows'
  params: {
    location: location
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: network.outputs.subnetId
    publicIpId: network.outputs.publicIpId
    scriptUrl: windowsScriptUrl
    enablePublicHttps: enablePublicHttps
    gatewayPassword: gatewayPassword
    fqdn: network.outputs.fqdn
  }
}

// --- Outputs ---

output publicIpAddress string = network.outputs.publicIpAddress
output fqdn string = network.outputs.fqdn
#disable-next-line BCP318
output vmName string = osType == 'Ubuntu' ? vmUbuntu.outputs.vmName : vmWindows.outputs.vmName
output osType string = osType
output adminUsername string = adminUsername
output enablePublicHttps bool = enablePublicHttps

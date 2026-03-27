// Windows 11 VM module: NIC + VM + CustomScriptExtension

@description('Azure region')
param location string

@description('VM size SKU')
param vmSize string

@description('Admin username')
param adminUsername string

@description('Admin password')
@secure()
param adminPassword string

@description('Subnet resource ID')
param subnetId string

@description('Public IP resource ID')
param publicIpId string

@description('Install script content (embedded at build time)')
param scriptContent string

@description('Enable public HTTPS access')
param enablePublicHttps bool = false

@description('Gateway password for authentication')
@secure()
param gatewayPassword string = ''

@description('Fully qualified domain name for HTTPS certificate')
param fqdn string = ''

// Base64 encode the gateway password to avoid shell escaping issues
var encodedGatewayPassword = base64(gatewayPassword)

// --- Network Interface ---

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'openclaw-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIpId
          }
        }
      }
    ]
  }
}

// --- Virtual Machine ---

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'openclaw-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'openclaw-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-pro'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// --- CustomScriptExtension ---

resource installScript 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'install-openclaw'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {}
    protectedSettings: {
      commandToExecute: enablePublicHttps
        ? 'powershell -ExecutionPolicy Bypass -Command "\$b=[Convert]::FromBase64String(\'${base64(scriptContent)}\'); [IO.File]::WriteAllBytes(\'C:\\install.ps1\', \$b); & \'C:\\install.ps1\' -EnablePublicHttps -GatewayPasswordB64 \'${encodedGatewayPassword}\' -Fqdn \'${fqdn}\'"'
        : 'powershell -ExecutionPolicy Bypass -Command "\$b=[Convert]::FromBase64String(\'${base64(scriptContent)}\'); [IO.File]::WriteAllBytes(\'C:\\install.ps1\', \$b); & \'C:\\install.ps1\' -GatewayPasswordB64 \'${encodedGatewayPassword}\'"'
    }
  }
}

// --- Outputs ---

output vmName string = vm.name

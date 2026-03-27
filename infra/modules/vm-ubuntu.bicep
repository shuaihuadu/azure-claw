// Ubuntu 24.04 LTS VM module: NIC + VM + CustomScript extension

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
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
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

// --- CustomScript Extension ---

resource installScript 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'install-openclaw'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {}
    protectedSettings: {
      commandToExecute: enablePublicHttps
        ? 'printf \'%s\' \'${base64(scriptContent)}\' | base64 -d > /tmp/install-openclaw.sh && bash /tmp/install-openclaw.sh ${adminUsername} true ${encodedGatewayPassword} ${fqdn}'
        : 'printf \'%s\' \'${base64(scriptContent)}\' | base64 -d > /tmp/install-openclaw.sh && bash /tmp/install-openclaw.sh ${adminUsername} false ${encodedGatewayPassword}'
    }
  }
}

// --- Outputs ---

output vmName string = vm.name

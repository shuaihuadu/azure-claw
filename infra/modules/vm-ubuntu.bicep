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
param enablePublicHttps bool = true

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
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
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

// Construct a self-contained wrapper: set positional args via 'set --', then include the install script.
// Using replace() chain to avoid shell quoting/base64-in-commandToExecute issues.
// The install script reads $1..$4 as positional args, so we prepend 'set --' to provide them.
var wrapperTemplate = '''#!/bin/bash
set -- "__PH_ADMIN__" "__PH_HTTPS__" "__PH_GWPWD__" "__PH_FQDN__"
__PH_SCRIPT__'''

var w1 = replace(wrapperTemplate, '__PH_ADMIN__', adminUsername)
var w2 = replace(w1, '__PH_HTTPS__', enablePublicHttps ? 'true' : 'false')
var w3 = replace(w2, '__PH_GWPWD__', encodedGatewayPassword)
var w4 = replace(w3, '__PH_FQDN__', fqdn)
var fullScript = replace(w4, '__PH_SCRIPT__', scriptContent)

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
      script: base64(fullScript)
    }
  }
}

// --- Outputs ---

output vmName string = vm.name

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
param enablePublicHttps bool = true

@description('Gateway password for authentication')
@secure()
param gatewayPassword string = ''

@description('Fully qualified domain name for HTTPS certificate')
param fqdn string = ''

@description('Microsoft Foundry endpoint URL (empty = skip Foundry config)')
param foundryEndpoint string = ''

@description('Microsoft Foundry API key')
@secure()
param foundryApiKey string = ''

@description('Comma-separated model deployment names')
param foundryModels string = ''

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

// Construct a self-contained wrapper: prepend param values, then include the install script.
// Windows CustomScriptExtension doesn't support 'script' field, so we use commandToExecute
// to decode a base64 wrapper and execute it.
var winWrapperTemplate = '''# Auto-generated wrapper — sets parameters before the install script
$EnablePublicHttps = [switch]("__PH_HTTPS__" -eq "true")
$GatewayPasswordB64 = "__PH_GWPWD__"
$Fqdn = "__PH_FQDN__"
$FoundryEndpoint = "__PH_FOUNDRY_EP__"
$FoundryApiKey = "__PH_FOUNDRY_KEY__"
$FoundryModels = "__PH_FOUNDRY_MODELS__"
__PH_SCRIPT__'''

var ww1 = replace(winWrapperTemplate, '__PH_HTTPS__', enablePublicHttps ? 'true' : 'false')
var ww2 = replace(ww1, '__PH_GWPWD__', encodedGatewayPassword)
var ww3 = replace(ww2, '__PH_FQDN__', fqdn)
var ww4 = replace(ww3, '__PH_FOUNDRY_EP__', foundryEndpoint)
var ww5 = replace(ww4, '__PH_FOUNDRY_KEY__', foundryApiKey)
var ww6 = replace(ww5, '__PH_FOUNDRY_MODELS__', foundryModels)
// Remove the original param() block from the script since we set variables directly
var scriptWithoutParams = replace(
  scriptContent,
  'param(\r\n    [switch]$EnablePublicHttps,\r\n    [string]$GatewayPasswordB64 = \'\',\r\n    [string]$Fqdn = \'\'\r\n)',
  '# (params set by wrapper)'
)
var winFullScript = replace(ww6, '__PH_SCRIPT__', scriptWithoutParams)

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
      commandToExecute: 'powershell -ExecutionPolicy Bypass -Command "[IO.File]::WriteAllBytes(\'C:\\\\openclaw-install.ps1\',[Convert]::FromBase64String(\'${base64(winFullScript)}\')); & \'C:\\\\openclaw-install.ps1\'"'
    }
  }
}

// --- Outputs ---

output vmName string = vm.name

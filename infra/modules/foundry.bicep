// Microsoft Foundry (Azure AI Services) module: optional AI resource + model deployment

@description('Azure region')
param location string

@description('Model deployment name')
param modelName string = 'gpt-4.1'

// Generate a unique resource name
var uniqueSuffix = uniqueString(resourceGroup().id, 'openclaw-ai')
var accountName = 'openclaw-ai-${uniqueSuffix}'

// --- Azure AI Services Account ---

resource aiAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: accountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: accountName
    publicNetworkAccess: 'Enabled'
  }
}

// --- Model Deployment ---

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aiAccount
  name: modelName
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: '*'
    }
  }
}

// --- Outputs ---

output endpoint string = '${aiAccount.properties.endpoint}openai/v1'
output accountName string = aiAccount.name
#disable-next-line outputs-should-not-contain-secrets
output apiKey string = aiAccount.listKeys().key1

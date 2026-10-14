// Ambiente da POC na Azure: runner self-hosted + servidor de destino na
// mesma VNet (o destino nao tem IP publico), Key Vault com as credenciais
// por ambiente (TU/TI/PRD). Ver docs/ambiente-poc-azure.md.
//
// Implantado por provisionar.ps1 - nao chamar direto: o script gera
// as chaves SSH, cria o SPN da esteira e preenche os parametros abaixo.

targetScope = 'resourceGroup'

@description('Regiao dos recursos.')
param location string = resourceGroup().location

@description('Prefixo curto usado nos nomes dos recursos.')
param prefixo string = 'estm'

@description('Usuario administrador das VMs (acesso de emergencia; a operacao normal usa run-command).')
param adminUsername string = 'estmadmin'

@description('Chave publica SSH do administrador.')
param adminPublicKey string

@description('Chaves publicas SSH dos usuarios de deploy de cada ambiente.')
param deployKeyTU string
param deployKeyTI string
param deployKeyPRD string

@description('Object ID do service principal da esteira (le segredos do Key Vault).')
param esteiraSpnObjectId string

@description('Object ID de quem provisiona (grava os segredos no Key Vault).')
param operadorObjectId string

@description('Tipo do principal operador: User (login interativo) ou ServicePrincipal.')
@allowed([
  'User'
  'ServicePrincipal'
])
param operadorPrincipalType string = 'User'

// Serie B nao esta liberada para a subscription da POC em brazilsouth e
// a v7 ficou sem capacidade na regiao (AllocationFailed). D2s_v4: 2 vCPU,
// 8 GB. Sobrescreva via provisionar.ps1 -VmSize se a regiao mudar.
param runnerVmSize string = 'Standard_D2s_v4'
param alvoVmSize string = 'Standard_D2s_v4'
param alvoPrivateIp string = '10.60.1.10'

@description('Horario do desligamento automatico diario (HHmm), fuso de Brasilia.')
param autoShutdownTime string = '2200'

var tags = {
  projeto: 'esteira-model-cob'
  ambiente: 'poc'
}
var kvName = 'kv-${prefixo}-poc-${take(uniqueString(resourceGroup().id), 10)}'
var ubuntu = {
  publisher: 'Canonical'
  offer: 'ubuntu-24_04-lts'
  sku: 'server'
  version: 'latest'
}
var roleKvSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var roleKvSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

var alvoCloudInit = replace(replace(replace(replace(replace(replace(
  loadTextContent('alvo/cloud-init.yaml'),
  '__KEY_TU__', deployKeyTU),
  '__KEY_TI__', deployKeyTI),
  '__KEY_PRD__', deployKeyPRD),
  '__KEY_VAULT__', kvName),
  '__ADMIN_USER__', adminUsername),
  '__SUBMIT_B64__', loadFileAsBase64('alvo/estm-submit.py'))

// ---------------------------------------------------------------- rede

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${prefixo}-poc'
  location: location
  tags: tags
  properties: {
    // Sem regra de entrada: as regras padrao ja negam tudo que vem da
    // internet e liberam o trafego dentro da VNet (runner -> destino:22).
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${prefixo}-poc'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.60.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-poc'
        properties: {
          addressPrefix: '10.60.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
          // Saida para a internet (GitHub, apt, Key Vault) sem IP publico
          // nem NAT Gateway - suficiente para a POC.
          defaultOutboundAccess: true
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- Key Vault

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource kvEsteira 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, esteiraSpnObjectId, roleKvSecretsUser)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsUser)
    principalId: esteiraSpnObjectId
    principalType: 'ServicePrincipal'
  }
}

resource kvOperador 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, operadorObjectId, roleKvSecretsOfficer)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsOfficer)
    principalId: operadorObjectId
    principalType: operadorPrincipalType
  }
}

resource kvAlvo 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, alvoVm.id, roleKvSecretsUser)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsUser)
    principalId: alvoVm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------- VMs

resource alvoNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${prefixo}-alvo'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: alvoPrivateIp
        }
      }
    ]
  }
}

resource alvoVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-${prefixo}-alvo'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: alvoVmSize
    }
    osProfile: {
      computerName: 'vm-${prefixo}-alvo'
      adminUsername: adminUsername
      customData: base64(alvoCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: ubuntu
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: alvoNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

resource runnerNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${prefixo}-runner'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource runnerVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-${prefixo}-runner'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: runnerVmSize
    }
    osProfile: {
      computerName: 'vm-${prefixo}-runner'
      adminUsername: adminUsername
      customData: base64(loadTextContent('runner/cloud-init.yaml'))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: ubuntu
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 64
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: runnerNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

var shutdownProperties = {
  status: 'Enabled'
  taskType: 'ComputeVmShutdownTask'
  dailyRecurrence: {
    time: autoShutdownTime
  }
  timeZoneId: 'E. South America Standard Time'
  notificationSettings: {
    status: 'Disabled'
  }
}

resource alvoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${alvoVm.name}'
  location: location
  tags: tags
  properties: union(shutdownProperties, { targetResourceId: alvoVm.id })
}

resource runnerShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${runnerVm.name}'
  location: location
  tags: tags
  properties: union(shutdownProperties, { targetResourceId: runnerVm.id })
}

output keyVaultName string = kv.name
output alvoVmName string = alvoVm.name
output alvoPrivateIp string = alvoPrivateIp
output runnerVmName string = runnerVm.name

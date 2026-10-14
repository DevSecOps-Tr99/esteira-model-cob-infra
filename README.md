# esteira-model-cob-infra

Infraestrutura da POC `esteira-model-cob` na Azure: o runner self-hosted, o
servidor de destino que simula o mainframe e o Key Vault com as credenciais
por ambiente. Também configura o GitHub do repositório de JCL (Environments,
variables, secret e runner).

| Repositório | Papel |
|---|---|
| [esteira-model-cob-jcl](https://github.com/DevSecOps-Tr99/esteira-model-cob-jcl) | JCLs, parâmetros por ambiente, caller do workflow. **É o repositório que este provisionamento configura** |
| [esteira-model-cob](https://github.com/DevSecOps-Tr99/esteira-model-cob) | motor Python + workflow reutilizável + regras de governança. Arquitetura completa em [`docs/esteira-poc-como-funciona.md`](https://github.com/DevSecOps-Tr99/esteira-model-cob/blob/main/docs/esteira-poc-como-funciona.md) |
| **esteira-model-cob-infra** (este) | Bicep, cloud-init e provisionamento |

## Topologia

```
GitHub · esteira-model-cob-jcl  (Environments TU / TI / PRD, variables, secret)
  │  job deploy -> runner self-hosted (label estm-runner)  [aprovação em TI e PRD]
  ▼
rg-esteira-model-cob-poc (brazilsouth)
  ├─ vnet-estm-poc 10.60.0.0/16 · snet-poc 10.60.1.0/24 · NSG sem entrada da internet
  ├─ vm-estm-runner   runner do GitHub Actions (systemd), az CLI, Python; só saída HTTPS
  │        │ SSH :22 (só dentro da VNet)
  │        ▼
  ├─ vm-estm-alvo     10.60.1.10, sem IP público, managed identity
  │        usuários estmtu / estmti / estmprd  ->  /srv/estm/TU | TI | PRD
  │        /usr/local/bin/estm-submit  (valida o token no Key Vault e "submete")
  └─ kv-estm-poc-*    chaves SSH e tokens fictícios por ambiente (RBAC)
```

Os três ambientes compartilham as VMs e o Key Vault, mas cada um tem as
próprias credenciais: usuário, chave SSH, token e pasta. O `estm-submit`
recusa quando um usuário tenta publicar em outro ambiente.

## Arquivos

| Arquivo | O que faz |
|---|---|
| `main.bicep` | VNet, NSG, Key Vault (RBAC), as duas VMs, auto-shutdown e papéis no Key Vault |
| `alvo/cloud-init.yaml` | usuários por ambiente, pastas, `sshd` só com chave, instala o `estm-submit` |
| `alvo/estm-submit.py` | a "submissão" no servidor: valida o token, grava o membro, gera JOBID e spool |
| `runner/cloud-init.yaml` | dependências do runner (Python, az CLI, git, jq) |
| `runner/registrar-runner.sh` | registra o runner no repositório de JCL como serviço systemd |
| `provisionar.ps1` | faz tudo de ponta a ponta, de forma idempotente |

## Provisionar (ou reproduzir) o ambiente

**Pré-requisitos**

| O quê | Permissão necessária |
|---|---|
| `az` logado (`az login`) | **Owner** na subscription, ou Contributor + User Access Administrator, porque o Bicep cria papéis no Key Vault. No Entra ID, permissão para criar app registration (padrão para usuários membros) |
| `gh` logado (`gh auth login`) | **admin** do repositório de JCL (runners, environments, variables, secrets) |
| `ssh-keygen` | vem com o Git for Windows ou o OpenSSH |
| PowerShell 5.1+ ou 7 | Windows, ou Cloud Shell (pwsh) |

**Rodar**

```powershell
powershell -ExecutionPolicy Bypass -File provisionar.ps1 -Subscription <id-da-subscription>
```

Parâmetros opcionais: `-Location` (padrão `brazilsouth`), `-ResourceGroup`,
`-Repo` (padrão `DevSecOps-Tr99/esteira-model-cob-jcl`), `-Reviewers`
(logins que aprovam TI e PRD; o padrão é o usuário do `gh`), `-VmSize`
(padrão `Standard_D2s_v4`), `-Az`/`-Gh` (caminho dos executáveis).

O script faz, em ordem:
1. cria o resource group e o SPN `sp-esteira-model-cob-poc-kv`;
2. gera as chaves SSH, ou reaproveita as que já estão no Key Vault;
3. roda o Bicep;
4. grava os segredos no Key Vault;
5. lê a host key do destino;
6. registra o runner no repositório de JCL;
7. cria os Environments com aprovação em TI e PRD;
8. cria as variables do repositório e o secret `SPN_KV_DEV_SECRET`.

Leva de 10 a 15 minutos.

**Depois**, no repositório de JCL, publique as variables `JCL_*` de cada
Environment: `python scripts/sincronizar-variables.py`.

Se a região estiver sem capacidade para o tamanho de VM, use outro com
`-VmSize`. A série B não é liberada para a subscription da POC em
brazilsouth, e a v7 já ficou sem capacidade lá. Antes de repetir, apague as
VMs que ficaram em estado *Failed*:
`az vm delete --ids $(az vm list -g rg-esteira-model-cob-poc --query "[?provisioningState=='Failed'].id" -o tsv) --yes`.

## Key Vault

| Segredo | Conteúdo | Quem lê |
|---|---|---|
| `estm-tu-ssh-key` / `estm-ti-ssh-key` / `estm-prd-ssh-key` | chave privada SSH do usuário de deploy do ambiente | SPN da esteira |
| `estm-tu-token` / `estm-ti-token` / `estm-prd-token` | token fictício do ambiente | SPN da esteira e a managed identity do destino |
| `estm-admin-ssh-key` | chave do administrador das VMs (emergência) | só quem provisiona (Key Vault Secrets Officer) |

O valor nunca aparece no log da esteira, que mostra só o nome, a versão, a
data e o SHA-256 parcial. As chaves privadas não ficam no disco de quem
provisiona: o script apaga a pasta temporária no final.

## O que o script configura no GitHub (repositório de JCL)

**Secret**

| Nome | Conteúdo |
|---|---|
| `SPN_KV_DEV_SECRET` | `{"clientId","clientSecret","subscriptionId","tenantId"}` do SPN, com *Key Vault Secrets User* só no Key Vault |

**Variables do repositório**, com os mesmos nomes da esteira corporativa de deploy Linux:

| Nome | Valor |
|---|---|
| `GH_KV_DEV` | nome do Key Vault |
| `DEPLOY_SERVERS_TU` / `_TI` / `_PRD` | `10.60.1.10` |
| `G_DEPLOYMENT_TARGET_LINUX_<ENV>_USER` | `estmtu` / `estmti` / `estmprd` |
| `G_DEPLOYMENT_TARGET_LINUX_<ENV>_KEY` | `estm-<env>-ssh-key` (nome do segredo, não o valor) |
| `G_DEPLOYMENT_TARGET_LINUX_<ENV>_TOKEN` | `estm-<env>-token` |
| `G_DEPLOYMENT_TARGET_<ENV>_PATH` | `/srv/estm/<ENV>` |
| `G_DEPLOYMENT_TARGET_LINUX_KNOWN_HOSTS` | `10.60.1.10 ssh-ed25519 AAAA...` (o SSH roda com `StrictHostKeyChecking=yes`) |

**Environments**

| Environment | Aprovação |
|---|---|
| `TU` | nenhuma |
| `TI` | required reviewers (`-Reviewers`) |
| `PRD` | required reviewers (`-Reviewers`) |

Em repositório privado de conta Free, o GitHub não oferece required
reviewers. Por isso os repositórios da POC são públicos.

## Operação

| Tarefa | Como |
|---|---|
| Ligar antes de uma demo (auto-shutdown às 22h, horário de Brasília) | `az vm start -g rg-esteira-model-cob-poc -n vm-estm-runner` e `-n vm-estm-alvo` |
| Ver o que o destino recebeu | `az vm run-command invoke -g rg-esteira-model-cob-poc -n vm-estm-alvo --command-id RunShellScript --scripts "tail -n 20 /var/lib/estm/auditoria.log"` |
| Trocar o token de um ambiente | gravar uma nova versão de `estm-<env>-token` no Key Vault (os dois lados leem de lá) |
| Trocar o secret do SPN | rodar `provisionar.ps1` de novo |
| Apontar o runner para outro repositório | `provisionar.ps1 -Repo <owner/repo>` |
| Destruir tudo | `az group delete -n rg-esteira-model-cob-poc`, `az keyvault purge -n <kv>` (soft delete de 7 dias), `az ad sp delete --id <appId>` e apagar o runner offline no GitHub |

Custo: as duas VMs `Standard_D2s_v4` são o principal item. Com o
auto-shutdown e ligando só para as demos, o custo fica bem abaixo do valor
com as VMs ligadas 24h. Use a calculadora de preços da Azure para estimar.

<#
.SYNOPSIS
  Sobe (ou atualiza) o ambiente da POC na Azure e configura o GitHub.

.DESCRIPTION
  Idempotente - pode rodar de novo a qualquer momento (ex.: depois de
  apagar o resource group). Ver docs/ambiente-poc-azure.md.

  1. Resource group + SPN da esteira (padrao corporativo: JSON do SPN no
     secret SPN_KV_DEV_SECRET, papel so de leitura de segredos no Key Vault).
  2. Chaves SSH: uma por ambiente (TU/TI/PRD) + admin. Se o Key Vault ja
     tem a chave, ela e reaproveitada (a VM ja confia nela); senao e gerada.
  3. main.bicep: VNet, Key Vault, VM destino (sem IP publico) e VM runner.
  4. Segredos no Key Vault: chaves privadas e tokens ficticios por ambiente.
  5. Runner self-hosted registrado no repositorio de JCL (servico systemd).
  6. GitHub (repositorio de JCL): Environments TU/TI/PRD com aprovacao em
     TI e PRD, variables do padrao corporativo e o secret do SPN.

  As variables JCL_* de cada Environment pertencem ao repositorio de JCL:
  publicadas por scripts/sincronizar-variables.py de la.

  Requer: az (logado, Owner na subscription), gh (logado, admin do
  repositorio de JCL) e ssh-keygen.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Subscription,
    [string]$Location = 'brazilsouth',
    [string]$ResourceGroup = 'rg-esteira-model-cob-poc',
    [string]$Repo = 'DevSecOps-Tr99/esteira-model-cob-jcl',
    [string]$SpnName = 'sp-esteira-model-cob-poc-kv',
    [string]$RunnerName = 'vm-estm-runner',
    [string]$RunnerLabels = 'self-hosted,linux,x64,estm-runner',
    [string[]]$Reviewers = @(),
    [string]$VmSize = 'Standard_D2s_v4',
    [string]$Az = 'az',
    [string]$Gh = 'gh'
)

$ErrorActionPreference = 'Stop'
$Ambientes = @('TU', 'TI', 'PRD')

# Funcao simples (sem param/[Parameter]) de proposito: numa funcao avancada
# o PowerShell tentaria casar flags como -o com -OutVariable/-OutBuffer.
function Invoke-Native {
    $exe = $args[0]
    $resto = @($args | Select-Object -Skip 1)
    $out = & $exe @resto
    if ($LASTEXITCODE -ne 0) { throw "$exe $($resto[0..2] -join ' ') ... saiu com $LASTEXITCODE" }
    return $out
}
function az { Invoke-Native $Az @args }
function gh { Invoke-Native $Gh @args }
function Json { param([Parameter(ValueFromPipeline = $true)]$linhas) begin { $buf = @() } process { $buf += $linhas } end { ($buf -join "`n") | ConvertFrom-Json } }

function Step([string]$texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }

function Retry([scriptblock]$bloco, [string]$descricao, [int]$tentativas = 12, [int]$espera = 20) {
    for ($i = 1; $i -le $tentativas; $i++) {
        try { return & $bloco } catch {
            if ($i -eq $tentativas) { throw }
            Write-Host "    $descricao ainda nao disponivel ($i/$tentativas), aguardando ${espera}s..."
            Start-Sleep -Seconds $espera
        }
    }
}

# Windows PowerShell 5.1 corrompe texto enviado por pipe para executavel
# nativo e descarta argumento vazio - stdin vai por arquivo, via cmd.
function Invoke-WithStdin([string]$Exe, [string]$Conteudo, [string]$Argumentos) {
    $tmp = Join-Path $work ("stdin-" + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tmp, $Conteudo, (New-Object Text.UTF8Encoding $false))
    try {
        cmd /c "`"$Exe`" $Argumentos < `"$tmp`""
        if ($LASTEXITCODE -ne 0) { throw "$Exe $Argumentos saiu com $LASTEXITCODE" }
    } finally { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }
}

function New-SshKey([string]$path, [string]$comment) {
    $legacy = $PSVersionTable.PSVersion.Major -lt 7 -or
        ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 3)
    $vazio = if ($legacy) { '""' } else { '' }
    & ssh-keygen -q -t ed25519 -N $vazio -C $comment -f $path
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen falhou para $comment" }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("estm-poc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    # ------------------------------------------------------------------ 1
    Step "Subscription e resource group"
    az account set --subscription $Subscription
    $tenantId = az account show --query tenantId -o tsv
    az group create -n $ResourceGroup -l $Location --tags projeto=esteira-model-cob ambiente=poc -o none
    $operadorId = az ad signed-in-user show --query id -o tsv

    Step "Service principal da esteira ($SpnName)"
    $sp = az ad sp create-for-rbac --name $SpnName --years 1 -o json | Json
    $spObjectId = Retry { az ad sp show --id $sp.appId --query id -o tsv } 'service principal'
    $spnCreds = [ordered]@{
        clientId       = $sp.appId
        clientSecret   = $sp.password
        subscriptionId = $Subscription
        tenantId       = $tenantId
    } | ConvertTo-Json -Compress
    Write-Host "    appId $($sp.appId)"

    # ------------------------------------------------------------------ 2
    Step "Chaves SSH (reaproveita as que ja estao no Key Vault)"
    $kvExistente = az keyvault list -g $ResourceGroup --query "[0].name" -o tsv
    $chaves = [ordered]@{ admin = 'estm-admin-ssh-key' }
    foreach ($amb in $Ambientes) { $chaves[$amb] = "estm-$($amb.ToLower())-ssh-key" }
    $publicas = @{}
    foreach ($apelido in @($chaves.Keys)) {
        $privada = Join-Path $work $apelido
        $reaproveitada = $false
        if ($kvExistente) {
            $existe = & $Az keyvault secret list --vault-name $kvExistente --query "[?name=='$($chaves[$apelido])'].name" -o tsv
            if ($LASTEXITCODE -eq 0 -and $existe) {
                az keyvault secret download --vault-name $kvExistente -n $chaves[$apelido] -f $privada -o none
                # No Windows o download grava CRLF, que o ssh-keygen nao le
                # ("error in libcrypto"): normaliza para LF, sem BOM.
                $texto = ([IO.File]::ReadAllText($privada) -replace "`r`n", "`n").TrimEnd() + "`n"
                [IO.File]::WriteAllText($privada, $texto, (New-Object Text.UTF8Encoding $false))
                $derivada = (& ssh-keygen -y -f $privada) -join ''
                if ($LASTEXITCODE -ne 0 -or $derivada -notmatch '^ssh-ed25519 \S+') {
                    throw "nao foi possivel derivar a chave publica de $($chaves[$apelido]) - nada foi alterado"
                }
                # Mesmo formato da chave gerada na primeira execucao (tipo,
                # chave, comentario): o cloud-init das VMs nao pode mudar.
                $publicas[$apelido] = (($derivada.Trim() -split ' ')[0..1] -join ' ') + " estm-$apelido"
                $reaproveitada = $true
            }
        }
        if (-not $reaproveitada) {
            New-SshKey $privada "estm-$apelido"
            $publicas[$apelido] = (Get-Content "$privada.pub" -Raw).Trim()
        }
        Write-Host ("    {0,-6} {1}" -f $apelido, $(if ($reaproveitada) { 'reaproveitada do Key Vault' } else { 'gerada' }))
    }

    # ------------------------------------------------------------------ 3
    Step "Infra (main.bicep) - alguns minutos"
    # VM ja criada nao aceita mudanca de customData (cloud-init): nas
    # execucoes seguintes o Bicep atualiza o resto e deixa as VMs como estao.
    $vmsExistentes = @(& $Az vm list -g $ResourceGroup --query "[?name=='vm-estm-alvo' || name=='vm-estm-runner'].name" -o tsv)
    $criarVms = $vmsExistentes.Count -lt 2
    Write-Host "    VMs: $(if ($criarVms) { 'serao criadas' } else { 'ja existem - mantidas como estao' })"
    $paramsFile = Join-Path $work 'params.json'
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            location           = @{ value = $Location }
            criarVms           = @{ value = $criarVms }
            runnerVmSize       = @{ value = $VmSize }
            alvoVmSize         = @{ value = $VmSize }
            adminPublicKey     = @{ value = $publicas['admin'] }
            deployKeyTU        = @{ value = $publicas['TU'] }
            deployKeyTI        = @{ value = $publicas['TI'] }
            deployKeyPRD       = @{ value = $publicas['PRD'] }
            esteiraSpnObjectId = @{ value = $spObjectId }
            operadorObjectId   = @{ value = $operadorId }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $paramsFile -Encoding Ascii

    $outputs = az deployment group create -g $ResourceGroup -n esteira-model-cob-poc `
        -f (Join-Path $PSScriptRoot 'main.bicep') -p "@$paramsFile" `
        --query properties.outputs -o json | Json
    $kv = $outputs.keyVaultName.value
    $alvoIp = $outputs.alvoPrivateIp.value
    $alvoVm = $outputs.alvoVmName.value
    $runnerVm = $outputs.runnerVmName.value
    Write-Host "    Key Vault $kv | destino $alvoVm ($alvoIp) | runner $runnerVm"

    # ------------------------------------------------------------------ 4
    Step "Segredos no Key Vault"
    foreach ($apelido in @($chaves.Keys)) {
        $privada = Join-Path $work $apelido
        $nome = $chaves[$apelido]
        Retry { az keyvault secret set --vault-name $kv -n $nome --file $privada --encoding utf-8 -o none } 'permissao no Key Vault'
        Write-Host "    $nome"
    }
    foreach ($amb in $Ambientes) {
        $nome = "estm-$($amb.ToLower())-token"
        $existe = az keyvault secret list --vault-name $kv --query "[?name=='$nome'].name" -o tsv
        if (-not $existe) {
            # Token ficticio - so precisa ser imprevisivel e diferente por ambiente.
            $valor = "estm-$($amb.ToLower())-" + [guid]::NewGuid().ToString('N')
            az keyvault secret set --vault-name $kv -n $nome --value $valor -o none
            Write-Host "    $nome (gerado)"
        } else {
            Write-Host "    $nome (mantido)"
        }
    }

    # ------------------------------------------------------------------ 5
    Step "Host key do servidor de destino (known_hosts)"
    $hostKeyScript = Join-Path $work 'hostkey.sh'
    [IO.File]::WriteAllText($hostKeyScript,
        "cloud-init status --wait >/dev/null 2>&1; cat /etc/ssh/ssh_host_ed25519_key.pub`n",
        (New-Object Text.UTF8Encoding $false))
    $msg = az vm run-command invoke -g $ResourceGroup -n $alvoVm --command-id RunShellScript `
        --scripts "@$hostKeyScript" --query "value[0].message" -o tsv
    $hostKey = ($msg -split "`n" | Where-Object { $_ -match '^ssh-ed25519 ' } | Select-Object -First 1)
    if (-not $hostKey) { throw "host key nao encontrada na resposta do run-command: $msg" }
    $knownHosts = "$alvoIp " + (($hostKey.Trim() -split ' ')[0..1] -join ' ')
    Write-Host "    $knownHosts"

    # ------------------------------------------------------------------ 6
    Step "GitHub Environments (TU livre, TI e PRD com aprovacao)"
    # Padrao: todos os colaboradores que ja aceitaram o convite (o GitHub so
    # aceita como aprovador quem tem acesso, e no maximo 6 por Environment).
    # Convites pendentes ficam de fora - rode de novo depois que aceitarem.
    if ($Reviewers.Count -eq 0) {
        $Reviewers = @(gh api "repos/$Repo/collaborators" | Json | ForEach-Object { $_.login } | Select-Object -First 6)
        $pendentes = @(gh api "repos/$Repo/invitations" | Json | ForEach-Object { $_.invitee.login })
        if ($pendentes.Count) { Write-Host "    convites pendentes (ainda nao podem aprovar): $($pendentes -join ', ')" }
    }
    $reviewerIds = @(foreach ($login in $Reviewers) { @{ type = 'User'; id = [int](gh api "users/$login" --jq .id) } })
    foreach ($amb in $Ambientes) {
        $body = if ($amb -eq 'TU') { @{} } else {
            @{ reviewers = $reviewerIds; prevent_self_review = $false; wait_timer = 0 }
        }
        $bodyFile = Join-Path $work "env-$amb.json"
        $body | ConvertTo-Json -Depth 5 | Set-Content -Path $bodyFile -Encoding Ascii
        gh api -X PUT "repos/$Repo/environments/$amb" --input $bodyFile | Out-Null
        Write-Host "    $amb $(if ($amb -eq 'TU') { '(sem aprovacao)' } else { '(aprovadores: ' + ($Reviewers -join ', ') + ')' })"
    }

    Step "GitHub variables (repositorio - padrao corporativo)"
    $repoVars = [ordered]@{
        GH_KV_DEV                             = $kv
        G_DEPLOYMENT_TARGET_LINUX_KNOWN_HOSTS = $knownHosts
    }
    foreach ($amb in $Ambientes) {
        $repoVars["DEPLOY_SERVERS_$amb"] = $alvoIp
        $repoVars["G_DEPLOYMENT_TARGET_LINUX_${amb}_USER"] = "estm$($amb.ToLower())"
        $repoVars["G_DEPLOYMENT_TARGET_LINUX_${amb}_KEY"] = "estm-$($amb.ToLower())-ssh-key"
        $repoVars["G_DEPLOYMENT_TARGET_LINUX_${amb}_TOKEN"] = "estm-$($amb.ToLower())-token"
        $repoVars["G_DEPLOYMENT_TARGET_${amb}_PATH"] = "/srv/estm/$amb"
    }
    foreach ($nome in @($repoVars.Keys)) {
        gh variable set $nome --repo $Repo --body $repoVars[$nome] | Out-Null
        Write-Host "    $nome"
    }

    Step "GitHub secret SPN_KV_DEV_SECRET"
    Invoke-WithStdin $Gh $spnCreds "secret set SPN_KV_DEV_SECRET --repo $Repo"

    # Runner por ultimo: jobs ja enfileirados no repositorio so podem comecar
    # depois que os Environments tem aprovacao e as variables/secret existem.
    Step "Runner self-hosted ($RunnerName) - instala e registra, alguns minutos"
    $runners = gh api "repos/$Repo/actions/runners" | Json
    foreach ($r in @($runners.runners | Where-Object { $_.status -eq 'offline' })) {
        gh api -X DELETE "repos/$Repo/actions/runners/$($r.id)" | Out-Null
        Write-Host "    runner offline $($r.name) removido"
    }
    $regToken = gh api -X POST "repos/$Repo/actions/runners/registration-token" --jq .token
    $msg = az vm run-command invoke -g $ResourceGroup -n $runnerVm --command-id RunShellScript `
        --scripts "@$(Join-Path $PSScriptRoot 'runner/registrar-runner.sh')" `
        --parameters "https://github.com/$Repo" $regToken $RunnerName $RunnerLabels `
        --query "value[0].message" -o tsv
    Write-Host (($msg -split "`n" | Select-Object -Last 8) -join "`n")

    Step "Pronto"
    Write-Host "Key Vault ........ $kv"
    Write-Host "Destino .......... $alvoVm ($alvoIp, sem IP publico)"
    Write-Host "Runner ........... $runnerVm ($RunnerLabels) -> $Repo"
    Write-Host "Falta ............ variables JCL_*: python scripts/sincronizar-variables.py (no repositorio de JCL)"
    Write-Host "Disparar ......... gh workflow run esteira.yml --repo $Repo -f ambiente=TU"
}
finally {
    # Chaves privadas so ficam no Key Vault.
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

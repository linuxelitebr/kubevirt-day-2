#Requires -RunAsAdministrator
<#
  setup-demo-farm.ps1 - monta uma farm IIS que replica o padrao do cliente: N sites servindo
  conteudo de uma RAIZ que pode estar no NAS (UNC/DFS) ou em disco LOCAL, pra medir o efeito da
  arquitetura content-on-UNC. Espelha o app + fragmentos nos DOIS backings, entao o toggle-root.ps1
  so' vira o physicalPath ao vivo, sem recopiar nada.

  Cada site roda o arquetipo dynamic-reads-root (le TODOS os fragmentos da raiz por request) - o
  padrao do cliente (35 sites servindo de um concentrador DFS unico). Compressao dinamica off e
  porta propria por site espelham o cliente.

  IDENTIDADE DO APP POOL: pra ler o NAS, o app pool precisa de uma conta com acesso ao share (como
  no cliente, uma conta de servico de dominio). Passe -PoolCredential (Get-Credential) pra rodar os
  pools com essa conta; sem isso, os pools usam ApplicationPoolIdentity (a conta de maquina precisa
  ter acesso ao share).

  Exemplo:
    $c = Get-Credential DOMINIO\svc_iis
    .\setup-demo-farm.ps1 -ContentUnc \\server\share\demo-farm -Sites 8 -Fragments 30 -FragKB 8 -Backing nas -PoolCredential $c
#>
param(
  [Parameter(Mandatory=$true)][string]$ContentUnc,
  [string]$ContentLocal = 'C:\demo-farm',
  [int]$Sites = 8,
  [int]$Fragments = 30,
  [int]$FragKB = 8,
  [int]$BasePort = 9000,
  [ValidateSet('nas','local')][string]$Backing = 'nas',
  [string]$AppSource = (Join-Path $PSScriptRoot '..\app'),
  [string]$Prefix = 'demo',
  [System.Management.Automation.PSCredential]$PoolCredential
)
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

$AppSource = (Resolve-Path $AppSource).Path
foreach ($root in @($ContentUnc, $ContentLocal)) {
  if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
}

# buffer reutilizado pros fragmentos (o conteudo nao importa pra latencia de leitura)
$buf = New-Object byte[] ($FragKB * 1024)
(New-Object Random).NextBytes($buf)

function Provision($root, $i) {
  $siteDir = Join-Path $root ("{0}{1}" -f $Prefix,$i)
  $frag = Join-Path $siteDir 'fragments'
  New-Item -ItemType Directory -Path $frag -Force | Out-Null
  Copy-Item (Join-Path $AppSource 'Default.aspx') $siteDir -Force
  Copy-Item (Join-Path $AppSource 'web.config')  $siteDir -Force
  for ($f = 0; $f -lt $Fragments; $f++) {
    [System.IO.File]::WriteAllBytes((Join-Path $frag ("f{0:D4}.frag" -f $f)), $buf)
  }
  return $siteDir
}

Write-Host ("Provisionando {0} sites em NAS ({1}) e LOCAL ({2}), {3} fragmentos de {4}KB cada..." -f $Sites,$ContentUnc,$ContentLocal,$Fragments,$FragKB) -ForegroundColor Yellow
for ($i = 1; $i -le $Sites; $i++) {
  $uncDir   = Provision $ContentUnc   $i
  $localDir = Provision $ContentLocal $i
  $physical = if ($Backing -eq 'nas') { $uncDir } else { $localDir }

  $name = "{0}{1}" -f $Prefix,$i
  $port = $BasePort + $i

  if (Test-Path ("IIS:\AppPools\$name")) { Remove-WebAppPool -Name $name }
  New-WebAppPool -Name $name | Out-Null
  Set-ItemProperty ("IIS:\AppPools\$name") -Name managedRuntimeVersion -Value 'v4.0'
  Set-ItemProperty ("IIS:\AppPools\$name") -Name managedPipelineMode -Value 'Integrated'
  if ($PoolCredential) {
    Set-ItemProperty ("IIS:\AppPools\$name") -Name processModel -Value @{
      identitytype = 'SpecificUser'
      userName     = $PoolCredential.UserName
      password     = $PoolCredential.GetNetworkCredential().Password
    }
  }

  if (Test-Path ("IIS:\Sites\$name")) { Remove-Website -Name $name }
  New-Website -Name $name -Port $port -PhysicalPath $physical -ApplicationPool $name | Out-Null

  Write-Host ("  {0}  porta {1}  -> {2}" -f $name,$port,$physical)
}

Write-Host ("Farm no ar: {0} sites, backing={1}, portas {2}..{3}." -f $Sites,$Backing,($BasePort+1),($BasePort+$Sites)) -ForegroundColor Cyan
Write-Host ("Teste 1 site:  curl http://localhost:{0}/Default.aspx   (olhe io_ms vs compute_ms)" -f ($BasePort+1)) -ForegroundColor Cyan
Write-Host ("Vira NAS<->local ao vivo:  .\toggle-root.ps1 -Backing local -ContentUnc '{0}' -ContentLocal '{1}'" -f $ContentUnc,$ContentLocal) -ForegroundColor Cyan

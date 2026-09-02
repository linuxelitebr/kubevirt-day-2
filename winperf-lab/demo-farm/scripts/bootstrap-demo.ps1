#Requires -RunAsAdministrator
<#
  bootstrap-demo.ps1 - TURNKEY: sobe a farm de demo inteira numa VM Windows, num comando so'.
  Instala as features do IIS (se precisar), provisiona a farm (NAS + local espelhados + dashboard),
  e imprime os proximos passos. Roda de dentro da pasta demo-farm\scripts.

    # 1) copie a pasta demo-farm pra VM.  2) PowerShell como Administrador:
    $c = Get-Credential DOMINIO\svc_iis           # conta que le o NAS (opcional; senao ApplicationPoolIdentity)
    cd C:\demo-farm\scripts
    .\bootstrap-demo.ps1 -ContentUnc \\server\share\demo-farm -Sites 8 -PoolCredential $c
    # abra:  http://localhost:9000/dashboard.html?base=9000&sites=8
#>
param(
  [Parameter(Mandatory=$true)][string]$ContentUnc,
  [string]$ContentLocal = 'C:\demo-farm',
  [int]$Sites = 8,
  [int]$Fragments = 30,
  [int]$FragKB = 8,
  [int]$BasePort = 9000,
  [ValidateSet('nas','local')][string]$Backing = 'nas',
  [System.Management.Automation.PSCredential]$PoolCredential,
  [switch]$SkipIisInstall
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Get-ChildItem (Split-Path $here) -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

if (-not $SkipIisInstall) {
  Write-Host "Instalando features do IIS (IIS + ASP.NET 4.x + AppInit + compressao dinamica/estatica)..." -ForegroundColor Yellow
  if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
    # Windows Server
    Install-WindowsFeature Web-Server,Web-Asp-Net45,Web-Net-Ext45,Web-AppInit,Web-Dyn-Compression,Web-Stat-Compression,Web-Mgmt-Console,Web-Scripting-Tools -ErrorAction SilentlyContinue | Out-Null
  } else {
    # Windows client
    $feats = 'IIS-WebServerRole','IIS-WebServer','IIS-ASPNET45','IIS-NetFxExtensibility45','IIS-ApplicationInit','IIS-HttpCompressionDynamic','IIS-HttpCompressionStatic','IIS-ManagementScriptingTools'
    foreach ($f in $feats) { try { Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop | Out-Null } catch { Write-Host ("  ({0}: {1})" -f $f,$_.Exception.Message) -ForegroundColor DarkGray } }
  }
}

$params = @{ ContentUnc=$ContentUnc; ContentLocal=$ContentLocal; Sites=$Sites; Fragments=$Fragments; FragKB=$FragKB; BasePort=$BasePort; Backing=$Backing }
if ($PoolCredential) { $params.PoolCredential = $PoolCredential }
& (Join-Path $here 'setup-demo-farm.ps1') @params

Write-Host ""
Write-Host "=== Pronto ===" -ForegroundColor Green
Write-Host ("DASHBOARD:  http://localhost:{0}/dashboard.html?base={0}&sites={1}" -f $BasePort,$Sites) -ForegroundColor Green
Write-Host ("Medir no terminal:  .\consumer-poll.ps1 -Sites {0} -BasePort {1} -Out C:\winperf\demo-poll.csv" -f $Sites,$BasePort)
Write-Host ""
Write-Host "Roteiro do 2x2 (no dashboard, escolha o cenario e clique Capturar apos cada troca):"
Write-Host ("  A) .\toggle-root.ps1 -Backing nas   -ContentUnc '{0}' -ContentLocal '{1}';  .\toggle-compression.ps1 -State off  -> NAS sem compressao (o cliente)" -f $ContentUnc,$ContentLocal)
Write-Host ("  B) .\toggle-compression.ps1 -State on                                        -> NAS com compressao")
Write-Host ("  C) .\toggle-root.ps1 -Backing local -ContentUnc '{0}' -ContentLocal '{1}';  .\toggle-compression.ps1 -State off  -> Local sem compressao" -f $ContentUnc,$ContentLocal)
Write-Host ("  D) .\toggle-compression.ps1 -State on                                        -> Local com compressao (o ideal)")

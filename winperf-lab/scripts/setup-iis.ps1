<#
  setup-iis.ps1  - instala IIS + ASP.NET 4.x + App Init, publica a app, e liga/desliga o warm-up.
  Rode como Administrador dentro da VM Windows.

  Exemplos:
    # 1a vez (instala tudo e publica), warm-up DESLIGADO (baseline cold-start):
    .\setup-iis.ps1 -AppSource .\app -Warmup off
    # liga o warm-up (App Init / AlwaysRunning / idle timeout 0):
    .\setup-iis.ps1 -Warmup on
    # volta pro baseline:
    .\setup-iis.ps1 -Warmup off
#>
param(
  [ValidateSet('on','off')][string]$Warmup = 'off',
  [string]$AppSource = '',
  [string]$SitePath  = 'C:\inetpub\winperf',
  [string]$Pool      = 'winperf',
  [int]$Port         = 8080
)
$ErrorActionPreference = 'Stop'

Write-Host "== Instalando features do IIS ==" -ForegroundColor Cyan
Install-WindowsFeature Web-Server, Web-Asp-Net45, Web-Net-Ext45, Web-AppInit, Web-Mgmt-Console -IncludeManagementTools | Out-Null

Import-Module WebAdministration

if ($AppSource) {
  Write-Host "== Publicando a app de $AppSource para $SitePath ==" -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path $SitePath | Out-Null
  Copy-Item -Path (Join-Path $AppSource '*') -Destination $SitePath -Recurse -Force
}

if (-not (Test-Path "IIS:\AppPools\$Pool")) { New-WebAppPool -Name $Pool | Out-Null }
Set-ItemProperty "IIS:\AppPools\$Pool" -Name managedRuntimeVersion -Value 'v4.0'
Set-ItemProperty "IIS:\AppPools\$Pool" -Name managedPipelineMode  -Value 'Integrated'

if (-not (Test-Path "IIS:\Sites\$Pool")) {
  New-Website -Name $Pool -Port $Port -PhysicalPath $SitePath -ApplicationPool $Pool -Force | Out-Null
} else {
  Set-ItemProperty "IIS:\Sites\$Pool" -Name physicalPath -Value $SitePath
}

if ($Warmup -eq 'on') {
  Write-Host "== Warm-up ON (AlwaysRunning + preload + idleTimeout 0) ==" -ForegroundColor Green
  Set-ItemProperty "IIS:\AppPools\$Pool" -Name startMode -Value 'AlwaysRunning'
  Set-ItemProperty "IIS:\AppPools\$Pool" -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
    -filter "system.applicationHost/sites/site[@name='$Pool']/application[@path='/']" `
    -name preloadEnabled -value $true
} else {
  Write-Host "== Warm-up OFF (OnDemand + idleTimeout 20min + sem preload) = baseline cold-start ==" -ForegroundColor Yellow
  Set-ItemProperty "IIS:\AppPools\$Pool" -Name startMode -Value 'OnDemand'
  Set-ItemProperty "IIS:\AppPools\$Pool" -Name processModel.idleTimeout -Value ([TimeSpan]'00:20:00')
  Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
    -filter "system.applicationHost/sites/site[@name='$Pool']/application[@path='/']" `
    -name preloadEnabled -value $false
}

Restart-WebAppPool -Name $Pool
Write-Host ("== Pronto. URL: http://localhost:{0}/Default.aspx  (pool={1}, warmup={2}) ==" -f $Port,$Pool,$Warmup) -ForegroundColor Cyan

#Requires -RunAsAdministrator
<#
  toggle-compression.ps1 - liga/desliga a compressao DINAMICA nas sites da farm (o cliente esta com
  ela OFF). Combine com toggle-root.ps1 pra montar o 2x2: NAS/local x com/sem compressao.

  Requer a feature de compressao dinamica instalada (Web-Dyn-Compression no Server / IIS-HttpCompressionDynamic
  no client). O bootstrap-demo.ps1 instala. Sem a feature, doDynamicCompression=true nao tem efeito.

    .\toggle-compression.ps1 -State on
    .\toggle-compression.ps1 -State off
#>
param(
  [Parameter(Mandatory=$true)][ValidateSet('on','off')][string]$State,
  [string]$Prefix = 'demo'
)
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
$val = ($State -eq 'on')
$sites = @(Get-Website | Where-Object { $_.Name -match "^$Prefix\d+$" })
if ($sites.Count -eq 0) { throw "Nenhuma site '$Prefix<n>'. Rode setup-demo-farm.ps1 primeiro." }
foreach ($s in $sites) {
  Set-WebConfigurationProperty -PSPath ("IIS:\Sites\" + $s.Name) -Filter 'system.webServer/urlCompression' -Name 'doDynamicCompression' -Value $val
  Write-Host ("{0}  doDynamicCompression={1}" -f $s.Name,$val)
}
Write-Host ("Compressao dinamica agora: {0}. (Primeira request apos mudar pode reciclar.)" -f $State) -ForegroundColor Cyan

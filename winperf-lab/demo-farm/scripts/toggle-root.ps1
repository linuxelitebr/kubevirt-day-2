#Requires -RunAsAdministrator
<#
  toggle-root.ps1 - vira o physicalPath de TODAS as sites da farm entre NAS (UNC/DFS) e disco local,
  ao vivo. O conteudo ja esta espelhado nos dois (o setup-demo-farm faz isso), entao a plateia ve
  o tempo de resposta mudar com SO' a localizacao da raiz mudando, tudo o mais parado. E' o momento
  visceral do demo.

    .\toggle-root.ps1 -Backing local -ContentUnc \\server\share\demo-farm -ContentLocal C:\demo-farm
    .\toggle-root.ps1 -Backing nas   -ContentUnc \\server\share\demo-farm -ContentLocal C:\demo-farm
#>
param(
  [Parameter(Mandatory=$true)][ValidateSet('nas','local')][string]$Backing,
  [Parameter(Mandatory=$true)][string]$ContentUnc,
  [string]$ContentLocal = 'C:\demo-farm',
  [string]$Prefix = 'demo'
)
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

$root = if ($Backing -eq 'nas') { $ContentUnc } else { $ContentLocal }
$sites = @(Get-Website | Where-Object { $_.Name -like "$Prefix*" })
if ($sites.Count -eq 0) { throw "Nenhuma site '$Prefix*' encontrada. Rode setup-demo-farm.ps1 primeiro." }

foreach ($s in $sites) {
  $target = Join-Path $root $s.Name
  Set-ItemProperty ("IIS:\Sites\" + $s.Name) -Name physicalPath -Value $target
  Write-Host ("{0} -> {1}" -f $s.Name,$target)
}
Write-Host ("Farm agora servindo de: {0} ({1})" -f $Backing,$root) -ForegroundColor Cyan
Write-Host "Dica: a primeira request apos o toggle pode reciclar/recompilar (cold-start). Descarte-a na leitura." -ForegroundColor DarkGray

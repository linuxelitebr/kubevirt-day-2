<#
  measure-ttfb.ps1 - mede o tempo da PRIMEIRA resposta (cold-start) e de uma resposta quente logo depois.
  Recicla o app pool a cada rodada pra forcar o estado frio (com warm-up ON, o preload aquece antes = fica rapido: esse e' o ponto).

  Exemplo:
    .\measure-ttfb.ps1 -Stage baseline-warmupOFF -Runs 6 -Out results.csv
    .\measure-ttfb.ps1 -Stage warmupON        -Runs 6 -Out results.csv   # (append)
#>
param(
  [string]$Url   = 'http://localhost:8080/Default.aspx',
  [string]$Pool  = 'winperf',
  [int]$Runs     = 6,
  [string]$Out   = 'results.csv',
  [string]$Stage = 'baseline'
)
$ErrorActionPreference = 'SilentlyContinue'
Import-Module WebAdministration

if (-not (Test-Path $Out)) { "stage,run,type,ms,status" | Out-File $Out -Encoding utf8 }

function Hit([string]$u) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $code = 0
  try { $resp = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 180; $code = [int]$resp.StatusCode } catch { $code = -1 }
  $sw.Stop()
  return @($sw.ElapsedMilliseconds, $code)
}

for ($r = 1; $r -le $Runs; $r++) {
  # Forca estado frio: recicla o pool. Com warm-up ON o preload reaquece sozinho (e' o que queremos provar).
  Restart-WebAppPool -Name $Pool
  Start-Sleep -Milliseconds 800

  $cold = Hit $Url
  "$Stage,$r,cold,$($cold[0]),$($cold[1])" | Add-Content $Out
  Write-Host ("run {0}  cold={1} ms (http {2})" -f $r,$cold[0],$cold[1])

  $warm = Hit $Url
  "$Stage,$r,warm,$($warm[0]),$($warm[1])" | Add-Content $Out

  Start-Sleep -Milliseconds 500
}
Write-Host "Feito. Descartar run 1 na analise (primeira compilacao). Saida: $Out" -ForegroundColor Cyan

<#
  measure-ttfb.ps1 - mede o tempo da PRIMEIRA resposta (cold-start) e de uma resposta quente logo depois.
  Para e sobe o app pool a cada rodada pra forcar um worker FRIO de verdade. (O Restart-WebAppPool faz
  overlapped recycling e as vezes deixa o worker quente servir, mascarando o cold-start - foi o que
  baguncou a primeira coleta.) Com warm-up ON, o Start dispara o preload e a medicao pega o worker ja
  aquecido: esse e' o ponto do Exp 4.

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
  # Forca cold-start DETERMINISTICO: PARA o pool (mata o worker quente; sem worker antigo nao ha overlapped
  # recycling pra 'roubar' a medicao), espera parar, e sobe de novo. Com warm-up OFF o proximo Hit spawna
  # um worker FRIO e paga o cold-start inteiro; com warm-up ON o Start ja dispara o App Init.
  $deadline = (Get-Date).AddSeconds(30)
  Stop-WebAppPool -Name $Pool
  while ((Get-WebAppPoolState -Name $Pool).Value -ne 'Stopped' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
  Start-WebAppPool -Name $Pool
  while ((Get-WebAppPoolState -Name $Pool).Value -ne 'Started' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
  Start-Sleep -Milliseconds 400

  $cold = Hit $Url
  "$Stage,$r,cold,$($cold[0]),$($cold[1])" | Add-Content $Out
  Write-Host ("run {0}  cold={1} ms (http {2})" -f $r,$cold[0],$cold[1])

  $warm = Hit $Url
  "$Stage,$r,warm,$($warm[0]),$($warm[1])" | Add-Content $Out

  Start-Sleep -Milliseconds 500
}
Write-Host "Feito. Descartar run 1 na analise (primeira compilacao). Saida: $Out" -ForegroundColor Cyan

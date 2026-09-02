<#
  consumer-poll.ps1 - o "consumidor": bate em TODAS as sites da farm continuamente e mostra o
  tempo de resposta ao vivo, separando io_ms (sensivel a NAS-vs-local) de compute_ms (constante e
  local). Enquanto isso roda, use toggle-root.ps1 pra virar NAS<->local e VEJA o io_ms mudar na tela.
  E' a demonstracao que mata o "nao toca disco" em tempo real.

    .\consumer-poll.ps1 -Sites 8 -BasePort 9000 -IntervalSec 2 -Out C:\winperf\demo-poll.csv
#>
param(
  [int]$Sites = 8,
  [int]$BasePort = 9000,
  [double]$IntervalSec = 2,
  [string]$Out = 'demo-poll.csv',
  [int]$DurationSec = 0,
  [string]$HostName = 'localhost'
)
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $Out)) { "ts,site,port,total_ms,io_ms,compute_ms,fragments,http" | Out-File $Out -Encoding utf8 }

$sum = @{}; $cnt = @{}
for ($i=1; $i -le $Sites; $i++) { $sum[$i] = 0.0; $cnt[$i] = 0 }
$deadline = if ($DurationSec -gt 0) { (Get-Date).AddSeconds($DurationSec) } else { [datetime]::MaxValue }

while ((Get-Date) -lt $deadline) {
  $rows = @()
  for ($i=1; $i -le $Sites; $i++) {
    $port = $BasePort + $i
    $url  = "http://{0}:{1}/Default.aspx" -f $HostName,$port
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $io = ''; $cpu = ''; $frag = ''; $code = 0
    try {
      $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 60
      $code = [int]$r.StatusCode
      $j = $r.Content | ConvertFrom-Json
      $io = $j.io_ms; $cpu = $j.compute_ms; $frag = $j.fragments
    } catch { $code = -1 }
    $sw.Stop()
    $tot = [Math]::Round($sw.Elapsed.TotalMilliseconds,1)
    $sum[$i] += $tot; $cnt[$i]++
    $avg = [Math]::Round($sum[$i]/$cnt[$i],1)
    "$([DateTime]::UtcNow.ToString('o')),demo$i,$port,$tot,$io,$cpu,$frag,$code" | Add-Content $Out
    $rows += [pscustomobject]@{ Site="demo$i"; Port=$port; total_ms=$tot; io_ms=$io; compute_ms=$cpu; avg_ms=$avg; http=$code }
  }
  Clear-Host
  Write-Host ("consumer-poll  " + (Get-Date -Format 'HH:mm:ss') + "   (Ctrl+C encerra)  saida: $Out") -ForegroundColor Cyan
  $rows | Format-Table -AutoSize | Out-Host
  Write-Host "io_ms alto = servindo do NAS.  Rode toggle-root.ps1 -Backing local e veja despencar." -ForegroundColor DarkGray
  Start-Sleep -Seconds $IntervalSec
}

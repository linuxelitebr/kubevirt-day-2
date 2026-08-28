<#
  spin-cpu.ps1 - "vizinho barulhento": satura TODOS os vCPUs por N segundos, pra criar contencao
  de CPU no node compartilhado. Rode na winperf-b enquanto mede a winperf-a (Exp 2).

  Dimensione a winperf-b com vCPUs suficientes (~= cores do node) pra o burn saturar o fisico.

  Exemplo:
    .\spin-cpu.ps1 -Seconds 180
#>
param(
  [int]$Seconds = 180,
  [int]$Threads = 0
)
if ($Threads -le 0) { $Threads = [Environment]::ProcessorCount }
$end = (Get-Date).AddSeconds($Seconds)
Write-Host ("Queimando {0} threads por {1}s (ate {2:HH:mm:ss}). Ctrl+C aborta." -f $Threads,$Seconds,$end) -ForegroundColor Yellow

$sb = {
  param($until)
  $x = 0.0
  while ((Get-Date) -lt $until) {
    for ($i = 0; $i -lt 2000000; $i++) { $x = [Math]::Sqrt($i) + $x }
  }
  $x
}

$jobs = 1..$Threads | ForEach-Object { Start-Job -ScriptBlock $sb -ArgumentList $end }
Wait-Job $jobs | Out-Null
$jobs | Remove-Job -Force
Write-Host "Burn terminado." -ForegroundColor Cyan

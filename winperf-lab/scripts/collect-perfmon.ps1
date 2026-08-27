<#
  collect-perfmon.ps1 - coleta os contadores que decidem a CAMADA do gargalo.
  Rode uma janela OCIOSA (>=600s, guest quiesced) e outra SOB CARGA.
    .\collect-perfmon.ps1 -Seconds 600 -Out perf-idle.csv
    .\collect-perfmon.ps1 -Seconds 120 -Out perf-load.csv   # durante o measure-ttfb
#>
param([int]$Seconds = 600, [string]$Out = 'perfmon.csv')

$counters = @(
  '\Processor(_Total)\% Processor Time',
  '\Processor(_Total)\% User Time',
  '\Processor(_Total)\% Privileged Time',
  '\Processor(_Total)\% Interrupt Time',
  '\Processor(_Total)\% DPC Time',
  '\System\Processor Queue Length',
  '\System\Context Switches/sec',
  '\LogicalDisk(_Total)\Avg. Disk sec/Read',
  '\LogicalDisk(_Total)\Avg. Disk sec/Write',
  '\LogicalDisk(_Total)\Current Disk Queue Length',
  '\Memory\Available MBytes',
  '\Memory\Pages/sec'
)
typeperf $counters -si 1 -sc $Seconds -f CSV -o $Out
Write-Host "Perfmon salvo em $Out" -ForegroundColor Cyan
# Leitura rapida:
#  % User alto + CPU alta      => CPU-bound da app (tuning de VM ajuda pouco)
#  % Privileged/Interrupt/DPC  => overhead de interrupt/timer (enlightenments ajudam; conferir se estao vivos)
#  Avg. Disk sec/Read > ~0.015 => disco (testar bus virtio)
#  Available MBytes baixo + Pages/sec alto => memoria/paging

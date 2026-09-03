<#
  capture-memory.ps1 - fingerprint datado de MEMORIA/NUMA do w3wp (o app .NET real) numa VM.
  Diz se memoria/NUMA e' um 2o fator no caso: bitness do pool (32-bit e' fatal com 96GB), topologia
  de CPU/NUMA que o guest ve, e os counters de GC/heap/fragmentacao/working-set sob carga.

  Rode nas VMs do cliente COM O APP SOB CARGA (senao os counters do w3wp nao dizem nada).
    .\capture-memory.ps1 -Out C:\winperf\mem-fingerprint.txt -Seconds 60
#>
param(
  [string]$Out = 'mem-fingerprint.txt',
  [int]$Seconds = 60
)
$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]
function Log($s){ $t=[string]$s; $lines.Add($t)|Out-Null; Write-Host $t }

Log ("===== capture-memory  " + (Get-Date -Format o) + "  host=" + $env:COMPUTERNAME + " =====")

# 1) Topologia de CPU/NUMA que o guest enxerga
Log "`n--- CPU / sockets / NUMA (visao do guest) ---"
$cs = Get-CimInstance Win32_ComputerSystem
$procs = @(Get-CimInstance Win32_Processor)
Log ("Sockets (NumberOfProcessors):            " + $cs.NumberOfProcessors)
Log ("Logical CPUs (NumberOfLogicalProcessors):" + $cs.NumberOfLogicalProcessors)
Log ("RAM total:                                " + [math]::Round($cs.TotalPhysicalMemory/1GB,1) + " GB")
Log ("Sockets fisicos distintos:                " + (@($procs | Select-Object -Expand SocketDesignation -Unique).Count))
Log "NOTA NUMA: se sockets > 1, o guest tem vNUMA. Confirme no NODE se a VM CRUZA nos NUMA fisicos:"
Log "  oc debug node/<node> -- chroot /host lscpu | grep -i numa   (e compare com o tamanho da VM)"

# 2) Bitness dos app pools (32-bit e' fatal com 96GB)
Log "`n--- App pools: bitness (enable32BitAppOnWin64 = True e' RED FLAG) ---"
try {
  Import-Module WebAdministration -ErrorAction Stop
  Get-ChildItem IIS:\AppPools | ForEach-Object {
    $b = (Get-ItemProperty ("IIS:\AppPools\" + $_.Name) -Name enable32BitAppOnWin64).Value
    Log ("  " + $_.Name.PadRight(24) + " enable32Bit=" + $b + "  (.NET " + $_.managedRuntimeVersion + ", " + $_.managedPipelineMode + ")")
  }
} catch { Log ("  (WebAdministration indisponivel: " + $_.Exception.Message + ")") }

# 3) Processos w3wp
Log "`n--- Processos w3wp ---"
$w = @(Get-Process w3wp -ErrorAction SilentlyContinue)
if ($w.Count -eq 0) { Log "  Nenhum w3wp ativo. Gere carga no app antes (os counters de GC precisam do worker vivo)." }
foreach ($p in $w) { Log ("  PID " + $p.Id + "  WorkingSet=" + [math]::Round($p.WorkingSet64/1GB,2) + " GB  Private=" + [math]::Round($p.PrivateMemorySize64/1GB,2) + " GB") }

# 4) Counters de GC/heap/fragmentacao sob carga
Log ("`n--- .NET GC / heap / fragmentacao (avg/max em " + $Seconds + "s) ---")
$ctrs = @(
 '\.NET CLR Memory(w3wp*)\% Time in GC',
 '\.NET CLR Memory(w3wp*)\# Bytes in all Heaps',
 '\.NET CLR Memory(w3wp*)\Large Object Heap size',
 '\.NET CLR Memory(w3wp*)\Gen 2 heap size',
 '\.NET CLR Memory(w3wp*)\# Gen 2 Collections',
 '\Process(w3wp*)\Private Bytes',
 '\Process(w3wp*)\Virtual Bytes',
 '\Process(w3wp*)\Working Set'
)
try {
  $n = [math]::Max(2, [int]($Seconds/5))
  $samples = Get-Counter -Counter $ctrs -SampleInterval 5 -MaxSamples $n -ErrorAction Stop
  $byPath = @{}
  foreach ($s in $samples) { foreach ($c in $s.CounterSamples) {
    $k = ($c.Path -replace '^\\\\[^\\]+','')
    if (-not $byPath.ContainsKey($k)) { $byPath[$k] = New-Object System.Collections.Generic.List[double] }
    $byPath[$k].Add([double]$c.CookedValue)
  } }
  foreach ($k in ($byPath.Keys | Sort-Object)) {
    $v = $byPath[$k]
    $avg = ($v | Measure-Object -Average).Average
    $max = ($v | Measure-Object -Maximum).Maximum
    if ($k -match 'Bytes|Heap size|Working Set') { $u='GB'; $avg=[math]::Round($avg/1GB,2); $max=[math]::Round($max/1GB,2) }
    else { $u=''; $avg=[math]::Round($avg,2); $max=[math]::Round($max,2) }
    Log ("  " + $k.PadRight(50) + " avg=" + $avg + "  max=" + $max + " " + $u)
  }
} catch { Log ("  (Get-Counter falhou: " + $_.Exception.Message + ")") }

Log "`n--- Como ler ---"
Log "  enable32Bit=True ............. FATAL (nao usa >4GB de 96); manda corrigir o pool."
Log "  % Time in GC > ~10-20% ....... GC dominando; pausas = jitter na resposta."
Log "  Virtual Bytes >> Private ..... fragmentacao de espaco de enderecamento."
Log "  Large Object Heap grande ..... fragmentacao de LOH (arrays/strings grandes)."
Log "  Working Set ~50-60 GB ........ working set gigante (bate com o 96GB pedido) = custo de cold-start."

$lines -join "`r`n" | Out-File -FilePath $Out -Encoding utf8 -Force
Write-Host ("Salvo em " + $Out) -ForegroundColor Cyan
Write-Host "Boundary: NUMA/vNUMA = teu lado (escolha migracao-safe). Bitness/GC/working-set do app = dominio do dono. Isso aqui e' evidencia, nao defesa." -ForegroundColor DarkGray

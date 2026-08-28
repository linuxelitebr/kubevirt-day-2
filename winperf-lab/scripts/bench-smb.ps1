<#
  bench-smb.ps1 - Exp 5, Camada 1 (MECANISMO): mede a latencia de acesso SMB da VM ate o NAS,
  ISOLANDO o caminho de rede. E' o teste direto da tese "o stack de rede do Kubernetes tem mais
  saltos internos; pra TCP a granel isso nao muda (bandwidth-bound), mas pra SMB/CIFS
  (request/response, chatty, assinado) soma (latency-bound)".

  Roda a MESMA corpus de arquivos pequenos a partir da MESMA VM em cada plataforma (VMware e
  OpenShift). Como e' um A/B relativo, efeitos de cache batem igual nos dois lados e o DELTA
  entre plataformas continua valido.

  Duas medicoes por rodada:
    - STAT: abre o handle e fecha, SEM ler dados. Isola o round-trip de METADADOS (open/close),
      que e' onde a chattiness mora e onde saltos extras doem mais. E' o numero-chave.
    - READ: abre, le o arquivo inteiro, fecha. Inclui a transferencia dos dados.

  Preparar a corpus UMA vez (de qualquer plataforma, grava no NAS):
    .\bench-smb.ps1 -Share \\nas\share\winperf-bench -Prepare -Files 800 -SizeKB 8

  Medir (rode em cada plataforma, com -Stage identificando de onde):
    .\bench-smb.ps1 -Share \\nas\share\winperf-bench -Stage vmware    -Runs 6 -Out smb.csv
    .\bench-smb.ps1 -Share \\nas\share\winperf-bench -Stage openshift -Runs 6 -Out smb.csv

  Signing (o ambiente do cliente EXIGE): pra medir tambem o custo da assinatura, use -Signing on|off.
  Trocar o signing so' vale pra conexoes NOVAS; o script ja derruba a conexao com o share pra
  forcar renegociacao. Rode as duas variantes com -Stage diferente (ex.: openshift-sign / openshift-nosign).

  Regra de ouro do kit: >= 6 rodadas, descarta a run 1, compara MEDIANA (nao media).
#>
param(
  [Parameter(Mandatory=$true)][string]$Share,
  [switch]$Prepare,
  [int]$Files = 800,
  [int]$SizeKB = 8,
  [int]$Runs = 6,
  [string]$Out = 'smb.csv',
  [string]$Stage = 'baseline',
  [ValidateSet('leave','on','off')][string]$Signing = 'leave'
)

$ErrorActionPreference = 'Stop'
$corpus = Join-Path $Share 'corpus'

if ($Prepare) {
  Write-Host ("Preparando corpus: {0} arquivos de {1} KB em {2}" -f $Files,$SizeKB,$corpus) -ForegroundColor Yellow
  if (-not (Test-Path $corpus)) { New-Item -ItemType Directory -Path $corpus -Force | Out-Null }
  $buf = New-Object byte[] ($SizeKB * 1024)
  (New-Object Random).NextBytes($buf)
  for ($i = 0; $i -lt $Files; $i++) {
    [System.IO.File]::WriteAllBytes((Join-Path $corpus ("f{0:D5}.bin" -f $i)), $buf)
  }
  Write-Host "Corpus pronto." -ForegroundColor Cyan
  return
}

if ($Signing -ne 'leave') {
  $req = ($Signing -eq 'on')
  Write-Host ("Set-SmbClientConfiguration RequireSecuritySignature = {0} (vale so' pra conexoes NOVAS)" -f $req) -ForegroundColor Yellow
  Set-SmbClientConfiguration -RequireSecuritySignature $req -Force
  # derruba a conexao existente com o servidor do share pra forcar renegociacao com o novo signing
  cmd /c "net use $Share /delete /y" 2>$null | Out-Null
  Start-Sleep -Seconds 1
}

if (-not (Test-Path $corpus)) { throw "Corpus nao encontrado em $corpus. Rode com -Prepare primeiro." }
$list = [System.IO.Directory]::GetFiles($corpus, '*.bin')
if ($list.Count -eq 0) { throw "Corpus vazio em $corpus." }
Write-Host ("Medindo {0} arquivos, {1} rodadas, stage={2}, signing={3}" -f $list.Count,$Runs,$Stage,$Signing) -ForegroundColor Yellow

if (-not (Test-Path $Out)) { "stage,signing,run,op,count,total_ms,median_ms,p95_ms,mb" | Out-File $Out -Encoding utf8 }

function Pct([double[]]$vals,[double]$p) {
  $s = $vals | Sort-Object
  if ($s.Count -eq 0) { return 0 }
  $idx = [int][Math]::Ceiling(($p/100.0) * $s.Count) - 1
  if ($idx -lt 0) { $idx = 0 }
  if ($idx -ge $s.Count) { $idx = $s.Count - 1 }
  return $s[$idx]
}

for ($r = 1; $r -le $Runs; $r++) {
  foreach ($op in @('stat','read')) {
    $lat = New-Object System.Collections.Generic.List[double]
    $bytes = [long]0
    $swAll = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $list) {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      if ($op -eq 'stat') {
        $fs = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $fs.Close()
      } else {
        $b = [System.IO.File]::ReadAllBytes($f)
        $bytes += $b.LongLength
      }
      $sw.Stop()
      $lat.Add($sw.Elapsed.TotalMilliseconds)
    }
    $swAll.Stop()
    $arr = $lat.ToArray()
    $med = [Math]::Round((Pct $arr 50),3)
    $p95 = [Math]::Round((Pct $arr 95),3)
    $mb  = [Math]::Round($bytes / 1MB, 2)
    $tot = [Math]::Round($swAll.Elapsed.TotalMilliseconds, 1)
    "$Stage,$Signing,$r,$op,$($arr.Count),$tot,$med,$p95,$mb" | Add-Content $Out
    Write-Host ("run {0} {1,-4}  total={2,9} ms  mediana={3,8} ms  p95={4,8} ms" -f $r,$op,$tot,$med,$p95)
  }
}
Write-Host "Feito. Descarte a run 1. Chave: compare a MEDIANA de 'stat' entre plataformas -> e' o custo de round-trip do caminho, multiplicado depois pelos round-trips/pagina." -ForegroundColor Cyan

<#
  bench-smb.ps1 - Exp 5, Camada 1 (MECANISMO): mede a latencia de acesso SMB da VM ate o share,
  ISOLANDO o caminho de rede. Teste direto da tese "o stack de rede do Kubernetes tem mais saltos;
  pra TCP a granel nao muda (bandwidth-bound), pra SMB/CIFS chatty e assinado soma (latency-bound)".

  CACHE (leia isto): o cliente SMB do Windows cacheia conteudo/handles. Sem cuidado, SO' a PRIMEIRA
  passada bate na rede; as seguintes sao servidas da RAM (latencia ~0.08 ms, que NAO e' rede). Por isso:

    -Cold  (RECOMENDADO pra medir rede): cada rodada le um LOTE DISJUNTO de arquivos nunca lidos.
           Toda rodada e' fria e bate no fio. Compare a MEDIANA direto (NAO descarte a run 1 aqui).
           Requer preparar Files*Runs arquivos (o -Prepare -Cold faz).

    (sem -Cold): warm. run 1 = frio (rede); runs 2..N = cache. Util so' pra VER o cache colapsar
                 (a run 1 fica em ms e o resto despenca pra ~0.08 ms). Nesse modo o unico numero
                 de rede e' a run 1.

  Preparar (de qualquer plataforma, grava no share). Pra modo Cold, passe -Cold e o mesmo -Runs:
    .\bench-smb.ps1 -Share \\server\share\winperf-bench -Prepare -Cold -Files 800 -Runs 6 -SizeKB 8

  Medir (rode em cada plataforma, MESMO -Share UNC, mesma janela de horario):
    .\bench-smb.ps1 -Share \\server\share\winperf-bench -Cold -Stage vmware    -Runs 6 -Out smb.csv
    .\bench-smb.ps1 -Share \\server\share\winperf-bench -Cold -Stage openshift -Runs 6 -Out smb.csv

  Signing (o ambiente do cliente EXIGE): -Signing on|off pra dimensionar a parcela da assinatura.

  Duas medicoes por rodada:
    - STAT: abre o handle e fecha, SEM ler dados. Isola o round-trip de METADADOS (open/close) -
      onde a chattiness mora e onde saltos extras doem mais. E' o numero-chave.
    - READ: abre, le o arquivo inteiro, fecha. Inclui a transferencia (e a coluna MB/s).

  Chave: compare a MEDIANA de 'stat' entre plataformas -> custo de round-trip do caminho,
  multiplicado depois pelos round-trips/pagina (a amplificacao do concentrador).
#>
param(
  [Parameter(Mandatory=$true)][string]$Share,
  [switch]$Prepare,
  [switch]$Cold,
  [int]$Files = 800,
  [int]$SizeKB = 8,
  [int]$Runs = 6,
  [string]$Out = 'smb.csv',
  [string]$Stage = 'baseline',
  [ValidateSet('leave','on','off')][string]$Signing = 'leave'
)

$ErrorActionPreference = 'Stop'
$corpus = Join-Path $Share 'corpus'
$need = if ($Cold) { $Files * $Runs } else { $Files }

if ($Prepare) {
  $modo = if ($Cold) { 'COLD' } else { 'warm' }
  Write-Host ("Preparando corpus: {0} arquivos de {1} KB em {2} (modo {3})" -f $need,$SizeKB,$corpus,$modo) -ForegroundColor Yellow
  if (-not (Test-Path $corpus)) { New-Item -ItemType Directory -Path $corpus -Force | Out-Null }
  $buf = New-Object byte[] ($SizeKB * 1024)
  (New-Object Random).NextBytes($buf)
  for ($i = 0; $i -lt $need; $i++) {
    [System.IO.File]::WriteAllBytes((Join-Path $corpus ("f{0:D6}.bin" -f $i)), $buf)
  }
  Write-Host ("Corpus pronto ({0} arquivos)." -f $need) -ForegroundColor Cyan
  return
}

if ($Signing -ne 'leave') {
  $req = ($Signing -eq 'on')
  Write-Host ("Set-SmbClientConfiguration RequireSecuritySignature = {0} (vale so' pra conexoes NOVAS)" -f $req) -ForegroundColor Yellow
  try { Set-SmbClientConfiguration -RequireSecuritySignature $req -Force }
  catch { Write-Host ("  aviso: nao mudou o signing (" + $_.Exception.Message + "); precisa de Admin.") -ForegroundColor Yellow }
  # Best-effort: derruba conexoes com o SERVIDOR (nao o subcaminho X:\tmp\...) pra forcar renegociacao. Nunca aborta.
  $srv = $null
  if ($Share -match '^([A-Za-z]:)') {
    try { $rp = (Get-SmbMapping -LocalPath $matches[1] -ErrorAction SilentlyContinue).RemotePath; if ($rp -match '^\\\\([^\\]+)\\') { $srv = $matches[1] } } catch {}
  } elseif ($Share -match '^\\\\([^\\]+)\\') { $srv = $matches[1] }
  if ($srv) { try { cmd /c "net use \\$srv /delete /y" 2>&1 | Out-Null } catch {} }
  Start-Sleep -Seconds 1
  if ($req) { Write-Host "  nota: se o servidor EXIGE signing, a conexao ja vem assinada mesmo sem este passo." -ForegroundColor DarkGray }
}

if (-not (Test-Path $corpus)) { throw "Corpus nao encontrado em $corpus. Rode com -Prepare primeiro." }
$all = @([System.IO.Directory]::GetFiles($corpus, '*.bin') | Sort-Object)
if ($all.Count -lt $need) {
  $dica = if ($Cold) { "Rode: -Prepare -Cold -Files $Files -Runs $Runs" } else { "Rode: -Prepare -Files $Files" }
  throw ("Corpus tem {0} arquivos, o modo pede {1}. {2}" -f $all.Count,$need,$dica)
}
$modo = if ($Cold) { 'COLD (toda rodada fria)' } else { 'warm (run 1 = rede, resto = cache)' }
Write-Host ("Medindo: Files={0}/rodada, Runs={1}, modo={2}, stage={3}, signing={4}" -f $Files,$Runs,$modo,$Stage,$Signing) -ForegroundColor Yellow

if (-not (Test-Path $Out)) { "stage,signing,mode,run,op,count,total_ms,median_ms,p95_ms,mb,mbps" | Out-File $Out -Encoding utf8 }

function Pct([double[]]$vals,[double]$p) {
  $s = $vals | Sort-Object
  if ($s.Count -eq 0) { return 0 }
  $idx = [int][Math]::Ceiling(($p/100.0) * $s.Count) - 1
  if ($idx -lt 0) { $idx = 0 }
  if ($idx -ge $s.Count) { $idx = $s.Count - 1 }
  return $s[$idx]
}

$mode = if ($Cold) { 'cold' } else { 'warm' }
for ($r = 1; $r -le $Runs; $r++) {
  # COLD: lote DISJUNTO por rodada, dividido em DOIS pra 'stat' e 'read' NUNCA tocarem o mesmo
  # arquivo (senao o 'stat' abre cada arquivo primeiro e AQUECE o 'read', mascarando a leitura).
  # warm: sempre os mesmos Files primeiros arquivos -> run 1 frio, resto do cache.
  if ($Cold) {
    $runSlice = $all[(($r-1)*$Files)..(($r*$Files)-1)]
    $half = [int]($Files/2)
    $sliceOf = @{ stat = $runSlice[0..($half-1)]; read = $runSlice[$half..($Files-1)] }
  } else {
    $warm = $all[0..($Files-1)]
    $sliceOf = @{ stat = $warm; read = $warm }
  }
  foreach ($op in @('stat','read')) {
    $slice = $sliceOf[$op]
    $lat = New-Object System.Collections.Generic.List[double]
    $bytes = [long]0
    $swAll = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $slice) {
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
    $mbps = if ($op -eq 'read' -and $swAll.Elapsed.TotalSeconds -gt 0) { [Math]::Round($mb / $swAll.Elapsed.TotalSeconds, 2) } else { '' }
    "$Stage,$Signing,$mode,$r,$op,$($arr.Count),$tot,$med,$p95,$mb,$mbps" | Add-Content $Out
    $extra = if ($op -eq 'read') { "  {0} MB/s" -f $mbps } else { '' }
    Write-Host ("run {0} {1,-4}  total={2,9} ms  mediana={3,8} ms  p95={4,8} ms{5}" -f $r,$op,$tot,$med,$p95,$extra)
  }
}
if ($Cold) {
  Write-Host "Modo COLD: TODAS as rodadas sao frias. Compare a MEDIANA de 'stat' entre plataformas (VMware vs OpenShift) = custo de round-trip do caminho." -ForegroundColor Cyan
} else {
  Write-Host "Modo warm: SO' a run 1 e' rede; runs 2+ sao cache (~0.08 ms). Pra medir rede de verdade, use -Cold." -ForegroundColor Cyan
}

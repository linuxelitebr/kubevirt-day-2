<#
  capture-net-path.ps1 - Exp 5, identidade de CAMINHO: captura QUAL file server o DFS entregou
  pra esta VM, a que distancia, e se a identidade de rede (IP/sub-rede/AD site) mudou.
  Rode em CADA plataforma e compare os dois arquivos de saida.

  IMPORTANTE: rode em PowerShell COMO ADMINISTRADOR. O Get-SmbConnection (que mostra a replica
  resolvida, dialeto e assinatura) exige elevacao; sem admin ele falha com "Acesso negado / Erro 5"
  e o script cai no fallback Get-SmbMapping (menos detalhe).

  Serve pra separar as duas causas de um delta de SMB:
    - datapath: mesmos servidor e saltos, so' mais latencia por hop -> RTT ~igual.
    - referral: o DFS apontou pra uma REPLICA mais longe porque a sub-rede/AD site mudou na
      migracao -> muda o ServerName e/ou o AD site e/ou o RTT sobe. Este e' o efeito de segundos.

    .\capture-net-path.ps1 -Share X:\tmp\bench -Out C:\winperf\netpath-openshift.txt
    .\capture-net-path.ps1 -Share X:\tmp\bench -Out C:\winperf\netpath-vmware.txt

  Dica: escreva o -Out em disco LOCAL (C:\winperf\...), nao no proprio share de rede.
#>
param(
  [Parameter(Mandatory=$true)][string]$Share,
  [string]$Out = 'netpath.txt'
)
$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]
function Log($s){ $t = [string]$s; $lines.Add($t) | Out-Null; Write-Host $t }

Log ("===== capture-net-path  " + (Get-Date -Format o) + " =====")
Log ("Share alvo: " + $Share)

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Log "AVISO: sessao SEM elevacao. Get-SmbConnection precisa de Admin; parte dos dados vai faltar. Rode o PowerShell como Administrador." }

# 1) Toca o share pra garantir conexao ativa (resolve o DFS e abre a sessao SMB)
try { Get-ChildItem $Share -ErrorAction Stop | Out-Null; Log "Share acessivel: sim" }
catch { Log ("Share acessivel: NAO -> " + $_.Exception.Message) }

# 2) IP/sub-rede/AD site desta VM (o que DECIDE o referral do DFS)
Log "`n--- Identidade de rede da VM ---"
Log ((Get-NetIPAddress -AddressFamily IPv4 |
      Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
      Select-Object IPAddress,PrefixLength,InterfaceAlias | Format-Table -Auto | Out-String).Trim())
Log "AD site desta VM (nltest /dsgetsite):"
try { Log ((nltest /dsgetsite 2>&1 | Out-String).Trim()) } catch { Log "  (nltest indisponivel)" }

# 3) QUAL servidor o DFS entregou de fato + dialeto/assinatura (PRECISA de admin)
Log "`n--- Conexao SMB efetiva (a replica que o DFS resolveu) [requer Admin] ---"
$conns = @()
try {
  $conns = @(Get-SmbConnection -ErrorAction Stop)
  Log (($conns | Select-Object ServerName,ShareName,Dialect,Signed,Encrypted,ContinuouslyAvailable |
        Format-Table -Auto | Out-String).Trim())
} catch {
  Log ("  FALHOU: " + $_.Exception.Message)
  Log "  -> rode o PowerShell como ADMINISTRADOR pra este passo."
}

# 3b) Fallback sem admin: mapeamentos de drive (mostra pra onde o X: aponta)
Log "`n--- Get-SmbMapping (fallback, sem admin) ---"
$maps = @()
try {
  $maps = @(Get-SmbMapping -ErrorAction Stop)
  Log (($maps | Select-Object LocalPath,RemotePath,Status | Format-Table -Auto | Out-String).Trim())
} catch { Log ("  (Get-SmbMapping falhou: " + $_.Exception.Message + ")") }

# 4) Config de assinatura do cliente (nao precisa admin)
Log "`n--- SMB client config ---"
try { Log ((Get-SmbClientConfiguration |
      Select-Object RequireSecuritySignature,EnableSecuritySignature,EnableMultiChannel |
      Format-List | Out-String).Trim()) } catch { Log "  (falhou)" }

# 5) Referral DFS detalhado (so' se o dfsutil existir; evita o warning de CWD-UNC)
Log "`n--- Referral DFS (dfsutil /pktinfo; requer RSAT DFS Mgmt Tools) ---"
if (Get-Command dfsutil.exe -ErrorAction SilentlyContinue) {
  Push-Location $env:SystemRoot
  try { Log ((dfsutil /pktinfo 2>&1 | Out-String).Trim()) } catch { Log "  (dfsutil falhou)" }
  Pop-Location
} else { Log "  dfsutil ausente (RSAT DFS Mgmt nao instalado). O ServerName do passo 3 ja da a replica." }

# 6) Monta a lista de file servers: da conexao SMB, dos mapeamentos, e do proprio -Share se for UNC
$servers = New-Object System.Collections.Generic.List[string]
foreach ($c in $conns) { if ($c.ServerName) { $servers.Add([string]$c.ServerName) | Out-Null } }
foreach ($m in $maps) { if ($m.RemotePath -match '^\\\\([^\\]+)\\') { $servers.Add($matches[1]) | Out-Null } }
if ($Share -match '^\\\\([^\\]+)\\') { $servers.Add($matches[1]) | Out-Null }
$servers = @($servers | Where-Object { $_ } | Select-Object -Unique)

# 7) Distancia (RTT) e PMTU efetivo ate cada file server
Log "`n--- RTT e PMTU efetivo ate os file servers da sessao ---"
if ($servers.Count -eq 0) { Log "  Nenhum servidor identificado (rode como Admin, ou passe -Share em UNC)." }
foreach ($srv in $servers) {
  Log ("Servidor: " + $srv)
  $tnc = Test-NetConnection -ComputerName $srv -Port 445 -WarningAction SilentlyContinue
  $rtt = if ($tnc -and $tnc.PingReplyDetails) { $tnc.PingReplyDetails.RoundtripTime } else { 'n/d' }
  Log ("  TCP 445: " + $tnc.TcpTestSucceeded + "   RTT(ping ms): " + $rtt)
  # PMTU efetivo: maior payload que passa com DF setado. 1472 + 28 = 1500. Guest 1500 nao prova
  # o PMTU efetivo: sob encap geneve o caminho pode ficar ~58 bytes menor.
  $mtu = 0
  foreach ($sz in @(1472,1414,1400,1372,1300,1200)) {
    $p = ping -n 1 -f -l $sz $srv 2>&1 | Out-String
    if ($p -match 'TTL=') { $mtu = $sz + 28; break }
  }
  if ($mtu -gt 0) { Log ("  PMTU efetivo aprox: " + $mtu + " bytes (maior pacote DF que passou)") }
  else { Log "  PMTU: nao determinado (ICMP/DF bloqueado no caminho?)" }
}

Log "`n===== fim ====="

# Escreve UMA vez, no fim (evita o conflito de handle que dava 'usado por outro processo')
try {
  $lines -join "`r`n" | Out-File -FilePath $Out -Encoding utf8 -Force
  Write-Host ("Salvo em " + $Out) -ForegroundColor Cyan
} catch {
  Write-Host ("Nao consegui salvar em " + $Out + " -> " + $_.Exception.Message) -ForegroundColor Yellow
  Write-Host "Tente -Out C:\winperf\netpath.txt (disco local)." -ForegroundColor Yellow
}
Write-Host "Compare ServerName, AD site e RTT entre plataformas: mudou => referral/caminho mudou. Iguais => delta (se houver) e' datapath puro." -ForegroundColor Cyan

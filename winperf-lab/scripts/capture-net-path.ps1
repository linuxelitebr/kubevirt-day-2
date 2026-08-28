<#
  capture-net-path.ps1 - Exp 5, identidade de CAMINHO: captura QUAL file server o DFS entregou
  pra esta VM, a que distancia, e se a identidade de rede (IP/sub-rede/AD site) mudou.
  Rode em CADA plataforma e compare os dois arquivos de saida.

  Serve pra separar as duas causas possiveis de um delta de SMB:
    - datapath: mesmos servidor e saltos, so' mais latencia por hop (overlay/encap) -> RTT sobe pouco.
    - referral: o DFS passou a apontar pra uma REPLICA mais longe porque a sub-rede mudou na
      migracao -> muda o ServerName e/ou o RTT sobe muito. Este e' o efeito que pode valer segundos.

  O sinal mais forte e' Get-SmbConnection.ServerName: mostra a replica que o DFS resolveu de fato,
  SEM precisar de ferramentas de DFS. Se o ServerName ou o RTT mudam entre plataformas, o caminho mudou.

    .\capture-net-path.ps1 -Share \\dfs.dominio\namespace\app -Out netpath-vmware.txt
    .\capture-net-path.ps1 -Share \\dfs.dominio\namespace\app -Out netpath-openshift.txt
#>
param(
  [Parameter(Mandatory=$true)][string]$Share,
  [string]$Out = 'netpath.txt'
)
$ErrorActionPreference = 'Continue'
"" | Out-File $Out -Encoding utf8
function Log($s){ $s | Tee-Object -FilePath $Out -Append | Out-Null; Write-Host $s }

Log ("===== capture-net-path  " + (Get-Date -Format o) + " =====")
Log ("Share alvo: " + $Share)

# 1) Toca o share pra garantir conexao ativa (resolve o DFS e abre a sessao SMB)
try { Get-ChildItem $Share -ErrorAction Stop | Out-Null; Log "Share acessivel: sim" }
catch { Log ("Share acessivel: NAO -> " + $_.Exception.Message) }

# 2) IP/sub-rede/AD site desta VM (o que DECIDE o referral do DFS)
Log "`n--- Identidade de rede da VM ---"
Log ((Get-NetIPAddress -AddressFamily IPv4 |
      Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
      Select-Object IPAddress,PrefixLength,InterfaceAlias | Format-Table -Auto | Out-String).Trim())
Log "AD site desta VM (nltest /dsgetsite):"
Log ((nltest /dsgetsite 2>&1 | Out-String).Trim())

# 3) QUAL servidor o DFS entregou de fato + dialeto/assinatura/encrypt da sessao
Log "`n--- Conexao SMB efetiva (a replica que o DFS resolveu) ---"
Log ((Get-SmbConnection |
      Select-Object ServerName,ShareName,Dialect,Signed,Encrypted,ContinuouslyAvailable |
      Format-Table -Auto | Out-String).Trim())

# 4) Config de assinatura do cliente
Log "`n--- SMB client config ---"
Log ((Get-SmbClientConfiguration |
      Select-Object RequireSecuritySignature,EnableSecuritySignature,EnableMultiChannel |
      Format-List | Out-String).Trim())

# 5) Referral DFS detalhado (opcional; precisa das ferramentas DFS. Se faltar, o passo 3 ja resolve)
Log "`n--- Referral DFS (dfsutil /pktinfo; requer RSAT DFS Mgmt Tools) ---"
Log ((cmd /c "dfsutil /pktinfo" 2>&1 | Out-String).Trim())

# 6) Distancia (RTT) e PMTU efetivo ate cada file server que apareceu na sessao SMB
Log "`n--- RTT e PMTU efetivo ate os file servers da sessao ---"
$servers = @(Get-SmbConnection | Select-Object -ExpandProperty ServerName -Unique)
if ($servers.Count -eq 0) { Log "Nenhuma conexao SMB ativa (o share resolveu?)." }
foreach ($srv in $servers) {
  Log ("Servidor: " + $srv)
  $tnc = Test-NetConnection -ComputerName $srv -Port 445 -WarningAction SilentlyContinue
  $rtt = if ($tnc.PingReplyDetails) { $tnc.PingReplyDetails.RoundtripTime } else { 'n/d' }
  Log ("  TCP 445: " + $tnc.TcpTestSucceeded + "   RTT(ping ms): " + $rtt)
  # PMTU efetivo: maior payload que passa com DF setado. 1472 de payload + 28 de cabecalho = 1500.
  # Guest MTU 1500 NAO prova PMTU efetivo: sob encap geneve o caminho pode ficar ~58 bytes menor.
  $mtu = 0
  foreach ($sz in @(1472,1414,1400,1372,1300,1200)) {
    $p = ping -n 1 -f -l $sz $srv 2>&1 | Out-String
    if ($p -match 'TTL=') { $mtu = $sz + 28; break }
  }
  if ($mtu -gt 0) { Log ("  PMTU efetivo aprox: " + $mtu + " bytes (maior pacote DF que passou)") }
  else { Log "  PMTU: nao determinado (ICMP/DF bloqueado no caminho?)" }
}
Log "`n===== fim ====="
Write-Host "Compare ServerName e RTT entre plataformas: mudou o servidor OU subiu o RTT => referral/caminho mudou. Iguais => o delta (se houver) e' datapath puro." -ForegroundColor Cyan

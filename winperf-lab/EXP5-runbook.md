# Exp 5: roteiro do zero (bench-smb + capture-net-path)

Roteiro completo pra rodar numa VM Windows Server **onde você tem admin**. Objetivo: medir o custo de round-trip SMB da VM ate o file server em cada plataforma (VMware e OpenShift) e comparar.

## Regras que evitam os erros comuns

- **Rode o PowerShell como Administrador.** O `capture-net-path` usa `Get-SmbConnection`, que exige elevacao.
- **Use caminho UNC (`\\server\share`), nao letra mapeada (`X:`).** Drive mapeado nao aparece em sessao elevada (token separado do UAC), e garante o mesmo endpoint nas duas plataformas.
- **Escreva o `-Out` em disco LOCAL (`C:\winperf\...`)**, nunca no proprio share de rede.
- **Corpus cold:** precisa de `Files*Runs` arquivos (800*6 = 4800). Se a contagem der 800, refaca com `-Prepare -Cold`.

## Passo 0 - preparar a VM (uma vez)

PowerShell **como Administrador**:

```powershell
New-Item -ItemType Directory C:\winperf -Force | Out-Null
Set-Location C:\winperf
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/linuxelitebr/kubevirt-day-2/main/winperf-lab/scripts/bench-smb.ps1       -OutFile .\bench-smb.ps1
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/linuxelitebr/kubevirt-day-2/main/winperf-lab/scripts/capture-net-path.ps1 -OutFile .\capture-net-path.ps1
Get-ChildItem . | Unblock-File
```

## Passo 1 - escolher o share (UNC) e confirmar que e rede

Aponte pro file server que quer medir (o NAS/share real do cliente da a medida mais fiel). Confirme que responde:

```powershell
$share = '\\FILESERVER\SHARE\winperf-bench'
Test-Path $share
```

## Passo 2 - preparar o corpus cold (uma vez, de qualquer plataforma)

```powershell
.\bench-smb.ps1 -Share $share -Prepare -Cold -Files 800 -Runs 6 -SizeKB 8
(Get-ChildItem "$share\corpus" -Filter *.bin).Count   # deve dar 4800
```

## Passo 3 - medir ESTA VM (troque o stage pela plataforma onde ela roda)

```powershell
$stage = 'openshift'   # ou 'vmware'
.\bench-smb.ps1       -Share $share -Cold -Stage $stage -Runs 6 -Out "C:\winperf\smb-$stage.csv"
.\capture-net-path.ps1 -Share $share -Out "C:\winperf\netpath-$stage.txt"
```

O que esperar: 6 rodadas com `stat` e `read` na casa de **ms** (nao despenca pra 0,08; se despencar, o corpus nao e cold). O `capture-net-path` (admin) mostra `ServerName`, `Dialect`, `Signed`, o AD site e o RTT via handshake TCP.

## Passo 4 - custo do signing (fidelidade; o cliente exige signing)

```powershell
.\bench-smb.ps1 -Share $share -Cold -Signing on  -Stage "$stage-sign"   -Runs 6 -Out "C:\winperf\smb-$stage.csv"
.\bench-smb.ps1 -Share $share -Cold -Signing off -Stage "$stage-nosign" -Runs 6 -Out "C:\winperf\smb-$stage.csv"
```

## Passo 5 - repetir na VM da OUTRA plataforma

Mesma sequencia (Passos 0, 3, 4) numa VM Windows na outra plataforma, apontando pro **mesmo** `$share`. Nao precisa re-preparar o corpus (as duas VMs leem o mesmo share). Use `-Stage vmware` (ou `openshift`).

## Passo 6 - comparar

Junte os `smb-*.csv` num lugar so e rode:

```powershell
Import-Csv C:\winperf\smb-openshift.csv, C:\winperf\smb-vmware.csv |
  Group-Object stage, op |
  ForEach-Object {
    $vals = $_.Group | ForEach-Object { [double]$_.median_ms } | Sort-Object
    "{0,-22} mediana={1,8:N3} ms" -f $_.Name, $vals[[int]($vals.Count/2)]
  }
```

O numero que decide: a linha **`stat`** de cada plataforma. Depois compare `ServerName`, AD site e RTT nos dois `netpath-*.txt`.

## Leitura do resultado

| Observacao | Leitura |
|---|---|
| `stat` mediana **sobe** no OpenShift, `ServerName`/AD site/RTT **iguais** | datapath: overlay/hops do stack somam latencia por round-trip. Multiplica pelos round-trips/pagina = a amplificacao. |
| `ServerName` ou AD site ou RTT **mudam** no OpenShift | caminho/referral mudou (so aparece se o share for via DFS namespace; um `\\servidor\share` direto nao tem referral). |
| `stat` mediana **~igual** nas duas | a rede nao e o gargalo. O suspeito vira o app (cold-start, I/O na raiz por request). |
| `signing on` vs `off` **separa muito** | parcela grande e a assinatura. Documenta como fator. |

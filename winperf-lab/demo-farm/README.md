# demo-farm: content-on-NAS vs disco local, ao vivo

Farm IIS que reproduz o padrao do cliente (varios sites servindo conteudo de um concentrador NAS via
UNC/DFS) e mede, na tela, o custo desse padrao. Cada site roda uma app **ASP.NET compilada** (nao
estatico); o dashboard mostra `io_ms` (leitura do conteudo da raiz) separado de `compute_ms` (trabalho
local constante), e o tamanho na rede (efeito da compressao).

**O que prova:** o tempo de resposta e' quase todo **entrega de conteudo** (I/O contra o NAS), nao
trabalho da app. E' platform-independent: roda igual em VMware e OpenShift. Se a fala "e' .NET, vai pra
memoria, nao toca disco" fosse verdade, NAS e local dariam o mesmo numero. Nao dao.

---

## Pre-requisitos

- VM Windows (Server 2016+; Server 2022 testado), **PowerShell como Administrador**.
- Um **share no NAS** que voce possa **escrever** (pra provisionar) e **ler** (pra servir).
- A **conta de servico do dominio** que le o NAS (a mesma que a app real usa). Sem ela, os sites
  respondem mas com `fragments=0` (a conta de maquina nao tem acesso ao NAS do dominio).
- Saida pra internet na VM pra baixar o pacote (ou copie o ZIP por outro meio).

## Passo 0 - baixar o pacote (na VM, PowerShell Admin)

```powershell
Set-Location C:\
Invoke-WebRequest -UseBasicParsing https://github.com/linuxelitebr/kubevirt-day-2/archive/refs/heads/main.zip -OutFile kd2.zip
Expand-Archive kd2.zip -DestinationPath C:\ -Force
Set-Location C:\kubevirt-day-2-main\winperf-lab\demo-farm\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Get-ChildItem C:\kubevirt-day-2-main -Recurse -File | Unblock-File
```

## Passo 1 - subir a farm (um comando)

```powershell
$c = Get-Credential DOMINIO\<conta_servico>          # conta que le o NAS
.\bootstrap-demo.ps1 -ContentUnc \\<nas>\<share>\demo-farm -Sites 8 -PoolCredential $c
```

O bootstrap instala as features do IIS, provisiona os 8 sites **espelhados no NAS e no disco local**,
sobe o site do dashboard e imprime os proximos passos. (Se falhar criando arquivos no NAS = escrita;
se os sites derem `fragments=0` = leitura do pool.)

## Passo 2 - abrir o dashboard

```
http://localhost:9000/dashboard.html?base=9000&sites=8
```

Mostra por site: `total_ms` (com ponto de severidade verde/ambar/vermelho), a barra `io+compute`,
`io_ms`, `compute_ms`, `rede KB` e o HTTP. No topo, a mediana das sites e o runtime `.NET CLR ... w3wp`.
Limiares ajustaveis: `...&warn=150&slow=400` (ms).

## Passo 3 - o 2x2 (NAS/local x com/sem compressao)

Pra cada cenario: rode o toggle no PowerShell, espere ~15s estabilizar, selecione o cenario no
dashboard e clique **Capturar**. O comparativo dos 4 aparece embaixo.

```powershell
# A) NAS, sem compressao (o cliente)
.\toggle-root.ps1 -Backing nas   -ContentUnc \\<nas>\<share>\demo-farm -ContentLocal C:\demo-farm
.\toggle-compression.ps1 -State off
# B) NAS, com compressao
.\toggle-compression.ps1 -State on
# C) Local, sem compressao
.\toggle-root.ps1 -Backing local -ContentUnc \\<nas>\<share>\demo-farm -ContentLocal C:\demo-farm
.\toggle-compression.ps1 -State off
# D) Local, com compressao (o ideal)
.\toggle-compression.ps1 -State on
```

O momento de ouro e' o **C**: virar pra local faz o vermelho (`io_ms`) despencar. Se fosse tudo memoria,
nao mudaria. Troque a metrica do comparativo (total_ms / io_ms / rede KB) pra mostrar cada eixo.

## Passo 4 - rodar nos DOIS hypervisors (OpenShift e VMware)

Este e' o argumento de plataforma: **o mesmo pacote, o mesmo NAS, numa VM no OpenShift e numa VM no
VMware**. Repita os Passos 0-3 em cada VM (apontando o `-ContentUnc` pro **mesmo** NAS).

- Capture o 2x2 no dashboard de **cada** VM e ponha as duas telas lado a lado.
- Pra numeros, rode o poller com nome de arquivo por plataforma:
  ```powershell
  .\consumer-poll.ps1 -Sites 8 -BasePort 9000 -Out C:\winperf\demo-poll-openshift.csv   # na VM OpenShift
  .\consumer-poll.ps1 -Sites 8 -BasePort 9000 -Out C:\winperf\demo-poll-vmware.csv       # na VM VMware
  ```

Leitura esperada: o `io_ms` (custo do NAS) e' **parecido nos dois** hypervisors -> a plataforma nao
adiciona custo de entrega; o gargalo e' a arquitetura content-on-NAS, que existe igual nos dois lados.
O braco **local** e' rapido nos dois. Isso fecha "nao e' o hypervisor" com o mesmo grafico.

## Como ler os resultados

| Observacao | Leitura |
|---|---|
| `io_ms` alto, barra quase toda vermelha | a resposta e' ~toda leitura de conteudo do NAS, nao trabalho da app |
| virar pra **local** derruba o `io_ms` | prova que o custo e' entrega de conteudo (refuta "vai pra memoria, nao toca disco") |
| `io_ms` parecido em OpenShift e VMware | a plataforma nao e' o gargalo; e' a arquitetura |
| `rede KB` cai muito com compressao on | a compressao dinamica desligada e' um fator (200 KB -> ~2 KB) |

## Extras

- **Modo "app pesada de memoria"** (reproduz o 16 vCPU / 96 GB): edite `app\web.config` e ponha
  `MemLoadMB` > 0 (ex.: 2000 = 2 GB por site) antes do setup, ou nos sites ja criados e recicle o pool.
  O `Global.asax` aloca e segura essa RAM no start (working set + fragmentacao de LOH); a 1a request paga
  o carregamento (cold-start caro). `Default.aspx` reporta `heap_mb`/`ws_mb`. Dimensione pro seu lab.
- **Fingerprint de memoria/NUMA do app real:** `..\..\scripts\capture-memory.ps1 -Out C:\winperf\mem.txt -Seconds 60`
  (bitness do pool, GC/LOH/fragmentacao, working set, topologia NUMA). Rode com o app sob carga.
- **Latencia crua do NAS:** `..\..\scripts\bench-smb.ps1` (ver `winperf-lab\EXP5-*`).

## De-identificacao

O dashboard e os prints mostram o **nome real do NAS/dominio**. Pra apresentar **ao cliente**, tudo bem
(e' o ambiente deles). Pro **post/repo publico**, mascare tudo (NAS, dominio, sites) antes.

## Gotchas (o que morde)

- **PowerShell como Administrador** (o bootstrap instala features do IIS).
- **UNC, nao letra mapeada** — drive mapeado some em sessao elevada.
- **`-Out` em disco local** (`C:\winperf\...`), nunca no proprio share.
- **`-PoolCredential`** com a conta que le o NAS do dominio (senao `fragments=0`).
- Compressao: o toggle precisa da feature de compressao dinamica instalada (o bootstrap instala).

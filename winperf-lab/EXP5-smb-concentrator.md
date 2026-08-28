# Exp 5: o NAS como concentrador (SMB no stack de rede do Kubernetes)

O caso que motivou este experimento **não** é sobre o hypervisor ser lento. É sobre o **caminho** até o NAS mudar na migração, encontrando uma app que **amplifica** qualquer milissegundo extra desse caminho.

## A tese (o modelo a refutar ou confirmar, declarado ANTES de medir)

O stack de rede do Kubernetes (OVN, overlay geneve, SNAT, bridge OVS) tem mais saltos internos que o caminho VMXNET3 do VMware.

- Pra **TCP a granel** (download, cópia grande) isso é invisível: é *bandwidth-bound*, a janela TCP mantém bytes em voo e esconde a latência por hop.
- Pra **SMB/CIFS** é diferente: é *request/response*, *chatty* (open/query/read/close por arquivo), muitas vezes serializado, e aqui **assinado** (signing exigido). É *latency-bound*: o tempo total é aproximadamente `RTT x número de round-trips`. Cada salto extra entra direto na conta.
- **Normalmente não atrapalha.** O que torna este caso específico: o NAS é o **concentrador** único. A web farm IIS inteira serve **todo** o conteúdo de lá, e IIS-servindo-de-UNC transforma **uma** página em centenas de operações SMB contra aquele mount. O fator de amplificação (round-trips por página) é enorme, e cai todo no único caminho cuja latência a migração mexeu.

Resultado: `delta pequeno por round-trip x contagem enorme de round-trips = segundos, e visível`. Num app normal (conteúdo local, rede só pra query esparsa) o mesmo delta seria invisível.

**Predição falsificável:** a mediana de `stat` (round-trip de metadados) sobe do VMware pro OpenShift; o `read` sobe menos (a transferência é menos sensível a hop que o handshake); e a maior parte de um eventual salto vem de **referral** (file server mais longe), não de datapath puro — o que aparece como `ServerName` e/ou `RTT` diferentes em `capture-net-path`.

## As duas camadas

**Camada 1 — mecanismo (`bench-smb.ps1`):** micro-benchmark de SMB puro, VM -> NAS, mesma corpus, medida em cada plataforma. Isola o custo de round-trip (op `stat`) do custo de transferência (op `read`). Sem IIS, sem app: só o caminho.

**Camada 2 — identidade (`capture-net-path.ps1`):** descobre **qual** replica o DFS entregou (`Get-SmbConnection.ServerName`, sem precisar de ferramenta de DFS), a que **distância** (RTT), o **AD site** da VM (`nltest /dsgetsite`) e o **PMTU efetivo** (guest 1500 não prova o PMTU sob encap). Roda nas duas plataformas e compara.

Junto, respondem: *houve delta de SMB? Foi datapath (mesmos servidor e saltos, RTT ~igual) ou referral (servidor/ RTT diferentes, o efeito que vale segundos)?*

## Escolha do endpoint: um share SMB controlado como stand-in do NAS

Não precisa do appliance de produção pra este experimento. "NAS" aqui é um **papel** (armazenamento compartilhado, servido por rede, por onde tudo é funilado), não uma caixa específica. Um compartilhamento SMB num Windows Server que você controla é um stand-in válido, e em alguns pontos **melhor**: você controla o dialeto, liga/desliga o signing (medir, em vez de citar número de terceiro) e define a corpus exata.

O que decide a validade **não** é o tipo do storage, é a **posição de rede** do endpoint:

- **Fora do cluster, na rede física.** O share tem que ficar num server físico/VMware, como o NAS real. Se ficar num node do cluster, num pod, num PVC ou for alcançado pela pod-network, o tráfego **não passa** pelo overlay/SNAT/hops que queremos medir, e o teste não prova nada. É o único jeito de invalidar o experimento.
- **Mesmo endpoint dos dois lados.** A VM monta o **mesmo** `\\server\share` no VMware e no OpenShift. Isso *é* o A/B: mesmo destino, duas plataformas, o caminho é a única variável.
- **Mesma postura de protocolo.** SMB 3.1.1 + **signing required** no server (`Set-SmbServerConfiguration -RequireSecuritySignature $true`). É o que torna o custo de round-trip e de assinatura representativo.
- **Idealmente na mesma sub-rede/site** que o NAS de produção, pro comprimento do datapath (VM -> OVS -> geneve -> gateway -> uplink -> file server) ser parecido.

O que esse share **não** reproduz, e como tratamos:

1. **Quirks do appliance** (oplocks/leases, enumeração, multichannel próprio do NAS). **Cancelam no A/B**: mesmo endpoint nos dois lados, o quirk aparece igual e some no delta.
2. **DFS / site-cost referral.** Um `\\server\share` puro não tem DFS, então o efeito "a migração me jogou numa réplica mais longe" **não aparece** aqui. Ou seja: o share do lab isola limpo a metade **datapath** (`bench-smb.ps1`); a metade **referral** continua sendo medição in-place no ambiente do cliente, com o `capture-net-path.ps1` rodando contra o DFS real.

Ajustes opcionais pra ficar mais fiel: se o NAS real serve single-stream, desligue o multichannel no cliente (`Set-SmbClientConfiguration -EnableMultiChannel $false`) pra não ganhar um paralelismo que a produção não tem. O dialeto não precisa forçar: Windows Server moderno negocia 3.1.1 sozinho.

## Como rodar

Preparar a corpus uma vez (grava no NAS de qualquer lugar):

```powershell
.\scripts\bench-smb.ps1 -Share \\<nas>\<share>\winperf-bench -Prepare -Files 800 -SizeKB 8
```

Medir com a VM no VMware, depois migrar a MESMA VM pro OpenShift e repetir (mesma janela de horário):

```powershell
.\scripts\bench-smb.ps1 -Share \\<nas>\<share>\winperf-bench -Stage vmware    -Runs 6 -Out smb.csv
.\scripts\capture-net-path.ps1 -Share \\<dfs>\<namespace>\<app> -Out netpath-vmware.txt
# migrar a VM para o OpenShift, mesma janela:
.\scripts\bench-smb.ps1 -Share \\<nas>\<share>\winperf-bench -Stage openshift -Runs 6 -Out smb.csv
.\scripts\capture-net-path.ps1 -Share \\<dfs>\<namespace>\<app> -Out netpath-openshift.txt
```

Custo do signing (o ambiente do cliente exige; medir os dois pra dimensionar a parcela dele):

```powershell
.\scripts\bench-smb.ps1 -Share \\<nas>\<share>\winperf-bench -Stage openshift-sign   -Signing on  -Runs 6 -Out smb.csv
.\scripts\bench-smb.ps1 -Share \\<nas>\<share>\winperf-bench -Stage openshift-nosign -Signing off -Runs 6 -Out smb.csv
```

Regra de ouro do kit: **>= 6 rodadas, descarta a run 1, compara mediana + p95** (não média — uma média deixa um outlier mandar).

## O que confirma / o que refuta a tese

| Observação | Leitura |
|---|---|
| `stat` mediana sobe no OpenShift e `ServerName`/`RTT` iguais | datapath: overlay/hops adicionam latência por round-trip. Real, geralmente modesto. |
| `ServerName` muda **ou** `RTT` sobe muito no OpenShift | referral: o DFS mandou pra uma replica mais longe após a sub-rede mudar. Aqui mora o efeito de segundos. |
| `stat` mediana ~igual nas duas | a rede não é o gargalo. Vira pro app (compressão off, cold-start, backend). |
| signing on vs off separa muito | parcela grande é a assinatura; documentar como fator, não como culpa da plataforma. |

## Parâmetros do ambiente

Endpoint da Camada 1: resolvido usando um **share SMB controlado** (Windows Server que você tem acesso), na rede física, fora do cluster, com signing required (ver "Escolha do endpoint"). Isso dispensa depender do NAS de produção pro mecanismo. Ainda faltam, pra interpretar o número:

1. **Tipo de attachment de rede da VM migrada** (bridged/localnet vs pod-network+SNAT) — decide se encap/SNAT sequer entram. Confere no VMI spec / NNCP.
2. **O caminho DFS real da app** (`\\<dfs>\<namespace>\<app>`) — só pra a metade `capture-net-path` in-place, contra o DFS de produção (o share do lab não exercita DFS).
3. **O switch de origem no VMware: VDS/VSS (VLAN) ou NSX-T.** Metade do argumento ("o OpenShift adicionou hops de overlay") depende de a origem *não* ter overlay. Se a origem já era NSX-T (Geneve + SNAT), o contraste encolhe. Confirmar antes de cravar.

Camada 2 do IIS (site com content root em UNC vs disco local, medindo a página inteira com timing server-side) entra num próximo script (`setup-unc-site.ps1` + `measure-unc-ab.ps1`) assim que a Camada 1 confirmar o delta de caminho.

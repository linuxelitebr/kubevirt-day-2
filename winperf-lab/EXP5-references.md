# Exp 5: a espinha citada (fonte primária)

Base factual pra explicação ao cliente e pro futuro post. Cada afirmação foi verificada contra fonte primária (Microsoft Learn/[MS-SMB2], docs OpenShift/Red Hat, OVN-Kubernetes, RFC) e passou por um passo adversarial que derrubou números falsos (ver o fim). **A direção é certa e citável; a MAGNITUDE (3s->5s) é inferência e só fecha com medição** (é o que o Exp 5 faz).

## A. SMB é request/response serializado (latency-bound)

| Afirmação defensável | Número | Fonte |
|---|---|---|
| SMB 2/3 é protocolo stateful request/response: sessão + tree connect, depois requests discretos (CREATE, READ, QUERY_INFO, CLOSE), cada um respondido antes do próximo. | — | [MS-SMB2] Overview: learn.microsoft.com/openspecs/windows_protocols/ms-smb2/4287490c-602c-41c0-a23e-140a1f137832 |
| Ler UM arquivo pequeno = 3 round-trips serializados (open/CREATE, READ, CLOSE) = 6 mensagens. O CREATE já devolve timestamps e tamanho, então diga "open, read, close, mais eventuais metadata queries", não um QUERY_INFO fixo por arquivo. | 3 RTT = 6 msg; header SMB2 = 64 bytes | [MS-SMB2] Reading from a Remote File: learn.microsoft.com/openspecs/windows_protocols/ms-smb2/4801c3e5-dd73-4e1c-b2ba-8ebf73642227 |
| Microsoft documenta que cada op SMB é serializada (request, transmit, trabalho no FS, response antes da próxima), a latência por op domina, e throughput single-thread pode cair **abaixo de 1 MB/s**. | <1 MB/s single-thread | learn.microsoft.com/troubleshoot/windows-server/networking/slow-smb-file-transfer |
| "SMB de arquivo pequeno é latency-bound" é **inferência** sólida da contagem fixa de round-trips (mesma contagem independe da banda), não citação da Microsoft. | — | (inferência do [MS-SMB2]) |

## B. IIS servindo conteúdo de UNC/DFS

| Afirmação defensável | Número | Fonte |
|---|---|---|
| IIS cacheia conteúdo de file share e detecta mudança por 1 de 2 métodos: polling de last-modified ou File Change Notification (FCN); o objetivo declarado é **reduzir tráfego SMB de volta ao file server**, que é o concentrador de escala. | — | IIS 6.0 SMB Scaling: learn.microsoft.com/previous-versions/windows/it-pro/windows-server-2008-R2-and-2008/dd296655(v=ws.10) |
| IIS registra handlers FCN pra monitorar o share UNC. Usar como referência de MECANISMO (FCN sobre UNC), **não** como prova de defeito (a KB é sobre um bug específico do static file handler). | — | KB "slow performance ... IIS 7.5 virtual directory ... UNC share": support.microsoft.com/topic/...-53f8145d-da7f-5ec1-4494-cc7b0287a228 |
| SEPARADO (não confundir): IIS detecta mudança nos próprios arquivos de CONFIG num share via change notification ou polling; esse período de 3 min governa config, não latência de conteúdo por request. | enableUncPolling default false; pollingPeriod 00:03:00 | learn.microsoft.com/iis/configuration/configurationredirection |

## C. Custo de signing / encryption (signing é EXIGIDO no caso)

| Afirmação defensável | Número | Fonte |
|---|---|---|
| Signing assina/verifica cada pacote; esse trabalho por mensagem "consome CPU adicional do cliente"; o quanto "depende muito da capacidade do hardware". Custo inerente de integridade, não defeito. | — | learn.microsoft.com/troubleshoot/windows-server/networking/slow-smb-file-transfer |
| Signing é required por default desde Windows 11 24H2 / Windows Server 2025, e a Microsoft recomenda manter. Tratar como dado fixo, não como algo a negociar. | — | (mesma fonte acima) |
| Algoritmos: SMB 3.0/3.02 signing = AES-128-CMAC; 3.1.1 adicionou AES-128-GMAC. | — | learn.microsoft.com/windows-server/storage/file-server/smb-security |
| BOUNDARY: o fallback dramático de RDMA com signing/encryption (perde placement direto, teto de 1.394 bytes) é **só SMB Direct/RDMA**. O cliente roda SMB sobre TCP no OVN, então essa magnitude **não** se aplica aqui. Diga isso explicitamente. | teto 1.394 B (só RDMA) | learn.microsoft.com/troubleshoot/windows-server/networking/reduced-performance-after-smb-encryption-signing |

## D. Saltos do OVN-Kubernetes vs VMware

| Afirmação defensável | Número | Fonte |
|---|---|---|
| OVN-K monta overlay Geneve entre nodes; o OpenShift **reserva 100 bytes de MTU** (cluster MTU = menor MTU de hardware dos nodes menos 100). | 100 bytes (OpenShift SDN = 50) | cluster-network-operator README (github.com/openshift/cluster-network-operator) |
| PRECISÃO: os 100 bytes são a **folga reservada**, NÃO o tamanho do header Geneve. Geneve = header fixo de 8 bytes (8 a 260 total), UDP dst 6081. | Geneve 8 B (máx 260); UDP 6081 | RFC 8926: datatracker.ietf.org/doc/html/rfc8926 |
| O datapath OVN adiciona hops de processamento: br-int, ovn_cluster_router distribuído, join switch, gateway router por node (que faz **SNAT** do pod IP pro node IP), e br-ex, com encap/decap Geneve em cada hop inter-node. | — | ovn-kubernetes topology.md; docs.redhat.com OCP 4.18 ovn-kubernetes-architecture |
| CONTRASTE (escopo): um vSphere Standard/Distributed Switch em VLAN faz L2-forward do VMXNET3 sem overlay, sem router distribuído/gateway, sem SNAT do próprio endereço da VM. **SE a origem rodava NSX-T**, o VMware TAMBÉM usava Geneve (TEP + tier-0/tier-1 + SNAT) e o contraste encolhe. Confirmar qual. | — | (ver "perguntas em aberto") |

## E. Binding KubeVirt: qual caminho preserva a identidade L2

| Afirmação defensável | Número | Fonte |
|---|---|---|
| Pod network default + masquerade: KubeVirt "aloca IPs internos e os esconde atrás de NAT", "todo tráfego que sai é source-NAT'ed com o IP do pod". NAS/AD veem a identidade do pod/node, **não** a da VM. | — | kubevirt.io/user-guide/network/interfaces_and_networks |
| Bridged/localnet (rede secundária) preserva a identidade L2: no bridge binding "o MAC do pod é delegado à VM"; localnet "conecta ao underlay físico", IPAM Disabled, endereços da própria sub-rede do NAS/AD. Aí reverse DNS, acesso SMB por host, regras de firewall e mapeamento subnet->site do AD resolvem pro endereço real da VM. **Esse é o fix honesto.** | ipam.mode: Disabled (exigido pra VM) | docs.okd.io/latest/virt/vm_networking/virt-connecting-vm-to-secondary-udn |

## F. Por que TCP a granel esconde hops e SMB chatty não

| Afirmação defensável | Número | Fonte |
|---|---|---|
| TCP a granel é bandwidth-bound: throughput = janela/RTT; janela >= BDP mantém o cano cheio, roda na banda do gargalo quase independente do RTT. Poucos hops extras são absorvidos pela janela. | throughput = RWND×8/RTT; BDP = RTT×BB | RFC 6349: rfc-editor.org/rfc/rfc6349.html |
| Request/response serializado é latency-bound: a conexão fica ociosa um RTT por turno, total ≈ N × RTT, e banda nenhuma tira isso. | total ≈ N × RTT | (raciocínio, ancorado nas fontes) |
| Hops extras somam linearmente: cada hop adiciona um incremento fixo ao atraso de uma via, pago em **todo** round-trip num fluxo latency-bound. | d = Q × (proc+trans+prop) | (fonte de delay em redes) |
| "Latency, not bandwidth, is the performance bottleneck for most websites" (verificado na página). O exemplo "90 RTT × 50 ms = 4,5 s" é **aritmética nossa**, não citação. | 90 × 50 ms = 4,5 s (nossa conta) | hpbn.co/primer-on-latency-and-bandwidth |

## G. Distância de referral DFS (contribuinte opcional, com escopo)

| Afirmação defensável | Número | Fonte |
|---|---|---|
| Um referral lista targets in-site primeiro; os out-of-site são ordenados por método: Random, Lowest cost (EnableSiteCosting) ou Exclude/INSITE. | — | learn.microsoft.com/windows-server/storage/dfs-namespaces/set-the-ordering-method-for-targets-in-referrals |
| O DFS mapeia a máquina pro site pelo **IP de origem** do request de referral (subnet->site no AD). IP em sub-rede não mapeada -> o DFS não obtém o site -> a ordenação por site degrada. | cache de referral raiz TTL default 15 min | learn.microsoft.com/troubleshoot/windows-server/networking/dfsn-access-failures |
| ESCOPO: o DFS só muda QUAL target é escolhido, e só importa com **múltiplos targets cross-site**. Com um único target UNC/DFS, a lentidão é comprimento de caminho + chattiness SMB contra o concentrador, não DFS. Verificar com `dfsutil /sitename:<ip_cliente>` antes de atribuir ao DFS. | — | learn.microsoft.com/windows-server/storage/dfs-namespaces/set-target-priority-to-override-referral-ordering |

---

## Números que NÃO devem ser citados como fonte (o passo adversarial derrubou)

- **"até 15% para SMB signing"** — não existe em fonte primária Microsoft. Os 10-15% são de **ENCRYPTION**, lado storage, só Azure NetApp Files.
- **"não há acelerador de hardware pra signing, ao contrário de IPsec"** — não está em nenhuma página Microsoft. Cortar ou marcar como raciocínio.
- **875 -> ~250 MiB/s (~71%) com signing** — número real, mas é **UMA** plataforma / **UM** teste (Azure NetApp Files, conexão única sem multichannel, leitura sequencial 64 KiB, signing preso no Core 0). Não apresentar como a penalidade esperada do cliente.
- Nenhuma fonte primária dá latência por-operação em ms pra SMB nem delta por-hop pro OVN. A magnitude é específica do ambiente e **tem que ser medida**.

## Perguntas em aberto que as citações levantaram

1. **A magnitude só fecha com medição.** Todo mecanismo é citável e a direção é certa, mas o salto "cada op um pouco mais lenta" -> "3s virou 5s" é inferência. É exatamente o que `bench-smb.ps1` + `capture-net-path.ps1` quantizam.
2. **O VMware de origem era VLAN (VDS/VSS) ou NSX-T?** O contraste "o OpenShift adicionou hops de overlay" é load-bearing pra metade do argumento (comprimento de caminho). Se a origem já era NSX-T (que também usa Geneve + SNAT), esse contraste encolhe muito. **Confirmar antes de cravar.**

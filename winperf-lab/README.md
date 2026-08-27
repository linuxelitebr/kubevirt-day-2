# winperf-lab: medir performance de VM Windows/IIS migrada no OpenShift Virtualization

Kit reprodutível para provar, com número, **onde** está a lentidão de uma app IIS numa VM migrada, sem usar nada que quebre live migration (nada de CPU pinning, dedicated CPUs ou host-passthrough).

---

## A hipótese (o modelo a refutar)

A queixa era "a primeira resposta da URL passou de 3s pra 5s depois de migrar". O teste natural do cliente (voltar uma VM pro VMware fez as **duas** caírem pra 3s, inclusive a que ficou no OpenShift) decompõe o número assim:

| Componente | Causa | Onde se resolve | Experimento |
|---|---|---|---|
| **3s (piso)** | cold-start da app (JIT + priming do IIS) | dentro do Windows (App Init) | **Exp 4** |
| **+2s** | contenção entre 2 VMs grandes co-locadas (overcommit de vCPU) | placement / requests | **Exp 2, 3** |
| (ruído) | host-passthrough setado na mão | trocar por host-model | **Exp 1** |

**Predição falsificável (declare ANTES de medir):** os enlightenments mexem em idle-CPU e jitter, **não** em throughput; a contenção some com anti-affinity; o piso de 3s só cai com warm-up de IIS; host-passthrough **empata** com host-model em performance mas **arrisca** a migração.

---

## Topologia e pré-requisitos

- 1 cluster OpenShift Virtualization (ou KubeVirt) com **>= 2 nodes** (Exp 2 precisa separar VMs).
- Um **golden image Windows Server** (PVC) com **virtio-win já instalado**. O kit não fornece Windows.
- `oc` com acesso ao namespace de teste; `virtctl` para restart/migrate.
- Copiar a pasta `app/` e `scripts/` para dentro da VM Windows (via RDP/console/`virtctl` scp).

**Dimensionamento** (a contenção é vCPU vs cores **físicos**, não RAM, então dá pra reproduzir sem os 96GB):
- **Lab pequeno:** `cores` = nº de cores físicos do node. Duas VMs = 2x overcommit = reproduz o +2s.
- **Lab do cliente:** `cores: 16`, `memory.guest: 96Gi` (repro fiel).

---

## Setup (uma vez)

1. Crie 2 VMs a partir de `vms/vm-app.yaml` (uma `winperf-a`, outra `winperf-b`; ajuste `source.pvc`, `cores`, `memory`, firmware). As duas com `labels.app: winperf`.
   ```bash
   oc apply -f vms/vm-app.yaml -n <ns>     # winperf-a
   # edite name/domain para winperf-b e aplique de novo
   ```
2. Dentro de cada VM (PowerShell como Administrador), publique a app e comece com warm-up OFF:
   ```powershell
   .\scripts\setup-iis.ps1 -AppSource .\app -Warmup off
   ```
3. Sanidade: `curl http://localhost:8080/Default.aspx` deve responder `OK ...`. Calibre `WarmupIterations` no `web.config` até o cold-start dar ~2-4s numa VM ociosa.

---

## Os 4 experimentos

Regra de ouro em todos: **um reboot = uma variável**; mesmo node (a não ser Exp 2), guest quiesced (Windows Update/Defender/tarefas OFF), **>= 6 rodadas, descarta a run 1**, reporta **mediana + IQR**.

### Exp 1: CPU model: host-passthrough vs host-model
Mede se passthrough compra algo (esperado: não) e o que faz com a migração (esperado: vira risco).
```bash
# estado do cliente (arriscado):
oc patch vm winperf-a -n <ns> --type merge -p '{"spec":{"template":{"spec":{"domain":{"cpu":{"model":"host-passthrough"}}}}}}'
virtctl restart winperf-a -n <ns>
# ... rode measure-ttfb (Stage=cpu-passthrough) + collect-perfmon ...
oc get vmi winperf-a -n <ns> -o jsonpath='{range .status.conditions[?(@.type=="LiveMigratable")]}{.status} {.reason}{"\n"}{end}'
virtctl migrate winperf-a -n <ns>   # tente migrar; observe se restringe/falha em node de CPU diferente

# a correção:
oc patch vm winperf-a -n <ns> --type merge -p '{"spec":{"template":{"spec":{"domain":{"cpu":{"model":"host-model"}}}}}}'
virtctl restart winperf-a -n <ns>
# ... rode measure-ttfb (Stage=cpu-hostmodel) ...
```
**Predição:** TTFB/CPU empatam; passthrough só migra entre CPUs idênticas (num cluster heterogêneo, quebra).

### Exp 2: Contenção: 2 VMs co-locadas vs separadas (o achado principal)
```bash
# ARM A (contendido): fixe as duas no MESMO node
oc patch vm winperf-a -n <ns> --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<node1>"}}}}}'
oc patch vm winperf-b -n <ns> --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<node1>"}}}}}'
virtctl restart winperf-a -n <ns>; virtctl restart winperf-b -n <ns>
# meça winperf-a com winperf-b OCIOSA, depois com winperf-b em cold-start SIMULTANEO
# (dispare o measure-ttfb nas duas ao mesmo tempo -> reproduz a rajada)

# ARM B (isolado): separe as duas (anti-affinity OU nodeSelector distinto)
oc patch vm winperf-b -n <ns> --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<node2>"}}}}}'
virtctl restart winperf-b -n <ns>
# meça winperf-a de novo
```
Anti-affinity declarativa (alternativa ao nodeSelector), para o material final:
```bash
oc patch vm winperf-a -n <ns> --type merge -p '{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["winperf"]}]},"topologyKey":"kubernetes.io/hostname"}]}}}}}}'
```
**Predição:** co-locadas + rajada simultânea = +2s no TTFB; separadas = volta ao piso. É a reprodução do teste do cliente.

### Exp 3: Overcommit: `resources: {}` vs `requests.cpu`
```bash
# reserva cores de verdade (N = cores da VM); o scheduler para de empilhar as duas
oc patch vm winperf-a -n <ns> --type merge -p '{"spec":{"template":{"spec":{"domain":{"resources":{"requests":{"cpu":"4"}}}}}}}'
oc patch vm winperf-b -n <ns> --type merge -p '{"spec":{"template":{"spec":{"domain":{"resources":{"requests":{"cpu":"4"}}}}}}}'
virtctl restart winperf-a -n <ns>; virtctl restart winperf-b -n <ns>
oc get vmi -n <ns> -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName   # confirme que NAO co-locaram
```
**Predição:** com requests reais, as duas não cabem no mesmo node (ou não disputam), e o +2s some sem precisar de anti-affinity explícita. Mostra que a causa era o `resources: {}`.

### Exp 4: Warm-up de IIS: o piso de 3s
```powershell
# dentro da VM:
.\scripts\setup-iis.ps1 -Warmup on     # AlwaysRunning + preload + idle timeout 0
.\scripts\measure-ttfb.ps1 -Stage warmupON -Runs 6 -Out results.csv
.\scripts\setup-iis.ps1 -Warmup off
.\scripts\measure-ttfb.ps1 -Stage warmupOFF -Runs 6 -Out results.csv
```
**Predição:** com warm-up ON, o `cold` do measure-ttfb cai pra perto do `warm` (o App Init aqueceu antes do usuário). É o único lever que derruba o piso.

---

## Medir e ler

- **TTFB de cold-start:** `scripts/measure-ttfb.ps1` (recicla o pool, mede 1ª resposta + resposta quente, N rodadas, CSV).
- **Camada do gargalo (perfmon):** `scripts/collect-perfmon.ps1` numa janela ociosa (idle CPU) e sob carga.
  - `% User` alto + CPU alta ⇒ CPU-bound da app · `% Privileged/Interrupt/DPC` ⇒ interrupt/timer (enlightenments) · `Avg. Disk sec/Read > ~0.015` ⇒ disco · `Available MBytes` baixo + `Pages/sec` alto ⇒ memória.
- **Contenção do lado do host** (o guest Windows NÃO vê steal no perfmon):
  ```bash
  # vcpu wait/delay (proxy de steal) lido do host, via o pod launcher (domain = <ns>_<vm>):
  POD=$(oc get pod -n <ns> -l kubevirt.io/vm=winperf-a -o name | head -1)
  oc exec "$POD" -n <ns> -c compute -- virsh domstats --vcpu <ns>_winperf-a | grep -E 'vcpu|wait|delay'
  # e a pressao de CPU do node:
  oc adm top node <node>
  ```
  E o teste **wall-clock vs %CPU do guest**: se o TTFB é grande mas o `% Processor Time` do guest é modesto, o tempo sumiu em steal de um node lotado (problema de capacidade, não de tecla de VM).
- **Estatística:** `python3 scripts/analyze.py results.csv` → tabela mediana + IQR por stage (descarta run 1 automaticamente).

---

## Como concluir (tabela de decisão)

| Se o teste mostrar | Conclusão | Ação |
|---|---|---|
| TTFB igual passthrough vs host-model | passthrough é inútil e arriscado | host-model |
| +2s só quando co-locadas na rajada | era contenção, hipervisor inocente | anti-affinity + requests.cpu |
| warmupON derruba o cold | os 3s eram cold-start da app | App Init (lado Windows) |
| `% User` alto no perfmon durante a lentidão | é código da app | não é curável por VM; devolve pro cliente com dado |
| wall-clock ≫ %CPU do guest | steal / node lotado | capacidade/placement, não tuning |

---

## Higiene de publicação

Reporte os **negativos** com o mesmo destaque dos positivos (é o ponto do post, na linha do Part 1). Fixe versões (KubeVirt/OpenShift Virt, virtio-win, MTV) porque defaults mudam. Apresente qualquer "~1000x" de .NET Console como observação anedótica de ordem de grandeza (não há número primário da Microsoft para `WindowWidth`). E scrub todo identificador de cliente antes de qualquer coisa pública.

#!/usr/bin/env bash
#
# vm-runstrategy.sh
#
# Migra spec.runStrategy Always -> RerunOnFailure apenas em VMs ligadas.
#
# Modos:
#   sem parametros           AUDITORIA. Somente leitura. Emite o plano.
#   --apply --plan DIR       Aplica o plano, revalidando cada VM contra o
#                            estado registrado na auditoria.
#
# Alvos:
#   (default)                o cluster da sessao oc corrente (standalone)
#   --hosted-clusters        a partir de um hosting cluster (HCP): o proprio
#                            hosting cluster e cada HostedCluster disponivel
#   --hosted NS/NOME         a partir de um hosting cluster: so um HostedCluster
#   --skip-hosting           com --hosted-clusters, nao audita o hosting cluster
#
# O apply nunca opera a partir do estado corrente do cluster. Ele opera a
# partir do plano, e recusa qualquer VM cujo estado tenha mudado desde a
# auditoria.
#
# As VMs que sao workers de hosted clusters (namespaces de control plane do
# HCP) nunca entram no plano: quem cuida delas e a NodePool.
#
set -uo pipefail

CONTEXT=""; NAMESPACE=""; PLAN=""; APPLY=false; ONLY=""
INCLUDE_NOT_RUNNING=false
OUTDIR=""
CAMPAIGN="./runstrategy-campaign.log"
HOSTED_ALL=false; HOSTED_ONE=""; SKIP_HOSTING=false

usage() {
  cat <<EOF
AUDITORIA (default, somente leitura):
  $0 [--context CTX] [--namespace NS] [--only ns/nome] [--include-not-running] [--outdir DIR]
  $0 --hosted-clusters [--skip-hosting] [--namespace NS] [--include-not-running] [--outdir DIR]
  $0 --hosted NS/NOME [--namespace NS] [--only ns/nome] [--include-not-running] [--outdir DIR]

APLICACAO:
  $0 --apply --plan DIR [--only ns/nome] [--context CTX]

  --context CTX          contexto oc
  --namespace NS         restringe a um namespace (em cada cluster)
  --only ns/nome         restringe os elegiveis a um unico VM (canario)
  --include-not-running  promove a elegivel VMs Always fora de Running
  --outdir DIR           diretorio da auditoria
                         (default: ./runstrategy-<cluster>-<timestamp>)
  --plan DIR             diretorio de auditoria a aplicar
  --hosted-clusters      roda no hosting cluster e em cada HostedCluster
  --hosted NS/NOME       roda so no HostedCluster NS/NOME
  --skip-hosting         com --hosted-clusters, pula o proprio hosting cluster

Opera sobre a sessao oc corrente. Para hosted clusters, faca oc login no
hosting cluster: o script le o kubeconfig de admin de cada HostedCluster
(status.kubeconfig) e usa uma copia temporaria, apagada ao sair. Nenhuma
credencial e gravada no plano: o --apply busca o kubeconfig de novo.

O plano fica amarrado ao cluster em que foi auditado e o --apply recusa
aplica-lo em outro. A auditoria salva o YAML integral de cada VM elegivel
em DIR/backup/. Cada execucao registra uma linha em ./runstrategy-campaign.log.

ROLLBACK:
  Cada --apply gera DIR/rollback.sh (numa campanha, um por cluster em
  DIR/<cluster>/rollback.sh). O de um hosted cluster roda com a sessao oc
  no HOSTING cluster: ele busca o kubeconfig do hosted sozinho, como o --apply.
  O de um cluster standalone roda com a sessao oc nesse cluster.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --plan) PLAN="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --include-not-running) INCLUDE_NOT_RUNNING=true; shift ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --hosted-clusters) HOSTED_ALL=true; shift ;;
    --hosted) HOSTED_ONE="$2"; shift 2 ;;
    --skip-hosting) SKIP_HOSTING=true; shift ;;
    -h|--help) usage ;;
    *) echo "opcao desconhecida: $1" >&2; usage ;;
  esac
done

command -v jq >/dev/null || { echo "jq nao encontrado" >&2; exit 1; }
SCOPE=(-A); [[ -n "$NAMESPACE" ]] && SCOPE=(-n "$NAMESPACE")

# sessao base: o cluster onde o usuario fez login (standalone ou hosting)
BASE_OC=(oc); [[ -n "$CONTEXT" ]] && BASE_OC+=(--context "$CONTEXT")
OC=("${BASE_OC[@]}")

TMPKC=$(mktemp -d "${TMPDIR:-/tmp}/runstrategy-kc.XXXXXX")
chmod 700 "$TMPKC"
trap 'rm -rf "$TMPKC"' EXIT

# epoch de um timestamp UTC ISO-8601, em GNU date e em BSD date (macOS)
to_epoch() {
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || echo 0
}

cluster_id() {
  local id
  id=$("${OC[@]}" get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)
  if [[ -z "$id" ]]; then
    id=$("${OC[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
         | sed -e 's#https\?://##' -e 's#^api\.##' -e 's#:[0-9]*$##' -e 's#[^A-Za-z0-9._-]#-#g')
  fi
  echo "${id:-desconhecido}"
}

# O cluster tem OpenShift Virtualization / KubeVirt?
has_kubevirt() {
  "${OC[@]}" get crd virtualmachines.kubevirt.io >/dev/null 2>&1
}

# Namespaces de control plane de HCP no cluster corrente (onde moram as VMs
# dos workers dos hosted clusters). Lista JSON, vazia se nao for hosting.
hcp_namespaces() {
  "${OC[@]}" get hostedcluster -A -o json 2>/dev/null \
    | jq -c '[.items[] | .metadata.namespace + "-" + .metadata.name]' 2>/dev/null \
    || echo '[]'
}

# Falha cedo e com mensagem clara em vez de resultado parcial.
preflight() {
  local verb="$1" who can
  who=$("${OC[@]}" whoami 2>&1) || {
    echo "ABORTADO: sessao oc invalida ou expirada." >&2
    echo "  $who" >&2
    echo "  Faca oc login no cluster desejado e rode de novo." >&2
    exit 1; }
  local scope=(-A); [[ -n "$NAMESPACE" ]] && scope=(-n "$NAMESPACE")
  can=$("${OC[@]}" auth can-i "$verb" virtualmachines.kubevirt.io "${scope[@]}" 2>/dev/null)
  if [[ "$can" != "yes" ]]; then
    echo "ABORTADO: usuario $who nao tem permissao de '$verb' em virtualmachines." >&2
    exit 1; fi
  echo "[*] usuario:  $who"
}

campaign() { printf '%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" >> "$CAMPAIGN"; }

# --------------------------------------------------------- HOSTED CLUSTERS
# Le o kubeconfig de admin de um HostedCluster (NS/NOME) a partir da sessao
# base e grava numa copia temporaria. Imprime o caminho.
fetch_hosted_kubeconfig() {
  local ref="$1" ns name secret kc
  ns="${ref%%/*}"; name="${ref##*/}"
  secret=$("${BASE_OC[@]}" get hostedcluster "$name" -n "$ns" \
             -o jsonpath='{.status.kubeconfig.name}' 2>/dev/null)
  [[ -z "$secret" ]] && return 1
  kc="$TMPKC/${ns}__${name}.kubeconfig"
  ( umask 077
    "${BASE_OC[@]}" get secret "$secret" -n "$ns" -o jsonpath='{.data.kubeconfig}' \
      | base64 -d > "$kc" ) 2>/dev/null || return 1
  [[ -s "$kc" ]] || return 1
  echo "$kc"
}

# HostedClusters a processar, um NS/NOME por linha. So os disponiveis.
list_hosted() {
  if [[ -n "$HOSTED_ONE" ]]; then
    echo "$HOSTED_ONE"; return
  fi
  "${BASE_OC[@]}" get hostedcluster -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(any(.status.conditions[]?; .type=="Available" and .status=="True"))
    | .metadata.namespace + "/" + .metadata.name'
}

# ---------------------------------------------------------------- AUDITORIA
audit() {
  echo "[*] AUDITORIA - somente leitura, nenhum objeto sera modificado"
  if ! has_kubevirt; then
    echo "[*] cluster sem OpenShift Virtualization (CRD virtualmachines.kubevirt.io ausente). Nada a fazer."
    return 0
  fi
  preflight list
  local ctx server cid hcpns
  ctx=$("${OC[@]}" config current-context 2>/dev/null)
  server=$("${OC[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  cid=$(cluster_id)
  hcpns=$(hcp_namespaces)
  echo "[*] cluster:  $cid"
  echo "[*] servidor: $server"
  [[ "$hcpns" != "[]" ]] && echo "[*] namespaces de control plane HCP (VMs de worker, excluidas): $(jq -r 'join(" ")' <<<"$hcpns")"
  [[ -z "$OUTDIR" ]] && OUTDIR="./runstrategy-${cid}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$OUTDIR"
  { echo "CONTEXT=$ctx"; echo "SERVER=$server"; echo "CLUSTER=$cid"
    echo "HOSTED_REF=${HOSTED_REF:-}"
    echo "AUDITED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$OUTDIR/origin.env"

  "${OC[@]}" get vm  "${SCOPE[@]}" -o json > "$OUTDIR/vms.json"  || exit 1
  "${OC[@]}" get vmi "${SCOPE[@]}" -o json > "$OUTDIR/vmis.json" || echo '{"items":[]}' > "$OUTDIR/vmis.json"

  echo "[*] VMs: $(jq '.items|length' "$OUTDIR/vms.json")   VMIs: $(jq '.items|length' "$OUTDIR/vmis.json")"

  jq -r --slurpfile v "$OUTDIR/vmis.json" \
        --argjson inr "$INCLUDE_NOT_RUNNING" \
        --argjson hcpns "$hcpns" '
    ( $v[0].items | map({key:(.metadata.namespace+"/"+.metadata.name),
                         value:{uid:.metadata.uid, phase:.status.phase}}) | from_entries) as $vmi
    | [ .items[]
      | . as $vm
      | (.spec.runStrategy // null) as $rs
      | (.spec.running // null) as $run
      | (.status.printableStatus // "Unknown") as $st
      | (.metadata.namespace+"/"+.metadata.name) as $ref
      | ([.metadata.ownerReferences[]?.kind] | unique) as $owners
      | ([.metadata.managedFields[]?.manager] | unique) as $mgrs
      | ($mgrs | map(select(test("argocd|gitops|policy|multicluster|klusterlet";"i")))) as $ctrl
      | (if $rs=="Always" then "runStrategy" elif $run==true then "running" else null end) as $field
      | select($field != null)
      | {
          namespace: .metadata.namespace,
          name: .metadata.name,
          field: $field,
          runStrategy: $rs,
          running: $run,
          status: $st,
          generation: .metadata.generation,
          vmiUid: ($vmi[$ref].uid // null),
          vmiPhase: ($vmi[$ref].phase // null),
          owners: $owners,
          managers: $mgrs,
          verdict: (
              if   ($hcpns | index($vm.metadata.namespace)) != null then "BLOCK:hcp-worker-vm"
              elif ($owners|length) > 0 then "BLOCK:owned-by-"+($owners|join("/"))
              elif ($ctrl|length)   > 0 then "BLOCK:managed-by-"+($ctrl|join("/"))
              elif ($st|test("^(Starting|Stopping|Terminating|Migrating|Provisioning|WaitingFor)")) then "BLOCK:transitional-"+$st
              elif $st=="Running"       then "ELIGIBLE"
              elif $inr and $st!="Stopped" then "ELIGIBLE"
              else "SKIP:"+$st end )
        } ]
  ' "$OUTDIR/vms.json" > "$OUTDIR/plan.json"

  jq -r --arg only "$ONLY" '.[] | select(.verdict=="ELIGIBLE")
         | select($only=="" or (.namespace+"/"+.name)==$only)
         | [.namespace,.name,.field,(.generation|tostring),(.vmiUid//"-")] | @tsv' \
    "$OUTDIR/plan.json" > "$OUTDIR/eligible.tsv"

  echo
  echo "[*] Veredito:"
  if [[ $(jq 'length' "$OUTDIR/plan.json") -eq 0 ]]; then
    echo "    nenhuma VM com runStrategy Always ou running: true"
  else
    jq -r '.[].verdict' "$OUTDIR/plan.json" | sort | uniq -c | sort -rn | sed 's/^/    /'
    echo
    echo "[*] Detalhe:"
    jq -r '.[] | [.verdict,(.namespace+"/"+.name),.status,(.managers|join(","))] | @tsv' \
      "$OUTDIR/plan.json" | sort | column -t -s$'\t' | sed 's/^/    /'
  fi

  N=$(wc -l < "$OUTDIR/eligible.tsv" | tr -d ' ')
  echo
  [[ -n "$ONLY" ]] && echo "[*] filtro --only=$ONLY aplicado aos elegiveis"
  echo "[*] Elegiveis: $N"

  if [[ "$N" -gt 0 ]]; then
    mkdir -p "$OUTDIR/backup"
    while IFS=$'\t' read -r ns name _; do
      [[ -z "$ns" ]] && continue
      "${OC[@]}" get vm "$name" -n "$ns" -o yaml > "$OUTDIR/backup/${ns}__${name}.yaml"
      "${OC[@]}" get vm "$name" -n "$ns" -o json \
        | jq 'del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid,
                  .metadata.creationTimestamp, .metadata.generation, .metadata.selfLink,
                  .status, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
        > "$OUTDIR/backup/${ns}__${name}.clean.json"
    done < "$OUTDIR/eligible.tsv"
    echo "[*] YAML integral salvo em $OUTDIR/backup/ ($(ls -1 "$OUTDIR/backup"/*.yaml 2>/dev/null | wc -l | tr -d ' ') objetos)"
    echo "[*] O backup e registro forense. O rollback real e o patch inverso em rollback.sh,"
    echo "    nao reaplicar o YAML: recriar um VM destroi o VMI."
  fi

  campaign AUDIT "$cid" \
    "elegiveis=$N block=$(jq '[.[].verdict|select(startswith("BLOCK"))]|length' "$OUTDIR/plan.json") skip=$(jq '[.[].verdict|select(startswith("SKIP"))]|length' "$OUTDIR/plan.json")" \
    "$OUTDIR"
  echo "[*] Plano em:  $OUTDIR"
}

# ---------------------------------------------------------------- APLICACAO
apply_plan() {
  [[ -z "$PLAN" ]] && { echo "--apply exige --plan DIR" >&2; exit 1; }
  [[ -f "$PLAN/eligible.tsv" ]] || { echo "plano invalido: $PLAN/eligible.tsv ausente" >&2; exit 1; }
  [[ -f "$PLAN/origin.env" ]]   || { echo "plano invalido: $PLAN/origin.env ausente" >&2; exit 1; }

  # o plano so pode ser aplicado no cluster em que foi auditado
  local P_SERVER P_CTX P_AT NOW_SERVER
  P_SERVER=$(grep -m1 '^SERVER='     "$PLAN/origin.env" | cut -d= -f2-)
  P_CTX=$(grep    -m1 '^CONTEXT='    "$PLAN/origin.env" | cut -d= -f2-)
  P_AT=$(grep     -m1 '^AUDITED_AT=' "$PLAN/origin.env" | cut -d= -f2-)
  preflight patch
  NOW_SERVER=$("${OC[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)

  if [[ "$P_SERVER" != "$NOW_SERVER" ]]; then
    echo "ABORTADO: o plano foi auditado em outro cluster." >&2
    echo "  plano: $P_SERVER  (contexto $P_CTX)" >&2
    echo "  atual: $NOW_SERVER" >&2
    exit 1
  fi

  local age=$(( $(date -u +%s) - $(to_epoch "$P_AT") ))
  if [[ $age -gt 1800 ]]; then
    echo "[!] AVISO: plano auditado ha $((age/60)) minutos ($P_AT)."
    echo "[!] O estado do cluster muda. Considere reauditar antes de aplicar."
  fi

  local LOG="$PLAN/result.csv" RB="$PLAN/rollback.sh"
  echo "namespace,name,field,outcome,detail" > "$LOG"
  local P_HOSTED
  P_HOSTED=$(grep -m1 '^HOSTED_REF=' "$PLAN/origin.env" | cut -d= -f2-)
  if [[ -n "$P_HOSTED" ]]; then
    # rollback de hosted cluster: roda com a sessao oc no hosting cluster e
    # busca o kubeconfig de admin do HostedCluster na hora, como o --apply
    cat > "$RB" <<RBEOF
#!/usr/bin/env bash
# Rollback do hosted cluster $P_HOSTED ($NOW_SERVER).
# Rode com a sessao oc no HOSTING cluster: o kubeconfig do hosted e buscado aqui.
set -euo pipefail
KC=\$(mktemp "\${TMPDIR:-/tmp}/runstrategy-rb.XXXXXX"); trap 'rm -f "\$KC"' EXIT
SECRET=\$(oc get hostedcluster ${P_HOSTED##*/} -n ${P_HOSTED%%/*} -o jsonpath='{.status.kubeconfig.name}')
oc get secret "\$SECRET" -n ${P_HOSTED%%/*} -o jsonpath='{.data.kubeconfig}' | base64 -d > "\$KC"
[[ "\$(oc --kubeconfig "\$KC" config view --minify -o jsonpath='{.clusters[0].cluster.server}')" == "$NOW_SERVER" ]] \\
  || { echo "ABORTADO: o kubeconfig obtido nao aponta para $NOW_SERVER" >&2; exit 1; }
OC=(oc --kubeconfig "\$KC")
RBEOF
  else
    { echo "#!/usr/bin/env bash"; echo "set -e"
      echo "# rode com a sessao oc apontando para: $NOW_SERVER"
      echo 'OC=(oc)'; } > "$RB"
  fi
  chmod +x "$RB"

  local OK=0 SKIP=0 FAIL=0
  echo "[*] APLICANDO plano $PLAN"
  echo "[*] cluster: $(grep -m1 '^CLUSTER=' "$PLAN/origin.env" | cut -d= -f2-)  ($NOW_SERVER)"

  while IFS=$'\t' read -r ns name field gen uid; do
    [[ -z "$ns" ]] && continue
    [[ -n "$ONLY" && "$ns/$name" != "$ONLY" ]] && continue
    local cur
    cur=$("${OC[@]}" get vm "$name" -n "$ns" -o json 2>/dev/null)
    if [[ -z "$cur" ]]; then
      echo "$ns,$name,$field,SKIP,vm-ausente" >> "$LOG"; SKIP=$((SKIP+1))
      printf '[SKIP] %s/%s vm nao existe mais\n' "$ns" "$name"; continue
    fi

    # revalidacao contra o estado auditado
    local now_gen now_rs now_run now_st drift=""
    now_gen=$(jq -r '.metadata.generation' <<<"$cur")
    now_rs=$(jq -r '.spec.runStrategy // "-"' <<<"$cur")
    now_run=$(jq -r '.spec.running // "-"'   <<<"$cur")
    now_st=$(jq -r '.status.printableStatus // "-"' <<<"$cur")

    [[ "$now_gen" != "$gen" ]] && drift="generation $gen->$now_gen"
    [[ "$field" == "runStrategy" && "$now_rs"  != "Always" ]] && drift="${drift:+$drift; }runStrategy=$now_rs"
    [[ "$field" == "running"     && "$now_run" != "true"   ]] && drift="${drift:+$drift; }running=$now_run"
    [[ "$now_st" != "Running" ]] && drift="${drift:+$drift; }status=$now_st"

    if [[ -n "$drift" ]]; then
      echo "$ns,$name,$field,SKIP,\"$drift\"" >> "$LOG"; SKIP=$((SKIP+1))
      printf '[SKIP] %s/%s desviou do plano: %s\n' "$ns" "$name" "$drift"; continue
    fi

    local out rc
    if [[ "$field" == "runStrategy" ]]; then
      out=$("${OC[@]}" patch vm "$name" -n "$ns" --type=merge \
            -p '{"spec":{"runStrategy":"RerunOnFailure"}}' 2>&1); rc=$?
    else
      out=$("${OC[@]}" patch vm "$name" -n "$ns" --type=json \
            -p '[{"op":"remove","path":"/spec/running"},
                 {"op":"add","path":"/spec/runStrategy","value":"RerunOnFailure"}]' 2>&1); rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
      echo "$ns,$name,$field,FAIL,\"${out//\"/}\"" >> "$LOG"; FAIL=$((FAIL+1))
      printf '[FAIL] %s/%s %s\n' "$ns" "$name" "$out" >&2; continue
    fi

    local after uid_after
    after=$("${OC[@]}" get vm  "$name" -n "$ns" -o jsonpath='{.spec.runStrategy}' 2>/dev/null)
    uid_after=$("${OC[@]}" get vmi "$name" -n "$ns" -o jsonpath='{.metadata.uid}' 2>/dev/null)

    if [[ "$after" != "RerunOnFailure" ]]; then
      echo "$ns,$name,$field,FAIL,runStrategy=$after" >> "$LOG"; FAIL=$((FAIL+1))
      printf '[FAIL] %s/%s runStrategy=%s\n' "$ns" "$name" "$after" >&2; continue
    fi
    if [[ "$uid" != "-" && "$uid_after" != "$uid" ]]; then
      echo "$ns,$name,$field,OK,\"vmi recriado $uid -> $uid_after\"" >> "$LOG"
      printf '[WARN] %s/%s patch ok porem VMI FOI RECRIADO\n' "$ns" "$name" >&2
    else
      echo "$ns,$name,$field,OK,vmi-preservado" >> "$LOG"
      printf '[OK]   %s/%s\n' "$ns" "$name"
    fi
    OK=$((OK+1))

    if [[ "$field" == "runStrategy" ]]; then
      echo "\"\${OC[@]}\" patch vm $name -n $ns --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >> "$RB"
    else
      echo "\"\${OC[@]}\" patch vm $name -n $ns --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/runStrategy\"},{\"op\":\"add\",\"path\":\"/spec/running\",\"value\":true}]'" >> "$RB"
    fi
  done < "$PLAN/eligible.tsv"

  echo
  echo "[*] OK=$OK  SKIP=$SKIP  FAIL=$FAIL"
  campaign APPLY "$(grep -m1 '^CLUSTER=' "$PLAN/origin.env" | cut -d= -f2-)" \
    "ok=$OK skip=$SKIP fail=$FAIL" "$PLAN"
  echo "[*] Log: $LOG"
  echo "[*] Rollback: $RB"
  [[ $FAIL -eq 0 ]]
}

# --------------------------------------------------------------- MULTI-CLUSTER
# Auditoria em varios clusters: um subdiretorio de plano por cluster e um
# clusters.tsv (subdir, tipo, HostedCluster) na raiz da campanha.
audit_multi() {
  local root="${OUTDIR:-./runstrategy-campaign-$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$root"; : > "$root/clusters.tsv"
  "${BASE_OC[@]}" whoami >/dev/null 2>&1 || {
    echo "ABORTADO: sessao oc invalida. Faca oc login no hosting cluster." >&2; exit 1; }
  "${BASE_OC[@]}" get crd hostedclusters.hypershift.openshift.io >/dev/null 2>&1 || {
    echo "ABORTADO: a sessao corrente nao e um hosting cluster (sem CRD HostedCluster)." >&2
    echo "  Para um cluster standalone, rode sem --hosted-clusters/--hosted." >&2; exit 1; }

  if $HOSTED_ALL && ! $SKIP_HOSTING; then
    echo "================ hosting cluster"
    OC=("${BASE_OC[@]}"); HOSTED_REF=""; OUTDIR="$root/hosting"
    audit && printf 'hosting\thosting\t-\n' >> "$root/clusters.tsv"
    echo
  fi

  local refs ref kc sub
  refs=$(list_hosted)
  [[ -z "$refs" ]] && echo "[*] nenhum HostedCluster disponivel encontrado"
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    echo "================ hosted cluster $ref"
    if ! kc=$(fetch_hosted_kubeconfig "$ref"); then
      echo "[!] nao foi possivel obter o kubeconfig de $ref (status.kubeconfig vazio ou sem acesso ao Secret). Pulando."
      echo; continue
    fi
    sub="hosted__${ref//\//__}"
    OC=(oc --kubeconfig "$kc"); HOSTED_REF="$ref"; OUTDIR="$root/$sub"
    audit && printf '%s\thosted\t%s\n' "$sub" "$ref" >> "$root/clusters.tsv"
    echo
  done <<< "$refs"

  echo "================ resumo"
  local total=0 n
  while IFS=$'\t' read -r sub kind ref; do
    [[ -f "$root/$sub/eligible.tsv" ]] || continue
    n=$(wc -l < "$root/$sub/eligible.tsv" | tr -d ' '); total=$((total+n))
    [[ "$ref" == "-" ]] && ref=""
    printf '    %-40s elegiveis: %s\n' "$sub${ref:+ ($ref)}" "$n"
  done < "$root/clusters.tsv"
  echo "[*] Elegiveis no total: $total"
  echo "[*] Campanha em: $root"
  [[ $total -gt 0 ]] && echo "[*] Para aplicar: $0 --apply --plan $root"
  return 0
}

apply_multi() {
  local root="$PLAN" rc=0 sub kind ref kc
  "${BASE_OC[@]}" whoami >/dev/null 2>&1 || {
    echo "ABORTADO: sessao oc invalida. Faca oc login no hosting cluster da auditoria." >&2; exit 1; }
  while IFS=$'\t' read -r sub kind ref; do
    [[ -z "$sub" ]] && continue
    [[ -f "$root/$sub/eligible.tsv" ]] || continue
    if [[ ! -s "$root/$sub/eligible.tsv" ]]; then
      echo "[*] $sub: nenhum elegivel, nada a aplicar"; continue
    fi
    [[ "$ref" == "-" ]] && ref=""
    echo "================ $sub${ref:+ ($ref)}"
    if [[ "$kind" == "hosted" ]]; then
      if ! kc=$(fetch_hosted_kubeconfig "$ref"); then
        echo "[!] nao foi possivel obter o kubeconfig de $ref. Pulando." >&2; rc=1; continue
      fi
      OC=(oc --kubeconfig "$kc")
    else
      OC=("${BASE_OC[@]}")
    fi
    PLAN="$root/$sub"
    apply_plan || rc=1
    echo
  done < "$root/clusters.tsv"
  return $rc
}

# -------------------------------------------------------------------- MAIN
HOSTED_REF=""
if $APPLY; then
  if [[ -n "$PLAN" && -f "$PLAN/clusters.tsv" ]]; then apply_multi; else apply_plan; fi
elif $HOSTED_ALL || [[ -n "$HOSTED_ONE" ]]; then
  [[ -n "$ONLY" && "$HOSTED_ALL" == true ]] && {
    echo "--only nao combina com --hosted-clusters; use --hosted NS/NOME --only ns/vm" >&2; exit 1; }
  audit_multi
else
  audit
  [[ -s "${OUTDIR}/eligible.tsv" ]] && echo "[*] Para aplicar: $0 --apply --plan $OUTDIR"
  exit 0
fi

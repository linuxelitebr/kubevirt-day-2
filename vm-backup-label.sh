#!/usr/bin/env bash
#
# vm-backup-label.sh
#
# Audita e opcionalmente propaga o label de backup das VirtualMachines para os
# PVCs que servem de disco a elas (OpenShift Virtualization + NetBackup).
#
# Fonte da verdade: o label da VM. O script NUNCA inventa valor: VM sem o label
# e reportada como VM_UNLABELED e ignorada na correcao.
#
# Nao destrutivo por construcao:
#   - default e dry-run
#   - a unica escrita e "oc label", que emite um merge patch restrito a
#     metadata.labels; nenhum outro campo do objeto e tocado
#   - com --fix, grava snapshot pre-mudanca e script de undo
#
# Requisitos: oc, jq
#
set -euo pipefail

LABEL_KEY="Backup"
LABEL_VALUE="Com-Backup"
MODE="inherit"            # inherit = valor vem da VM | fixed = usa --value
NAMESPACE=""
CONTEXT=""
VM_SELECTOR=""
VM_NAME=""
EXCLUDE_NS_RE=""
FIX=false
OVERWRITE_VALUE=false
LABEL_VMS=""
SKIP_DV=false
SKIP_PV=false
CSV_OUT=""
CLUSTER_OVERRIDE=""
WORKDIR=""
TS="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<EOF
Uso: $(basename "$0") [opcoes]

  --key KEY            Chave do label                  (default: ${LABEL_KEY})
  --value VAL          Valor, usado so em --mode fixed (default: ${LABEL_VALUE})
  --mode inherit|fixed inherit: PVC herda o valor do label da propria VM
                       fixed:   PVC recebe --value independente da VM
                                                       (default: ${MODE})
  -n, --namespace NS   Restringe a um namespace        (default: todos)
  --context CTX        Contexto do oc
  -l, --vm-selector S  Label selector nas VMs (ex: "Backup=Com-Backup")
  --vm NOME            Restringe a uma unica VM (piloto). Desliga a
                       verificacao inversa de PVC orfao.
  --exclude-ns REGEX   Ignora namespaces que casem com o regex
  --fix                Aplica os labels faltantes      (default: dry-run)
  --overwrite-value    Tambem corrige PVC/PV com valor divergente
  --label-vms VALOR    Rotula VMs que estao SEM o label, com VALOR.
                       So mexe em VM sem a chave; VM com valor explicito
                       (ex: Sem-Backup) nunca e alterada. Exige --fix.
                       Depois de rotular, o inventario de VMs e recoletado
                       e os discos dessas VMs entram na correcao.
  --skip-dv            Nao audita nem rotula a DataVolume
  --skip-pv            Nao rotula o PersistentVolume (so PVC)
  --csv ARQUIVO        Relatorio completo em CSV
  --cluster NOME       Forca o nome do cluster no relatorio. Sem isto o nome
                       vem do dominio de ingress, e so cai para o host da
                       API se esse lookup falhar.
  --workdir DIR        Onde gravar snapshot e undo
                       (default: ./vm-backup-label-<cluster>-<timestamp>)
  -h, --help           Esta ajuda
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)             LABEL_KEY="$2"; shift 2 ;;
    --value)           LABEL_VALUE="$2"; shift 2 ;;
    --mode)            MODE="$2"; shift 2 ;;
    -n|--namespace)    NAMESPACE="$2"; shift 2 ;;
    --context)         CONTEXT="$2"; shift 2 ;;
    -l|--vm-selector)  VM_SELECTOR="$2"; shift 2 ;;
    --vm)              VM_NAME="$2"; shift 2 ;;
    --exclude-ns)      EXCLUDE_NS_RE="$2"; shift 2 ;;
    --fix)             FIX=true; shift ;;
    --overwrite-value) OVERWRITE_VALUE=true; shift ;;
    --label-vms)       LABEL_VMS="$2"; shift 2 ;;
    --skip-dv)         SKIP_DV=true; shift ;;
    --skip-pv)         SKIP_PV=true; shift ;;
    --csv)             CSV_OUT="$2"; shift 2 ;;
    --cluster)         CLUSTER_OVERRIDE="$2"; shift 2 ;;
    --workdir)         WORKDIR="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Argumento desconhecido: $1" >&2; usage; exit 1 ;;
  esac
done

valid_label_value() {
  [[ "$1" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$ ]]
}
check_valor() {
  local flag="$1" v="$2"
  if [[ "$v" == *=* ]]; then
    echo "erro: ${flag} recebe SO o valor do label, nao chave=valor." >&2
    echo "      voce passou: ${flag} ${v}" >&2
    echo "      provavelmente queria: ${flag} ${v#*=}" >&2
    exit 1
  fi
  valid_label_value "$v" || {
    echo "erro: valor invalido para ${flag}: '${v}'" >&2
    echo "      alfanumerico nas pontas, ate 63 chars, permitido - _ . no meio" >&2
    exit 1
  }
}
[[ -z "$LABEL_VMS" ]]   || check_valor --label-vms "$LABEL_VMS"
[[ -z "$LABEL_VALUE" ]] || check_valor --value "$LABEL_VALUE"

VMERR=0
if [[ -n "$LABEL_VMS" && "$FIX" != true ]]; then
  echo "AVISO: --label-vms so aplica com --fix. Em dry-run apenas relata." >&2
fi
[[ "$MODE" == "inherit" || "$MODE" == "fixed" ]] || { echo "--mode invalido: $MODE" >&2; exit 1; }
command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq nao encontrado" >&2; exit 1; }

OC=(oc)
[[ -n "$CONTEXT" ]] && OC+=(--context "$CONTEXT")

# --- identificacao do cluster --------------------------------------------------
SERVER="$("${OC[@]}" whoami --show-server 2>/dev/null || true)"
WHO="$("${OC[@]}" whoami 2>/dev/null || true)"
[[ -n "$SERVER" ]] || { echo "nao autenticado (oc whoami falhou)" >&2; exit 1; }
# nome do cluster: override > dominio de ingress > host da API
CLUSTER="$CLUSTER_OVERRIDE"
if [[ -z "$CLUSTER" ]]; then
  DOMAIN="$("${OC[@]}" get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  CLUSTER="$(sed -E 's|^apps\.||' <<< "${DOMAIN:-}")"
fi
[[ -n "$CLUSTER" ]] || CLUSTER="$(sed -E 's|^https?://||; s|^api\.||; s|:[0-9]+$||' <<< "$SERVER")"
CLUSTER="${CLUSTER:-desconhecido}"
CLUSTER_SAN="$(tr -cd '[:alnum:]._-' <<< "$CLUSTER")"
[[ -n "$WORKDIR" ]] || WORKDIR="./vm-backup-label-${CLUSTER_SAN}-${TS}"

echo "=============================================================="
echo " Cluster : ${CLUSTER}"
echo " Server  : ${SERVER}"
echo " Usuario : ${WHO}"
echo " Modo    : $([[ "$FIX" == true ]] && echo "CORRECAO (--fix)" || echo "auditoria (dry-run)")"
echo "=============================================================="

if [[ -n "$NAMESPACE" ]]; then SCOPE=(-n "$NAMESPACE"); else SCOPE=(-A); fi

VMSEL=()
[[ -n "$VM_SELECTOR" ]] && VMSEL=(-l "$VM_SELECTOR")
VMSEL_EXP=(${VMSEL[@]+"${VMSEL[@]}"})

mkdir -p "$WORKDIR"
VMS_JSON="$WORKDIR/vms.json"
PVCS_JSON="$WORKDIR/pvcs-snapshot.json"
REPORT="$WORKDIR/report.tsv"
FIXLIST="$WORKDIR/fixlist.tsv"
UNDO="$WORKDIR/undo.sh"
PVS_JSON="$WORKDIR/pvs-snapshot.json"
DVS_JSON="$WORKDIR/dvs-snapshot.json"
RELCSV="$WORKDIR/relatorio.csv"
printf '%s\t%s\t%s\n' "$CLUSTER" "$SERVER" "$WHO" > "$WORKDIR/cluster.txt"

echo "== Coletando inventario =="
"${OC[@]}" get vm "${SCOPE[@]}" "${VMSEL_EXP[@]}" -o json > "$VMS_JSON"
"${OC[@]}" get pvc "${SCOPE[@]}" -o json > "$PVCS_JSON"
"${OC[@]}" get pv -o json > "$PVS_JSON"
if ! "${OC[@]}" get dv "${SCOPE[@]}" -o json > "$DVS_JSON" 2>/dev/null; then
  echo '{"items":[]}' > "$DVS_JSON"
  echo "AVISO: nao foi possivel listar DataVolumes. DV nao sera auditada." >&2
fi

VM_CLI=$("${OC[@]}" get vm "${SCOPE[@]}" "${VMSEL_EXP[@]}" --no-headers 2>/dev/null | wc -l)
VM_JSON=$(jq '.items | length' "$VMS_JSON")
if [[ "$VM_CLI" -ne "$VM_JSON" ]]; then
  echo "AVISO: coleta inconsistente (cli=${VM_CLI} json=${VM_JSON}). Repita." >&2
fi
echo "VMs: ${VM_JSON}  PVCs: $(jq '.items | length' "$PVCS_JSON")  PVs: $(jq '.items | length' "$PVS_JSON")"
echo "DataVolumes: $(jq '.items | length' "$DVS_JSON")"
echo "Snapshots pre-mudanca: ${PVCS_JSON} , ${PVS_JSON} , ${DVS_JSON}"

# --- distribuicao do label no nivel da VM -------------------------------------
echo
echo "== Label '${LABEL_KEY}' nas VMs =="
jq -r --arg key "$LABEL_KEY" --arg exre "$EXCLUDE_NS_RE" --arg vmn "$VM_NAME" '
  .items[]
  | select($vmn == "" or .metadata.name == $vmn)
  | select($exre == "" or (.metadata.namespace | test($exre) | not))
  | (.metadata.labels[$key] // "(ausente)")
' "$VMS_JSON" | sort | uniq -c | sort -rn | awk '{printf "  %-6s %s\n", $1, substr($0, index($0,$2))}'

# --- correlacao VM -> disco -> PVC -> PV ---------------------------------------
# status_pvc: OK | MISSING | DIVERGENT | PVC_NOT_FOUND | VM_UNLABELED
# status_pv : OK | MISSING | DIVERGENT | PV_NOT_FOUND | PV_NOT_BOUND
#             PV_TERMINATING | VM_UNLABELED | -
run_correlation() {
jq -r --arg key "$LABEL_KEY" --arg val "$LABEL_VALUE" --arg mode "$MODE" \
      --arg exre "$EXCLUDE_NS_RE" --arg vmn "$VM_NAME" \
      --slurpfile pvcs "$PVCS_JSON" --slurpfile pvs "$PVS_JSON" \
      --slurpfile dvs "$DVS_JSON" '
  ( ($pvcs[0].items // [])
    | map({ key:   (.metadata.namespace + "/" + .metadata.name),
            value: { v: (.metadata.labels[$key] // null),
                     pv: (.spec.volumeName // "") } })
    | from_entries ) as $pvcidx
  | ( ($pvs[0].items // [])
    | map({ key:   .metadata.name,
            value: { v: (.metadata.labels[$key] // null),
                     term: (.metadata.deletionTimestamp != null),
                     phase: (.status.phase // "-") } })
    | from_entries ) as $pvidx
  | ( ($dvs[0].items // [])
    | map({ key:   (.metadata.namespace + "/" + .metadata.name),
            value: { v: (.metadata.labels[$key] // null) } })
    | from_entries ) as $dvidx
  | .items[]
  | select($vmn == "" or .metadata.name == $vmn)
  | select($exre == "" or (.metadata.namespace | test($exre) | not))
  | .metadata.namespace         as $ns
  | .metadata.name              as $vm
  | (.metadata.labels[$key])    as $vmlab
  | (if $mode == "inherit" then $vmlab else $val end) as $exp
  | (.spec.template.spec.volumes // [])[]
  | select(has("persistentVolumeClaim") or has("dataVolume"))
  | { vol: .name,
      pvc: (.persistentVolumeClaim.claimName // .dataVolume.name),
      src: (if has("dataVolume") then "dv" else "pvc" end) }
  | . + { c: ($pvcidx[$ns + "/" + .pvc]) }
  | . + { pvname: (if .c == null then "" else .c.pv end) }
  | . + { p: (if (.pvname // "") == "" then null else $pvidx[.pvname] end) }
  | . + { st_pvc: (
      if   $exp   == null then "VM_UNLABELED"
      elif .c     == null then "PVC_NOT_FOUND"
      elif .c.v   == null then "MISSING"
      elif .c.v   == $exp then "OK"
      else "DIVERGENT" end) }
  | . + { d: ($dvidx[$ns + "/" + .pvc]) }
  | . + { st_dv: (
      if   $exp == null    then "VM_UNLABELED"
      elif .d   == null    then (if .src == "dv" then "DV_NOT_FOUND" else "-" end)
      elif .d.v == null    then "MISSING"
      elif .d.v == $exp    then "OK"
      else "DIVERGENT" end) }
  | . + { st_pv: (
      if   $exp   == null then "VM_UNLABELED"
      elif .c     == null then "-"
      elif (.pvname // "") == "" then "PV_NOT_BOUND"
      elif .p     == null then "PV_NOT_FOUND"
      elif .p.term        then "PV_TERMINATING"
      elif .p.v   == null then "MISSING"
      elif .p.v   == $exp then "OK"
      else "DIVERGENT" end) }
  | [ $ns, $vm, .vol, .pvc,
      (if (.pvname // "") == "" then "-" else .pvname end),
      .src,
      ($vmlab // "-"),
      (if (.c == null or .c.v == null) then "-" else .c.v end),
      (if (.p == null or .p.v == null) then "-" else .p.v end),
      ($exp // "-"),
      .st_pvc, .st_pv,
      (if .p == null then "-" else .p.phase end),
      (if (.d == null or .d.v == null) then "-" else .d.v end),
      .st_dv ]
  | @tsv
' "$VMS_JSON" | sort -u > "$REPORT"
}

# lista de VMs sem a chave, respeitando o escopo
vms_sem_label() {
  jq -r --arg key "$LABEL_KEY" --arg exre "$EXCLUDE_NS_RE" --arg vmn "$VM_NAME" '
    .items[]
    | select($vmn == "" or .metadata.name == $vmn)
    | select($exre == "" or (.metadata.namespace | test($exre) | not))
    | select(.metadata.labels[$key] == null)
    | [.metadata.namespace, .metadata.name] | @tsv
  ' "$VMS_JSON" | sort -u
}

render_report() {
echo
printf '%-22s %-18s %-9s %-30s %-5s %-11s %-11s %-11s %-11s %-14s %-14s %s\n' \
  NAMESPACE VM VOLUME PVC ORIG LABEL-VM LB-PVC LB-PV LB-DV ST-PVC ST-PV ST-DV
awk -F'\t' '$11!="OK" || ($12!="OK" && $12!="-") || ($15!="OK" && $15!="-") {
  printf "%-22s %-18s %-9s %-30s %-5s %-11s %-11s %-11s %-11s %-14s %-14s %s\n",
    $1,$2,$3,$4,$6,$7,$8,$9,$14,$11,$12,$15}' "$REPORT"
echo "  (linhas OK omitidas; nome do PV e fase em ${REPORT} e no CSV)"

echo
echo "== Resumo por disco =="
printf '  %-16s %8s %8s %8s\n' STATUS PVC PV DV
awk -F'\t' '{a[$11]++; b[$12]++; c[$15]++; k[$11]=1; k[$12]=1; k[$15]=1}
  END {for (s in k) if (s != "-") printf "  %-16s %8d %8d %8d\n", s, a[s]+0, b[s]+0, c[s]+0}' "$REPORT" | sort

# cobertura de DataVolume: quantas existem e quantas servem disco de VM
DV_TOTAL=$(jq '.items | length' "$DVS_JSON")
awk -F'\t' '{print $1"/"$4}' "$REPORT" | sort -u > "$WORKDIR/.discos"
jq -r '.items[] | .metadata.namespace + "/" + .metadata.name' "$DVS_JSON" | sort -u > "$WORKDIR/.dvs"
DV_LIG=$(comm -12 "$WORKDIR/.dvs" "$WORKDIR/.discos" | wc -l)
DV_SOLTA=$((DV_TOTAL - DV_LIG))
comm -23 "$WORKDIR/.dvs" "$WORKDIR/.discos" > "$WORKDIR/dv-sem-vm.txt"
rm -f "$WORKDIR/.discos" "$WORKDIR/.dvs"
echo
echo "== Cobertura de DataVolume =="
echo "  DVs no escopo:              ${DV_TOTAL}"
echo "  ligadas a disco de VM:      ${DV_LIG}"
echo "  sem VM que as referencie:   ${DV_SOLTA}"
if [[ "$DV_LIG" -eq 0 && "$DV_TOTAL" -gt 0 ]]; then
  echo "  Nenhum disco de VM e servido por DataVolume viva. ST-DV fica '-' e"
  echo "  isso e o esperado: as DVs existentes sao resto de migracao."
fi
[[ "$DV_SOLTA" -gt 0 ]] && echo "  lista: ${WORKDIR}/dv-sem-vm.txt"

{ echo "cluster,namespace,vm,volume,pvc,pv,origem,label_vm,label_pvc,label_pv,esperado,status_pvc,status_pv,pv_phase,label_dv,status_dv"
  awk -F'\t' -v cl="$CLUSTER" '{print cl","$1","$2","$3","$4","$5","$6","$7","$8","$9","$10","$11","$12","$13","$14","$15}' "$REPORT"
} > "$RELCSV"
echo "  CSV: $RELCSV"
if [[ -n "$CSV_OUT" ]]; then cp "$RELCSV" "$CSV_OUT"; echo "  copia: $CSV_OUT"; fi
}

run_correlation

TOTAL=$(wc -l < "$REPORT")
if [[ "$TOTAL" -eq 0 ]]; then
  echo; echo "Nenhum disco de VM encontrado no escopo."
  exit 0
fi

render_report

# --- fase A: VMs sem o label ---------------------------------------------------
VMFIX="$WORKDIR/vms-sem-label.tsv"
vms_sem_label > "$VMFIX"
VM_SEM=$(wc -l < "$VMFIX")

if [[ "$VM_SEM" -gt 0 ]]; then
  echo
  if [[ -z "$LABEL_VMS" ]]; then
    echo "ATENCAO: ${VM_SEM} VM(s) sem o label '${LABEL_KEY}'. Nao serao tocadas."
    echo "Use --label-vms VALOR --fix para rotula-las e propagar aos discos."
    awk -F'\t' '{print "  "$1"/"$2}' "$VMFIX"
  elif [[ "$FIX" != true ]]; then
    echo "${VM_SEM} VM(s) receberiam ${LABEL_KEY}=${LABEL_VMS} (precisa de --fix):"
    awk -F'\t' '{print "  "$1"/"$2}' "$VMFIX"
  else
    echo "== Fase A: rotulando ${VM_SEM} VM(s) com ${LABEL_KEY}=${LABEL_VMS} =="
    { echo "#!/usr/bin/env bash"
      echo "# Undo gerado em $(date -Is)"
      echo "# cluster: ${CLUSTER}  server: ${SERVER}"
      echo "# contem apenas operacoes que foram de fato aplicadas"
      echo "set -u"; } > "$UNDO"
    chmod +x "$UNDO"
    CTXARG=""
    [[ -n "$CONTEXT" ]] && CTXARG=$(printf -- '--context %q ' "$CONTEXT")

    VMOK=0
    while IFS=$'\t' read -r ns vm; do
      if "${OC[@]}" label vm -n "$ns" "$vm" "${LABEL_KEY}=${LABEL_VMS}" >/dev/null 2>&1; then
        echo "  ok    vm  ${ns}/${vm}"; VMOK=$((VMOK+1))
        printf 'oc %slabel vm -n %s %s %s-\n' "$CTXARG" "$ns" "$vm" "$LABEL_KEY" >> "$UNDO"
      else
        echo "  ERRO  vm  ${ns}/${vm}"; VMERR=$((VMERR+1))
      fi
    done < "$VMFIX"
    echo "  VMs rotuladas: ${VMOK}  Falhas: ${VMERR}"
    if [[ "$VMERR" -gt 0 ]]; then
      echo "  AVISO: houve falha na fase A. Os discos dessas VMs seguem sem correcao."
    fi

    echo
    echo "== Recoletando VMs e recalculando =="
    "${OC[@]}" get vm "${SCOPE[@]}" "${VMSEL_EXP[@]}" -o json > "$VMS_JSON"
    run_correlation
    render_report
  fi
fi

# --- selecao do que corrigir ---------------------------------------------------
# fixlist: kind \t ns \t nome \t esperado \t valor_anterior
{
  if [[ "$OVERWRITE_VALUE" == true ]]; then PAT='MISSING|DIVERGENT'; else PAT='MISSING'; fi
  awk -F'\t' -v pat="$PAT" '$11 ~ "^("pat")$" {print "pvc\t"$1"\t"$4"\t"$10"\t"$8}' "$REPORT"
  if [[ "$SKIP_PV" != true ]]; then
    awk -F'\t' -v pat="$PAT" '$12 ~ "^("pat")$" {print "pv\t-\t"$5"\t"$10"\t"$9}' "$REPORT"
  fi
  if [[ "$SKIP_DV" != true ]]; then
    awk -F'\t' -v pat="$PAT" '$15 ~ "^("pat")$" {print "dv\t"$1"\t"$4"\t"$10"\t"$14}' "$REPORT"
  fi
} | sort -u > "$FIXLIST"
FIX_COUNT=$(wc -l < "$FIXLIST")
FIX_PVC=$(awk -F'\t' '$1=="pvc"' "$FIXLIST" | wc -l)
FIX_PV=$(awk -F'\t' '$1=="pv"' "$FIXLIST" | wc -l)
FIX_DV=$(awk -F'\t' '$1=="dv"' "$FIXLIST" | wc -l)

TERM_PV=$(awk -F'\t' '$12=="PV_TERMINATING"' "$REPORT" | cut -f5 | sort -u | wc -l)
if [[ "$TERM_PV" -gt 0 ]]; then
  echo
  echo "ATENCAO: ${TERM_PV} PV(s) em Terminating. Nao serao rotulados."
  awk -F'\t' '$12=="PV_TERMINATING" {print "  "$5"  (pvc "$1"/"$4")"}' "$REPORT" | sort -u
fi

# --- verificacao inversa: PVC rotulado sem VM que o referencie -----------------
echo
if [[ -n "$VM_SELECTOR" || -n "$VM_NAME" ]]; then
  echo "== PVC rotulado sem VM: pulado (escopo de VM restrito produziria falsos positivos) =="
else
  ORPHANS="$WORKDIR/pvc-rotulado-sem-vm.tsv"
  jq -r --arg key "$LABEL_KEY" --arg exre "$EXCLUDE_NS_RE" --slurpfile vms "$VMS_JSON" '
    ( [ ($vms[0].items // [])[]
        | .metadata.namespace as $ns
        | (.spec.template.spec.volumes // [])[]
        | select(has("persistentVolumeClaim") or has("dataVolume"))
        | $ns + "/" + (.persistentVolumeClaim.claimName // .dataVolume.name) ]
      | map({key: ., value: true}) | from_entries ) as $used
    | .items[]
    | select($exre == "" or (.metadata.namespace | test($exre) | not))
    | select(.metadata.labels[$key] != null)
    | select($used[.metadata.namespace + "/" + .metadata.name] != true)
    | [ .metadata.namespace, .metadata.name, .metadata.labels[$key],
        (.status.phase // "-") ]
    | @tsv
  ' "$PVCS_JSON" | sort -u > "$ORPHANS"
  ORPHAN_COUNT=$(wc -l < "$ORPHANS")
  echo "== PVC rotulado '${LABEL_KEY}' sem VM que o referencie: ${ORPHAN_COUNT} =="
  if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
    awk -F'\t' '{printf "  %-24s %-38s %-12s %s\n",$1,$2,$3,$4}' "$ORPHANS" | head -30
    [[ "$ORPHAN_COUNT" -gt 30 ]] && echo "  ... (lista completa em ${ORPHANS})"
    echo "  Somente relatorio. O script nao remove label nem PVC."
  fi
fi

if [[ "$FIX_COUNT" -eq 0 ]]; then
  echo; echo "Nada a corrigir."
  [[ "$VMERR" -eq 0 ]] || exit 2
  exit 0
fi

if [[ "$FIX" != true ]]; then
  echo
  echo "A corrigir: ${FIX_PVC} PVC(s), ${FIX_PV} PV(s), ${FIX_DV} DV(s). Rode com --fix."
  echo "Lista: ${FIXLIST}"
  exit 0
fi

# --- aplicacao, com undo escrito por operacao concluida ------------------------
if [[ ! -s "$UNDO" ]]; then
  { echo "#!/usr/bin/env bash"
    echo "# Undo gerado em $(date -Is)"
    echo "# cluster: ${CLUSTER}  server: ${SERVER}"
    echo "# contem apenas operacoes que foram de fato aplicadas"
    echo "set -u"; } > "$UNDO"
  chmod +x "$UNDO"
fi
CTXARG=""
[[ -n "$CONTEXT" ]] && CTXARG=$(printf -- '--context %q ' "$CONTEXT")

undo_line() {   # kind ns nome prior
  local kind="$1" ns="$2" name="$3" prior="$4"
  if [[ "$kind" == "dv" ]]; then
    if [[ "$prior" == "-" ]]; then
      printf 'oc %slabel dv -n %s %s %s-\n' "$CTXARG" "$ns" "$name" "$LABEL_KEY" >> "$UNDO"
    else
      printf 'oc %slabel dv -n %s %s %s=%s --overwrite\n' "$CTXARG" "$ns" "$name" "$LABEL_KEY" "$prior" >> "$UNDO"
    fi
    return
  fi
  if [[ "$kind" == "pv" ]]; then
    if [[ "$prior" == "-" ]]; then
      printf 'oc %slabel pv %s %s-\n' "$CTXARG" "$name" "$LABEL_KEY" >> "$UNDO"
    else
      printf 'oc %slabel pv %s %s=%s --overwrite\n' "$CTXARG" "$name" "$LABEL_KEY" "$prior" >> "$UNDO"
    fi
  else
    if [[ "$prior" == "-" ]]; then
      printf 'oc %slabel pvc -n %s %s %s-\n' "$CTXARG" "$ns" "$name" "$LABEL_KEY" >> "$UNDO"
    else
      printf 'oc %slabel pvc -n %s %s %s=%s --overwrite\n' "$CTXARG" "$ns" "$name" "$LABEL_KEY" "$prior" >> "$UNDO"
    fi
  fi
}

echo
echo "Undo: ${UNDO}"
echo
echo "== Aplicando ${LABEL_KEY} em ${FIX_PVC} PVC(s), ${FIX_PV} PV(s), ${FIX_DV} DV(s) =="
OK=0; ERR=0
while IFS=$'\t' read -r kind ns name exp prior; do
  if [[ "$kind" == "dv" ]]; then
    if "${OC[@]}" label dv -n "$ns" "$name" "${LABEL_KEY}=${exp}" --overwrite >/dev/null 2>&1; then
      echo "  ok    dv  ${ns}/${name} -> ${LABEL_KEY}=${exp}"; OK=$((OK+1)); undo_line dv "$ns" "$name" "$prior"
    else
      echo "  ERRO  dv  ${ns}/${name}"; ERR=$((ERR+1))
    fi
    continue
  fi
  if [[ "$kind" == "pv" ]]; then
    if "${OC[@]}" label pv "$name" "${LABEL_KEY}=${exp}" --overwrite >/dev/null 2>&1; then
      echo "  ok    pv  ${name} -> ${LABEL_KEY}=${exp}"; OK=$((OK+1)); undo_line pv "$ns" "$name" "$prior"
    else
      echo "  ERRO  pv  ${name}"; ERR=$((ERR+1))
    fi
    continue
  fi
  if "${OC[@]}" label pvc -n "$ns" "$name" "${LABEL_KEY}=${exp}" --overwrite >/dev/null 2>&1; then
    echo "  ok    pvc ${ns}/${name} -> ${LABEL_KEY}=${exp}"; OK=$((OK+1)); undo_line pvc "$ns" "$name" "$prior"
  else
    echo "  ERRO  pvc ${ns}/${name}"; ERR=$((ERR+1))
  fi
done < "$FIXLIST"

echo
echo "Aplicados: ${OK}  Falhas: ${ERR}"

echo
echo "== Revalidando =="
REMAIN=0
while IFS=$'\t' read -r kind ns name exp prior; do
  if [[ "$kind" == "dv" ]]; then
    cur=$("${OC[@]}" get dv -n "$ns" "$name" -o json 2>/dev/null \
          | jq -r --arg k "$LABEL_KEY" '.metadata.labels[$k] // ""' 2>/dev/null || true)
    [[ "$cur" == "$exp" ]] || { echo "  PENDENTE dv  ${ns}/${name} (valor='${cur}')"; REMAIN=$((REMAIN+1)); }
    continue
  fi
  if [[ "$kind" == "pv" ]]; then
    cur=$("${OC[@]}" get pv "$name" -o json 2>/dev/null \
          | jq -r --arg k "$LABEL_KEY" '.metadata.labels[$k] // ""' 2>/dev/null || true)
    [[ "$cur" == "$exp" ]] || { echo "  PENDENTE pv  ${name} (valor='${cur}')"; REMAIN=$((REMAIN+1)); }
  else
    cur=$("${OC[@]}" get pvc -n "$ns" "$name" -o json 2>/dev/null \
          | jq -r --arg k "$LABEL_KEY" '.metadata.labels[$k] // ""' 2>/dev/null || true)
    [[ "$cur" == "$exp" ]] || { echo "  PENDENTE pvc ${ns}/${name} (valor='${cur}')"; REMAIN=$((REMAIN+1)); }
  fi
done < "$FIXLIST"
echo "Pendentes: ${REMAIN}"
[[ "$REMAIN" -eq 0 && "$ERR" -eq 0 && "$VMERR" -eq 0 ]] || exit 2

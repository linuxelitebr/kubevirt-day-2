#!/usr/bin/env bash
#
# vm-hyperv-tuning.sh
#
# Aplica o baseline Windows ausente em VMs migradas por MTV/Forklift:
# features.hyperv, clock.timer, ioThreadsPolicy, terminationGracePeriodSeconds
# e inputs[].bus.
#
# Modelo audit/apply. O audit gera um plano CSV; o apply consome o plano,
# reconfere drift, aplica, verifica o delta contra allowlist e grava o undo.
#
# ESCOPO
#   Apenas VMs em execucao com guest agent respondendo. VM parada nao permite
#   identificar o SO com confianca e sai como SKIP/NOT_RUNNING.
#
# LANDING
#   O patch nao e hot-appliable e NAO entra com reboot do guest: o libvirt trata
#   o reset internamente e o domain XML nao e re-renderizado. Precisa de shutdown
#   completo do guest e religar. Sob runStrategy: Always o VMI e recriado sozinho;
#   sob RerunOnFailure exige `virtctl start` explicito.
#
#   Nada neste script desliga ou religa VM.
#
# USO
#   ./vm-hyperv-tuning.sh audit  (--all | -n NS... | --vm NS/NAME...) [-o OUTDIR]
#   ./vm-hyperv-tuning.sh apply  -p PLAN.csv [-n NS...] [--vm NS/NAME...] [-l N] [--dry-run]
#   ./vm-hyperv-tuning.sh status -p PLAN.csv [-n NS...] [--vm NS/NAME...]
#   ./vm-hyperv-tuning.sh undo   -u UNDODIR [-n NS...] [--vm NS/NAME...] [-l N]
#
set -euo pipefail

OUTDIR="./hyperv-tuning"
PLAN=""
UNDODIR=""
LIMIT=1
DRYRUN=0
SCOPE_ALL=0
declare -a SCOPE_NS=()
declare -a SCOPE_VM=()

TS="$(date -u +%Y%m%dT%H%M%SZ)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CAMPAIGN_LOG="/dev/null"

GRACE_TARGET=3600
SPINLOCKS_TARGET=8191
HV_KEYS='["relaxed","vapic","vpindex","synic","synictimer","spinlocks","tlbflush","ipi","runtime","reset","frequencies","reenlightenment"]'

ALLOW_RE='^spec\.template\.spec\.terminationGracePeriodSeconds=|^spec\.template\.spec\.domain\.ioThreadsPolicy=|^spec\.template\.spec\.domain\.features\.hyperv\.|^spec\.template\.spec\.domain\.clock\.timer\.|^spec\.template\.spec\.domain\.clock\.utc=|^spec\.template\.spec\.domain\.devices\.inputs\.[0-9]+\.bus='

die()  { echo "ERRO: $*" >&2; exit 1; }
warn() { echo "AVISO: $*" >&2; }
log()  { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$CAMPAIGN_LOG"; }

# ---------------------------------------------------------------- escopo

in_scope() {
  local ns="$1" vm="$2" e
  (( SCOPE_ALL )) && return 0
  if (( ${#SCOPE_NS[@]} )); then
    for e in "${SCOPE_NS[@]}"; do [[ "$e" == "$ns" ]] && return 0; done
  fi
  if (( ${#SCOPE_VM[@]} )); then
    for e in "${SCOPE_VM[@]}"; do [[ "$e" == "$ns/$vm" ]] && return 0; done
  fi
  return 1
}

require_scope() {
  (( SCOPE_ALL )) && return 0
  (( ${#SCOPE_NS[@]} + ${#SCOPE_VM[@]} )) && return 0
  die "escopo obrigatorio: use --all, -n NAMESPACE ou --vm NAMESPACE/NOME"
}

scope_label() {
  (( SCOPE_ALL )) && { echo "TODO O CLUSTER"; return; }
  local out=""
  (( ${#SCOPE_NS[@]} )) && out="ns=$(IFS=,; echo "${SCOPE_NS[*]}")"
  (( ${#SCOPE_VM[@]} )) && out="${out}${out:+ }vm=$(IFS=,; echo "${SCOPE_VM[*]}")"
  echo "$out"
}

cluster_id() {
  oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' 2>/dev/null \
    || oc whoami --show-server
}

# ---------------------------------------------------------------- jq helpers

read -r -d '' JQ_FLATTEN <<'JQEOF' || true
def flat:
  [ paths as $p
    | getpath($p) as $v
    | ($v|type) as $t
    | if   $t == "object" then (if ($v|length)==0 then "\($p|map(tostring)|join("."))={}" else empty end)
      elif $t == "array"  then (if ($v|length)==0 then "\($p|map(tostring)|join("."))=[]" else empty end)
      else "\($p|map(tostring)|join("."))=\($v|tostring)"
      end ];
{spec: .spec} | flat | sort | .[]
JQEOF

flatten_spec() { jq -r "$JQ_FLATTEN"; }

read -r -d '' JQ_AUDIT <<'JQEOF' || true
($hv_keys)        as $HV
($grace|tonumber) as $GRACE
($spin|tonumber)  as $SPIN
($vmis | map({key:"\(.metadata.namespace)/\(.metadata.name)", value:.}) | from_entries) as $VMIS

def owner:
  (.metadata.annotations // {}) as $a
  | (.metadata.labels // {})    as $l
  | if   $a["argocd.argoproj.io/tracking-id"]                        then "ARGOCD"
    elif $l["argocd.argoproj.io/instance"]                           then "ARGOCD"
    elif $l["app.kubernetes.io/instance"]                            then "ARGOCD_LIKE"
    elif $a["apps.open-cluster-management.io/hosting-subscription"]  then "ACM_SUBSCRIPTION"
    elif $l["apps.open-cluster-management.io/reconcile-option"]      then "ACM"
    elif ((.metadata.ownerReferences // []) | length) > 0            then "OWNERREF"
    else null end;

def hv_state:
  (.spec.template.spec.domain.features.hyperv // null) as $h
  | if $h == null then "ABSENT"
    else
      (($HV - ($h|keys)) | length) as $missing
      | if $missing > 0 then "PARTIAL"
        elif ($h.spinlocks.spinlocks // -1) != $SPIN then "PARTIAL"
        elif ($h.synictimer.direct // null) == null  then "PARTIAL"
        else "COMPLETE" end
    end;

def clock_state:
  (.spec.template.spec.domain.clock.timer // null) as $t
  | if $t == null then "ABSENT"
    elif ($t.hpet.present // true) == false
         and ($t|has("hyperv"))
         and (($t.pit.tickPolicy // "") == "delay")
         and (($t.rtc.tickPolicy // "") == "catchup") then "COMPLETE"
    else "PARTIAL" end;

def clock_offset:
  (.spec.template.spec.domain.clock // null) as $c
  | if $c == null then "ABSENT"
    elif ($c|has("utc"))      then "UTC"
    elif ($c|has("timezone")) then "TIMEZONE"
    else "NONE" end;

def inputs_state:
  (.spec.template.spec.domain.devices.inputs // null) as $i
  | if $i == null then {state:"ABSENT", idx:""}
    else
      ([ range(0; ($i|length)) | select($i[.].bus == "virtio") ] | map(tostring) | join(";")) as $ix
      | if ($ix|length) == 0 then {state:"OK", idx:""} else {state:"VIRTIO", idx:$ix} end
    end;

.items[]
| . as $vm
| $vm.metadata.namespace as $ns
| $vm.metadata.name      as $name
| ($VMIS["\($ns)/\($name)"] // null)            as $vmi
| (($vmi.status.guestOSInfo // {}).id   // "")  as $osid
| (($vmi.status.guestOSInfo // {}).name // "")  as $osname
| ($vm.status.printableStatus // "Unknown")     as $pstatus
| ($vm.spec.template.spec.terminationGracePeriodSeconds // -1) as $grace
| ($vm.spec.template.spec.domain.ioThreadsPolicy // "")        as $iop
| ($vm | hv_state)     as $hvs
| ($vm | clock_state)  as $cks
| ($vm | clock_offset) as $cko
| ($vm | inputs_state) as $ins
| ($vm | owner)        as $own
| ([ ($vm.spec.template.spec.domain.devices.disks // [])[]
     | (.disk.bus // .lun.bus // .cdrom.bus // "none") ] | unique | join(";")) as $buses
| (if $pstatus != "Running" or $vmi == null then {c:"SKIP",  r:"NOT_RUNNING"}
   elif ($osid == "" and $osname == "")     then {c:"SKIP",  r:"NO_GUEST_AGENT"}
   elif ($osid != "mswindows" and (($osname // "") | ascii_downcase | test("windows") | not))
                                            then {c:"SKIP",  r:"NOT_WINDOWS"}
   elif $own != null                        then {c:"BLOCK", r:"OWNED_BY_\($own)"}
   elif ($hvs == "PARTIAL" or $cks == "PARTIAL")
                                            then {c:"BLOCK", r:"PARTIAL_CONFIG_REVIEW"}
   elif ($hvs == "COMPLETE" and $cks == "COMPLETE" and $iop != "" and $grace >= $GRACE)
                                            then {c:"SKIP",  r:"ALREADY_TUNED"}
   else {c:"ELIGIBLE", r:"MISSING_BASELINE"} end) as $cls
| { namespace: $ns, vm: $name,
    classification: $cls.c, reason: $cls.r,
    os: (if $osname == "" then $osid else $osname end),
    hyperv: $hvs, clock: $cks, clock_offset: $cko,
    iothreads: (if $iop == "" then "ABSENT" else $iop end),
    grace: ($grace|tostring),
    inputs: $ins.state, inputs_idx: $ins.idx,
    disk_buses: $buses,
    canon: ($vm.spec.template.spec | tojson) }
JQEOF

# ------------------------------------------------------------------- audit

do_audit() {
  require_scope
  mkdir -p "$OUTDIR"

  local cid; cid="$(cluster_id)"
  local plan="$OUTDIR/plan-${TS}.csv"
  local vmis="$OUTDIR/.vmis-${TS}.json"

  local -a q=(-A)
  if (( ${#SCOPE_NS[@]} == 1 )) && (( ${#SCOPE_VM[@]} == 0 )) && ! (( SCOPE_ALL )); then
    q=(-n "${SCOPE_NS[0]}")
  fi

  echo "cluster: $cid"
  echo "escopo:  $(scope_label)"
  echo

  oc get vmi "${q[@]}" -o json | jq '[.items[]]' > "$vmis"

  {
    echo "cluster,namespace,vm,classification,reason,os,hyperv,clock,clock_offset,iothreads,grace,inputs,inputs_idx,disk_buses,fingerprint"
    oc get vm "${q[@]}" -o json \
      | jq -c --argjson hv_keys "$HV_KEYS" \
             --arg grace "$GRACE_TARGET" --arg spin "$SPINLOCKS_TARGET" \
             --slurpfile vmis_file "$vmis" \
             --argjson vmis "$(cat "$vmis")" \
             "$JQ_AUDIT" \
      | while IFS= read -r line; do
          local ns vm fp
          ns="$(jq -r '.namespace' <<<"$line")"
          vm="$(jq -r '.vm' <<<"$line")"
          in_scope "$ns" "$vm" || continue
          fp="$(jq -r '.canon' <<<"$line" | sha256sum | cut -c1-16)"
          jq -r --arg c "$cid" --arg fp "$fp" \
            '[$c,.namespace,.vm,.classification,.reason,.os,.hyperv,.clock,.clock_offset,
              .iothreads,.grace,.inputs,.inputs_idx,.disk_buses,$fp] | @csv' <<<"$line"
        done
  } > "$plan"

  rm -f "$vmis"

  echo "plano: $plan"
  echo
  awk -F',' 'NR>1 {gsub(/"/,"",$4); c[$4]++} END {for (k in c) printf "  %-10s %d\n", k, c[k]}' "$plan"
  echo
  echo "Distribuicao dos SKIP:"
  awk -F',' 'NR>1 {gsub(/"/,"",$4); gsub(/"/,"",$5); if ($4=="SKIP") c[$5]++}
             END {for (k in c) printf "  %-18s %d\n", k, c[k]}' "$plan"
  echo
  echo "ELIGIBLE por namespace (unidade de onda):"
  awk -F',' 'NR>1 {gsub(/"/,"",$2); gsub(/"/,"",$4); if ($4=="ELIGIBLE") c[$2]++}
             END {for (k in c) printf "  %-45s %d\n", k, c[k]}' "$plan" | sort -k2 -rn
}

# ------------------------------------------------------------------- apply

build_patch_a() {
  local offset_frag=""
  [[ "$1" == "ABSENT" || "$1" == "NONE" ]] && offset_frag='"utc":{},'
  cat <<EOF
{"spec":{"template":{"spec":{
  "terminationGracePeriodSeconds":${GRACE_TARGET},
  "domain":{
    "ioThreadsPolicy":"auto",
    "features":{"hyperv":{
      "relaxed":{},"vapic":{},"vpindex":{},"synic":{},
      "synictimer":{"direct":{}},"spinlocks":{"spinlocks":${SPINLOCKS_TARGET}},
      "tlbflush":{},"ipi":{},"runtime":{},"reset":{},
      "frequencies":{},"reenlightenment":{}}},
    "clock":{${offset_frag}"timer":{
      "hpet":{"present":false},
      "pit":{"tickPolicy":"delay"},
      "rtc":{"tickPolicy":"catchup"},
      "hyperv":{}}}
  }}}}}
EOF
}

build_patch_b() {
  local idx ops=() i
  IFS=';' read -ra idx <<< "$1"
  for i in "${idx[@]}"; do
    [[ -z "$i" ]] && continue
    ops+=("{\"op\":\"test\",\"path\":\"/spec/template/spec/domain/devices/inputs/${i}/bus\",\"value\":\"virtio\"}")
    ops+=("{\"op\":\"replace\",\"path\":\"/spec/template/spec/domain/devices/inputs/${i}/bus\",\"value\":\"usb\"}")
  done
  printf '[%s]' "$(IFS=,; echo "${ops[*]}")"
}

build_undo() {
  local before="$1" offset="$2"
  local drop_utc=false
  [[ "$offset" == "ABSENT" || "$offset" == "NONE" ]] && drop_utc=true
  jq -c --argjson drop_utc "$drop_utc" '
    .spec.template.spec as $t
    | {spec:{template:{spec:{
        terminationGracePeriodSeconds: ($t.terminationGracePeriodSeconds // null),
        domain:{
          ioThreadsPolicy: ($t.domain.ioThreadsPolicy // null),
          features: (if ($t.domain.features.hyperv // null) == null
                     then {hyperv:null} else {hyperv:$t.domain.features.hyperv} end),
          clock: (if ($t.domain.clock // null) == null then null
                  elif $drop_utc then ($t.domain.clock + {utc:null})
                  else $t.domain.clock end)
        }}}}}' "$before"
}

do_apply() {
  [[ -n "$PLAN" && -f "$PLAN" ]] || die "apply exige -p PLAN.csv valido"

  local base; base="$(dirname "$PLAN")"
  local undo_dir="$base/undo-${TS}"
  local diff_dir="$base/diff-${TS}"
  local applied="$base/applied-${TS}.csv"
  CAMPAIGN_LOG="$base/campaign-${TS}.log"
  mkdir -p "$undo_dir" "$diff_dir"

  local cid_now cid_plan
  cid_now="$(cluster_id)"
  cid_plan="$(awk -F',' 'NR==2 {gsub(/"/,"",$1); print $1; exit}' "$PLAN")"
  [[ -n "$cid_plan" ]] || die "plano vazio"
  [[ "$cid_now" == "$cid_plan" ]] || \
    die "guarda de identidade: plano gerado em '$cid_plan', sessao atual em '$cid_now'"

  # sem escopo explicito, o apply herda o plano inteiro
  (( SCOPE_ALL )) || (( ${#SCOPE_NS[@]} + ${#SCOPE_VM[@]} )) || SCOPE_ALL=1

  echo "cluster: $cid_now"
  echo "escopo:  $(scope_label)"
  echo "limite:  $LIMIT   (0 = sem limite)"
  (( DRYRUN )) && echo "modo:    DRY-RUN (server-side, nada e gravado)"
  echo

  [[ $DRYRUN -eq 0 ]] && echo "cluster,namespace,vm,applied_at" > "$applied"

  local done=0 ok=0 fail=0 held=0
  while IFS=',' read -r c_cluster c_ns c_vm c_cls c_reason c_os c_hv c_ck c_cko c_io c_gr c_in c_inidx c_buses c_fp; do
    local v
    for v in c_ns c_vm c_cls c_cko c_inidx c_fp; do eval "$v=\${$v//\\\"/}"; done
    [[ "$c_cls" == "ELIGIBLE" ]] || continue
    in_scope "$c_ns" "$c_vm" || continue
    if (( LIMIT > 0 && done >= LIMIT )); then held=$((held+1)); continue; fi
    done=$((done+1))

    local tag="$c_ns/$c_vm"
    local before="$diff_dir/${c_ns}__${c_vm}.before.json"
    local after="$diff_dir/${c_ns}__${c_vm}.after.json"

    if ! oc get vm "$c_vm" -n "$c_ns" -o json > "$before" 2>/dev/null; then
      echo "  $tag  FALHA  VM_NOT_FOUND"; log "$tag	FAIL	VM_NOT_FOUND"; fail=$((fail+1)); continue
    fi

    local fp_now
    fp_now="$(jq -c '.spec.template.spec' "$before" | sha256sum | cut -c1-16)"
    if [[ "$fp_now" != "$c_fp" ]]; then
      echo "  $tag  PULADO  DRIFT (plano $c_fp, atual $fp_now)"
      log "$tag	SKIP	DRIFT"; fail=$((fail+1)); continue
    fi

    local pa; pa="$(build_patch_a "$c_cko")"

    if (( DRYRUN )); then
      oc patch vm "$c_vm" -n "$c_ns" --type merge --dry-run=server -o json -p "$pa" > "$after" || {
        echo "  $tag  FALHA  PATCH_A_DRYRUN"; fail=$((fail+1)); continue; }
      if [[ -n "$c_inidx" ]]; then
        jq --argjson ix "[$(echo "$c_inidx" | tr ';' ',')]" \
           'reduce $ix[] as $i (.; .spec.template.spec.domain.devices.inputs[$i].bus = "usb")' \
           "$after" > "$after.tmp" && mv "$after.tmp" "$after"
      fi
    else
      build_undo "$before" "$c_cko" > "$undo_dir/${c_ns}__${c_vm}.merge.json.pending"
      [[ -n "$c_inidx" ]] && \
        build_patch_b "$c_inidx" | sed 's/"usb"/"virtio"/g' > "$undo_dir/${c_ns}__${c_vm}.json6902.json.pending"

      if ! oc patch vm "$c_vm" -n "$c_ns" --type merge -p "$pa" >/dev/null; then
        echo "  $tag  FALHA  PATCH_A"; log "$tag	FAIL	PATCH_A"
        rm -f "$undo_dir/${c_ns}__${c_vm}."*.pending; fail=$((fail+1)); continue
      fi

      if [[ -n "$c_inidx" ]]; then
        if ! oc patch vm "$c_vm" -n "$c_ns" --type json -p "$(build_patch_b "$c_inidx")" >/dev/null; then
          echo "  $tag  FALHA  PATCH_B (test falhou) - revertendo A"
          oc patch vm "$c_vm" -n "$c_ns" --type merge \
            -p "$(cat "$undo_dir/${c_ns}__${c_vm}.merge.json.pending")" >/dev/null || true
          log "$tag	ROLLED_BACK	PATCH_B_TEST"
          rm -f "$undo_dir/${c_ns}__${c_vm}."*.pending; fail=$((fail+1)); continue
        fi
      fi
      oc get vm "$c_vm" -n "$c_ns" -o json > "$after"
    fi

    local delta out_of_scope
    delta="$(comm -3 <(flatten_spec < "$before") <(flatten_spec < "$after") \
             | tr -d '\t' | sed 's/^ *//' | sort -u)"
    out_of_scope="$(grep -vE "$ALLOW_RE" <<<"$delta" || true)"

    if [[ -n "$out_of_scope" ]]; then
      echo "  $tag  FALHA  DELTA_FORA_DE_ESCOPO"
      sed 's/^/      /' <<<"$out_of_scope"
      log "$tag	FAIL	OUT_OF_SCOPE"
      if (( DRYRUN == 0 )); then
        oc patch vm "$c_vm" -n "$c_ns" --type merge \
          -p "$(cat "$undo_dir/${c_ns}__${c_vm}.merge.json.pending")" >/dev/null || true
        echo "      revertido"; log "$tag	ROLLED_BACK	OUT_OF_SCOPE"
      fi
      rm -f "$undo_dir/${c_ns}__${c_vm}."*.pending
      fail=$((fail+1)); continue
    fi

    if (( DRYRUN == 0 )); then
      local f
      for f in "$undo_dir/${c_ns}__${c_vm}."*.pending; do
        [[ -e "$f" ]] && mv "$f" "${f%.pending}"
      done
      printf '"%s","%s","%s","%s"\n' "$cid_now" "$c_ns" "$c_vm" "$NOW" >> "$applied"
    fi

    echo "  $tag  OK  ($(grep -c . <<<"$delta") caminhos)"
    log "$tag	OK	$(tr '\n' ' ' <<<"$delta")"
    ok=$((ok+1))
  done < <(tail -n +2 "$PLAN")

  echo
  echo "ok=$ok  falha=$fail  fora-do-limite=$held"
  if (( DRYRUN == 0 )); then
    echo "aplicados: $applied"
    echo "undo:      $undo_dir"
    echo "log:       $CAMPAIGN_LOG"
    echo
    echo "STAGED. Nada foi desligado. O patch so entra apos SHUTDOWN COMPLETO do guest"
    echo "e religar. Reboot de dentro do Windows nao serve: o libvirt trata o reset"
    echo "internamente e o domain XML nao e re-renderizado."
    echo
    echo "Acompanhe com:  $0 status -p $PLAN"
  fi
}

# ------------------------------------------------------------------ status

do_status() {
  [[ -n "$PLAN" && -f "$PLAN" ]] || die "status exige -p PLAN.csv valido"
  local base; base="$(dirname "$PLAN")"
  (( SCOPE_ALL )) || (( ${#SCOPE_NS[@]} + ${#SCOPE_VM[@]} )) || SCOPE_ALL=1

  local applied_all; applied_all="$(mktemp)"
  cat "$base"/applied-*.csv 2>/dev/null | grep -v '^cluster,' | tr -d '"' \
    | sort -t',' -k2,3 -k4,4r | awk -F',' '!seen[$2","$3]++' > "$applied_all" || true
  [[ -s "$applied_all" ]] || { rm -f "$applied_all"; die "nenhum applied-*.csv em $base"; }

  local vmis; vmis="$(mktemp)"
  oc get vmi -A -o json \
    | jq -r '.items[] | "\(.metadata.namespace),\(.metadata.name),\(.metadata.creationTimestamp)"' \
    > "$vmis"

  printf '%-45s %-22s %-12s %s\n' NAMESPACE VM ESTADO DETALHE
  local n_staged=0 n_landed=0 n_stopped=0

  while IFS=',' read -r a_cluster a_ns a_vm a_at; do
    in_scope "$a_ns" "$a_vm" || continue
    local vmi_ct
    vmi_ct="$(awk -F',' -v n="$a_ns" -v v="$a_vm" '$1==n && $2==v {print $3; exit}' "$vmis")"
    if [[ -z "$vmi_ct" ]]; then
      printf '%-45s %-22s %-12s %s\n' "$a_ns" "$a_vm" "STOPPED" "entra ao ligar"
      n_stopped=$((n_stopped+1))
    elif [[ "$vmi_ct" > "$a_at" ]]; then
      printf '%-45s %-22s %-12s %s\n' "$a_ns" "$a_vm" "LANDED" "vmi $vmi_ct"
      n_landed=$((n_landed+1))
    else
      printf '%-45s %-22s %-12s %s\n' "$a_ns" "$a_vm" "STAGED" "vmi $vmi_ct < patch $a_at"
      n_staged=$((n_staged+1))
    fi
  done < "$applied_all"

  rm -f "$applied_all" "$vmis"
  echo
  echo "landed=$n_landed  staged=$n_staged  stopped=$n_stopped"
  echo
  echo "STAGED e o indicador de risco da campanha: spec divergente do dominio em"
  echo "execucao. Reboot fora de janela muda o hardware do Windows sem aviso."
  echo
  echo "Spot-check de um LANDED:"
  echo "  oc exec -n <ns> <launcher-pod> -c compute -- virsh dumpxml 1 | grep -A3 hyperv"
}

# -------------------------------------------------------------------- undo

do_undo() {
  [[ -n "$UNDODIR" && -d "$UNDODIR" ]] || die "undo exige -u UNDODIR valido"
  (( SCOPE_ALL )) || (( ${#SCOPE_NS[@]} + ${#SCOPE_VM[@]} )) || SCOPE_ALL=1
  CAMPAIGN_LOG="$UNDODIR/undo-${TS}.log"

  local done=0 f
  for f in "$UNDODIR"/*.merge.json; do
    [[ -e "$f" ]] || die "nenhum undo em $UNDODIR"
    local b ns vm
    b="$(basename "$f" .merge.json)"; ns="${b%%__*}"; vm="${b##*__}"
    in_scope "$ns" "$vm" || continue
    if (( LIMIT > 0 && done >= LIMIT )); then break; fi
    done=$((done+1))
    echo "  revertendo $ns/$vm"
    if oc patch vm "$vm" -n "$ns" --type merge -p "$(cat "$f")" >/dev/null; then
      log "$ns/$vm	UNDO_OK	"
    else
      log "$ns/$vm	UNDO_FAIL	"; warn "$ns/$vm falhou"
    fi
    [[ -f "$UNDODIR/${b}.json6902.json" ]] && \
      oc patch vm "$vm" -n "$ns" --type json -p "$(cat "$UNDODIR/${b}.json6902.json")" >/dev/null || true
  done
  echo "log: $CAMPAIGN_LOG"
}

# --------------------------------------------------------------------- main

CMD="${1:-}"; shift || true
[[ -n "$CMD" ]] || die "uso: $0 {audit|apply|status|undo} [opcoes]"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)  SCOPE_ALL=1;          shift ;;
    -n)     SCOPE_NS+=("$2");     shift 2 ;;
    --vm)   SCOPE_VM+=("$2");     shift 2 ;;
    -o)     OUTDIR="$2";          shift 2 ;;
    -p)     PLAN="$2";            shift 2 ;;
    -u)     UNDODIR="$2";         shift 2 ;;
    -l)     LIMIT="$2";           shift 2 ;;
    --dry-run) DRYRUN=1;          shift ;;
    *) die "opcao desconhecida: $1" ;;
  esac
done

command -v oc >/dev/null || die "oc nao encontrado"
command -v jq >/dev/null || die "jq nao encontrado"

case "$CMD" in
  audit)  do_audit  ;;
  apply)  do_apply  ;;
  status) do_status ;;
  undo)   do_undo   ;;
  *) die "comando invalido: $CMD" ;;
esac

#!/usr/bin/env bash
#
# vm-hyperv-tuning.sh - v1.2
#
# Aplica o baseline Windows ausente em VMs migradas por MTV/Forklift:
# features.hyperv, clock.timer, ioThreadsPolicy e terminationGracePeriodSeconds.
#
# Rode `./vm-hyperv-tuning.sh -h` para o guia de uso.
#
set -euo pipefail
export LC_ALL=C   # ordenacao deterministica para sort/comm/comparacao de timestamp

VERSION="1.2"

OUTDIR="./hyperv-tuning"
PLAN=""
UNDODIR=""
LIMIT=1
DRYRUN=0
ASSUME_YES=0
SCOPE_ALL=0
EXIT_CODE=0
declare -a SCOPE_NS=()
declare -a SCOPE_VM=()

TS="$(date -u +%Y%m%dT%H%M%SZ)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CAMPAIGN_LOG="/dev/null"

GRACE_TARGET=3600
SPINLOCKS_TARGET=8191
HV_KEYS='["relaxed","vapic","vpindex","synic","synictimer","spinlocks","tlbflush","ipi","runtime","reset","frequencies","reenlightenment"]'

ALLOW_RE='^spec\.template\.spec\.terminationGracePeriodSeconds=|^spec\.template\.spec\.domain\.ioThreadsPolicy=|^spec\.template\.spec\.domain\.features\.hyperv\.|^spec\.template\.spec\.domain\.clock\.timer\.|^spec\.template\.spec\.domain\.clock\.utc='

die()  { echo "ERRO: $*" >&2; exit 2; }
warn() { echo "AVISO: $*" >&2; }
log()  { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$CAMPAIGN_LOG"; }

usage() {
cat <<'HELP'
vm-hyperv-tuning.sh - baseline Windows para VMs migradas por MTV/Forklift

O QUE FAZ
  Acrescenta em VMs Windows migradas os campos que o Forklift nao cria:
    features.hyperv          12 enlightenments, identicos ao template oficial
    clock.timer              hpet off, clocksource hyperv, politicas de tick
    terminationGracePeriodSeconds: 3600
    ioThreadsPolicy: auto    (adicao nossa, nao esta no template oficial)

  E um unico merge patch. Nenhum campo vive dentro de array, entao nao ha
  como danificar disks, inputs ou interfaces.

O QUE NAO FAZ
  Nao desliga, nao religa e nao reinicia VM nenhuma.

  O patch NAO entra com reboot de dentro do Windows: o libvirt trata o reset
  internamente e o domain XML nao e re-renderizado. Live migration tambem nao
  serve, porque o dominio e preservado no destino.

  So entra com SHUTDOWN COMPLETO do guest e religar. Sob runStrategy: Always o
  VMI e recriado sozinho; sob RerunOnFailure precisa de `virtctl start`.

ESCOPO DE COBERTURA
  Apenas VMs em execucao com guest agent respondendo. VM parada nao permite
  identificar o SO com confianca e sai do plano como SKIP/NOT_RUNNING.

FLUXO
  1. oc login no cluster alvo (um cluster por vez)
  2. audit   gera o plano CSV, nao escreve nada no cluster
  3. revise  o CSV: confira BLOCK e SKIP, remova linhas se precisar
  4. apply --dry-run   valida sem gravar
  5. apply   grava, com limite de 1 VM por padrao
  6. status  acompanha o que ja entrou e o que ainda esta pendente
  7. undo    reverte, se necessario

COMANDOS
  audit  (--all | -n NS... | --vm NS/NOME...) [-o DIR]
  apply  -p PLANO.csv [-n NS...] [--vm NS/NOME...] [-l N] [--dry-run] [--yes]
  status -p PLANO.csv [-n NS...] [--vm NS/NOME...]
  undo   -u DIR_UNDO [-n NS...] [--vm NS/NOME...] [-l N]

OPCOES
  --all           todo o cluster. Obrigatorio e explicito, nunca por omissao.
  -n NS           limita a um namespace. Pode repetir.
  --vm NS/NOME    limita a uma VM. Pode repetir.
  -l N            maximo de VMs por execucao. Padrao 1. Use 0 para sem limite.
                  Sem limite exige escopo explicito.
  --dry-run       server-side. Valida o delta completo sem gravar.
  --yes           pula a confirmacao interativa.
  -o DIR          diretorio de saida do audit. Padrao ./hyperv-tuning
  -h              esta ajuda. Funciona sem oc e sem jq instalados.

DEPENDENCIAS
  oc, jq (com suporte a regex), sha256sum, comm, awk.
  Sao verificadas antes de qualquer acao. Faltando qualquer uma, o script
  para com exit 2 e diz o que instalar.

EXEMPLOS
  ./vm-hyperv-tuning.sh audit --all
  ./vm-hyperv-tuning.sh apply -p hyperv-tuning/plan-*.csv --dry-run -l 0 -n meu-ns
  ./vm-hyperv-tuning.sh apply -p hyperv-tuning/plan-*.csv --vm meu-ns/minha-vm
  ./vm-hyperv-tuning.sh apply -p hyperv-tuning/plan-*.csv -n meu-ns -l 0
  ./vm-hyperv-tuning.sh status -p hyperv-tuning/plan-*.csv
  ./vm-hyperv-tuning.sh undo -u hyperv-tuning/undo-20260826T120000Z --vm meu-ns/minha-vm

CODIGOS DE SAIDA
  0  tudo certo
  1  concluiu com uma ou mais VMs em falha
  2  erro de uso, de ambiente ou cancelamento

ARQUIVOS GERADOS
  plan-<TS>.csv      plano do audit
  applied-<TS>.csv   VMs aplicadas, com timestamp. Base do status.
  undo-<TS>/         um merge patch de reversao por VM aplicada
  diff-<TS>/         estado antes e depois de cada VM
  campaign-<TS>.log  log da execucao

  Guarde undo-<TS>/ e applied-<TS>.csv. Sao o que permite reverter e acompanhar.
HELP
}

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

has_explicit_scope() {
  (( SCOPE_ALL )) && return 0
  (( ${#SCOPE_NS[@]} + ${#SCOPE_VM[@]} )) && return 0
  return 1
}

scope_label() {
  (( SCOPE_ALL )) && { echo "TODO O CLUSTER"; return; }
  local out=""
  (( ${#SCOPE_NS[@]} )) && out="ns=$(IFS=,; echo "${SCOPE_NS[*]}")"
  (( ${#SCOPE_VM[@]} )) && out="${out}${out:+ }vm=$(IFS=,; echo "${SCOPE_VM[*]}")"
  echo "${out:-PLANO INTEIRO}"
}

cluster_id() {
  oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' 2>/dev/null \
    || oc whoami --show-server
}

preflight() {
  local -a faltando=()
  command -v oc        >/dev/null 2>&1 || faltando+=("oc")
  command -v jq        >/dev/null 2>&1 || faltando+=("jq")
  command -v sha256sum >/dev/null 2>&1 || faltando+=("sha256sum")
  command -v comm      >/dev/null 2>&1 || faltando+=("comm")
  command -v awk       >/dev/null 2>&1 || faltando+=("awk")

  if (( ${#faltando[@]} )); then
    {
      echo "ERRO: dependencia ausente no PATH: ${faltando[*]}"
      echo
      echo "  RHEL / Fedora:   sudo dnf install -y jq coreutils gawk"
      echo "  Debian / Ubuntu: sudo apt-get install -y jq coreutils gawk"
      echo "  oc:              https://console.redhat.com/openshift/downloads"
      echo
      echo "  jq e obrigatorio. Todo o audit, a verificacao de delta e a"
      echo "  geracao do undo dependem dele. Nao ha modo degradado."
    } >&2
    exit 2
  fi

  # algumas builds minimas do jq vem sem oniguruma e nao tem test() nem gsub()
  jq -n '"x" | test("x")' >/dev/null 2>&1 \
    || die "este jq nao tem suporte a regex (test/gsub). Use o jq da distribuicao, nao um binario minimo."

  oc whoami >/dev/null 2>&1 \
    || die "sem sessao ativa no cluster. Rode 'oc login' no cluster alvo antes."
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

# verdadeiro se a VM ja esta no estado alvo
matches_target() {
  jq -e --argjson hv "$HV_KEYS" --arg spin "$SPINLOCKS_TARGET" --arg grace "$GRACE_TARGET" '
    .spec.template.spec as $t
    | ($t.domain.features.hyperv // {})  as $h
    | ($t.domain.clock.timer // {})      as $ck
    | ((($hv - ($h|keys)) | length) == 0)
      and ((($h.spinlocks // {}).spinlocks // -1) == ($spin|tonumber))
      and (($h.synictimer // {}) | has("direct"))
      and ($ck.hpet.present == false)
      and ($ck | has("hyperv"))
      and ((($ck.pit // {}).tickPolicy // "") == "delay")
      and ((($ck.rtc // {}).tickPolicy // "") == "catchup")
      and (($t.domain.ioThreadsPolicy // "") != "")
      and (($t.terminationGracePeriodSeconds // 0) >= ($grace|tonumber))
  ' "$1" >/dev/null 2>&1
}

read -r -d '' JQ_AUDIT <<'JQEOF' || true
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
      (($hv_keys - ($h|keys)) | length) as $missing
      | if $missing > 0 then "PARTIAL"
        elif (($h.spinlocks // {}).spinlocks // -1) != ($spin|tonumber) then "PARTIAL"
        elif (($h.synictimer // {}) | has("direct") | not)               then "PARTIAL"
        else "COMPLETE" end
    end;

def clock_state:
  (.spec.template.spec.domain.clock.timer // null) as $t
  | if $t == null then "ABSENT"
    elif ($t.hpet.present == false)
         and ($t|has("hyperv"))
         and ((($t.pit // {}).tickPolicy // "") == "delay")
         and ((($t.rtc // {}).tickPolicy // "") == "catchup") then "COMPLETE"
    else "PARTIAL" end;

def clock_offset:
  (.spec.template.spec.domain.clock // null) as $c
  | if $c == null then "ABSENT"
    elif ($c|has("utc"))      then "UTC"
    elif ($c|has("timezone")) then "TIMEZONE"
    else "NONE" end;

($vmisf[0] | map({key:"\(.metadata.namespace)/\(.metadata.name)", value:.}) | from_entries) as $VMIS
| ($grace|tonumber) as $GRACE
| .items[]
| . as $vm
| $vm.metadata.namespace as $ns
| $vm.metadata.name      as $name
| ($VMIS["\($ns)/\($name)"] // null)            as $vmi
| ((($vmi.status // {}).guestOSInfo // {}).id   // "")  as $osid
| ((($vmi.status // {}).guestOSInfo // {}).name // "")  as $osname
| ($vm.status.printableStatus // "Unknown")     as $pstatus
| ($vm.spec.template.spec.terminationGracePeriodSeconds // -1) as $g
| ($vm.spec.template.spec.domain.ioThreadsPolicy // "")        as $iop
| ($vm | hv_state)     as $hvs
| ($vm | clock_state)  as $cks
| ($vm | clock_offset) as $cko
| ($vm | owner)        as $own
| ([ ($vm.spec.template.spec.domain.devices.disks // [])[]
     | ((.disk // {}).bus // (.lun // {}).bus // (.cdrom // {}).bus // "none") ] | unique | join(";")) as $buses
| (($vm.metadata.labels // {})["vm.kubevirt.io/template"] // "-") as $tmpl
| (if $pstatus != "Running" or $vmi == null then {c:"SKIP",  r:"NOT_RUNNING"}
   elif ($osid == "" and $osname == "")     then {c:"SKIP",  r:"NO_GUEST_AGENT"}
   elif ($osid != "mswindows" and ($osname | ascii_downcase | test("windows") | not))
                                            then {c:"SKIP",  r:"NOT_WINDOWS"}
   elif $own != null                        then {c:"BLOCK", r:"OWNED_BY_\($own)"}
   elif ($hvs == "PARTIAL" or $cks == "PARTIAL")
                                            then {c:"BLOCK", r:"PARTIAL_CONFIG_REVIEW"}
   elif ($hvs == "COMPLETE" and $cks == "COMPLETE" and $iop != "" and $g >= $GRACE)
                                            then {c:"SKIP",  r:"ALREADY_TUNED"}
   elif ($hvs == "COMPLETE" and $cks == "COMPLETE" and $g >= $GRACE)
                                            then {c:"ELIGIBLE", r:"IOTHREADS_ONLY"}
   else {c:"ELIGIBLE", r:"MISSING_BASELINE"} end) as $cls
| { namespace: $ns, vm: $name,
    classification: $cls.c, reason: $cls.r,
    os: ($osname | if . == "" then $osid else . end | gsub(",";" ")),
    hyperv: $hvs, clock: $cks, clock_offset: $cko,
    iothreads: (if $iop == "" then "ABSENT" else $iop end),
    grace: ($g|tostring),
    disk_buses: $buses,
    template: $tmpl,
    canon: ($vm.spec.template.spec | tojson) }
JQEOF

# ------------------------------------------------------------------- audit

do_audit() {
  has_explicit_scope || die "escopo obrigatorio: use --all, -n NAMESPACE ou --vm NAMESPACE/NOME"
  mkdir -p "$OUTDIR"

  local cid; cid="$(cluster_id)"
  local plan="$OUTDIR/plan-${TS}.csv"
  local vmis="$OUTDIR/.vmis-${TS}.json"

  local -a q=(-A)
  if (( ${#SCOPE_NS[@]} == 1 )) && (( ${#SCOPE_VM[@]} == 0 )) && ! (( SCOPE_ALL )); then
    q=(-n "${SCOPE_NS[0]}")
  fi

  echo "vm-hyperv-tuning v${VERSION}  |  audit (somente leitura)"
  echo "cluster: $cid"
  echo "escopo:  $(scope_label)"
  echo

  oc get vmi "${q[@]}" -o json | jq '[.items[]]' > "$vmis"

  {
    echo "cluster,namespace,vm,classification,reason,os,hyperv,clock,clock_offset,iothreads,grace,disk_buses,template,fingerprint"
    oc get vm "${q[@]}" -o json \
      | jq -c --argjson hv_keys "$HV_KEYS" \
             --arg grace "$GRACE_TARGET" --arg spin "$SPINLOCKS_TARGET" \
             --slurpfile vmisf "$vmis" \
             "$JQ_AUDIT" \
      | while IFS= read -r line; do
          local ns vm fp
          ns="$(jq -r '.namespace' <<<"$line")"
          vm="$(jq -r '.vm' <<<"$line")"
          in_scope "$ns" "$vm" || continue
          fp="$(jq -r '.canon' <<<"$line" | sha256sum | cut -c1-16)"
          jq -r --arg c "$cid" --arg fp "$fp" \
            '[$c,.namespace,.vm,.classification,.reason,.os,.hyperv,.clock,.clock_offset,
              .iothreads,.grace,.disk_buses,.template,$fp] | @csv' <<<"$line"
        done
  } > "$plan"

  rm -f "$vmis"

  echo "plano: $plan"
  echo
  awk -F',' 'NR>1 {gsub(/"/,"",$4); c[$4]++} END {for (k in c) printf "  %-10s %d\n", k, c[k]}' "$plan"
  echo
  echo "Quebra dos ELIGIBLE:"
  awk -F',' 'NR>1 {gsub(/"/,"",$4); gsub(/"/,"",$5); if ($4=="ELIGIBLE") c[$5]++}
             END {for (k in c) printf "  %-18s %d\n", k, c[k]}' "$plan"
  echo "    MISSING_BASELINE = VM crua do Forklift"
  echo "    IOTHREADS_ONLY   = baseline oficial ja presente, falta so a adicao nossa"
  echo
  echo "Quebra dos SKIP e BLOCK:"
  awk -F',' 'NR>1 {gsub(/"/,"",$4); gsub(/"/,"",$5); if ($4!="ELIGIBLE") c[$5]++}
             END {for (k in c) printf "  %-24s %d\n", k, c[k]}' "$plan"
  echo
  echo "ELIGIBLE por namespace (unidade de onda):"
  awk -F',' 'NR>1 {gsub(/"/,"",$2); gsub(/"/,"",$4); if ($4=="ELIGIBLE") c[$2]++}
             END {for (k in c) printf "  %-45s %d\n", k, c[k]}' "$plan" | sort -k2 -rn
  echo
  echo "VMs com disco nao-virtio (ioThreadsPolicy fica inerte nelas):"
  awk -F',' 'NR>1 {gsub(/"/,"",$2); gsub(/"/,"",$3); gsub(/"/,"",$4); gsub(/"/,"",$12);
             if ($4=="ELIGIBLE" && $12 !~ /virtio/) print "  " $2 "/" $3 "  bus=" ($12=="" ? "-" : $12)}' "$plan" \
    | head -20
  echo
  echo "Proximo passo:  $0 apply -p $plan --dry-run"
}

# ------------------------------------------------------------------- apply

build_patch() {
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
  [[ -n "$PLAN" && -f "$PLAN" ]] || die "apply exige -p PLANO.csv valido"
  if (( LIMIT == 0 )) && ! has_explicit_scope; then
    die "-l 0 (sem limite) exige escopo explicito: --all, -n NAMESPACE ou --vm NAMESPACE/NOME"
  fi

  local base; base="$(dirname "$PLAN")"
  local undo_dir="$base/undo-${TS}"
  local diff_dir="$base/diff-${TS}"
  local applied="$base/applied-${TS}.csv"
  CAMPAIGN_LOG="$base/campaign-${TS}.log"
  mkdir -p "$undo_dir" "$diff_dir"

  local cid_now cid_plan
  cid_now="$(cluster_id)"
  cid_plan="$(awk -F',' 'NR==2 {gsub(/"/,"",$1); print $1; exit}' "$PLAN")"
  [[ -n "$cid_plan" ]] || die "plano vazio ou malformado"
  [[ "$cid_now" == "$cid_plan" ]] || \
    die "guarda de identidade: plano gerado em '$cid_plan', sessao atual em '$cid_now'"

  local plan_mtime age_h
  plan_mtime="$(stat -c %Y "$PLAN" 2>/dev/null || stat -f %m "$PLAN" 2>/dev/null || echo 0)"
  if [[ "$plan_mtime" =~ ^[0-9]+$ ]] && (( plan_mtime > 0 )); then
    age_h=$(( ( $(date +%s) - plan_mtime ) / 3600 ))
    (( age_h > 24 )) && warn "plano tem ${age_h}h. Drift provavel. Considere refazer o audit."
  fi

  has_explicit_scope || SCOPE_ALL=1

  # pre-passagem: conta o que sera tocado
  local n_target=0
  while IFS=',' read -r _c c_ns c_vm c_cls _rest; do
    c_ns="${c_ns//\"/}"; c_vm="${c_vm//\"/}"; c_cls="${c_cls//\"/}"
    [[ "$c_cls" == "ELIGIBLE" ]] || continue
    in_scope "$c_ns" "$c_vm" || continue
    n_target=$((n_target+1))
    if (( LIMIT > 0 && n_target >= LIMIT )); then break; fi
  done < <(tail -n +2 "$PLAN")

  echo "vm-hyperv-tuning v${VERSION}  |  apply"
  echo "cluster: $cid_now"
  echo "escopo:  $(scope_label)"
  echo "limite:  $LIMIT   (0 = sem limite)"
  echo "alvo:    $n_target VM(s) nesta execucao"
  (( DRYRUN )) && echo "modo:    DRY-RUN server-side, nada e gravado"
  echo

  (( n_target )) || { echo "Nenhuma VM ELIGIBLE dentro do escopo. Nada a fazer."; return 0; }

  if (( DRYRUN == 0 && ASSUME_YES == 0 )); then
    [[ -t 0 ]] || die "sessao nao interativa. Use --yes para confirmar automaticamente."
    echo "  O patch NAO reinicia VM. Ele fica pendente ate SHUTDOWN COMPLETO do guest."
    echo "  Reboot de dentro do Windows nao serve."
    echo
    local ans
    read -r -p "  Digite 'aplicar' para confirmar: " ans
    [[ "$ans" == "aplicar" ]] || die "cancelado pelo operador"
    echo
  fi

  (( DRYRUN == 0 )) && echo "cluster,namespace,vm,applied_at" > "$applied"

  local done=0 ok=0 fail=0 held=0 already=0
  while IFS=',' read -r c_cluster c_ns c_vm c_cls c_reason c_os c_hv c_ck c_cko c_io c_gr c_buses c_tmpl c_fp; do
    local v
    for v in c_ns c_vm c_cls c_cko c_fp; do eval "$v=\${$v//\\\"/}"; done
    [[ "$c_cls" == "ELIGIBLE" ]] || continue
    in_scope "$c_ns" "$c_vm" || continue
    if (( LIMIT > 0 && done >= LIMIT )); then held=$((held+1)); continue; fi

    local tag="$c_ns/$c_vm"
    local before="$diff_dir/${c_ns}__${c_vm}.before.json"
    local after="$diff_dir/${c_ns}__${c_vm}.after.json"

    if ! oc get vm "$c_vm" -n "$c_ns" -o json > "$before" 2>/dev/null; then
      echo "  $tag  FALHA  VM_NAO_ENCONTRADA"; log "$tag	FAIL	VM_NOT_FOUND"
      fail=$((fail+1)); continue
    fi

    if matches_target "$before"; then
      echo "  $tag  JA_APLICADO  (nada a fazer)"; log "$tag	SKIP	ALREADY_APPLIED"
      already=$((already+1)); continue
    fi

    local fp_now
    fp_now="$(jq -c '.spec.template.spec' "$before" | sha256sum | cut -c1-16)"
    if [[ "$fp_now" != "$c_fp" ]]; then
      echo "  $tag  PULADO  DRIFT: a VM mudou desde o audit. Refaca o audit."
      log "$tag	SKIP	DRIFT"; fail=$((fail+1)); continue
    fi

    done=$((done+1))
    local p; p="$(build_patch "$c_cko")"

    if (( DRYRUN )); then
      if ! oc patch vm "$c_vm" -n "$c_ns" --type merge --dry-run=server -o json -p "$p" > "$after"; then
        echo "  $tag  FALHA  PATCH_DRYRUN"; fail=$((fail+1)); continue
      fi
    else
      build_undo "$before" "$c_cko" > "$undo_dir/${c_ns}__${c_vm}.merge.json.pending"
      if ! oc patch vm "$c_vm" -n "$c_ns" --type merge -p "$p" >/dev/null; then
        echo "  $tag  FALHA  PATCH"; log "$tag	FAIL	PATCH"
        rm -f "$undo_dir/${c_ns}__${c_vm}.merge.json.pending"; fail=$((fail+1)); continue
      fi
      oc get vm "$c_vm" -n "$c_ns" -o json > "$after"
    fi

    local delta out_of_scope
    delta="$(comm -3 <(flatten_spec < "$before") <(flatten_spec < "$after") \
             | tr -d '\t' | sed 's/^ *//' | sort -u)"
    out_of_scope="$(grep -vE "$ALLOW_RE" <<<"$delta" || true)"

    if [[ -n "$out_of_scope" ]]; then
      echo "  $tag  FALHA  DELTA FORA DE ESCOPO"
      sed 's/^/      /' <<<"$out_of_scope"
      log "$tag	FAIL	OUT_OF_SCOPE"
      if (( DRYRUN == 0 )); then
        oc patch vm "$c_vm" -n "$c_ns" --type merge \
          -p "$(cat "$undo_dir/${c_ns}__${c_vm}.merge.json.pending")" >/dev/null || true
        echo "      revertido automaticamente"; log "$tag	ROLLED_BACK	OUT_OF_SCOPE"
      fi
      rm -f "$undo_dir/${c_ns}__${c_vm}.merge.json.pending"
      fail=$((fail+1)); continue
    fi

    if (( DRYRUN == 0 )); then
      mv "$undo_dir/${c_ns}__${c_vm}.merge.json.pending" "$undo_dir/${c_ns}__${c_vm}.merge.json"
      printf '"%s","%s","%s","%s"\n' "$cid_now" "$c_ns" "$c_vm" "$NOW" >> "$applied"
    fi

    echo "  $tag  OK  ($(grep -c . <<<"$delta") caminhos alterados)"
    log "$tag	OK	$(tr '\n' ' ' <<<"$delta")"
    ok=$((ok+1))
  done < <(tail -n +2 "$PLAN")

  echo
  echo "ok=$ok  ja-aplicado=$already  falha=$fail  fora-do-limite=$held"
  (( fail )) && EXIT_CODE=1

  if (( DRYRUN == 0 && ok > 0 )); then
    echo
    echo "aplicados: $applied"
    echo "undo:      $undo_dir      <- guarde este diretorio"
    echo "log:       $CAMPAIGN_LOG"
    echo
    echo "==================================================================="
    echo " PENDENTE. Nenhuma VM foi desligada."
    echo
    echo " O patch so entra apos SHUTDOWN COMPLETO do guest e religar."
    echo " Reboot de dentro do Windows NAO serve."
    echo "==================================================================="
    echo
    echo "Acompanhe com:  $0 status -p $PLAN"
  fi
}

# ------------------------------------------------------------------ status

do_status() {
  [[ -n "$PLAN" && -f "$PLAN" ]] || die "status exige -p PLANO.csv valido"
  local base; base="$(dirname "$PLAN")"
  has_explicit_scope || SCOPE_ALL=1

  local applied_all; applied_all="$(mktemp)"
  cat "$base"/applied-*.csv 2>/dev/null | grep -v '^cluster,' | tr -d '"' \
    | sort -t',' -k2,3 -k4,4r | awk -F',' '!seen[$2","$3]++' > "$applied_all" || true
  if [[ ! -s "$applied_all" ]]; then
    rm -f "$applied_all"; die "nenhum applied-*.csv em $base. Rode o apply primeiro."
  fi

  local vmis; vmis="$(mktemp)"
  oc get vmi -A -o json \
    | jq -r '.items[] | "\(.metadata.namespace),\(.metadata.name),\(.metadata.creationTimestamp)"' \
    > "$vmis"

  echo "vm-hyperv-tuning v${VERSION}  |  status"
  echo
  printf '%-45s %-24s %-12s %s\n' NAMESPACE VM ESTADO DETALHE
  local n_staged=0 n_landed=0 n_stopped=0

  while IFS=',' read -r a_cluster a_ns a_vm a_at; do
    in_scope "$a_ns" "$a_vm" || continue
    local vmi_ct
    vmi_ct="$(awk -F',' -v n="$a_ns" -v v="$a_vm" '$1==n && $2==v {print $3; exit}' "$vmis")"
    if [[ -z "$vmi_ct" || "$vmi_ct" == "null" ]]; then
      printf '%-45s %-24s %-12s %s\n' "$a_ns" "$a_vm" "PARADA" "entra ao ligar"
      n_stopped=$((n_stopped+1))
    elif [[ "$vmi_ct" > "$a_at" ]]; then
      printf '%-45s %-24s %-12s %s\n' "$a_ns" "$a_vm" "APLICADO" "vmi $vmi_ct"
      n_landed=$((n_landed+1))
    else
      printf '%-45s %-24s %-12s %s\n' "$a_ns" "$a_vm" "PENDENTE" "aguarda shutdown"
      n_staged=$((n_staged+1))
    fi
  done < "$applied_all"

  rm -f "$applied_all" "$vmis"
  echo
  echo "aplicado=$n_landed  pendente=$n_staged  parada=$n_stopped"
  echo
  echo "PENDENTE e o indicador de risco da campanha: o spec da VM diverge do"
  echo "dominio em execucao. Um reboot fora de janela muda o hardware virtual"
  echo "do Windows sem aviso. Reduza esse numero negociando janelas."
  echo
  echo "Conferencia pontual de uma VM APLICADO:"
  echo "  oc exec -n <ns> <virt-launcher-pod> -c compute -- virsh dumpxml 1 | grep -A3 hyperv"
}

# -------------------------------------------------------------------- undo

do_undo() {
  [[ -n "$UNDODIR" && -d "$UNDODIR" ]] || die "undo exige -u DIR_UNDO valido"
  if (( LIMIT == 0 )) && ! has_explicit_scope; then
    die "-l 0 (sem limite) exige escopo explicito"
  fi
  has_explicit_scope || SCOPE_ALL=1
  CAMPAIGN_LOG="$UNDODIR/undo-${TS}.log"

  echo "vm-hyperv-tuning v${VERSION}  |  undo"
  echo "escopo: $(scope_label)"
  echo

  local done=0 f
  shopt -s nullglob
  local -a files=("$UNDODIR"/*.merge.json)
  shopt -u nullglob
  (( ${#files[@]} )) || die "nenhum arquivo de undo em $UNDODIR"

  for f in "${files[@]}"; do
    local b ns vm
    b="$(basename "$f" .merge.json)"; ns="${b%%__*}"; vm="${b##*__}"
    in_scope "$ns" "$vm" || continue
    if (( LIMIT > 0 && done >= LIMIT )); then break; fi
    done=$((done+1))
    if oc patch vm "$vm" -n "$ns" --type merge -p "$(cat "$f")" >/dev/null 2>&1; then
      echo "  $ns/$vm  REVERTIDO"; log "$ns/$vm	UNDO_OK	"
    else
      echo "  $ns/$vm  FALHA"; log "$ns/$vm	UNDO_FAIL	"; EXIT_CODE=1
    fi
  done

  echo
  echo "log: $CAMPAIGN_LOG"
  echo "A reversao tambem so vale no proximo boot completo do guest."
}

# --------------------------------------------------------------------- main

CMD="${1:-}"
case "$CMD" in
  audit|apply|status|undo) ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) echo "ERRO: comando invalido ou ausente: '$CMD'." >&2
     echo "Use um comando: audit | apply | status | undo   (veja '$0 -h')." >&2
     exit 2 ;;
esac
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)  SCOPE_ALL=1;      shift ;;
    -n)     SCOPE_NS+=("$2"); shift 2 ;;
    --vm)   SCOPE_VM+=("$2"); shift 2 ;;
    -o)     OUTDIR="$2";      shift 2 ;;
    -p)     PLAN="$2";        shift 2 ;;
    -u)     UNDODIR="$2";     shift 2 ;;
    -l)     LIMIT="$2";       shift 2 ;;
    --dry-run) DRYRUN=1;      shift ;;
    --yes)  ASSUME_YES=1;     shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERRO: opcao desconhecida: $1" >&2; echo "Rode '$0 -h' para ajuda." >&2; exit 2 ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "-l precisa ser um inteiro >= 0"
preflight

case "$CMD" in
  audit)  do_audit  ;;
  apply)  do_apply  ;;
  status) do_status ;;
  undo)   do_undo   ;;
  *) echo "ERRO: comando invalido: $CMD" >&2; echo "Rode '$0 -h' para ajuda." >&2; exit 2 ;;
esac

exit $EXIT_CODE

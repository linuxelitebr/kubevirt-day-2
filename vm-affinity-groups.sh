#!/usr/bin/env bash
# vm-affinity-groups.sh
#
# Keeps groups of KubeVirt VMs on different nodes (anti-affinity) or on the
# same node (affinity), without restarting or migrating anything that is
# already where it should be.
#
# Each member VM gets a group label and a pod (anti-)affinity rule. The label
# goes to three places, because KubeVirt does not propagate labels to running
# objects (measured on OpenShift Virtualization 4.21, vmRolloutStrategy
# LiveUpdate):
#   VM template        survives restarts (a new VMI is built from it)
#   VMI                survives migrations (the target pod copies VMI labels)
#   virt-launcher pod  counts right now for the scheduler
# The rule goes to the VM template. With LiveUpdate KubeVirt copies it to the
# running VMI on its own; the running pod keeps its old spec (pod specs are
# immutable), so the rule binds from the next migration or restart on.
#
# The rule uses matchExpressions (key In [group]), the same shape the console's
# affinity editor writes, so the console shows it. A group spread over several
# namespaces also gets a namespaces list (without it, a term only sees its own
# namespace); the console cannot show that field and drops it when someone saves
# the VM's affinity there. 'verify' flags it and 'apply' puts it back. Rules
# written by older versions of this script (matchLabels) are recognized and
# converted by 'apply'.
#
# Things the rules do not do on their own, and how this script covers them:
#   - Affinity is IgnoredDuringExecution: VMs that already break a rule stay
#     put. 'verify' reports them, 'fix' moves them with live migration.
#   - An affinity group splits on any migration of a member (drain,
#     descheduler, manual): KubeVirt never lands a migration on the source
#     node. 'fix' brings the member back to the group's node.
#   - A preferred anti-affinity rule can lose to the scheduler's resource
#     scoring. 'fix' sends each extra member to a node with no member.
#   - After undo or a group change, the running pod keeps the old rule and
#     still repels the group (required anti-affinity works both ways).
#     'verify' lists these pods, 'renew' (or 'fix') replaces them.
#
# Usage:
#   vm-affinity-groups.sh <mode> -f groups.txt --prefix <domain> [options]
#   vm-affinity-groups.sh renew --prefix <domain> [-y]
#
# Modes:
#   plan     show what apply would change; changes nothing
#   apply    write labels and rules, then run verify
#   verify   check template, VMI, pod, real placement and outdated pod rules
#   fix      live-migrate members that break their group rule (asks first)
#   undo     remove this script's labels and rules from the groups' VMs
#   renew    live-migrate VMs whose running pod still has an outdated rule
#
# Options:
#   -f FILE                    groups file (all modes but renew)
#   --prefix DOMAIN            label prefix, e.g. example.com (or AFFINITY_PREFIX)
#   --group NAME               act on one group only (repeatable)
#   --allow-required-affinity  accept 'affinity ... required' groups (see below)
#   -y                         do not ask before migrating (fix, renew)
#   OC_CONTEXT=<ctx>           environment variable to target another cluster
#
# Groups file, one group per line:
#   # kind      group     rule       members (name or namespace/name)
#   anti        db        required   db-1 db-2 prod/db-3
#   affinity    app-web   preferred  app-1 web-1
#
# Labels written: <prefix>/anti-affinity=<group> and <prefix>/affinity=<group>.
# A group name is a label value: up to 63 characters, letters, digits, '-',
# '_' and '.', starting and ending alphanumeric. A VM can be in one anti group
# and one affinity group, not two of the same kind (a label key holds one
# value). Bare names are searched in every namespace, case-insensitively; a
# name found in two namespaces is refused, use namespace/name for it.
#
# Guard rails:
#   Any error in the groups file stops apply, fix and undo before they change
#   anything. A VM with a migration in progress is skipped; run again later.
#   anti/required with more members than schedulable nodes is refused (the
#   extra VM would stay Pending). With exactly as many members as nodes it
#   warns: draining any node of the group then has nowhere to send its VM.
#   affinity/required is refused unless --allow-required-affinity: such a
#   group cannot live-migrate (the migration target must sit next to the
#   group, but KubeVirt forbids it on the source node, so it never schedules).
#
# Needs bash 4+, jq and oc. Exit codes: 0 no problems, 1 bad input or
# cluster access, 2 finished with problems (listed in the output).

set -uo pipefail

[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "ERROR: bash 4 or newer required" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }

OC=(oc --request-timeout=30s)
[ -n "${OC_CONTEXT:-}" ] && OC+=(--context "$OC_CONTEXT")
HOST_KEY="kubernetes.io/hostname"
MIGRATION_TIMEOUT=420

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*"; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ---------- arguments ----------
mode=${1:-}; shift || true
case "$mode" in plan|apply|verify|fix|undo|renew) ;; *) usage ;; esac
file=""; prefix=${AFFINITY_PREFIX:-}; only=(); allow_req_aff=0; assume_yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    -f) file=${2:-}; shift 2 ;;
    --prefix) prefix=${2:-}; shift 2 ;;
    --group) [ -n "${2:-}" ] || die "--group needs a name"; only+=("$2"); shift 2 ;;
    --allow-required-affinity) allow_req_aff=1; shift ;;
    -y) assume_yes=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
if [ "$mode" != renew ]; then
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "groups file not found: $file"
fi

# ---------- label validation (Kubernetes rules) ----------
prefix=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')
[ -n "$prefix" ] || die "--prefix is required (a DNS name you own, e.g. example.com)"
[ ${#prefix} -le 253 ] || die "prefix longer than 253 characters"
[[ "$prefix" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]] \
  || die "prefix '$prefix' is not a valid DNS subdomain"
case "$prefix" in kubernetes.io|*.kubernetes.io|k8s.io|*.k8s.io) die "prefix '$prefix' is reserved by Kubernetes" ;; esac
KEY_ANTI="$prefix/anti-affinity"
KEY_AFF="$prefix/affinity"

valid_value() { [ ${#1} -le 63 ] && [[ "$1" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]]; }

# ---------- cluster inventory ----------
inv=$("${OC[@]}" get vm -A -o json) || die "cannot list VirtualMachines"
inv_lines=$(jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' <<<"$inv")
rollout=$("${OC[@]}" get kubevirt -A -o jsonpath='{.items[0].spec.configuration.vmRolloutStrategy}' 2>/dev/null)
nodes_json=$("${OC[@]}" get nodes -o json) || die "cannot list nodes"
eligible_nodes=$(jq '[.items[] | select(.metadata.labels["kubevirt.io/schedulable"]=="true")
  | select((.spec.unschedulable // false) | not)
  | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length' <<<"$nodes_json")
eligible_names=$(jq -r '.items[] | select(.metadata.labels["kubevirt.io/schedulable"]=="true")
  | select((.spec.unschedulable // false) | not)
  | select(any(.status.conditions[]; .type=="Ready" and .status=="True")) | .metadata.name' <<<"$nodes_json")

resolve() { # name or ns/name -> "ns name", or an error message on stderr
  local m=${1,,} hits n
  if [[ "$m" == */* ]]; then
    hits=$(awk -v ns="${m%%/*}" -v n="${m#*/}" '$1==ns && $2==n' <<<"$inv_lines")
  else
    hits=$(awk -v n="$m" '$2==n' <<<"$inv_lines")
  fi
  n=$(grep -c . <<<"$hits" || true)
  if [ "$n" -eq 0 ]; then echo "not found: $1" >&2; return 1; fi
  if [ "$n" -gt 1 ]; then echo "ambiguous: $1 exists in $(awk '{print $1}' <<<"$hits" | tr '\n' ' ')(use namespace/name)" >&2; return 1; fi
  echo "$hits"
}

# ---------- parse groups ----------
[ "$mode" = renew ] && file=/dev/null
declare -A G_KIND G_RULE G_MEMBERS G_NS SEEN_IN
groups=(); errors=0
while read -r kind group rule rest; do
  [ -z "${kind:-}" ] && continue
  case "$kind" in \#*) continue ;; esac
  if [ ${#only[@]} -gt 0 ] && ! printf '%s\n' "${only[@]}" | grep -qx -- "$group"; then continue; fi
  case "$kind" in anti|affinity) ;; *) echo "ERROR: group '$group': kind must be anti or affinity, got '$kind'"; errors=$((errors+1)); continue ;; esac
  case "$rule" in required|preferred) ;; *) echo "ERROR: group '$group': rule must be required or preferred, got '$rule'"; errors=$((errors+1)); continue ;; esac
  if ! valid_value "$group"; then
    echo "ERROR: group '$group' is not a valid label value (max 63 chars: letters, digits, '-', '_', '.', alphanumeric at both ends)"; errors=$((errors+1)); continue
  fi
  id="$kind/$group"
  [ -n "${G_KIND[$id]:-}" ] && { echo "ERROR: group '$group' ($kind) defined twice"; errors=$((errors+1)); continue; }
  if [ "$kind" = affinity ] && [ "$rule" = required ] && [ $allow_req_aff -eq 0 ]; then
    echo "ERROR: group '$group': affinity/required blocks live migration of its VMs; use preferred, or pass --allow-required-affinity"; errors=$((errors+1)); continue
  fi
  members=(); bad=0
  for m in $rest; do
    if r=$(resolve "$m" 2>/tmp/vag.$$); then
      ref="${r% *}/${r#* }"
      if [ -n "${SEEN_IN[$kind:$ref]:-}" ]; then
        echo "ERROR: $ref is in $kind groups '${SEEN_IN[$kind:$ref]}' and '$group' (one $kind group per VM)"; bad=1
      else SEEN_IN[$kind:$ref]=$group; members+=("$ref"); fi
    else echo "ERROR: group '$group': $(cat /tmp/vag.$$)"; bad=1; fi
  done
  rm -f /tmp/vag.$$
  [ $bad -eq 1 ] && { errors=$((errors+1)); continue; }
  [ ${#members[@]} -ge 2 ] || { echo "ERROR: group '$group' needs at least 2 VMs"; errors=$((errors+1)); continue; }
  if [ "$kind" = anti ] && [ "$rule" = required ]; then
    if [ ${#members[@]} -gt "$eligible_nodes" ]; then
      echo "ERROR: group '$group': ${#members[@]} VMs with required anti-affinity but only $eligible_nodes schedulable nodes; the extra VMs would stay Pending"; errors=$((errors+1)); continue
    elif [ ${#members[@]} -eq "$eligible_nodes" ]; then
      warn "group '$group': ${#members[@]} VMs on $eligible_nodes schedulable nodes leaves no spare node; draining one of them will block (its VM has nowhere to go)"
    fi
  fi
  [ "$kind" = affinity ] && [ "$rule" = required ] && warn "group '$group': affinity/required accepted; its VMs will not live-migrate"
  G_KIND[$id]=$kind; G_RULE[$id]=$rule; G_MEMBERS[$id]="${members[*]}"
  G_NS[$id]=$(printf '%s\n' "${members[@]}" | cut -d/ -f1 | sort -u | jq -R . | jq -sc .)
  groups+=("$id")
done < "$file"

[ ${#groups[@]} -gt 0 ] || [ "$mode" = renew ] || die "no valid group to work on ($errors error(s))"
case "$mode" in apply|fix|undo) [ $errors -eq 0 ] || die "$errors error(s) in $file; fix them first, nothing was changed" ;; esac
[ "$rollout" = LiveUpdate ] || warn "vmRolloutStrategy is '${rollout:-unknown}', not LiveUpdate: new rules reach running VMIs only after a restart"

# ---------- helpers ----------
key_of()   { [ "$1" = anti ] && echo "$KEY_ANTI" || echo "$KEY_AFF"; }
field_of() { [ "$1" = anti ] && echo podAntiAffinity || echo podAffinity; }

# affinity JSON on stdin -> same without the terms that select on $key
JQ_STRIP='
# A term is ours when its selector uses our key, in either form: matchLabels
# (older runs of this script) or matchExpressions (current, what the console shows).
def mine($k): (.labelSelector // .podAffinityTerm.labelSelector // {}) as $s
  | (($s.matchLabels // {}) | has($k)) or ([$s.matchExpressions[]? | .key] | index($k) != null);
def keep($k): map(select(mine($k) | not));
def strip($k):
  (. // {})
  | reduce ("podAffinity","podAntiAffinity") as $t (.;
      if .[$t] == null then . else
        .[$t] |= reduce ("requiredDuringSchedulingIgnoredDuringExecution","preferredDuringSchedulingIgnoredDuringExecution") as $f (.;
          if .[$f] == null then . else (.[$f] |= keep($k)) | (if (.[$f] | length) == 0 then del(.[$f]) else . end) end)
        | (if (.[$t] | length) == 0 then del(.[$t]) else . end)
      end);
# matchExpressions, not matchLabels: same pods selected, and it is the only form
# the console affinity editor can display (it shows matchLabels rules as empty).
# namespaces only when the group spans more than one: without the field a term
# already looks at its own namespace, and that is exactly what the console writes.
def term($k; $g; $ns): {labelSelector: {matchExpressions: [{key: $k, operator: "In", values: [$g]}]}}
  + (if ($ns | length) > 1 then {namespaces: $ns} else {} end) + {topologyKey: $host};
def add($t; $rule; $k; $g; $ns):
  if $rule == "required" then .[$t].requiredDuringSchedulingIgnoredDuringExecution += [term($k; $g; $ns)]
  else .[$t].preferredDuringSchedulingIgnoredDuringExecution += [{weight: 100, podAffinityTerm: term($k; $g; $ns)}] end;
def norm: if . == {} then null else . end;
'
desired_affinity() { # current-affinity-json kind rule group ns-json
  jq -c --arg k "$(key_of "$2")" --arg t "$(field_of "$2")" --arg rule "$3" --arg g "$4" \
     --argjson ns "$5" --arg host "$HOST_KEY" "$JQ_STRIP strip(\$k) | add(\$t; \$rule; \$k; \$g; \$ns) | norm" <<<"$1"
}
stripped_affinity() { # current-affinity-json kind
  jq -c --arg k "$(key_of "$2")" --arg host "$HOST_KEY" "$JQ_STRIP strip(\$k) | norm" <<<"$1"
}
rule_state() { # affinity-json kind rule group ns-json -> ok | old-format | no-namespaces | missing
  jq -r --arg k "$(key_of "$2")" --arg t "$(field_of "$2")" --arg rule "$3" --arg g "$4" --argjson ns "$5" '
    (if $rule == "required" then [.[$t].requiredDuringSchedulingIgnoredDuringExecution[]?]
     else [.[$t].preferredDuringSchedulingIgnoredDuringExecution[]? | .podAffinityTerm] end) as $terms
    | ($terms | map(select(.labelSelector.matchExpressions == [{key: $k, operator: "In", values: [$g]}]))) as $new
    | if ($new | map(select(((.namespaces // []) | sort) == ($ns | sort) or (($ns | length) == 1 and ((.namespaces // []) | length) == 0))) | length) > 0 then "ok"
      elif ($new | length) > 0 then "no-namespaces"
      elif ($terms | map(select(.labelSelector.matchLabels[$k]? == $g)) | length) > 0 then "old-format"
      else "missing" end' <<<"${1:-null}"
}
# pod (anti-)affinity terms whose selector selects every pod: an empty labelSelector.
# The console leaves these behind when it saves a rule it could not read.
empty_selectors() { # affinity-json -> count
  jq -r '[(.podAffinity, .podAntiAffinity)? // empty
    | (.requiredDuringSchedulingIgnoredDuringExecution[]?, .preferredDuringSchedulingIgnoredDuringExecution[]?.podAffinityTerm)
    | (.labelSelector // {}) | select(((.matchLabels // {}) | length) == 0 and ((.matchExpressions // []) | length) == 0)] | length' <<<"${1:-null}"
}

vmi_json()   { "${OC[@]}" get vmi "$2" -n "$1" -o json 2>/dev/null; }
# the pod that runs the VM now: same VMI uid, Running, on the VMI's node
active_pod() { # ns vmi-json -> pod name
  local uid node
  uid=$(jq -r .metadata.uid <<<"$2"); node=$(jq -r '.status.nodeName // ""' <<<"$2")
  "${OC[@]}" get pods -n "$1" -l "kubevirt.io/created-by=$uid" -o json 2>/dev/null \
    | jq -r --arg n "$node" '[.items[] | select(.status.phase=="Running" and .spec.nodeName==$n)][0].metadata.name // ""'
}
# a migration counts as running until its VMIM ends; migrationState.completed
# flips before the VMI points at the target node, so it is not enough
migrating() { # ns vmi-name
  "${OC[@]}" get vmim -n "$1" -o json 2>/dev/null \
    | jq -e --arg v "$2" '[.items[] | select(.spec.vmiName == $v and (.status.phase != "Succeeded" and .status.phase != "Failed"))] | length > 0' >/dev/null
}

set_template() { # ns name key value|"" affinity-json|null
  local patch
  if [ -n "$4" ]; then patch=$(jq -nc --arg k "$3" --arg v "$4" '{spec:{template:{metadata:{labels:{($k):$v}}}}}')
  else patch=$(jq -nc --arg k "$3" '{spec:{template:{metadata:{labels:{($k):null}}}}}'); fi
  "${OC[@]}" patch vm "$2" -n "$1" --type merge -p "$patch" >/dev/null || return 1
  if [ "$5" = null ]; then
    local cur; cur=$("${OC[@]}" get vm "$2" -n "$1" -o jsonpath='{.spec.template.spec.affinity}')
    [ -z "$cur" ] || "${OC[@]}" patch vm "$2" -n "$1" --type json -p '[{"op":"remove","path":"/spec/template/spec/affinity"}]' >/dev/null
  else
    "${OC[@]}" patch vm "$2" -n "$1" --type json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/affinity\",\"value\":$5}]" >/dev/null
  fi
}
set_live_label() { # kind(vmi|pod) ns name key value|""
  [ -n "$3" ] || return 0
  if [ -n "$5" ]; then "${OC[@]}" label "$1" "$3" -n "$2" --overwrite "$4=$5" >/dev/null
  else "${OC[@]}" label "$1" "$3" -n "$2" "$4-" >/dev/null; fi
}

# ---------- per-VM work ----------
failures=0
apply_member() { # id ref  (dry=1 for plan)
  local id=$1 ref=$2 ns=${2%%/*} name=${2#*/} kind=${G_KIND[$1]} rule=${G_RULE[$1]} group=${1#*/}
  local key vm cur_aff want cur_lbl vmi pod changes=()
  key=$(key_of "$kind")
  # read the VM fresh: an earlier group in this run may have changed it
  vm=$("${OC[@]}" get vm "$name" -n "$ns" -o json) || { echo "  $ref: cannot read VM"; failures=$((failures+1)); return; }
  cur_aff=$(jq -c '.spec.template.spec.affinity' <<<"$vm")
  cur_lbl=$(jq -r --arg k "$key" '.spec.template.metadata.labels[$k] // ""' <<<"$vm")
  want=$(desired_affinity "$cur_aff" "$kind" "$rule" "$group" "${G_NS[$id]}")
  [ "$cur_lbl" = "$group" ] || changes+=("template label ${cur_lbl:-none}->$group")
  [ "$(jq -cS . <<<"$cur_aff")" = "$(jq -cS . <<<"$want")" ] || changes+=("template rule")
  vmi=$(vmi_json "$ns" "$name"); pod=""
  if [ -n "$vmi" ]; then
    if migrating "$ns" "$name"; then echo "  $ref: migration in progress, skipped (run again when it ends)"; failures=$((failures+1)); return; fi
    [ "$(jq -r --arg k "$key" '.metadata.labels[$k] // ""' <<<"$vmi")" = "$group" ] || changes+=("VMI label")
    pod=$(active_pod "$ns" "$vmi")
    if [ -n "$pod" ]; then
      [ "$("${OC[@]}" get pod "$pod" -n "$ns" -o json | jq -r --arg k "$key" '.metadata.labels[$k] // ""')" = "$group" ] || changes+=("pod label")
    fi
  fi
  if [ ${#changes[@]} -eq 0 ]; then echo "  $ref: up to date"; return; fi
  if [ "$mode" = plan ]; then echo "  $ref: would set $(IFS=,; echo "${changes[*]}")"; return; fi
  if set_template "$ns" "$name" "$key" "$group" "$want" \
     && { [ -z "$vmi" ] || set_live_label vmi "$ns" "$name" "$key" "$group"; } \
     && set_live_label pod "$ns" "$pod" "$key" "$group"; then
    echo "  $ref: set $(IFS=,; echo "${changes[*]}")"
  else echo "  $ref: FAILED"; failures=$((failures+1)); fi
}

undo_member() { # kind ref group|"" ; removes our key from template, VMI, pod and the rule
  local kind=$1 ref=$2 ns=${2%%/*} name=${2#*/} key cur_aff want vmi pod
  key=$(key_of "$kind")
  cur_aff=$("${OC[@]}" get vm "$name" -n "$ns" -o json | jq -c '.spec.template.spec.affinity')
  want=$(stripped_affinity "$cur_aff" "$kind")
  if [ "$mode" = plan ]; then echo "  $ref: would remove $key (no longer a member of '$3')"; return; fi
  vmi=$(vmi_json "$ns" "$name"); pod=""
  [ -n "$vmi" ] && pod=$(active_pod "$ns" "$vmi")
  if set_template "$ns" "$name" "$key" "" "$want" \
     && { [ -z "$vmi" ] || set_live_label vmi "$ns" "$name" "$key" ""; } \
     && set_live_label pod "$ns" "$pod" "$key" ""; then
    echo "  $ref: removed $key"
  else echo "  $ref: FAILED"; failures=$((failures+1)); fi
}

# VMs that carry this group's label but are not listed as members any more
stale_members() { # id
  local kind=${G_KIND[$1]} group=${1#*/} key
  key=$(key_of "$kind")
  jq -r --arg k "$key" --arg g "$group" '.items[] | select(.spec.template.metadata.labels[$k] == $g) | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$inv" \
    | while read -r r; do printf '%s\n' ${G_MEMBERS[$1]} | grep -qx -- "$r" || echo "$r"; done
}

# ---------- stale rules in running pods ----------
# A pod spec cannot change, so a pod keeps the rule it was created with. After
# a VM leaves a group (or after undo) its running pod still repels (anti) the
# group until the VM migrates or restarts. These are the pods whose rule
# differs from what their VMI says now.
JQ_TERMS='[ (. // {}) as $aff | ("podAffinity", "podAntiAffinity") as $t
  | ( ($aff[$t].requiredDuringSchedulingIgnoredDuringExecution[]? | {r: "required", s: .}),
      ($aff[$t].preferredDuringSchedulingIgnoredDuringExecution[]? | {r: "preferred", s: .podAffinityTerm}) )
  | .r as $r | .s.labelSelector as $l
  | ( (($l.matchLabels // {}) | to_entries[] | {key, value}),
      ($l.matchExpressions[]? | select(.operator == "In") | {key, value: .values[]}) )
  | select(.key == $a or .key == $b)
  | "\(.key)=\(.value) (\($r))"] | sort | unique'
stale_pods() { # -> "ns/vm key=value,..." per pod; non-zero exit if the check could not run
  # The VMI list goes through a file: on a large cluster it does not fit in a
  # command-line argument ("Argument list too long").
  local pods vmis rc
  vmis=$(mktemp) || return 1
  pods=$("${OC[@]}" get pods -A -l kubevirt.io=virt-launcher --field-selector=status.phase=Running -o json) \
    && "${OC[@]}" get vmi -A -o json > "$vmis" \
    || { rm -f "$vmis"; return 1; }
  jq -r --arg a "$KEY_ANTI" --arg b "$KEY_AFF" --slurpfile vmis "$vmis" "
    def terms: $JQ_TERMS;
    (\$vmis[0].items | map({key: \"\(.metadata.namespace)/\(.metadata.name)\", value: (.spec.affinity | terms)}) | from_entries) as \$want
    | .items[]
    | (\"\(.metadata.namespace)/\(.metadata.labels[\"vm.kubevirt.io/name\"])\") as \$ref
    | (.spec.affinity | terms) as \$have
    | (\$have - (\$want[\$ref] // [])) as \$extra
    | select(\$extra | length > 0)
    | \"\(\$ref) \(\$extra | join(\",\"))\"" <<<"$pods"
  rc=$?
  rm -f "$vmis"
  return $rc
}
report_stale() {
  local lines
  if ! lines=$(stale_pods); then echo "  ERROR: could not check the running pods for outdated rules"; failures=$((failures+1)); return; fi
  if [ -z "$lines" ]; then echo "  no running pod carries an outdated rule"; return; fi
  echo "  running pods with an outdated rule (pod specs are immutable; 'renew' replaces them with a live migration):"
  sed 's/^/    /' <<<"$lines"; failures=$((failures+1))
}

# ---------- verify ----------
verify_group() { # id -> prints, bumps failures
  local id=$1 kind=${G_KIND[$1]} rule=${G_RULE[$1]} group=${1#*/} key ref ns name vm vmi pod tl va pl here st es problems placement=()
  key=$(key_of "$kind")
  for ref in ${G_MEMBERS[$id]}; do
    ns=${ref%%/*}; name=${ref#*/}; problems=()
    vm=$("${OC[@]}" get vm "$name" -n "$ns" -o json)
    tl=$(jq -r --arg k "$key" '.spec.template.metadata.labels[$k] // ""' <<<"$vm")
    [ "$tl" = "$group" ] || problems+=("template label=${tl:-none}")
    st=$(rule_state "$(jq -c '.spec.template.spec.affinity' <<<"$vm")" "$kind" "$rule" "$group" "${G_NS[$id]}")
    [ "$st" = ok ] || problems+=("template rule $st")
    es=$(empty_selectors "$(jq -c '.spec.template.spec.affinity' <<<"$vm")")
    [ "$es" -eq 0 ] || problems+=("$es affinity term(s) with an empty selector, which matches every pod in the namespace (left by a console save?)")
    vmi=$(vmi_json "$ns" "$name"); va="-"; pl="no pod"; here="not running"
    if [ -n "$vmi" ]; then
      va=$(jq -r --arg k "$key" '.metadata.labels[$k] // ""' <<<"$vmi")
      [ "$va" = "$group" ] || problems+=("VMI label=${va:-none}")
      if [ "$rollout" = LiveUpdate ]; then
        st=$(rule_state "$(jq -c '.spec.affinity' <<<"$vmi")" "$kind" "$rule" "$group" "${G_NS[$id]}")
        [ "$st" = ok ] || problems+=("VMI rule $st")
      fi
      pod=$(active_pod "$ns" "$vmi")
      if [ -n "$pod" ]; then
        pl=$("${OC[@]}" get pod "$pod" -n "$ns" -o json | jq -r --arg k "$key" '.metadata.labels[$k] // ""')
        [ "$pl" = "$group" ] || problems+=("pod label=${pl:-none}")
        here="node $(jq -r '.status.nodeName' <<<"$vmi")"; placement+=("${here#node } $ref")
      fi
    fi
    if [ ${#problems[@]} -eq 0 ]; then echo "  $ref: ok ($here)"
    else echo "  $ref: PROBLEM $(IFS=,; echo "${problems[*]}")"; failures=$((failures+1)); fi
  done
  # real placement of the running members
  local running=${#placement[@]} distinct
  [ "$running" -lt 2 ] && { echo "  placement: fewer than 2 members running, nothing to compare"; return; }
  distinct=$(printf '%s\n' "${placement[@]}" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
  if [ "$kind" = anti ]; then
    if [ "$distinct" -eq "$running" ]; then echo "  placement: ok, $running running members on $distinct nodes"
    else echo "  placement: VIOLATION, $running running members on only $distinct nodes:"
      printf '%s\n' "${placement[@]}" | sort | awk '{print "    "$1"  "$2}'
      [ "$rule" = preferred ] && echo "    (preferred rule: the scheduler may accept this when it has no better node)"
      failures=$((failures+1)); fi
  else
    if [ "$distinct" -eq 1 ]; then echo "  placement: ok, $running running members together on ${placement[0]%% *}"
    else echo "  placement: VIOLATION, $running running members spread over $distinct nodes:"
      printf '%s\n' "${placement[@]}" | sort | awk '{print "    "$1"  "$2}'
      failures=$((failures+1)); fi
  fi
}

# ---------- fix ----------
migrate() { # ns name [node] -> waits, prints result
  local ns=$1 name=$2 node=${3:-} spec vmim phase t=0
  spec=$(jq -nc --arg v "$name" --arg n "$node" --arg h "$HOST_KEY" '{vmiName: $v} + (if $n == "" then {} else {addedNodeSelector: {($h): $n}} end)')
  vmim=$(jq -nc --arg ns "$ns" --argjson s "$spec" '{apiVersion:"kubevirt.io/v1",kind:"VirtualMachineInstanceMigration",metadata:{generateName:"affinity-fix-",namespace:$ns},spec:$s}' \
    | "${OC[@]}" create -f - -o jsonpath='{.metadata.name}') || { echo "    $ns/$name: could not create migration"; return 1; }
  echo "    $ns/$name: migration $vmim started${node:+ (target $node)}"
  while [ $t -lt $MIGRATION_TIMEOUT ]; do
    phase=$("${OC[@]}" get vmim "$vmim" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$phase" in Succeeded) echo "    $ns/$name: now on $("${OC[@]}" get vmi "$name" -n "$ns" -o jsonpath='{.status.nodeName}')"; return 0 ;;
                     Failed) echo "    $ns/$name: migration FAILED"; return 1 ;; esac
    sleep 5; t=$((t+5))
  done
  echo "    $ns/$name: migration $vmim not finished after ${MIGRATION_TIMEOUT}s (phase ${phase:-unknown}); check 'oc get vmim -n $ns'"; return 1
}
fix_group() { # id
  local id=$1 kind=${G_KIND[$1]} ref ns name node anchor="" target n moves=()
  declare -A count=() first_seen=()
  local -a placed=()
  for ref in ${G_MEMBERS[$id]}; do
    ns=${ref%%/*}; name=${ref#*/}
    node=$("${OC[@]}" get vmi "$name" -n "$ns" -o jsonpath='{.status.nodeName}' 2>/dev/null)
    [ -n "$node" ] || continue
    placed+=("$node $ref"); count[$node]=$(( ${count[$node]:-0} + 1 ))
  done
  if [ "$kind" = anti ]; then
    # the scheduler may still co-locate a preferred group (resource scoring can
    # outweigh it), so each extra member is sent to a node with no member
    for p in "${placed[@]}"; do node=${p%% *}; [ -n "${first_seen[$node]:-}" ] || first_seen[$node]=${p#* }; done
    for p in "${placed[@]}"; do node=${p%% *}; ref=${p#* }
      [ "${first_seen[$node]}" = "$ref" ] && continue
      target=""
      for n in $eligible_names; do [ -n "${first_seen[$n]:-}" ] || { target=$n; first_seen[$n]=$ref; break; }; done
      moves+=("$ref|$target")
    done
  else
    for node in "${!count[@]}"; do
      if [ -z "$anchor" ] || [ "${count[$node]}" -gt "${count[$anchor]}" ]; then anchor=$node; fi; done
    for p in "${placed[@]}"; do node=${p%% *}; ref=${p#* }; [ "$node" = "$anchor" ] || moves+=("$ref|$anchor"); done
  fi
  [ ${#moves[@]} -eq 0 ] && { echo "  nothing to move"; return; }
  for mv in "${moves[@]}"; do echo "  to move: ${mv%%|*} -> ${mv#*|}"; done
  [ "$kind" = anti ] && printf '%s\n' "${moves[@]}" | grep -q '|$' && echo "  (no free node left for some members: the scheduler picks their target)"
  if [ $assume_yes -eq 0 ]; then
    [ -t 0 ] || { echo "  not a terminal; pass -y to migrate"; failures=$((failures+1)); return; }
    read -r -p "  live-migrate these VMs now? [y/N] " a; a=${a//$'\r'/}
    case "$a" in y|Y|yes|s|S|sim) ;; *) echo "  skipped"; return ;; esac
  fi
  for mv in "${moves[@]}"; do ref=${mv%%|*}
    migrate "${ref%%/*}" "${ref#*/}" "${mv#*|}" || failures=$((failures+1))
  done
}

# ---------- main ----------
echo "== prefix: $prefix   schedulable nodes: $eligible_nodes   rollout: ${rollout:-unknown}"
[ $errors -gt 0 ] && echo "== $errors group(s) with errors were skipped (see above)"
# renew outdated pods first, so the placement fixes below see the current rules
if [ "$mode" = fix ] || [ "$mode" = renew ]; then
  echo; echo "== outdated rules in running pods"
  if ! stale=$(stale_pods); then echo "  ERROR: could not check the running pods for outdated rules"; failures=$((failures+1)); stale=""
  elif [ -z "$stale" ]; then echo "  none"
  else
    sed 's/^/  /' <<<"$stale"
    ok=$assume_yes
    if [ $ok -eq 0 ] && [ -t 0 ]; then read -r -p "  live-migrate these VMs to renew their pods? [y/N] " a; a=${a//$'\r'/}; case "$a" in y|Y|yes|s|S|sim) ok=1 ;; esac; fi
    if [ $ok -eq 1 ]; then
      while read -r ref _; do migrate "${ref%%/*}" "${ref#*/}" || failures=$((failures+1)); done <<<"$stale"
    else echo "  skipped (pass -y or answer y)"; failures=$((failures+1)); fi
  fi
fi

for id in "${groups[@]}"; do
  echo; echo "== ${G_KIND[$id]} group '${id#*/}' (${G_RULE[$id]}): ${G_MEMBERS[$id]}"
  case "$mode" in
    plan|apply)
      for ref in ${G_MEMBERS[$id]}; do apply_member "$id" "$ref"; done
      for ref in $(stale_members "$id"); do undo_member "${G_KIND[$id]}" "$ref" "${id#*/}"; done ;;
    undo)
      for ref in ${G_MEMBERS[$id]} $(stale_members "$id"); do undo_member "${G_KIND[$id]}" "$ref" "${id#*/}"; done ;;
    verify) verify_group "$id" ;;
    fix) fix_group "$id" ;;
  esac
done

if [ "$mode" = apply ] || [ "$mode" = fix ]; then
  echo; echo "== verify"
  inv=$("${OC[@]}" get vm -A -o json)
  sleep 3
  for id in "${groups[@]}"; do echo "-- ${id#*/}"; verify_group "$id"; done
fi
if [ "$mode" != plan ]; then echo; echo "== outdated rules in running pods (whole cluster)"; sleep 2; report_stale; fi
if [ "$mode" = undo ]; then
  echo; echo "== check"
  for id in "${groups[@]}"; do key=$(key_of "${G_KIND[$id]}")
    left=$("${OC[@]}" get vm -A -o json | jq -r --arg k "$key" --arg g "${id#*/}" '.items[] | select(.spec.template.metadata.labels[$k] == $g) | "\(.metadata.namespace)/\(.metadata.name)"')
    if [ -z "$left" ]; then echo "  ${id#*/}: no VM carries the label any more"; else echo "  ${id#*/}: still labelled: $left"; failures=$((failures+1)); fi
  done
fi
echo
[ "$mode" = plan ] && echo "Nothing was changed. Run 'apply' to make these changes."
total=$((failures+errors))
[ $total -gt 0 ] && { echo "Finished with $total problem(s)."; exit 2; }
echo "Done, no problems."
exit 0

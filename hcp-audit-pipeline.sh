#!/usr/bin/env bash
#
# hcp-audit-pipeline.sh
#
# Checks, and optionally sets up, the audit crossing that lets a hosted
# cluster's API server records reach its own log store, which is what OVTools
# reads to say who acted on a machine.
#
# A hosted cluster's API server runs as pods on the cluster hosting it, so its
# audit records are written there and never reach the guest on their own. The
# crossing has nine pieces spread over both clusters, which is a lot to hold in
# your head and the reason this exists. See quick-start-audit-pipeline.md for
# what each piece is for.
#
# Run it against the HOSTING cluster. It reads the guest's credentials out of
# the HostedCluster itself and does the guest half for you.
#
# Not destructive by construction:
#   - default is check only, --apply is the opt-in
#   - --apply creates what is missing and never rewrites what is there
#   - the one restart it can cause is called out before it happens
#
# Exit: 0 everything in place, 1 something missing, 2 could not look.

set -uo pipefail

HC_NAME=""
HC_NS=""
CONTEXT=""
GUEST_SERVER_OVERRIDE=""
APPLY=false
LOGGING_NS="openshift-logging"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; DIM=$'\033[2m'; NC=$'\033[0m'

MISSING=0
APPLIED=0
GUEST_KUBECONFIG=""

cleanup() { [[ -n "$GUEST_KUBECONFIG" && -f "$GUEST_KUBECONFIG" ]] && rm -f "$GUEST_KUBECONFIG"; }
trap cleanup EXIT

usage() {
    cat <<'USAGE'
Usage: hcp-audit-pipeline.sh [options] <hosted-cluster-name>

Checks the audit crossing for one hosted cluster, from the hosting cluster.
Reads the guest's credentials out of the HostedCluster and checks both halves.

Options:
  -n, --namespace NS   namespace holding the HostedCluster (default: search for it)
      --context CTX    hosting cluster context (default: current context)
      --guest-server URL
                       reach the guest at this address instead of the one in its
                       kubeconfig, for when that address is a load balancer this
                       machine cannot route to
      --apply          create what is missing (default: report only)
  -h, --help           this

To see the hosted clusters and the namespaces they are in:
  oc get hc -A

Examples:
  hcp-audit-pipeline.sh hosted-lab
  hcp-audit-pipeline.sh -n clusters hosted-lab
  hcp-audit-pipeline.sh --apply hosted-lab
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) HC_NS="${2:-}"; shift 2 ;;
        --context)      CONTEXT="${2:-}"; shift 2 ;;
        --guest-server) GUEST_SERVER_OVERRIDE="${2:-}"; shift 2 ;;
        --apply)        APPLY=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)              HC_NAME="$1"; shift ;;
    esac
done

[[ -z "$HC_NAME" ]] && { usage >&2; exit 2; }

# oc against the hosting cluster, with the context the caller chose.
host() { if [[ -n "$CONTEXT" ]]; then oc --context "$CONTEXT" "$@"; else oc "$@"; fi; }
# oc against the guest, through the kubeconfig pulled out of the HostedCluster.
guest() { KUBECONFIG="$GUEST_KUBECONFIG" oc "$@"; }

section() { printf '\n%s%s%s\n' "$BLUE" "$1" "$NC"; }
ok()      { printf '  %s[ ok ]%s %s\n' "$GREEN" "$NC" "$1"; }
miss()    { printf '  %s[miss]%s %s\n' "$YELLOW" "$NC" "$1"; MISSING=$((MISSING+1)); }
made()    { printf '  %s[made]%s %s\n' "$GREEN" "$NC" "$1"; APPLIED=$((APPLIED+1)); }
bad()     { printf '  %s[ !! ]%s %s\n' "$RED" "$NC" "$1"; }
note()    { printf '         %s%s%s\n' "$DIM" "$1" "$NC"; }
die()     { printf '\n%s%s%s\n' "$RED" "$1" "$NC" >&2; exit 2; }

# exists <where> <kind> <name> [namespace]
exists() {
    local where="$1" kind="$2" name="$3" ns="${4:-}"
    if [[ "$where" == host ]]; then
        if [[ -n "$ns" ]]; then host get "$kind" "$name" -n "$ns" >/dev/null 2>&1
        else host get "$kind" "$name" >/dev/null 2>&1; fi
    else
        if [[ -n "$ns" ]]; then guest get "$kind" "$name" -n "$ns" >/dev/null 2>&1
        else guest get "$kind" "$name" >/dev/null 2>&1; fi
    fi
}

command -v oc >/dev/null 2>&1 || die "oc is not on PATH."

section "Hosting cluster"
WHO=$(host whoami 2>/dev/null) || die "Cannot reach the hosting cluster. Check your context or log in."
ok "connected as ${WHO}"

if [[ -z "$HC_NS" ]]; then
    HC_NS=$(host get hostedcluster -A --no-headers 2>/dev/null | awk -v n="$HC_NAME" '$2==n {print $1; exit}')
    [[ -z "$HC_NS" ]] && die "No HostedCluster named ${HC_NAME}. Run 'oc get hc -A' to see the names and their namespaces."
fi
exists host hostedcluster "$HC_NAME" "$HC_NS" || die "No HostedCluster ${HC_NAME} in ${HC_NS}."
ok "HostedCluster ${HC_NS}/${HC_NAME}"

# HyperShift names the control plane namespace after both, which is where the
# API server pods and their audit log actually live.
HCP_NS="${HC_NS}-${HC_NAME}"
if exists host namespace "$HCP_NS"; then ok "control plane namespace ${HCP_NS}"
else die "Expected control plane namespace ${HCP_NS} and it is not there."; fi

exists host namespace "$LOGGING_NS" || die "No ${LOGGING_NS} namespace on the hosting cluster. The collector lives there; install logging first."
ok "${LOGGING_NS} namespace"

section "Guest credentials"
KCFG_SECRET=$(host get hostedcluster "$HC_NAME" -n "$HC_NS" -o jsonpath='{.status.kubeconfig.name}' 2>/dev/null)
[[ -z "$KCFG_SECRET" ]] && KCFG_SECRET="${HC_NAME}-admin-kubeconfig"
if ! exists host secret "$KCFG_SECRET" "$HC_NS"; then
    die "No kubeconfig secret ${KCFG_SECRET} in ${HC_NS}. Without it there is no way into the guest."
fi
ok "kubeconfig secret ${KCFG_SECRET}"

GUEST_KUBECONFIG=$(mktemp)
chmod 600 "$GUEST_KUBECONFIG"
if ! host get secret "$KCFG_SECRET" -n "$HC_NS" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d > "$GUEST_KUBECONFIG" 2>/dev/null; then
    die "Could not read the guest kubeconfig out of ${KCFG_SECRET}."
fi
[[ -s "$GUEST_KUBECONFIG" ]] || die "The guest kubeconfig in ${KCFG_SECRET} is empty."

# The kubeconfig names the guest by whatever address its API is published on,
# usually a load balancer. A bastion often cannot route there while it can
# reach a node port perfectly well, so the address is overridable and the
# serving certificate is not checked when it is, because it will not match.
if [[ -n "$GUEST_SERVER_OVERRIDE" ]]; then
    guest config set-cluster "$(guest config view -o jsonpath='{.clusters[0].name}')" \
        --server="$GUEST_SERVER_OVERRIDE" --insecure-skip-tls-verify=true >/dev/null 2>&1
fi
GUEST_SERVER=$(guest config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
if GUEST_WHO=$(guest whoami --request-timeout=15s 2>/dev/null); then
    ok "guest reachable at ${GUEST_SERVER} as ${GUEST_WHO}"
else
    bad "guest NOT reachable at ${GUEST_SERVER}"
    note "The kubeconfig is fine, the address is not routable from here."
    note "That address usually comes from a load balancer. Pass --guest-server with one this machine can reach, such as a node port."
    die "Stopping: the guest half cannot be checked from this machine."
fi

section "Guest side: who is allowed to write the audit tenant"
if ! exists guest namespace "$LOGGING_NS"; then
    bad "no ${LOGGING_NS} namespace on the guest"
    note "The log store lives there. Install logging on the guest first; this script does not."
    MISSING=$((MISSING+1))
fi

# Found rather than assumed. The gateway's Route is named after the LokiStack,
# so hard-coding one name would report a cluster that named its store something
# else as having no store at all.
LOKISTACK=$(guest get lokistack -n "$LOGGING_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$LOKISTACK" ]]; then
    ok "LokiStack ${LOKISTACK}"
else
    LOKISTACK="logging-loki"
    miss "no LokiStack in ${LOGGING_NS} on the guest"
    note "This is the store the records land in. See manifests/lokistack.yaml; not created here, it needs sizing and object storage decisions."
fi

if exists guest serviceaccount hcp-audit-writer "$LOGGING_NS"; then
    ok "ServiceAccount hcp-audit-writer"
elif $APPLY; then
    if guest create serviceaccount hcp-audit-writer -n "$LOGGING_NS" >/dev/null 2>&1; then
        made "ServiceAccount hcp-audit-writer"
    else
        bad "could not create ServiceAccount hcp-audit-writer"
    fi
else
    miss "ServiceAccount hcp-audit-writer"
fi

if exists guest clusterrole hcp-audit-writer; then
    ok "ClusterRole hcp-audit-writer"
elif $APPLY; then
    if guest apply -f - >/dev/null 2>&1 <<'ROLE'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hcp-audit-writer
rules:
  - apiGroups: ["loki.grafana.com"]
    resources: ["audit"]
    resourceNames: ["logs"]
    verbs: ["create"]
ROLE
    then made "ClusterRole hcp-audit-writer"; else bad "could not create ClusterRole hcp-audit-writer"; fi
else
    miss "ClusterRole hcp-audit-writer"
    note "Writes the audit tenant and nothing else; the gateway serves three."
fi

if exists guest clusterrolebinding hcp-audit-writer; then
    ok "ClusterRoleBinding hcp-audit-writer"
elif $APPLY; then
    if guest create clusterrolebinding hcp-audit-writer \
        --clusterrole=hcp-audit-writer \
        --serviceaccount="${LOGGING_NS}:hcp-audit-writer" >/dev/null 2>&1; then
        made "ClusterRoleBinding hcp-audit-writer"
    else
        bad "could not create ClusterRoleBinding hcp-audit-writer"
    fi
else
    miss "ClusterRoleBinding hcp-audit-writer"
fi

# A Secret of this type carries a token that does not expire, which is what the
# crossing needs: a projected token would stop the records some weeks later with
# nothing on screen to say why.
if exists guest secret hcp-audit-writer-token "$LOGGING_NS"; then
    ok "Secret hcp-audit-writer-token"
elif $APPLY; then
    if guest apply -f - >/dev/null 2>&1 <<TOKEN
apiVersion: v1
kind: Secret
metadata:
  name: hcp-audit-writer-token
  namespace: ${LOGGING_NS}
  annotations:
    kubernetes.io/service-account.name: hcp-audit-writer
type: kubernetes.io/service-account-token
TOKEN
    then made "Secret hcp-audit-writer-token"; sleep 3; else bad "could not create Secret hcp-audit-writer-token"; fi
else
    miss "Secret hcp-audit-writer-token"
    note "A non-expiring token on purpose: a projected one would stop the crossing weeks later, silently."
fi

GUEST_TOKEN=$(guest get secret hcp-audit-writer-token -n "$LOGGING_NS" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
if [[ -n "$GUEST_TOKEN" ]]; then
    ok "the token is populated"
else
    miss "the token is not populated yet"
    note "The controller fills it a moment after the Secret appears. Run this again."
fi

# Part A of the guide, and the script used to skip it, which is how a cluster
# reported as fully set up still lost every snapshot deletion. Read from the
# guest, because that is the effective state: what the API server actually
# writes is what matters, not what was asked for somewhere else.
#
# Without bodies a deletion cannot be matched to its machine. A creation still
# can, because the snapshot is still there to be named, so the fault shows up
# as deletions silently missing while creations work.
AUDIT_SPEC=$(guest get apiserver cluster -o jsonpath='{.spec.audit}' 2>/dev/null)
if [[ "$AUDIT_SPEC" == *WriteRequestBodies* ]]; then
    ok "the API server captures write bodies"
else
    miss "the API server does not capture write bodies"
    note "Snapshot deletions will vanish and snapshots will have no name. Creations will look fine, which is what makes this hard to spot."
    note "Part A of quick-start-audit-pipeline.md. It patches the HostedCluster and restarts the hosted API server."
    if $APPLY; then
        printf '\n  %sTurning this on restarts the hosted API server, the same window as the webhook step.%s\n' "$YELLOW" "$NC"
        read -r -p "  Set the audit profile now? [y/N] " audit_answer
        if [[ "$audit_answer" == "y" || "$audit_answer" == "Y" ]]; then
            if host patch hostedcluster "$HC_NAME" -n "$HC_NS" --type=merge \
                -p '{"spec":{"configuration":{"apiServer":{"audit":{"profile":"Default","customRules":[{"group":"system:serviceaccounts","profile":"Default"},{"group":"system:authenticated","profile":"WriteRequestBodies"}]}}}}}' >/dev/null 2>&1; then
                made "audit profile on the HostedCluster"
                # Measured on a lab: the guest's own object catches up in about
                # twenty seconds, and the API server finishes rolling around
                # thirty-five. Only records written after that carry a body.
                note "Test with a NEW snapshot. Records written before the API server finishes rolling never gain a body, so deleting an older snapshot will still show nothing and look like this did not work."
            else
                bad "could not patch the audit profile"
            fi
        fi
    fi
fi

GUEST_LOKI_HOST=$(guest get route "$LOKISTACK" -n "$LOGGING_NS" -o jsonpath='{.spec.host}' 2>/dev/null)
if [[ -n "$GUEST_LOKI_HOST" ]]; then
    GUEST_LOKI_URL="https://${GUEST_LOKI_HOST}/api/logs/v1/audit"
    ok "guest log store endpoint"
    note "${GUEST_LOKI_URL}"
else
    GUEST_LOKI_URL=""
    miss "no route ${LOKISTACK} in ${LOGGING_NS} on the guest"
    note "Without it the collector has nowhere to send records."
    # Seen at a customer: the store was still coming up and the route appeared a
    # few minutes later. Worth saying, because otherwise the only way to tell a
    # cluster that is still starting from one that is misconfigured is to ask
    # somebody.
    if guest get lokistack "$LOKISTACK" -n "$LOGGING_NS" >/dev/null 2>&1; then
        note "The LokiStack is there, so this may just be still coming up. Run this again in a few minutes before treating it as wrong."
    fi
fi

section "Hosting side: collecting and forwarding"
if exists host serviceaccount audit-collector "$LOGGING_NS"; then
    ok "ServiceAccount audit-collector"
elif $APPLY; then
    if host create serviceaccount audit-collector -n "$LOGGING_NS" >/dev/null 2>&1; then
        made "ServiceAccount audit-collector"
    else
        bad "could not create ServiceAccount audit-collector"
    fi
else
    miss "ServiceAccount audit-collector"
fi

# The guest's token has to be on this side for the collector to authenticate
# with it. This is the one value the script moves between clusters.
if exists host secret guest-loki-token "$LOGGING_NS"; then
    ok "Secret guest-loki-token"
elif $APPLY; then
    if [[ -z "$GUEST_TOKEN" ]]; then
        bad "cannot create guest-loki-token: the guest token is not available yet"
    else
        if host create secret generic guest-loki-token -n "$LOGGING_NS" \
            --from-literal=token="$GUEST_TOKEN" >/dev/null 2>&1; then
            made "Secret guest-loki-token"
        else
            bad "could not create Secret guest-loki-token"
        fi
    fi
else
    miss "Secret guest-loki-token"
    note "Holds the guest ServiceAccount's token so the collector can write to the guest's store."
fi

if exists host clusterlogforwarder hosted-audit "$LOGGING_NS"; then
    ok "ClusterLogForwarder hosted-audit"
    HAS_RECV=$(host get clusterlogforwarder hosted-audit -n "$LOGGING_NS" -o jsonpath='{.spec.inputs[?(@.type=="receiver")].name}' 2>/dev/null)
    if [[ -n "$HAS_RECV" ]]; then ok "receiver input ${HAS_RECV}"; else miss "the forwarder has no receiver input"; fi
    HAS_OUT=$(host get clusterlogforwarder hosted-audit -n "$LOGGING_NS" -o jsonpath='{.spec.outputs[?(@.type=="loki")].name}' 2>/dev/null)
    if [[ -n "$HAS_OUT" ]]; then ok "loki output ${HAS_OUT}"; else miss "the forwarder has no loki output"; fi
    # Ask the operator rather than guessing which permissions it wants. A
    # receiver input needs none at all: on a working crossing this reports
    # "permitted to collect log types: []" and is still Authorized, so a check
    # for collect-audit-logs here would fail on a cluster that is perfectly set
    # up. It said so on the lab, which is how that check came out again.
    for cond in Authorized Valid; do
        STATE=$(host get clusterlogforwarder hosted-audit -n "$LOGGING_NS" \
            -o jsonpath="{.status.conditions[?(@.type=='observability.openshift.io/${cond}')].status}" 2>/dev/null)
        if [[ "$STATE" == "True" ]]; then
            ok "the forwarder reports ${cond}"
        else
            REASON=$(host get clusterlogforwarder hosted-audit -n "$LOGGING_NS" \
                -o jsonpath="{.status.conditions[?(@.type=='observability.openshift.io/${cond}')].message}" 2>/dev/null)
            miss "the forwarder does not report ${cond}"
            [[ -n "$REASON" ]] && note "$REASON"
        fi
    done
elif $APPLY; then
    if [[ -z "$GUEST_LOKI_URL" ]]; then
        bad "cannot create the forwarder: the guest log store endpoint is unknown"
    elif host apply -f - >/dev/null 2>&1 <<CLF
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: hosted-audit
  namespace: ${LOGGING_NS}
spec:
  serviceAccount:
    name: audit-collector
  inputs:
    - name: hosted-kas-audit
      type: receiver
      receiver:
        type: http
        port: 8443
        http:
          format: kubeAPIAudit
  outputs:
    - name: guest-loki
      type: loki
      loki:
        url: ${GUEST_LOKI_URL}
        authentication:
          token:
            from: secret
            secret:
              name: guest-loki-token
              key: token
      tls:
        insecureSkipVerify: true
  pipelines:
    - name: hosted-audit
      inputRefs: [hosted-kas-audit]
      outputRefs: [guest-loki]
CLF
    then made "ClusterLogForwarder hosted-audit"
    else bad "could not create the ClusterLogForwarder"; fi
else
    miss "ClusterLogForwarder hosted-audit"
    note "The receiver the hosted API server posts to, and the output that carries it to the guest."
fi

section "Hosting side: pointing the hosted API server at it"
if exists host secret audit-webhook "$HC_NS"; then
    ok "Secret audit-webhook in ${HC_NS}"
elif $APPLY; then
    WEBHOOK_FILE=$(mktemp); chmod 600 "$WEBHOOK_FILE"
    cat > "$WEBHOOK_FILE" <<'WEBHOOK'
apiVersion: v1
kind: Config
clusters:
- name: audit
  cluster:
    server: https://hosted-audit-hosted-kas-audit.openshift-logging.svc:8443
    insecure-skip-tls-verify: true
contexts:
- name: audit
  context: {cluster: audit, user: audit}
current-context: audit
users:
- name: audit
  user: {}
WEBHOOK
    if host create secret generic audit-webhook -n "$HC_NS" \
        --from-file=webhook-kubeconfig="$WEBHOOK_FILE" >/dev/null 2>&1; then
        made "Secret audit-webhook"
    else
        bad "could not create Secret audit-webhook"
    fi
    rm -f "$WEBHOOK_FILE"
else
    miss "Secret audit-webhook in ${HC_NS}"
    note "Goes beside the HostedCluster, not in the control plane namespace; HyperShift copies it across."
fi

WEBHOOK_SET=$(host get hostedcluster "$HC_NAME" -n "$HC_NS" -o jsonpath='{.spec.auditWebhook.name}' 2>/dev/null)
if [[ -n "$WEBHOOK_SET" ]]; then
    ok "HostedCluster points at ${WEBHOOK_SET}"
elif $APPLY; then
    printf '\n  %sThis restarts the hosted API server. On SingleReplica that is a short window with no API on the guest.%s\n' "$YELLOW" "$NC"
    read -r -p "  Turn it on now? [y/N] " answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        if host patch hostedcluster "$HC_NAME" -n "$HC_NS" --type=merge \
            -p '{"spec":{"auditWebhook":{"name":"audit-webhook"}}}' >/dev/null 2>&1; then
            made "HostedCluster.spec.auditWebhook"
        else
            bad "could not patch the HostedCluster"
        fi
    else
        miss "HostedCluster.spec.auditWebhook (left alone)"
    fi
else
    miss "HostedCluster.spec.auditWebhook is not set"
    note "The last step on purpose: it restarts the hosted API server."
fi

section "Summary"

# Anything created needs a moment before the cluster agrees it is there, and
# the only honest way to know it took is to look again rather than to trust
# that the writes returned without error.
recheck_advice() {
    printf '\n  %sWait about a minute, then check that it took:%s\n' "$BLUE" "$NC"
    local cmd="  ${0}"
    [[ -n "$CONTEXT" ]] && cmd+=" --context ${CONTEXT}"
    [[ -n "$GUEST_SERVER_OVERRIDE" ]] && cmd+=" --guest-server ${GUEST_SERVER_OVERRIDE}"
    [[ -n "$HC_NS" ]] && cmd+=" -n ${HC_NS}"
    cmd+=" ${HC_NAME}"
    printf '%s\n' "$cmd"
    note "Same command without --apply. Objects take a few seconds to settle, and the hosted API server about half a minute if you turned on the webhook or the audit profile, both of which restart it."
}

if (( MISSING == 0 )); then
    printf '  %sEverything the crossing needs is in place.%s\n' "$GREEN" "$NC"
    if (( APPLIED > 0 )); then
        recheck_advice
        note "Records themselves take a few minutes more. The query for them is in quick-start-audit-pipeline.md."
    fi
    exit 0
fi

printf '  %s%d piece(s) still missing.%s\n' "$YELLOW" "$MISSING" "$NC"
if ! $APPLY; then
    note "This was a check. Re-run with --apply to create what is missing."
elif (( APPLIED > 0 )); then
    recheck_advice
    note "Some of what is still missing may just not have appeared yet; some this script will not create, because it needs decisions it cannot make."
else
    note "Some pieces this script will not create, because they need decisions it cannot make."
fi
note "quick-start-audit-pipeline.md explains each piece."
exit 1

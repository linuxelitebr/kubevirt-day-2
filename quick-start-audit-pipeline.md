# Quick start: naming who did what

Commands, in order, with the cluster each one runs on. The reasons are in [audit-pipeline-setup.md](audit-pipeline-setup.md); this page assumes you want it working today.

**What this covers:** making a virtual machine's start, stop, restart and snapshot show the person who did it.

**What it does not:** standing up the log store. That is operators, a bucket and a storage class, and it is written up properly in [Operators](audit-pipeline-setup.md#operators), [Object storage](audit-pipeline-setup.md#object-storage) and [LokiStack](audit-pipeline-setup.md#lokistack). Step 0 below tells you whether you already have it.

Every block says which cluster it runs on. Check before each one, because both clusters in a hosted setup have an `openshift-logging` namespace and a `ClusterLogForwarder`, so the wrong context answers plausibly instead of erroring:

```bash
oc whoami --show-server
```

## Step 1: identify your clusters

Run this on each cluster you have:

```bash
oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}{"\n"}'
```

`External` means that cluster is a **hosted cluster**: its API server runs as pods somewhere else and writes its audit there. Anything else, `SingleReplica` or `HighlyAvailable`, means the control plane is that cluster's own.

- Nothing answers `External`: you have an ordinary cluster. Do **A** on it and stop.
- One answers `External`: that is the hosted cluster. Do **A** on it, then **B** on the cluster running its control plane, which is the hosting cluster.

Do not try to tell them apart by which one has virtual machines. With HyperShift on KubeVirt the hosting cluster runs the guest's nodes as virtual machines, and often others of its own, so `oc get vm` answers on both.

## Step 2: do you have a log store

*On the hosted cluster, or on the ordinary one:*

```bash
oc get lokistack -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .status.conditions[*]}{.type}={.status} {end}{"\n"}{end}'
```

You want one line ending `Ready=True Pending=False Failed=False`. Nothing at all, or `Pending=True`, means the store is not there or not up: go to [LokiStack](audit-pipeline-setup.md#lokistack) and come back.

```bash
oc auth can-i get 'audit.loki.grafana.com/logs'
```

`yes` means you can read the audit tenant. `no` means [Reader access](audit-pipeline-setup.md#reader-access) first, and note a cluster admin passes with no binding while everyone else needs one.

```bash
oc get clusterlogforwarder -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

A forwarder has to exist and carry an `audit` input. If it does not, [the forwarder section](audit-pipeline-setup.md#the-forwarder-with-the-filter-that-makes-this-affordable) has the whole file.

## A. On the cluster with the virtual machines

Power actions already carry a name once step 0 passes. Snapshot deletions do not, because the record names the snapshot and not the machine, and only the request body ties the two together. If you want those named, capture bodies for people and not for service accounts. This restarts the API server.

*On an ordinary cluster:*

```bash
oc patch apiserver cluster --type=merge -p '{"spec":{"audit":{"profile":"Default","customRules":[{"group":"system:serviceaccounts","profile":"Default"},{"group":"system:authenticated","profile":"WriteRequestBodies"}]}}}'
```

Order matters: a service account is also `system:authenticated`, so it has to match the narrower rule first.

On a hosted cluster that object exists but is a copy: it is owned by the cluster-version-operator and the hosted API server never reads it, so patching it there is accepted and does nothing. The setting lives on the `HostedCluster`, on the hosting cluster. Do this one before B7 and you take a single API restart instead of two.

*On the hosting cluster:*

```bash
oc patch hostedcluster <HC-NAME> -n <HC-NAMESPACE> --type=merge -p '{"spec":{"configuration":{"apiServer":{"audit":{"profile":"Default","customRules":[{"group":"system:serviceaccounts","profile":"Default"},{"group":"system:authenticated","profile":"WriteRequestBodies"}]}}}}}'
```

`<HC-NAME>` and `<HC-NAMESPACE>` come from the table in B. If you have not read them yet, skip this and come back after B's first block.

Then check the collector is not being refused. Scope it to the audit sink: the application and infrastructure sinks produce their own errors on healthy clusters, and a `429` anywhere is backpressure rather than permission.

*On the cluster with the virtual machines:*

```bash
oc logs -n openshift-logging -l app.kubernetes.io/component=collector --since=10m --tail=500 | grep -E 'output_default_lokistack_audit' | grep -iE 'error|403'
```

No output is what you want. A `403` here means the collector's write role, which the long page covers.

If this is an ordinary cluster, go to **Checking it worked**.

## B. Bringing the records across, hosted clusters only

The hosting cluster needs **Red Hat OpenShift Logging** installed. It does not need Loki, a LokiStack, or a bucket.

### The three names

*On the hosting cluster:*

```bash
oc get hc -A && oc get hcp -A
```

| placeholder | where to read it |
| --- | --- |
| `<HC-NAMESPACE>` | the NAMESPACE column of `oc get hc` |
| `<HC-NAME>` | the NAME column of `oc get hc` |
| `<CP-NAMESPACE>` | the NAMESPACE column of `oc get hcp`, which is the other two joined by a dash |

`oc get hc` prints namespace first and name second, the opposite of what `oc patch <name> -n <namespace>` wants. That is the easiest mistake here.

### B1. The writer identity

*On the hosted cluster:*

```bash
oc apply -f manifests/hosted-cluster-audit-writer.yaml
```

The token is filled in asynchronously, so wait for it rather than reading straight away:

```bash
oc wait --for=jsonpath='{.data.token}' secret/hcp-audit-writer-token -n openshift-logging --timeout=60s
```

```bash
oc get secret hcp-audit-writer-token -n openshift-logging -o jsonpath='{.data.token}' | base64 -d > /tmp/writer.token && wc -c < /tmp/writer.token
```

A few hundred bytes is right. Zero means you read it too early.

That token does not expire by design: it crosses a cluster boundary and the far side cannot renew it. Its role grants `create` on `audit` and nothing else.

### B2. The gateway host

*On the hosted cluster:*

```bash
oc get route -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway -o jsonpath='{.items[0].spec.host}{"\n"}'
```

Call this `<GATEWAY-HOST>`. It is a hostname, not the Route's name. Ask by label, because the Route is named after the LokiStack.

### B3. The collector identity and the token

*On the hosting cluster:*

```bash
oc create sa audit-collector -n openshift-logging
```

```bash
oc create secret generic guest-loki-token -n openshift-logging --from-file=token=/tmp/writer.token
```

The ServiceAccount needs no bindings. It only has to exist, or the forwarder is refused with `spec.serviceAccount: Required value`.

### B4. Prove the hosting cluster reaches the gateway

*On the hosting cluster:*

```bash
oc exec -n <CP-NAMESPACE> deploy/kube-apiserver -c kube-apiserver -- curl -sk -o /dev/null -w '%{http_code}\n' --max-time 15 https://<GATEWAY-HOST>/api/logs/v1/audit/loki/api/v1/labels
```

`302` is what you want: the gateway redirected a request with no token, so DNS resolved and the route answered. A timeout means the two clusters share no DNS, and nothing below is worth applying until that is fixed.

### B5. The forwarder

Put `<GATEWAY-HOST>` from B2 into the `url` field of `manifests/hosted-cluster-forwarder.yaml`, replacing the placeholder there. The host, not the Route's name.

*On the hosting cluster:*

```bash
oc apply -f manifests/hosted-cluster-forwarder.yaml
```

It goes in `openshift-logging`, not in the control plane namespace, where pod security rejects the collector outright.

Confirm the receiver came up. The operator names its Service after the forwarder plus the input:

```bash
oc get svc -n openshift-logging -o name | grep hosted-audit
```

You should see `hosted-audit-hosted-kas-audit`, which is the name the next step hard-codes.

### B6. The webhook kubeconfig

Write this to `/tmp/audit-webhook-kubeconfig`, substituting nothing:

```yaml
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
```

*On the hosting cluster:*

```bash
oc create secret generic audit-webhook -n <HC-NAMESPACE> --from-file=webhook-kubeconfig=/tmp/audit-webhook-kubeconfig
```

The key has to be `webhook-kubeconfig` exactly, and the Secret goes beside the `HostedCluster`, not in the control plane namespace. HyperShift copies it across itself.

### B7. Turn it on

This restarts the hosted API server. On `SingleReplica` that is a short window with no API on the hosted cluster.

The patch lands on the `HostedCluster` in one namespace and the Deployment it eventually rewrites is in another, so `oc rollout status` on its own reports the old pods as rolled out and exits in under a second. Note the generation first and wait for it to move.

*On the hosting cluster:*

```bash
GEN=$(oc get deploy kube-apiserver -n <CP-NAMESPACE> -o jsonpath='{.metadata.generation}')
```

```bash
oc patch hostedcluster <HC-NAME> -n <HC-NAMESPACE> --type=merge -p '{"spec":{"auditWebhook":{"name":"audit-webhook"}}}'
```

```bash
until [ "$(oc get deploy kube-apiserver -n <CP-NAMESPACE> -o jsonpath='{.metadata.generation}')" != "$GEN" ]; do sleep 5; done; oc rollout status deploy/kube-apiserver -n <CP-NAMESPACE> --timeout=10m
```

Then check the forwarder is not complaining. Its sink is named after the output, not after a tenant:

```bash
oc logs -n openshift-logging -l app.kubernetes.io/instance=hosted-audit --since=5m | grep -E 'output_guest_loki' | grep -iE 'error|403'
```

No output is what you want.

## Checking it worked

Start or stop a virtual machine, then ask the log store directly. The gateway authenticates with a bearer token, so this needs a session that has one: a kubeconfig that signs in with a client certificate makes `oc whoami -t` fail, and the request then goes out with an empty token and is rejected.

*On the hosted cluster, or on the ordinary one. Not on the hosting cluster, which has no gateway:*

```bash
GW=$(oc get route -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
T=$(oc whoami -t 2>/dev/null)
[ -n "$GW" ] || echo 'no gateway Route here: wrong cluster'
[ -n "$T" ]  || echo 'no token in this session: oc login -u <user> <api> first'
```

Both have to print nothing before the next block is worth running.

```bash
curl -sk -H "Authorization: Bearer $T" -G \
  --data-urlencode 'query={log_type="audit"} |~ "<VM-NAME>"' \
  --data-urlencode "start=$(( $(date +%s) - 3600 ))000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=20' \
  "https://$GW/api/logs/v1/audit/loki/api/v1/query_range" | python3 -m json.tool | head -40
```

Read the output rather than filtering it: an error comes back as JSON too, and a grep for the fields you hoped to see hides it. What you want is records carrying `username` and `verb`. `user.username` is whoever authenticated; `impersonatedUser.username`, when present, is the person it was done for, and that is the one that matters.

The console shows the same thing under Observe, Logs, audit tenant, but only on the cluster with the virtual machines. The hosting cluster has no Logs page, and after seven steps there that is the console you have open.

In OVTools, open a virtual machine and read the Activity section. When it names nobody it says why, with a link.

## When it does not work

| what you see | where to look |
| --- | --- |
| forwarder says `Ready`, nothing arrives | collector logs for `403` on the audit sink. The gateway checks `logging-collector-logs-writer`, which the operator's own validation does not |
| only node records, nothing from the API server | on a hosted cluster, part **B**. On an ordinary one, the forwarder's `audit` input |
| the Activity section says you may not read the audit trail | [Reader access](audit-pipeline-setup.md#reader-access) |
| a snapshot deletion names no machine | the audit profile has to capture bodies: part **A** |
| pause, unpause and softreboot never appear | those are instance subresources, not virtual machine ones. Check your filter names `virtualmachineinstances/pause` and not `virtualmachines/pause` |

# Quick start: naming who did what

Commands, in order, with the cluster each one runs on. The reasons are in [audit-pipeline-setup.md](audit-pipeline-setup.md); this page assumes you want it working today.

**What this covers:** making a virtual machine's start, stop, restart and snapshot show the person who did it.

**What it does not:** standing up the log store. That is operators, a bucket and a storage class, and it is written up properly in [Operators](audit-pipeline-setup.md#operators), [Object storage](audit-pipeline-setup.md#object-storage) and [LokiStack](audit-pipeline-setup.md#lokistack). Step 0 below tells you whether you already have it.

Every block says which cluster it runs on. Check before each one, because both clusters in a hosted setup have an `openshift-logging` namespace and a `ClusterLogForwarder`, so the wrong context answers plausibly instead of erroring:

```bash
oc whoami --show-server
```

## Step 0: do you have a log store

Run these on the cluster where `oc get vm -A` lists the machines you care about.

```bash
oc get lokistack -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .status.conditions[*]}{.type}={.status} {end}{"\n"}{end}'
```

You want one line ending `Ready=True`. Nothing at all, or `Pending=True`, means the store is not there or not up: go to [LokiStack](audit-pipeline-setup.md#lokistack) and come back.

```bash
oc auth can-i get 'audit.loki.grafana.com/logs'
```

`yes` means you can read the audit tenant. `no` means go to [Reader access](audit-pipeline-setup.md#reader-access) first, and note that a cluster admin passes without any binding while everyone else needs one.

```bash
oc get clusterlogforwarder -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

A forwarder has to exist and carry an `audit` input. If it does not, [the forwarder section](audit-pipeline-setup.md#the-forwarder-with-the-filter-that-makes-this-affordable) has the whole file.

## Step 1: which path

```bash
oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}{"\n"}'
```

Anything other than `External` is an ordinary cluster: do **A**, skip **B**.

`External` is a hosted cluster: its API server runs elsewhere and writes its audit there, so do **A** on it and then **B** on the cluster hosting its control plane.

On HyperShift with KubeVirt the hosting cluster also runs virtual machines, the guest's own nodes. Run the command above on the cluster whose API you use to start and stop the machines you care about, not on the one whose `oc get vm` happens to list something.

## A. On the cluster with the virtual machines

Power actions already carry a name once step 0 passes. Snapshot deletions do not, because the record names the snapshot and not the machine, and only the request body ties the two together. If you want those named, capture bodies for people and not for service accounts. This restarts the API server.

*On an ordinary cluster:*

```bash
oc patch apiserver cluster --type=merge -p '{"spec":{"audit":{"profile":"Default","customRules":[{"group":"system:serviceaccounts","profile":"Default"},{"group":"system:authenticated","profile":"WriteRequestBodies"}]}}}'
```

Order matters: a service account is also `system:authenticated`, so it has to match the narrower rule first.

On a hosted cluster the same setting lives on the `HostedCluster` instead. [That section](audit-pipeline-setup.md#on-a-hosted-cluster-the-api-server-is-somewhere-else) has it.

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

*On the hosting cluster:*

```bash
oc patch hostedcluster <HC-NAME> -n <HC-NAMESPACE> --type=merge -p '{"spec":{"auditWebhook":{"name":"audit-webhook"}}}'
```

```bash
oc rollout status deploy/kube-apiserver -n <CP-NAMESPACE> --timeout=10m
```

Then check the forwarder is not complaining. Its sink is named after the output, not after a tenant:

```bash
oc logs -n openshift-logging -l app.kubernetes.io/instance=hosted-audit --since=5m | grep -E 'output_guest_loki' | grep -iE 'error|403'
```

No output is what you want.

## Checking it worked

Start or stop a virtual machine, then ask the log store directly. This runs from your own machine against the cluster with the virtual machines, using your own token, which is the same path the dashboard uses.

```bash
GW=$(oc get route -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway -o jsonpath='{.items[0].spec.host}')
curl -sk -H "Authorization: Bearer $(oc whoami -t)" -G \
  --data-urlencode 'query={log_type="audit"} |~ "<VM-NAME>"' \
  --data-urlencode "start=$(( $(date +%s) - 3600 ))000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=20' \
  "https://$GW/api/logs/v1/audit/loki/api/v1/query_range" | python3 -m json.tool | grep -E 'username|"verb"|subresource'
```

A username and a verb coming back means it works. `user.username` is whoever authenticated; `impersonatedUser.username`, when present, is the person it was done for, and that is the one that matters.

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

# Quick start: naming who did what

The short version of [audit-pipeline-setup.md](audit-pipeline-setup.md). Commands only, one line of reason where getting it wrong fails silently. Every explanation lives in the long page; this one assumes you want the thing working today.

What you get: a virtual machine's activity named by person, in OVTools or in any Loki query. What it costs: a log store, and audit records leaving the API server.

## Which path you are on

*From the cluster holding the virtual machines:*

```bash
oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}{"\n"}'
```

Anything other than `External` means an ordinary cluster. Follow **A**, and stop there.

`External` means a hosted cluster: its API server runs in another cluster and writes its audit there. Follow **A** on it anyway, for the log store and the reader access, then **B** to bring the records across.

## Names you will substitute

*From the hosting cluster:*

```bash
oc get hc -A && oc get hcp -A
```

`oc get hc` prints the namespace first and the name second, the opposite of what `oc patch <name> -n <namespace>` wants. `oc get hcp` prints the control plane namespace, which is a third string, named `<namespace>-<name>`. Three different values, two of which look alike.

## A. The log store, on the cluster with the virtual machines

Install **Red Hat OpenShift Logging** and **Loki Operator**, and have an S3-compatible bucket with its Secret already created.

*From that cluster:*

```bash
oc apply -f manifests/lokistack.yaml
```

```bash
oc apply -f manifests/forwarder-and-rbac.yaml
```

Wait for the stack:

```bash
oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Then confirm the collector is not being refused. This is the one failure the operator never reports: the `ClusterLogForwarder` says `Ready` while every write is rejected.

```bash
oc logs -n openshift-logging -l app.kubernetes.io/component=collector --tail=50 | grep -iE 'error|403'
```

Silence there is the proof it works.

Give the people who will ask the questions read access. A cluster admin already passes without any binding, but the console's Logs page does not, and a non-admin has nothing:

```bash
oc adm groups new log-readers alice bob
```

```bash
oc create clusterrolebinding logs-view-audit --clusterrole=cluster-logging-audit-view --group=log-readers
```

That role reads the whole cluster's audit, not a filtered slice. The long page explains why.

On an ordinary cluster you are done. Skip to **Checking it worked**.

## B. Bringing the records across, for a hosted cluster

The API server is a pod in the hosting cluster, so nothing you configure on the hosted cluster will ever collect its audit. The hosting cluster needs **Red Hat OpenShift Logging** installed. It does not need Loki, a LokiStack, or a bucket.

### 1. The writer identity

*From the hosted cluster:*

```bash
oc apply -f manifests/hosted-cluster-audit-writer.yaml
```

```bash
oc get secret hcp-audit-writer-token -n openshift-logging -o jsonpath='{.data.token}' | base64 -d > /tmp/writer.token
```

That token does not expire, by design: it crosses a cluster boundary and the collector on the far side cannot renew it. The ClusterRole grants `create` on `audit` and nothing else.

### 2. The gateway host

*From the hosted cluster:*

```bash
oc get route -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway -o jsonpath='{.items[0].spec.host}{"\n"}'
```

Ask by label, not by name: the route is named after the LokiStack.

### 3. The collector identity and the token, on the other side

*From the hosting cluster:*

```bash
oc create sa audit-collector -n openshift-logging
```

```bash
oc create secret generic guest-loki-token -n openshift-logging --from-file=token=/tmp/writer.token
```

The ServiceAccount needs no bindings. It only has to exist, or the forwarder is refused.

### 4. Prove the hosting cluster reaches the gateway

*From the hosting cluster:*

```bash
oc exec -n <CONTROL-PLANE-NAMESPACE> deploy/kube-apiserver -c kube-apiserver -- curl -sk -o /dev/null -w '%{http_code}\n' --max-time 15 https://<GATEWAY-HOST>/api/logs/v1/audit/loki/api/v1/labels
```

`302` is what you want. A timeout means the two clusters share no DNS and nothing below is worth applying.

### 5. The forwarder

Edit `<GUEST-GATEWAY-ROUTE>` in the file first.

*From the hosting cluster:*

```bash
oc apply -f manifests/hosted-cluster-forwarder.yaml
```

It goes in `openshift-logging`, not in the control plane namespace, where pod security rejects the collector outright.

### 6. The webhook kubeconfig

Write this file, substituting nothing. The Service name is the forwarder's name plus the input's name, and both come from the manifest you just applied.

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

*From the hosting cluster, in the namespace the `HostedCluster` lives in:*

```bash
oc create secret generic audit-webhook -n <HOSTEDCLUSTER-NAMESPACE> --from-file=webhook-kubeconfig=<FILE>
```

The key has to be `webhook-kubeconfig` exactly.

### 7. Turn it on

This restarts the hosted API server. On `SingleReplica` that is a short window with no API on the hosted cluster.

*From the hosting cluster:*

```bash
oc patch hostedcluster <NAME> -n <HOSTEDCLUSTER-NAMESPACE> --type=merge -p '{"spec":{"auditWebhook":{"name":"audit-webhook"}}}'
```

```bash
oc rollout status deploy/kube-apiserver -n <CONTROL-PLANE-NAMESPACE> --timeout=10m
```

## Checking it worked

*From the hosting cluster, for a hosted cluster only:*

```bash
oc logs -n openshift-logging -l app.kubernetes.io/instance=hosted-audit --since=5m | grep -icE 'error|403|certificate'
```

Zero is what you want.

Then do something identifiable on a virtual machine, start or stop one, and look for it. In the console's Observe, Logs page, audit tenant:

```
{log_type="audit"} |~ "<VM-NAME>" | json | log_source="kubeAPI"
```

The record carries `user.username` and, when one account acted for another, `impersonatedUser.username`. The second is the person; the first is whoever carried it out.

In OVTools, open a virtual machine and read the Activity section. If it names nobody it says why, and the link goes to the part of the long page that covers it.

## When it does not work

| what you see | where to look |
| --- | --- |
| `ClusterLogForwarder` says `Ready`, nothing arrives | collector logs for `403`. The gateway validates a role the operator does not check |
| nothing from the API server, only node records | on a hosted cluster, section **B**. On an ordinary one, the forwarder's `audit` input |
| the drawer says you may not read the audit trail | reader access in **A** |
| a snapshot deletion names no machine | the audit profile has to capture bodies. See the long page |
| pause, unpause and softreboot never appear | they are instance subresources, not virtual machine ones. Check your filter names them correctly |

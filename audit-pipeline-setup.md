# Standing up a log pipeline that can answer who did what

## Why this is needed

[who-did-what.md](who-did-what.md) covers the queries that pull a username out of the audit log. [audit-log-retention.md](audit-log-retention.md) covers why those queries only reach back about a day: the API server keeps eleven files of 200 MB on the control plane node and nothing older. If you want an answer about last week, the audit log has to leave the node before it rotates away.

This is how to set that up, and how to ship only the part you actually want, which on a measured cluster was 0.67% of the audit stream by bytes. The other 99.3% was service accounts reconciling.

## What is required, and what is not

**Required:**

- Object storage. Any S3-compatible endpoint. MinIO inside the cluster is fine for a lab.
- **Loki Operator**, which provides the `LokiStack` resource.
- **Red Hat OpenShift Logging**, which provides the `ClusterLogForwarder` resource.
- Read access to the audit tenant for whoever is going to ask the questions.

**Not required, and worth saying out loud:**

- **Cluster Observability Operator.** It brings eighteen custom resources and the only one in this path is `UIPlugin`, which gives the web console its Observe, Logs page. Nothing in the data path touches it. Install it because looking at your logs in a browser is how you find out the pipeline is wrong, not because the pipeline needs it. If you are trimming operators off a cluster, this is the one you can remove without breaking anything, and the one you will miss the first time something looks off.

## Operators

Install both from OperatorHub, matched versions:

```bash
oc get csv -n openshift-logging
```

```
NAME                     DISPLAY                     VERSION   PHASE
cluster-logging.v6.6.1   Red Hat OpenShift Logging   6.6.1     Succeeded
loki-operator.v6.6.1     Loki Operator               6.6.1     Succeeded
```

## Object storage

The secret the LokiStack reads. `region` is the storage region, not anything about the cluster, and MinIO ignores it while real S3 does not:

```bash
oc apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: logging-loki-s3
  namespace: openshift-logging
stringData:
  access_key_id: YOUR-KEY-ID
  access_key_secret: YOUR-KEY-SECRET
  bucketnames: loki
  endpoint: https://YOUR-S3-ENDPOINT
  region: us-east-1
YAML
```

The endpoint needs its scheme. Leaving `https://` off is the single most common way this fails, and the error it produces does not say so.

## LokiStack

Valid sizes are `1x.demo`, `1x.pico`, `1x.extra-small`, `1x.small` and `1x.medium`. Use `1x.pico` for a lab; it runs the whole stack in minimal replicas:

```bash
oc apply -f - <<'YAML'
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: 1x.pico
  replicationFactor: 1
  managementState: Managed
  rules:
    enabled: true
  limits:
    global:
      retention:
        days: 15
      queries:
        queryTimeout: 2m
  tenants:
    mode: openshift-logging
  storage:
    schemas:
      - effectiveDate: '2022-06-21'
        version: v13
    secret:
      name: logging-loki-s3
      type: s3
    tls:
      caName: openshift-service-ca.crt
  storageClassName: YOUR-STORAGE-CLASS
YAML
```

`tenants.mode: openshift-logging` is what splits the data into the `application`, `infrastructure` and `audit` tenants and makes the gateway authorise each one separately against the caller's own token. That last part is why a tenant with namespace-scoped access cannot read the audit tenant, and it is worth keeping.

Wait for the pods before moving on:

```bash
oc get pods -n openshift-logging -w
```

## Collector identity

The service account the collector runs as, and the permissions it needs to read each source and write to the store:

```bash
oc apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: logcollector
  namespace: openshift-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: logging-collector-logs-writer
rules:
  - apiGroups: [loki.grafana.com]
    resourceNames: [logs]
    resources: [application, audit, infrastructure]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-logs-writer
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: logging-collector-logs-writer}
subjects: [{kind: ServiceAccount, name: logcollector, namespace: openshift-logging}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: collect-application-logs
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: collect-application-logs}
subjects: [{kind: ServiceAccount, name: logcollector, namespace: openshift-logging}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: collect-infrastructure-logs
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: collect-infrastructure-logs}
subjects: [{kind: ServiceAccount, name: logcollector, namespace: openshift-logging}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: collect-audit-logs
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: collect-audit-logs}
subjects: [{kind: ServiceAccount, name: logcollector, namespace: openshift-logging}]
YAML
```

## The forwarder, with the filter that makes this affordable

The `kubeAPIAudit` filter is a real Kubernetes audit policy running inside the collector. It decides what gets shipped, not what gets written, so the API server keeps its complete log on disk and you lose no forensic coverage by narrowing this.

Rules are evaluated top to bottom and the first match wins:

```bash
oc apply -f - <<'YAML'
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: logging
  namespace: openshift-logging
spec:
  managementState: Managed
  serviceAccount:
    name: logcollector
  collector:
    tolerations:
      - operator: Exists
  outputs:
    - name: default-lokistack
      type: lokiStack
      lokiStack:
        authentication:
          token:
            from: serviceAccount
        target:
          name: logging-loki
          namespace: openshift-logging
      tls:
        ca:
          configMapName: openshift-service-ca.crt
          key: service-ca.crt
  filters:
    - name: multiline
      type: detectMultilineException
    - name: vm-activity
      type: kubeAPIAudit
      kubeAPIAudit:
        omitStages:
          - RequestReceived
        rules:
          - level: None
            userGroups:
              - system:serviceaccounts
              - system:nodes
          - level: Metadata
            verbs: [create, update, patch, delete]
            resources:
              - group: kubevirt.io
                resources:
                  - virtualmachines
                  - virtualmachineinstances
                  - virtualmachineinstancemigrations
              - group: subresources.kubevirt.io
                resources:
                  - virtualmachines/start
                  - virtualmachines/stop
                  - virtualmachines/restart
                  - virtualmachines/pause
                  - virtualmachines/unpause
                  - virtualmachines/migrate
                  - virtualmachines/softreboot
              - group: snapshot.kubevirt.io
                resources:
                  - virtualmachinesnapshots
                  - virtualmachinerestores
          - level: None
  pipelines:
    - name: apps
      inputRefs: [application]
      filterRefs: [multiline]
      outputRefs: [default-lokistack]
    - name: infrastructure-logs
      inputRefs: [infrastructure]
      filterRefs: [multiline]
      outputRefs: [default-lokistack]
    - name: audit-logs
      inputRefs: [audit]
      filterRefs: [vm-activity]
      outputRefs: [default-lokistack]
YAML
```

### Why each rule

**Controllers first.** `virt-controller` writes to the same objects a person does, constantly, and its entries are usually the newest ones. Without the first rule the result is a record saying a controller did everything, which is accurate and useless.

**The subresources are not optional.** `virtctl start`, `virtctl stop`, and the power controls in the web console do not write to the VirtualMachine object at all. They call `virtualmachines/start` and `virtualmachines/stop` under `subresources.kubevirt.io`. A filter watching only `kubevirt.io` would miss every start and stop in the cluster and nobody would notice until someone asked. Verified on a live cluster:

```
verb=update  group=subresources.kubevirt.io  resource=virtualmachines  sub=start  user=admin
verb=update  group=subresources.kubevirt.io  resource=virtualmachines  sub=stop   user=admin
verb=patch   group=kubevirt.io               resource=virtualmachines  sub=       user=admin
```

**The last rule is the one that pays for everything.** `level: None` on anything that did not match turns gigabytes a day into kilobytes.

## The console plugin, if you want it

This is the part the Cluster Observability Operator provides, and the only part:

```bash
oc apply -f - <<'YAML'
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
  logging:
    lokiStack:
      name: logging-loki
    logsLimit: 50
    timeout: 30s
YAML
```

The troubleshooting panel is separate, and its name is not a choice. The API rejects anything else:

```bash
oc apply -f - <<'YAML'
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: troubleshooting-panel
spec:
  type: TroubleshootingPanel
YAML
```

Name it anything else and you get `UIPlugin name must be 'troubleshooting-panel' if type is TroubleshootingPanel`, which at least tells you exactly what it wants.

## Checking that it works

Collector pods running:

```bash
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector
```

Something arriving in each tenant, in GB over the last day:

```
sum by (tenant) (increase(loki_distributor_bytes_received_total[24h])) / 1073741824
```

Then do something to a virtual machine and go looking for it. Start one, stop it, and query the audit tenant in Observe, Logs:

```
{log_type="audit"} |= "virtualmachines"
```

If the filter is working, the audit tenant is tiny and everything in it is about virtual machines, with a real username in `user.username`. If it is full of service accounts reconciling configmaps, the pipeline is not referencing the filter.

## Scope and limits

This answers who, from the moment you turn it on. It does not reach backwards: whatever rotated off the node before the collector started is gone.

The filter is narrow on purpose, and narrow means you will eventually want something it drops. It is a one line change to add a resource, and a redeploy of the collector, so widen it when you have a reason rather than keeping everything against the day you might.

Shipping audit solves retention by turning it into a storage bill. On a cluster measured for this, audit was a rounding error next to application and infrastructure logs, so the filtered version costs effectively nothing. Unfiltered audit on a busy cluster does not, which is the whole reason the filter is here.

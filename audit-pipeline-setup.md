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

The endpoint needs its scheme. Leaving it off is the single most common way this fails, and the error it produces does not say so.

### If your storage lives in the same cluster

MinIO running beside Loki is the usual lab arrangement, and it comes with a trap. MinIO gets exposed through a Route, the Route is the obvious address, and Loki then fails like this:

```
msg="error running loki" err="init compactor: failed to init delete store:
Get \"https://s3-minio.apps.example.com/loki/index/...\":
tls: failed to verify certificate: x509: certificate signed by unknown authority"
```

Two things are going on. The Route has no TLS termination of its own, and the OpenShift router answers 443 for any host with the default wildcard certificate, so the handshake succeeds against a certificate Loki has no reason to trust. Meanwhile `storage.tls.caName` is usually set to `openshift-service-ca.crt`, which signs certificates for `*.svc` and has nothing to do with an address on `*.apps`. Different signer, and the one that is configured is not the one being presented.

You can go and fetch the ingress CA. It is already sitting in `openshift-config-managed/default-ingress-cert`, so at least you do not have to scrape it off the endpoint. But do not.

Point Loki at the Service instead:

```yaml
  endpoint: http://minio-api.minio-ocp.svc.cluster.local:9000
```

Loki and MinIO are neighbours. Sending their traffic out to the ingress and back in is a detour that invents the certificate problem, adds a router hop to every object operation, and puts all of your object storage traffic through the edge. Inside the cluster there is nothing to verify, so drop `storage.tls` entirely.

Check what the service actually speaks before assuming, because some MinIO deployments do serve TLS on 9000:

```bash
oc run tlscheck --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never --rm -i --quiet -- curl -s -o /dev/null -w "%{http_code}\n" http://minio-api.minio-ocp.svc.cluster.local:9000/minio/health/live
```

A secret edited after the fact does not reach the running pods on its own:

```bash
oc delete pod -n openshift-logging -l app.kubernetes.io/instance=logging-loki
```

For production the same reasoning gives a better answer rather than a different one. Annotate the MinIO service with `service.beta.openshift.io/serving-cert-secret-name`, mount the result, and the endpoint becomes `https://minio-api.minio-ocp.svc.cluster.local:9000`. At that point `openshift-service-ca.crt` is exactly the right CA, because now it really is a `*.svc` certificate. The setting most people already have was never wrong; it was pointed at the wrong address.

One more suspect if it still fails after this, with a complaint about the bucket or the signature: MinIO wants path style addressing rather than bucket-as-subdomain. The operator usually works this out from a non-AWS endpoint, so it is the second thing to check, not the first.

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

The collector needs an identity and four role bindings. It does not need the roles themselves: `logging-collector-logs-writer`, `collect-application-logs`, `collect-infrastructure-logs` and `collect-audit-logs` all ship with the Logging operator and are created when you install it.

Check before you write them, because most walkthroughs include the definitions and applying them overwrites objects OLM owns. Identical rules today, a conflict at the next operator upgrade:

```bash
oc get clusterrole logging-collector-logs-writer -o jsonpath='{.metadata.labels}'
```

```
{"olm.managed":"true","olm.owner":"cluster-logging.v6.6.1"}
```

So this is the whole of it, an account and four bindings:

```bash
oc apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: logcollector
  namespace: openshift-logging
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

## Reader access

Everything above is about writing. Reading is a separate set of roles, they ship with the operator, and on a fresh install nothing is bound to them:

```bash
oc get clusterrole | grep 'cluster-logging-.*-view'
```

```
cluster-logging-application-view
cluster-logging-audit-view
cluster-logging-infrastructure-view
```

Who needs these is not who you would guess, so it is worth a measurement rather than a rule of thumb:

```bash
oc auth can-i get audit.loki.grafana.com --as=system:admin
oc auth can-i get audit.loki.grafana.com --as=someone-else
```

```
yes
no
```

A cluster administrator already passes, with no binding of any kind, because the gateway asks Kubernetes whether you may `get` the tenant in `loki.grafana.com` and a wildcard answers yes. Anything querying the gateway directly works for them immediately.

The console's Logs page is the part that does not. It runs its own narrower check first, finds no binding, and refuses with `Missing permissions to get logs` even for a cluster administrator, which reads like the data is missing while the data is sitting there answering queries.

So: bind these for the console. The API already allowed it.

A project administrator is a different case and genuinely has nothing. The `admin` role covers a namespace and says nothing about `loki.grafana.com`, and neither does `system:authenticated`. They need a binding, and for application logs it should be the namespaced one below.

Bind to a group, not to a person. A binding per user is a thing you will forget to remove, and the first time someone else needs to look you will do it again rather than fix it:

```bash
oc adm groups new log-readers alice bob
```

```bash
oc create clusterrolebinding logs-view-application --clusterrole=cluster-logging-application-view --group=log-readers
```

```bash
oc create clusterrolebinding logs-view-infrastructure --clusterrole=cluster-logging-infrastructure-view --group=log-readers
```

```bash
oc create clusterrolebinding logs-view-audit --clusterrole=cluster-logging-audit-view --group=log-readers
```

With an identity provider that supplies groups, use the group it supplies and skip the first command.

### Application logs can be narrower than this

A cluster-wide binding is the blunt version. Application logs are tenanted by namespace, so a RoleBinding inside a namespace gives a team its own logs and nothing else, which is what the console suggests when it refuses:

```bash
oc create rolebinding view-application-logs -n THEIR-NAMESPACE --clusterrole=cluster-logging-application-view --group=their-team
```

That is the right shape for anyone who is not running the cluster.

### Audit cannot be narrowed, and that is the point

There is no namespace dimension to an audit trail. It records what every identity did everywhere, so `cluster-logging-audit-view` is all or nothing, and the console only ever offers namespace scoping for application logs.

Decide that deliberately. The role that answers "who stopped my virtual machine" is the same role that answers "what has everyone in this cluster been doing", including people whose work has nothing to do with whoever is asking. Give it to the people who run the cluster, and do not hand it out to a tenant because they asked a reasonable question about their own machine.

The practical consequence, if you are wiring this into a tool: anything that reads the audit trail on a person's behalf passes their token, so a namespace-scoped user gets a 403 and sees nothing. That is correct behaviour, and it means attribution is a feature for operators rather than for everyone.

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

If the console says you have no permission, check the data path directly before believing it. Forward the gateway:

```bash
oc port-forward -n openshift-logging svc/logging-loki-gateway-http 18080:8080
```

Then ask it yourself, with the tenant in the path and a range query, because a log selector is not valid as an instant query and the error says so in a way that sounds like something else:

```bash
curl -sk -H "Authorization: Bearer $(oc whoami -t)" -G --data-urlencode 'query={log_type=~".+"}' --data-urlencode 'limit=2' --data-urlencode "start=$(( $(date +%s) - 3600 ))000000000" --data-urlencode "end=$(date +%s)000000000" https://127.0.0.1:18080/api/logs/v1/audit/loki/api/v1/query_range
```

The service speaks TLS, so `http://` to it answers `Client sent an HTTP request to an HTTPS server`, which is at least unambiguous. A `status: success` with streams in it means the pipeline is fine and the console is the problem, which sends you to the reader roles above rather than to the collector.

Then do something to a virtual machine and go looking for it. Start one, stop it, and query the audit tenant in Observe, Logs:

```
{log_type="audit"} |= "virtualmachines"
```

If the filter is working, the audit tenant is tiny and everything in it is about virtual machines, with a real username in `user.username`. If it is full of service accounts reconciling configmaps, the pipeline is not referencing the filter.

## What breaks on the first run

All of this comes from standing the pipeline up on a cluster that had been running for eighteen days. None of it is a misconfiguration. It is one problem wearing three hats: the collector starts by reading every log file on the node from the beginning, and eighteen days of backlog is more than the defaults expect.

### The collector is OOMKilled

Exit code 137, a few restarts, and the log looks perfectly healthy right up to the end. The default memory limit is 2Gi and chewing through a backlog goes past it.

[The Red Hat article on this](https://access.redhat.com/articles/7089916) raises the limit to 4Gi. The resource is reachable as `obsclf`, which is shorter to type:

```bash
oc patch obsclf logging -n openshift-logging --type=merge -p '{"spec":{"collector":{"resources":{"limits":{"cpu":"6","memory":"4Gi"},"requests":{"cpu":"500m","memory":"64Mi"}}}}}'
```

Raise the limit, leave the request where it is. A 64Mi request next to a 4Gi limit looks wrong, and the instinct is to raise it so the pod is not first in line when the kubelet starts evicting. Resist it. The collector is a DaemonSet that tolerates everything, so it runs on every node, and the request is reserved on every node whether it is used or not. A gigabyte of reservation per node to protect against an eviction that happens during one backlog catch-up is a bad trade at fleet scale, which is why the shipped value is what it is.

The pods need recreating to pick up new limits:

```bash
oc delete pod -n openshift-logging -l app.kubernetes.io/component=collector
```

### Loki rejects the oldest entries

The distributor says so plainly, once per stream:

```
msg="write operation failed" details="entry for stream '{...}' has timestamp too old:
2026-09-19T13:00:05Z, oldest acceptable timestamp is: 2026-10-01T01:54:53Z"
```

Note the gap. Retention is set to fifteen days and the rejection is at seven, because they are different settings: the second one is `reject_old_samples_max_age` and the LokiStack CRD does not expose it. Raising retention will not help.

This one needs no fix. The rejected entries predate the pipeline, so they were never going to be there, and the errors stop on their own once the collector reaches the present. It is loud while it lasts.

### Ingestion rate limit exceeded

```
details="ingestion rate limit exceeded for user application (limit: 2097152 bytes/sec)
while attempting to ingest '1126' lines totaling '2490706' bytes"
```

Two megabytes per second per tenant, and the catch-up burst goes straight past it. Raise it to get through the first run:

```bash
oc patch lokistack logging-loki -n openshift-logging --type=merge -p '{"spec":{"limits":{"global":{"ingestion":{"ingestionRate":16,"ingestionBurstSize":32}}}}}'
```

You can put it back afterwards. Worth noting that the audit tenant hits this too, and that the filter above is what keeps it from happening again: filtered audit is kilobytes and never competes for ingestion bandwidth.

## Scope and limits

This answers who, from the moment you turn it on. It does not reach backwards: whatever rotated off the node before the collector started is gone.

The filter is narrow on purpose, and narrow means you will eventually want something it drops. It is a one line change to add a resource, and a redeploy of the collector, so widen it when you have a reason rather than keeping everything against the day you might.

Shipping audit solves retention by turning it into a storage bill. On a cluster measured for this, audit was a rounding error next to application and infrastructure logs, so the filtered version costs effectively nothing. Unfiltered audit on a busy cluster does not, which is the whole reason the filter is here.

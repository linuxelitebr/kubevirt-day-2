# Standing up a log pipeline that can answer who did what

## If you have not set Loki up yet

Everything below assumes a log store. If you do not have one, this document is the guide: work through it from the top. The YAML is also available as files under [manifests/](manifests/), because a snippet cannot be applied and a file can.

A dashboard that sends you here is telling you which part is missing, not that nothing works. The sections that answer the common ones:

| what you were told | where to go |
| --- | --- |
| audit is not reaching the log store | [the audit input is four things](#the-audit-input-is-four-things-not-one) |
| you cannot read the audit tenant | [reader access](#reader-access) |
| deletions have no name attached | [capturing a body](#capturing-a-body-and-only-where-you-need-one) |
| this is a hosted cluster | [a guest has no API server audit to collect](#a-guest-has-no-api-server-audit-to-collect) |
| the Loki dashboards are empty | [monitoring](#monitoring-which-the-loki-dashboards-need) |

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

### If you run ODF, let NooBaa make the bucket

With OpenShift Data Foundation already in the cluster there is no reason to stand MinIO up by hand. An `ObjectBucketClaim` asks NooBaa for a bucket and leaves the credentials in a Secret named after the claim:

```bash
oc apply -f - <<'YAML'
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: loki
  namespace: openshift-logging
spec:
  generateBucketName: loki
  storageClassName: openshift-storage.noobaa.io
YAML
```

Then build the Loki secret from what it produced, rather than copying values by hand:

```bash
oc apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: logging-loki-s3
  namespace: openshift-logging
stringData:
  access_key_id: $(oc get secret loki -n openshift-logging -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
  access_key_secret: $(oc get secret loki -n openshift-logging -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
  bucketnames: $(oc get obc loki -n openshift-logging -o jsonpath='{.spec.bucketName}')
  endpoint: https://s3.openshift-storage.svc:443
  region: us-east-1
YAML
```

Note the quoting: that heredoc is unquoted so the command substitutions run, which is the opposite of every other one in this document. Getting it backwards writes the literal text into the secret and Loki fails with credentials that are the shell script itself.

A dedicated backing store is worth it if you care about capping what Loki can consume. A `pv-pool` backing store bounded to a size you choose gives you a ceiling; the RGW backend has no simple equivalent.

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

### Handing audit to people who are not cluster admins

`cluster-logging-audit-view` is bindable to anything, so a cluster owner can decide that a group of operators gets to see who did what without making them administrators:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: audit-readers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-logging-audit-view
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: <your-group>
```

Be precise about what that grants, because it is wider than the equivalent in the tools people arrive from. In vSphere, who may see a task follows permission on the object. Here it does not.

The gateway narrows a query to the namespaces a reader may see by injecting a label matcher, and the labels it matches on are `kubernetes_namespace_name` and `k8s_namespace_name`. Container logs carry those. **Audit records do not**, so there is nothing for the matcher to narrow and the records pass whole.

Measured, rather than read off the configuration: a ServiceAccount in none of the admin groups, holding only `cluster-logging-audit-view`, queried the audit tenant and got records back. Reading the matcher in the operator's source suggests the opposite, that such a reader would see nothing. They see everything.

So a group given this role reads the whole cluster's audit, including namespaces they cannot otherwise list. That may be exactly what the cluster owner wants, and it is their call to make, but it should be made knowing which of the two it is.

Three groups skip the narrowing entirely and have this already. You can read them off the running gateway rather than trusting a default:

```bash
oc get deploy logging-loki-gateway -n openshift-logging -o jsonpath='{range .spec.template.spec.containers[?(@.name=="opa")].args[*]}{@}{"\n"}{end}' | grep admin-groups
```

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

## Decide what you are keeping before you filter anything

The filter below is narrow on purpose and it is not the right answer everywhere. Work out which of these you want first, because the wrong one costs either money or your audit trail.

**Measure the proportion.** This is the number the decision turns on:

```
sum by (tenant) (increase(loki_distributor_bytes_received_total[24h])) / 1073741824
```

On one cluster measured for this, audit was 0.68 GB a day against 589 GB of infrastructure and 90 GB of application logs. At 0.025% of ingestion, filtering audit saves nothing worth having and costs the record. On another, a quiet single node lab, audit was most of what the collector was pushing and the filter took it from 4.26 MB per minute to 3.1 KB.

Same filter, opposite conclusions. Look at your own number.

**Keep everything.** One pipeline, no filter on the audit input. The full trail is retained, anything querying it works, and you pay the volume. If audit is a rounding error next to your other logs, stop here: this is the right answer and the rest of this section is a distraction.

**Keep only what a tool needs.** One pipeline with the filter below. Cheap, and what you retain is a feed of virtual machine activity rather than an audit trail. Everything else survives only in the API server's own files on the control plane node, which on a busy cluster is a window of hours. Choose this when audit volume is a real problem and compliance is not.

**Keep both.** Two pipelines, one narrow and one whole. They overlap, so virtual machine records arrive twice. That is deduplicable, since every Kubernetes audit record carries a unique `auditID` and 100% of them survive the trip, but it is complexity bought in exchange for a saving that only exists if audit was expensive to begin with.

**A fourth shape, for the common case of wanting the trail without the cost.** Not covered by the filter below, and worth knowing about: 99.3% of the audit stream by bytes, measured, is service accounts reconciling. A filter whose only rule drops `system:serviceaccounts` and `system:nodes` and keeps everything else at `Metadata` preserves every human action on every resource and removes almost all of the volume. That is a real audit trail at a fraction of the size, and it is the shape to reach for when the goal is a quieter bucket rather than a tool.

## The forwarder, with the filter that makes this affordable

The `kubeAPIAudit` filter is a real Kubernetes audit policy running inside the collector. It decides what gets shipped, not what gets written, so the API server keeps its complete log on disk and you lose no forensic coverage by narrowing this.

Rules are evaluated top to bottom and **the first match wins**, which makes the order the whole design rather than a matter of taste. Two rules sit above the one that drops service accounts, and they are there because a backup tool is a service account: put the drop first and the only record of your backups taking snapshots disappears, silently, while everything still looks configured.

That is not hypothetical. It is what this page published until now, and what it was running on a customer.

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
        omitResponseCodes: [404, 429]
        rules:
          # 1. Snapshots and restores, whoever did them. This HAS to come before
          #    the service account drop below: a backup tool runs as a service
          #    account, and dropping those first throws its snapshots away.
          #    RequestResponse because the snapshot's name only exists in the
          #    response body.
          - level: RequestResponse
            verbs: [create, delete]
            resources:
              - group: snapshot.kubevirt.io
                resources:
                  - virtualmachinesnapshots
                  - virtualmachinerestores
          # 2. Powering a machine on or off, whoever did it, for the same
          #    reason: a cold backup stops the machine, snapshots it and starts
          #    it again, and without this the middle of that story is the only
          #    part on record. Only the subresources a client calls, so
          #    virt-controller's own writes do not come back in with them.
          - level: Metadata
            verbs: [create, update]
            resources:
              - group: subresources.kubevirt.io
                resources:
                  - virtualmachines/start
                  - virtualmachines/stop
                  - virtualmachines/restart
          # 3. Everything else a service account or a node does is machine
          #    traffic, and this is where the saving comes from.
          - level: None
            userGroups:
              - system:serviceaccounts
              - system:nodes
          # 4. What is left is a person acting on a machine.
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
                  - virtualmachines/migrate
                  - virtualmachineinstances/pause
                  - virtualmachineinstances/unpause
                  - virtualmachineinstances/softreboot
                  - virtualmachineinstances/reset
                  - virtualmachineinstances/addvolume
                  - virtualmachineinstances/removevolume
              - group: snapshot.kubevirt.io
                resources:
                  - virtualmachinesnapshots
                  - virtualmachinerestores
          - level: None
  inputs:
    - name: kube-audit
      type: audit
      audit:
        sources: [kubeAPI]
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
      inputRefs: [kube-audit]
      filterRefs: [vm-activity]
      outputRefs: [default-lokistack]
YAML
```

### Three things in that filter that are easy to get wrong

**Pause, unpause and softreboot are not virtual machine subresources.** They look like they should be, and an audit policy naming `virtualmachines/pause` is accepted without complaint, matches nothing, and falls through to the catch-all that drops the record. Ask the cluster rather than guessing:

```bash
oc get --raw /apis/subresources.kubevirt.io/v1 | python3 -c "import sys,json;print(sorted({r['name'] for r in json.load(sys.stdin)['resources']}))"
```

At the time of writing a virtual machine has `start`, `stop`, `restart`, `migrate`, `expand-spec`, `objectgraph` and `evacuate/cancel`, and nothing else. Pause, unpause, softreboot, reset and volume hotplug live on the instance, so the rule has to name `virtualmachineinstances/pause` and friends. A filter that names the wrong half silently hides those actions.

**`omitResponseCodes` has a default you did not write.** Leave the field out and the operator compiles in `[404, 409, 422, 429]`, which you can read back off the running collector:

```bash
oc get cm logging-config -n openshift-logging -o jsonpath='{.data.vector\.toml}' | grep -n 'responseStatus.code'
```

404 and 429 are noise worth dropping. 409 and 422 are not: a start on a machine that is already running answers 409, and an edit a webhook rejects answers 422. Both are someone trying to do something and being told no, which is the interesting half of an audit trail. 403 is not in the default list, so refusals for lack of permission survive either way. Setting the field explicitly to `[404, 429]` keeps the noise out and the refusals in.

**A snapshot deletion only carries the machine's name in the response.** A delete request body is `DeleteOptions`, which names nothing, so the deleted object appears in the response body and nowhere else. That is why snapshots get their own `RequestResponse` rule rather than riding along at `Metadata`: without it you can see that a snapshot was deleted and never learn which machine it belonged to, because by then nothing holds its name. Restores are in the same rule for symmetry, though their spec names a `target` rather than a `source`, so the same trick does not work on them.

### The audit input is four things, not one

`audit` collects from four sources and `kubeAPIAudit` only touches one of them. Everything else passes through whole, which is why the pipeline above names an input rather than using the built-in:

```yaml
  inputs:
    - name: kube-audit
      type: audit
      audit:
        sources: [kubeAPI]
```

Measured after the filter was in place and before the input was narrowed: six `kubeAPI` records in ten minutes against forty seven from `auditd`. The filter was working perfectly and the tenant was still mostly something else.

The other three are not noise in general, they are noise *here*, and each answers a question this document is not asking:

- **auditd** is the Linux audit daemon on the node: syscalls, file access, process execution, SELinux denials. It is where you look when the question is about the host rather than the API, and it is the only one of the four that sees anything a person did without going through Kubernetes.
- **openshiftAPI** covers the OpenShift API server and, in practice, the OAuth one as well. On a running cluster it carries `oauthaccesstokens`, `tokenreviews` and `users`, which is to say who logged in and when. That pairs well with who did what, as a separate question.
- **ovn** is the OVN-Kubernetes ACL audit log, which records packets a NetworkPolicy allowed or denied. It is empty unless ACL logging is turned on for a policy, and it is the log that answers why a virtual machine cannot reach something.

So narrow the input for this pipeline, and if you want the rest, add a second pipeline with the full `audit` input going wherever your retention and compliance requirements point. They are not in competition: one is a feature, the other is a record.

### Why each rule

**Controllers first.** `virt-controller` writes to the same objects a person does, constantly, and its entries are usually the newest ones. Without the first rule the result is a record saying a controller did everything, which is accurate and useless.

**The subresources are not optional.** `virtctl start`, `virtctl stop`, and the power controls in the web console do not write to the VirtualMachine object at all. They call `virtualmachines/start` and `virtualmachines/stop` under `subresources.kubevirt.io`. A filter watching only `kubevirt.io` would miss every start and stop in the cluster and nobody would notice until someone asked. Verified on a live cluster:

```
verb=update  group=subresources.kubevirt.io  resource=virtualmachines  sub=start  user=admin
verb=update  group=subresources.kubevirt.io  resource=virtualmachines  sub=stop   user=admin
verb=patch   group=kubevirt.io               resource=virtualmachines  sub=       user=admin
```

**The last rule is the one that pays for everything.** `level: None` on anything that did not match turns gigabytes a day into kilobytes.

## Capturing a body, and only where you need one

Everything above records metadata: who, when, which object, which verb. That is enough until you hit a record that names something other than what you care about. A snapshot is the case that shows up first: its audit record carries the snapshot's own name, and the machine it was taken from lives in the object's spec, which a metadata record does not have. So "who deleted that snapshot" has no answer, because by the time anyone asks, the snapshot is gone and nothing still holds its name.

The fix needs both halves of the pipeline, and the second half is what keeps it cheap.

### The API server has to capture it

Nothing downstream can add a body that was never written. The collector filter chooses what passes; it does not go back and ask the API server for more. Setting `level: RequestResponse` on a collector rule alone produces records labelled `RequestResponse` with no body in them, which is worse than not working, because it reads as though something stripped them later.

Capturing happens on the `APIServer` resource, and it does not have to be cluster-wide at full price. `customRules` applies a profile per group, first match wins, so service accounts can stay where they are while people get bodies.

*From a standalone cluster:*

```bash
oc patch apiserver cluster --type=merge -p '{"spec":{"audit":{"profile":"Default","customRules":[{"group":"system:serviceaccounts","profile":"Default"},{"group":"system:authenticated","profile":"WriteRequestBodies"}]}}}'
```

Order matters and the comment is the rule: a service account is also `system:authenticated`, so it has to match the narrower rule first or it falls through to the second one and you have bought the thing you were avoiding.

This rolls the kube-apiserver, node by node. On a single node cluster that is a short window with no API. Watch it land.

*From a standalone cluster:*

```bash
oc get kubeapiserver cluster -o jsonpath='{range .status.conditions[?(@.type=="NodeInstallerProgressing")]}{.reason}{": "}{.message}{"\n"}{end}'
```

### Two clusters from here on, and which one a command belongs to

Everything above this point concerns one cluster, so there was nothing to get wrong. From here there are two, and running the right command against the wrong one is the easiest mistake in this whole document.

The names used below:

| | |
| --- | --- |
| **the hosting cluster** | the one running the hosted control plane's pods. Also called the management cluster |
| **the hosted cluster** | the one that control plane serves, where the virtual machines and the people are. Also called the guest |

Every command from here on is preceded by a line in italics saying which of the two it belongs to.

### The three names you will be substituting, and where to read them

Most of the commands below take a hosted cluster's name, the namespace its `HostedCluster` lives in, or the namespace its control plane runs in. Those are three different strings and two of them look alike, which is how a patch ends up addressed at a cluster that does not exist.

*From the hosting cluster:*

```bash
oc get hc -A
```

```
NAMESPACE     NAME      VERSION   ...
clusters      payments  4.20.8    ...
```

The first column is the namespace the `HostedCluster` object lives in and the second is its name, in that order, which is the opposite of the order `oc patch <name> -n <namespace>` wants them in. The control plane runs in a third namespace, named `<namespace>-<name>`, so `clusters` plus `payments` gives `clusters-payments`. Read that one off the cluster rather than assembling it by hand:

*From the hosting cluster:*

```bash
oc get hcp -A
```

```
NAMESPACE           NAME      VERSION   ...
clusters-payments   payments  4.20.8    ...
```

That namespace is where steps 4 to 6 of the next section go, and where you look for the rendered audit configuration and the API server rollout. When in doubt, ask the cluster rather than the shell prompt.

*From either cluster:*

```bash
oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}{"\n"}'
```

`External` means you are on a guest: its API server runs elsewhere. Anything else, such as `SingleReplica` or `HighlyAvailable`, means the control plane is this cluster's own, so you are on a management cluster or on an ordinary one. That beats reading the context name, which says whatever somebody typed when they created it.

### On a hosted cluster the API server is somewhere else

A hosted control plane runs as pods in a management cluster, so none of the commands above land where you expect. The field moves, the watch command does not exist, and the obvious guess is wrong in a way that costs you the setting rather than just failing.

The audit configuration appears in three places and only one of them is yours to write. `HostedCluster.spec.configuration.apiServer.audit` on the management cluster is the source. The `HostedControlPlane` in the hosted control plane namespace carries the same field, which is why most people find it first, and the guest's own `APIServer` resource carries it too. Both are copies, rewritten on every reconcile:

```go
if hcluster.Spec.Configuration != nil {
    hcp.Spec.Configuration = hcluster.Spec.Configuration.DeepCopy()
} else {
    hcp.Spec.Configuration = nil
}
```

Note the `else`. Editing a copy while the `HostedCluster` carries no configuration of its own does not revert to the previous value, it clears it.

The block goes under `spec.configuration` on the `HostedCluster`.

*From the hosting cluster:*

```yaml
spec:
  configuration:
    apiServer:
      audit:
        profile: Default
        customRules:
        - group: system:serviceaccounts
          profile: Default
        - group: system:authenticated
          profile: WriteRequestBodies
```

Same ordering rule as above, for the same reason. `profile` and `customRules` are the only fields accepted here, the webhook form is not one of them.

To check it landed, where you are probably already working.

*From the hosted cluster:*

```bash
oc get apiserver cluster -o jsonpath='{.spec.audit}{"\n"}'
```

That reads a copy, so it tells you the setting reached the guest and nothing more, which is still the fastest way to catch a typo. For what the API server actually loaded, the management cluster holds the rendered policy and the profile name as plain text.

*From the hosting cluster:*

```bash
oc get cm kas-audit-config -n <hostedcluster-namespace>-<name> -o jsonpath='{.data.profile}{"\n"}'
```

The `oc get kubeapiserver cluster` command above does not work on a guest at all. That resource belongs to the cluster-kube-apiserver-operator, which a hosted cluster does not run. Watch the rollout instead.

*From the hosting cluster:*

```bash
oc rollout status deploy/kube-apiserver -n <hostedcluster-namespace>-<name>
```

The rollout is gentler here than on a single node cluster. `controllerAvailabilityPolicy` defaults to `HighlyAvailable` and the deployment rolls at 25 percent unavailable, so there is no window without an API. A cluster created with `SingleReplica` has one, and the field is immutable, so that is not a decision you get to revisit while you are standing there.

One more difference, before anyone goes looking for files on a node. A hosted control plane runs its API server with `audit-log-maxsize` of 10 and `audit-log-maxbackup` of 1, against 200 and 10 on a standalone cluster, so roughly 20 MB on disk instead of a couple of gigabytes. A sidecar tails the file to stdout continuously, which is what makes that survivable, but it also means there is no on-disk window worth going back to. Shipping is the only path.

### A guest has no API server audit to collect

Everything above configures what the hosted API server writes. None of it gets a single record to the guest's log store, and no setting on the guest changes that.

The `kubeAPI` audit source is not clever. It is a Vector `file` source with `include = ["/var/log/kube-apiserver/audit.log"]`, read off the node by hostPath. A hosted cluster's workers do not run an API server, so that file is not there, and the collector dutifully reads nothing. Measured on a stock hosted cluster with an untouched forwarder, all four audit sources enabled: 100 records sampled, 100 of them `auditd`, none from the API server. The audit tenant looks healthy, because node auditd is real and arrives, which is exactly what makes this take an afternoon to notice.

Confirm it before building anything.

*From the hosted cluster's log store:*

```
sum by (log_source) (count_over_time({log_type="audit"} | json [1h]))
```

`log_source` is a field rather than a stream label, which is why that needs the `json` parser. `auditd` and `ovn` come from the nodes and show up either way. `kubeAPI` is the one that will be missing.

### Why you cannot just point a reader at the management cluster

The obvious reaction is to leave the records where they are and query them where they live. That does not work, and the reason is worth knowing before anyone spends a day on it.

A LokiStack gateway in `openshift-logging` mode authenticates with a TokenReview and authorises with a SubjectAccessReview, both against the API server of the cluster it runs in. Its ClusterRole grants exactly `tokenreviews:create` and `subjectaccessreviews:create` and nothing else. A token minted by the guest is not an identity the management cluster can evaluate, so it is refused before RBAC is even consulted. No binding fixes that, because nothing is missing a permission.

So the records have to come to the guest. Then every reader that already works, with every user's own token, keeps working, and nothing downstream needs to know the cluster is hosted.

### Bringing them over

Seven steps across the two clusters, in this order. The rest of this section explains each one and why it is shaped the way it is, but the order is the part that matters, because the last step restarts an API server and the ones before it are what make that restart worth doing.

| | where | what |
| --- | --- | --- |
| 1 | hosted | the writer identity: a ServiceAccount, a ClusterRole granting `create` on `audit` and nothing else, and a Secret holding a token that does not expire |
| 2 | hosted | read the gateway host off the route |
| 3 | hosting | prove the hosting cluster can reach that host |
| 4 | hosting, in `openshift-logging` | a Secret holding the hosted cluster's token |
| 5 | hosting, in `openshift-logging` | the `ClusterLogForwarder`: a `receiver` input and a generic `loki` output pointed at the hosted cluster |
| 6 | hosting, in the namespace the `HostedCluster` lives in | a Secret holding the webhook kubeconfig, under the key `webhook-kubeconfig`. HyperShift syncs it into the control plane namespace itself |
| 7 | hosting | set `HostedCluster.spec.auditWebhook`, which rolls the hosted API server |

Steps 1 and 5 have files in [manifests/](manifests/): `hosted-cluster-audit-writer.yaml` on the guest and `hosted-cluster-forwarder.yaml` on the management cluster. Applying a file beats copying a snippet out of prose.

The order is not arbitrary. The token in step 1 is what step 4 carries, step 4 is what step 5 authenticates with, and step 7 sends traffic at something that has to already be listening. Doing 7 first gives you an API server restart and a webhook posting into nothing.

The hosted API servers can post audit events to a webhook, and HyperShift already wires that up: `HostedCluster.spec.auditWebhook` names a Secret holding a kubeconfig under the key `webhook-kubeconfig`, which is synced into the hosted control plane namespace, mounted at `/etc/kubernetes/auditwebhook`, and turned into `--audit-webhook-config-file` with `--audit-webhook-mode=batch`. It is applied to all four of them, kube-apiserver, openshift-apiserver, oauth-apiserver and oauth-server, so the openshift-apiserver and oauth records come along without extra work. They do not come along as `openshiftAPI`, though. The receiver stamps `log_source = "kubeAPI"` on everything it accepts, so on a hosted cluster all four servers share one `log_source`, and a query filtering `log_source="openshiftAPI"`, which is what those same records answer to on a standalone cluster, finds nothing.

Point that webhook at a `ClusterLogForwarder` receiver and give that forwarder a `loki` output aimed at the hosted cluster's gateway. This is step 5, and it goes in `openshift-logging` on the hosting cluster, **not** in the control plane namespace, which is the obvious guess and does not work: HyperShift labels those namespaces `pod-security enforce=restricted` and pins `scc.podSecurityLabelSync=false`, while the collector mounts a `hostPath` and sets no `securityContext`, so admission rejects the pod. Running it from `openshift-logging` works because the hosted API server has no egress restriction; every NetworkPolicy selecting it is Ingress only. Check that before assuming it holds in your version:

*From the hosting cluster:*

```bash
oc get networkpolicy -n <control-plane-namespace> -o custom-columns=NAME:.metadata.name,TYPES:.spec.policyTypes
```

The fragment below is the part that matters and is not a complete object. [manifests/hosted-cluster-forwarder.yaml](manifests/hosted-cluster-forwarder.yaml) is the whole file with its `apiVersion`, `kind` and `metadata`, which is what you apply.

*Applied on the hosting cluster:*

```yaml
spec:
  serviceAccount:
    name: hosted-audit-collector
  inputs:
    - name: hosted-audit
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
        url: https://<guest-gateway-host>/api/logs/v1/audit
        authentication:
          token:
            from: secret
            secret:
              name: guest-audit-writer
              key: token
  pipelines:
    - name: hosted-audit
      inputRefs: [hosted-audit]
      outputRefs: [guest-loki]
```

#### Finding the guest's gateway host, and proving the management cluster can reach it

The route is named after the LokiStack, so do not hard-code `logging-loki`. Ask by label instead.

*From the hosted cluster:*

```bash
oc get route -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway -o jsonpath='{.items[0].spec.host}'
```

That is the whole value for the `url` above, with `https://` in front and `/api/logs/v1/audit` after it. The tenant is part of the path, which is how LokiStack separates the three.

Reading the name is the easy half. The forwarder runs on the management cluster, and nothing says the management cluster can resolve a hostname served by the guest's ingress. In a lab where one cluster's wildcard sits under the other's it works by accident; between two clusters that share no DNS it does not, and the symptom is a collector retrying forever while the ClusterLogForwarder reports itself healthy. Check it from inside the cluster, not from your laptop.

*From the hosting cluster:*

```bash
# oc get hcp -A
oc exec -n <hosted-control-plane-namespace> <any-pod> -- curl -sk -o /dev/null -w '%{http_code}\n' --max-time 15 https://<guest-gateway-host>/api/logs/v1/audit/loki/api/v1/labels
```

`302` is the answer you want: the gateway redirects a request carrying no token, which means DNS resolved and the route answered. `000` or a timeout means the management cluster cannot get there, and that is a networking prerequisite to settle before any of the rest of this is worth applying.

`serviceAccount` is required, and the account has to exist in the forwarder's own namespace, which here is `openshift-logging` on the hosting cluster. It needs no role bindings: a forwarder whose only input is a receiver skips the `collect-*` authorization check entirely, so the account only has to be there. Leave it out and the apply is refused with `spec.serviceAccount: Required value` before any of the rest is read. Nothing creates it for you:

*From the hosting cluster:*

```bash
oc create sa audit-collector -n openshift-logging
```

That is the second ServiceAccount in this procedure and the two are easy to confuse, because they sit on opposite sides and do opposite jobs:

| | lives on | what it is for | needs RBAC |
| --- | --- | --- | --- |
| the writer | the hosted cluster | its **token** is what authenticates the write into that cluster's Loki | yes, `create` on `audit` and nothing more |
| the collector | the hosting cluster, in `openshift-logging` | only has to exist, so the forwarder passes validation | no bindings at all |

The output is `loki`, not `lokiStack`. The `lokiStack` type resolves an instance in its own cluster, which is the thing the management cluster does not have and does not want. The generic type takes a URL and a bearer token and asks no further questions.

That token belongs to a ServiceAccount on the **guest**, which is step 1 and has to exist before any of this is applied, bound to `logging-collector-logs-writer`, which ships with the operator. A guest ServiceAccount is an identity the guest gateway can evaluate, which is the whole point. Read the role before you bind it, though: it grants `create` on `logs` for `application`, `audit` and `infrastructure` alike, and there is no audit-only variant shipped. A token bound to it can write to all three tenants, on a cluster it does not live in. Writing your own ClusterRole naming the `audit` resource and nothing else costs four lines.

### Two things that will bite

**Do not use an `application` input to scrape the sidecar's stdout.** The kube-apiserver pod has an `audit-logs` container tailing the file to stdout, and collecting that container looks like the obvious shortcut. It silently destroys the filter. The `kubeAPIAudit` policy is VRL that opens with `is_string(.auditID) && is_string(.verb)`, and a container record carries the event as a string inside `.message` under `log_type=application`. The guard never matches, the whole policy becomes a no-op, nothing reports an error, and the records land in the `application` tenant. Everything in the section above about buying back volume stops being true, quietly. The `receiver` input does not have this problem: it sets `log_type=audit` and `log_source=kubeAPI`, and the record is flattened to the same top-level shape the file source produces, so the filter and any reader built against a normal cluster work unchanged.

**The receiver has no authentication, and `openshift-logging` does not protect it either.** `ReceiverSpec` carries a type, a port and TLS, and the operator never asks Vector to verify a client certificate, so requiring one is not expressible. The kubeconfig's client certificate is offered and ignored. An earlier version of this page argued that the hosted control plane namespace made that acceptable, on the strength of HyperShift's NetworkPolicies. That argument does not survive the forwarder living in `openshift-logging`, where those policies do not apply. Measured on a working setup: no NetworkPolicy in that namespace at all, the receiver's Service a plain ClusterIP, no Route. Any pod in the hosting cluster can post audit records into it.

Nothing downstream treats that as a problem, because the records are tagged by the receiver rather than trusted from the sender, but an unauthenticated sink that accepts anything is worth closing rather than explaining. The control plane namespaces carry a label to select them by, so one policy admits the senders and nobody else:

*From the hosting cluster:*

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: audit-receiver
  namespace: openshift-logging
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/instance: hosted-audit
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              hypershift.openshift.io/hosted-control-plane: "true"
      ports:
        - protocol: TCP
          port: 8443
```

Whatever you do, do not put a Route in front of it. Behind a Route it is an open audit sink on the internet.

### The field marked immutable is not

`spec.auditWebhook` carries a `// +immutable` marker in the API source, which reads like it can only be set when the cluster is created. The marker is a comment. Thirty-two fields in that file carry a real `XValidation` rule of `self == oldSelf`, and this is not one of them, so the API server enforces nothing. Verified against a running cluster with a server-side dry run, which exercises admission and persists nothing. On the **management cluster**, which is where `HostedCluster` lives.

*From the hosting cluster:*

```bash
oc patch hostedcluster <name> -n <namespace> --type=merge --dry-run=server -p '{"spec":{"auditWebhook":{"name":"does-not-exist"}}}'
```

It is accepted. So an existing hosted cluster can be wired up without being rebuilt, which is worth knowing before anyone schedules a rebuild over a code comment.

The operator agrees. It is level triggered, so it acts on a value set after creation: the HostedCluster reconcile copies `spec.auditWebhook` onto the `HostedControlPlane` and re-syncs the secret into the control plane namespace on every pass, and each of the four API server components reads it again every time it renders its deployment. Nothing validates the field on the way in either. Applying it does roll the control plane, so it is a change with a window and not a thing to try on a Friday.

One asymmetry to know before you experiment: that copy has no `else` branch, so removing `spec.auditWebhook` from the `HostedCluster` later does not clear it from the `HostedControlPlane`.

### The forwarder decides what leaves

The collector deletes bodies on any rule at `Metadata`. That is not an inference, it is in the Vector configuration the operator generates:

```
if .level == "Metadata" {
  del(.responseObject)
  del(.requestObject)
}
```

Which means one rule at `RequestResponse` for snapshots, ahead of the `Metadata` rule that covers everything else, sends exactly one kind of body to the log store and nothing more:

```yaml
        rules:
          - level: RequestResponse
            verbs: [create, delete]
            resources:
              - group: snapshot.kubevirt.io
                resources: [virtualmachinesnapshots, virtualmachinerestores]
          - level: Metadata
            verbs: [create, update]
            resources:
              - group: subresources.kubevirt.io
                resources: [virtualmachines/start, virtualmachines/stop, virtualmachines/restart]
          - level: None
            userGroups: [system:serviceaccounts, system:nodes]
          - level: Metadata
            verbs: [create, update, patch, delete]
            resources:
              # ...the groups from the filter above...
          - level: None
```

A create carries the object in `requestObject`, a delete in `responseObject`. Read both.

### What it costs, measured

On a cluster where this was done in stages with a baseline taken first:

| | |
| --- | --- |
| service account records carrying a body, after | 0 of 1774 |
| people's records carrying a body, after | 2 of 112, which were the two writes made during the test |
| audit reaching the log store | 8.1 KB/min, against 29 MB/min of infrastructure logs |
| API server audit files on the node | still 10 rotated, unchanged |

People are a little over one percent of audit records, so giving them bodies moves almost nothing. Reads stay at metadata on their own: `WriteRequestBodies` is about writes.

### What exposure actually changes

Be precise about this rather than reassuring. The log store receives one new thing: snapshot bodies. Nothing else.

The node's own audit files are where the change is real. They now carry request bodies for human writes against any resource, not only the ones you filter for downstream, because the API server captures before anything selects. Those files are readable by whoever can read node logs, and they rotate in hours. `Secret`, `Route` and `OAuthClient` stay at metadata level whatever the profile says, which is platform behaviour and not something you configured.

If that trade is wrong for your cluster, the honest answer is to leave the profile alone and accept that deletions stay unattributed. The rest of the pipeline works without this.

### Doing it in stages

Both halves change behaviour, and one of them restarts your API server, so change one at a time and keep something to compare against. Capture what the pipeline already answers before touching anything, re-check it after the API server lands, and re-check it again after the filter. When something stops working you want to know which of the two did it, and a baseline is the difference between a diagnosis and a guess.

## Monitoring, which the Loki dashboards need

The console's Logs view reads from Loki, but the dashboards that show how Loki itself is doing read from Prometheus. If those are empty while logs are fine, the log store is not the problem.

Two things are needed. The namespace has to be in scope for the platform monitoring stack:

```bash
oc label namespace openshift-logging openshift.io/cluster-monitoring=true
```

A namespace created by hand does not carry that label, and nothing complains about its absence. The symptom is a dashboard with no datapoints, which reads as a Loki problem and is not one.

And monitoring needs somewhere to keep its own data, which is also where user workload monitoring gets turned on:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
    alertmanagerMain:
      volumeClaimTemplate:
        metadata:
          name: pvc-alertmanager
        spec:
          resources:
            requests:
              storage: 10Gi
    prometheusK8s:
      volumeClaimTemplate:
        metadata:
          name: pvc-prometheus
        spec:
          resources:
            requests:
              storage: 100Gi
```

### The claim with no storage class

Those templates name no `storageClassName` on purpose, so each cluster uses whatever it already treats as default. That only works if the cluster has one:

```bash
oc get sc -o custom-columns=NAME:.metadata.name,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class
```

With no default, both claims are created with no class at all and sit `Pending` forever. Nothing in the monitoring operator's status points at storage, and the obvious reading is that monitoring is broken.

Marking a default fixes it, and fixes it for everything created afterwards rather than one claim at a time:

```bash
oc patch storageclass <your-class> -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Claims already stuck recover on their own: the volume controller keeps retrying unbound claims and picks up the default once it exists. If one does not, note that a claim's `storageClassName` can be set when it was never set, but not changed once it holds a value, so a claim created against a class that does not exist has to be deleted rather than edited.

Pinning the class explicitly in the template works too, and is the better choice when the cluster has several and the default is not the one you want Prometheus on.

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

The records are enveloped, which trips up the first attempt at parsing them. The top level keys are `@timestamp`, `hostname`, `kubernetes`, `level`, `log_source`, `log_type`, `message` and `openshift`, and for a `kubeAPI` record the audit event's own fields sit alongside them: `user`, `verb`, `objectRef`, `requestReceivedTimestamp`. An `auditd` record has none of those and carries `audit.linux` instead, so a parser that assumes every line is a Kubernetes audit event reads nulls and concludes nothing arrived. Filter on `log_source` first.

A working pipeline looks like this, from a real run where a virtual machine was created, started with virtctl, started again from the console, snapshotted and torn down:

```
02:25:32  admin  create  virtualmachines           ns=vmtest
02:25:33  admin  update  virtualmachines/start     ns=vmtest
02:25:35  admin  create  virtualmachinesnapshots   ns=vmtest
02:25:35  admin  patch   virtualmachines           ns=vmtest
02:25:35  admin  update  virtualmachines/stop      ns=vmtest
02:25:38  admin  delete  virtualmachinesnapshots   ns=vmtest
```

Note that the two ways of stopping a machine arrive as different records. The subresource call and the patch are both there, which is the thing the filter would have missed without the `subresources.kubevirt.io` block.

For scale: on the cluster this was measured on, the audit stream went from 4.26 MB per minute to 3.1 KB per minute, which is about 1400 to 1. It stopped being a cost and stopped competing for ingestion bandwidth at the same time.

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

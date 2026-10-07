# Keeping the audit log long enough to answer a question

## Why this is needed

Someone asks who stopped that virtual machine, or who deleted that snapshot, and when. The cluster knows. It wrote it down. The problem is that it threw the note away before anyone asked.

Kubernetes objects do not record who changed them. A VirtualMachine carries `managedFields`, which tells you when `runStrategy` last changed and what kind of client did it, and that is already useful. It does not carry a username. Events do not carry one either: start and stop produce events whose source is `virtualmachine-controller`, because the controller is what acted. The human is upstream of that.

The username exists in exactly one place, the kube-apiserver audit log. So the question becomes how long that log survives, and the answer on a default cluster is shorter than people expect.

## Where the audit log actually lives

It is not a PersistentVolumeClaim and it is not ephemeral. The kube-apiserver static pod mounts a hostPath:

```
volume audit-dir -> hostPath /var/log/kube-apiserver
```

That is local disk on the control plane node. It survives a reboot. There is no PVC to resize, which is the first thing people go looking for.

## Why the window is so short

Two settings decide it, and neither is about time:

```
audit-log-maxbackup   10
audit-log-maxsize     200     (MB per file)
```

There is no `audit-log-maxage`. The ceiling is eleven files of 200 MB, about 2.2 GB, and however much wall-clock time that covers is whatever it covers. On a quiet single-node lab it worked out to roughly 26 hours. On a busy cluster with three control plane nodes it is a lot less, and you also have three separate copies to search, because each API server writes its own.

Here is the part that surprises people. On that same lab, `/var` had 477 GB with 320 GB free. The API server is keeping 2.2 GB of audit history on a disk with 320 GB available. The limit has nothing to do with space. It is a configured value that nobody chose on purpose.

## What you cannot do

The obvious move is to raise `audit-log-maxbackup`. On OpenShift those arguments are rendered by the kube-apiserver operator, so the only way in is `unsupportedConfigOverrides` on the KubeAPIServer custom resource.

Do not. The field documents its own consequence, and it is worse than the name suggests:

> Red Hat does not support the use of this field. Misuse of this field could lead to unexpected behavior or conflict with other configuration options. Seek guidance from the Red Hat support before using this field. Use of this property blocks cluster upgrades, it must be removed before upgrading your cluster.

Blocking upgrades is not a policy position you can argue with, it is a mechanical gate. You would be trading a cluster you can patch for a slightly longer log.

Worth noting the asymmetry: `eventTTLMinutes` on the same resource is supported, with a documented range of 5 to 180 minutes. Events got a knob. The audit log did not.

## What you can do

Two supported levers, and they work in opposite directions.

**Write less, so the same 2.2 GB covers more days.** The APIServer resource has `spec.audit`, with a `profile` and per-group `customRules`:

```bash
oc get apiserver cluster -o jsonpath='{.spec.audit}'
```

A default cluster reports `{"profile":"Default"}`, which already omits request bodies. `customRules` lets you set a lighter profile for a specific group, down to `None`. The filtering is coarse, by group rather than by resource, so you usually trade some visibility you wanted for the noise you did not. Go the other way and `WriteRequestBodies` or `AllRequestBodies` will shorten the window considerably, which catches people who set them expecting more visibility and get less history.

**Forward it off the node.** This is the real answer. A ClusterLogForwarder with the `audit` input ships to Loki or to an external destination, and retention stops being a local disk question.

Be honest with yourself about what you are signing up for. Audit is the loudest input a cluster produces, and forwarding it solves retention by converting it into a storage bill. Buckets fill faster than anyone estimates, and the filtering available upstream is the same coarse per-group filtering described above, so trimming the volume tends to cost you the records you wanted. Plan the retention policy at the destination before turning the tap on, not after the first invoice.

## Checking your own cluster

What the API server is configured to keep:

```bash
oc get cm config -n openshift-kube-apiserver -o jsonpath='{.data.config\.yaml}' | python3 -c 'import json,sys; a=json.load(sys.stdin)["apiServerArguments"]; [print(k, v) for k, v in sorted(a.items()) if "audit" in k]'
```

How much history is actually on disk right now:

```bash
oc adm node-logs --role=master --path=kube-apiserver/ | grep audit- | sort | sed -n '1p;$p'
```

Whether anything is forwarding it:

```bash
oc get clusterlogforwarder -A
```

## Scope and limits

Reading the audit log needs `nodes/log` or `nodes/proxy`, which in practice means cluster admin. That is correct and should stay that way: a tenant with access to one namespace has no business reading cluster-wide activity.

None of this makes the audit log a query engine. It is a flat file designed to be shipped somewhere else, and grepping a few gigabytes of JSON across three control plane nodes is a forensic exercise, not a feature. If you need to answer who did what on a regular basis, forward it and query it at the destination. If you need it once, after an incident, the local files are fine, assuming you get there within the day.

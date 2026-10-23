# Keeping specific VMs out of descheduler balancing

The OpenShift Virtualization equivalent of setting a VM's DRS automation level to
"Disabled" in vSphere: the descheduler stops picking that VM for load-balancing
live migrations. Node drains, cluster updates and manual migrations still move it.

## What works

Put the annotation on the VM **template**, not on the `VirtualMachine` metadata:

```yaml
spec:
  template:
    metadata:
      annotations:
        descheduler.alpha.kubernetes.io/prefer-no-eviction: "true"
```

Measured on OpenShift Virtualization 4.21 (KubeVirt 1.7.4) with Kube Descheduler
Operator 5.3.4 and PSI enabled:

- On `metadata.annotations` of the `VirtualMachine`, the annotation never reaches the
  VMI or the `virt-launcher` pod, and the pod is what the descheduler evaluates.
- Under `spec.template.metadata`, it reaches the running pod immediately (no restart,
  no migration) and survives migrations and restarts.
- With a node at 97% CPU running 5 annotated VMs and 2 plain ones, the descheduler
  migrated only the 2 plain ones, then kept the node classified `overutilized` for the
  next 7 minutes and evicted nothing else.

## The profile matters

The annotation is only enforced when `noEvictionPolicy` on `DefaultEvictor` is
`Mandatory`. The default is `Preferred`, which the descheduler source describes as
"the annotation will get ignored by the DefaultEvictor plugin". The operator sets
`Mandatory` only inside the `KubeVirtRelieveAndMigrate` profile. With
`TopologyAndDuplicates`, `AffinityAndTaints` and the others, the annotation does
nothing. The script warns when the cluster is not using `KubeVirtRelieveAndMigrate`.

`KubeVirtRelieveAndMigrate` itself needs the operator namespace labeled
`openshift.io/cluster-monitoring=true` and PSI (`psi=1`) on the workers. When either
is missing, `KubeDescheduler` does not go Degraded; the error only shows in the
operator log.

## Auditing

The descheduler skips protected VMs silently: no log line, not even at `Debug`. Ask
the annotation instead:

```bash
oc get vm -A -o jsonpath='{range .items[?(@.spec.template.metadata.annotations.descheduler\.alpha\.kubernetes\.io/prefer-no-eviction=="true")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

## The script

`vm-descheduler-exclude.sh` reads a list of VM names (one per line, only the first
column is read, so a vSphere export with power state and DRS columns works as is),
finds each VM across all namespaces case-insensitively, and patches the template.
Names found in more than one namespace are reported and left alone.

```bash
./vm-descheduler-exclude.sh plan   vms.txt
./vm-descheduler-exclude.sh apply  vms.txt
./vm-descheduler-exclude.sh verify vms.txt
./vm-descheduler-exclude.sh undo   vms.txt
```

Write-up with the full test: [DRS for OpenShift Virtualization](https://linuxelite.com.br/blog/drs-for-openshift-virtualization/).

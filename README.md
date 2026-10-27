# KubeVirt Day 2 Scripts

## Run Strategy

Usage examples:

```bash
oc login https://api.<cluster>:6443
./vm-runstrategy.sh
./vm-runstrategy.sh --apply --plan runstrategy-<cluster>-<timestamp>
```

```bash
./vm-runstrategy.sh --only fencing-lab/vm-always
```

From a Hosted Control Planes hosting cluster, audit the hosting cluster and every available HostedCluster. The script reads each hosted cluster's admin kubeconfig from `status.kubeconfig` into a temporary file and deletes it on exit. VMs in HCP control plane namespaces (the hosted clusters' worker VMs) are always blocked: the NodePool owns them.

```bash
oc login https://api.<hosting-cluster>:6443
./vm-runstrategy.sh --hosted-clusters
./vm-runstrategy.sh --apply --plan runstrategy-campaign-<timestamp>
```

```bash
./vm-runstrategy.sh --hosted <namespace>/<hostedcluster>
./vm-runstrategy.sh --hosted-clusters --skip-hosting
```

Each `--apply` writes a `rollback.sh` (one per cluster in a campaign: `<plan>/<cluster>/rollback.sh`). A hosted cluster's rollback runs with your `oc` session on the hosting cluster and fetches the hosted admin kubeconfig itself, like `--apply`. A standalone rollback runs with your session on that cluster.

```bash
bash runstrategy-campaign-<timestamp>/hosted__<namespace>__<hostedcluster>/rollback.sh
```

Why `RerunOnFailure` and not `Always`: [runStrategy in OpenShift Virtualization: when a VM restarts](https://linuxelite.com.br/blog/runstrategy-openshift-virtualization-kubevirt/).

## Backup Labels

```bash
./vm-backup-label.sh --label-vms Com-Backup --fix
```

## Windows VM Enlightenment Tuning

```bash
./vm-hyperv-tuning.sh audit -n NAMESPACE
./vm-hyperv-tuning.sh apply -p ./hyperv-tuning/plan-XXX.csv --dry-run
```

```bash
./diff hyperv-tuning/diff-XXX/default__YYY.before.json hyperv-tuning/diff-XXX/default__YYY.after.json
```

```bash
./vm-hyperv-tuning.sh apply -p ./hyperv-tuning/plan-XXX.csv
```

## Descheduler Exclusion

```bash
./vm-descheduler-exclude.sh plan vms.txt
./vm-descheduler-exclude.sh apply vms.txt
./vm-descheduler-exclude.sh verify vms.txt
./vm-descheduler-exclude.sh apply --vm my-vm
./vm-descheduler-exclude.sh apply vms.txt -i
```

## VM Affinity Groups

```bash
./vm-affinity-groups.sh plan -f groups.txt --prefix example.com
./vm-affinity-groups.sh apply -f groups.txt --prefix example.com
./vm-affinity-groups.sh fix -f groups.txt --prefix example.com
./vm-affinity-groups.sh undo -f groups.txt --prefix example.com
./vm-affinity-groups.sh renew --prefix example.com
```

## Notes

- [windows-forklift-tuning.md](windows-forklift-tuning.md): what to add to a Windows VM after a Forklift migration, and why each field.
- [who-did-what.md](who-did-what.md): finding out who started, stopped or snapshotted a VM, and when.
- [audit-log-retention.md](audit-log-retention.md): where the audit log lives, why its window is so short, and what you can do about it.
- [audit-pipeline-setup.md](audit-pipeline-setup.md): standing up Loki and a log forwarder so the audit log survives long enough to answer a question, shipping only the part worth keeping.
- [descheduler-exclude-vms.md](descheduler-exclude-vms.md): keeping specific VMs out of descheduler balancing, and why it only works with `KubeVirtRelieveAndMigrate`.
- [vm-affinity-groups.md](vm-affinity-groups.md): keeping groups of VMs apart or together on running VMs, why the label has to be on the template, the VMI and the pod, and what the rules do not do on their own.

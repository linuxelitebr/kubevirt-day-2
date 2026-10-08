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

## Notes

- [windows-forklift-tuning.md](windows-forklift-tuning.md): what to add to a Windows VM after a Forklift migration, and why each field.
- [who-did-what.md](who-did-what.md): finding out who started, stopped or snapshotted a VM, and when.
- [audit-log-retention.md](audit-log-retention.md): where the audit log lives, why its window is so short, and what you can do about it.
- [audit-pipeline-setup.md](audit-pipeline-setup.md): standing up Loki and a log forwarder so the audit log survives long enough to answer a question, shipping only the part worth keeping.

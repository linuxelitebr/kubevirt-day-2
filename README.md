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

./diff hyperv-tuning/diff-XXX/default__YYY.before.json hyperv-tuning/diff-XXX/default__YYY.after.json

./vm-hyperv-tuning.sh apply -p ./hyperv-tuning/plan-XXX.csv
```

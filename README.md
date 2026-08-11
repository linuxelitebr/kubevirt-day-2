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

# Keeping groups of VMs apart or together

`vm-affinity-groups.sh` puts groups of VMs on different nodes (anti-affinity) or on
the same node (affinity) using a label and a pod (anti-)affinity rule. It does that
on running VMs without restarting them, and it checks its own work.

The rule itself is the easy part. Everything that makes it hard is about running VMs,
and that is what this note covers.

## The group label lives in three places

KubeVirt does not push label changes to running objects. Measured on OpenShift
Virtualization 4.21 (CNV 4.21.24, `vmRolloutStrategy: LiveUpdate`):

| Change | VM template | VMI | Running pod | After migration | After restart |
| --- | --- | --- | --- | --- | --- |
| Label on the VM template | stored | not copied | not copied | not there | there |
| Label on the VMI | - | stored | not copied | there (new pod copies VMI labels) | gone (new VMI comes from the template) |
| Label on the pod | - | - | counts right away, pod not recreated | gone | gone |
| Affinity rule on the template | stored | copied right away, no `RestartRequired` | unchanged (pod spec is immutable) | there | there |

So the script writes the label to the template, the VMI and the running
`virt-launcher` pod. The pod label is the one that counts *now*: a VM pinned to a node
whose pod carries the group label, with a required anti-affinity rule against that
group, stays `Pending` with `didn't match pod anti-affinity rules`. Remove the label
from the pod and the same VM starts on that node.

The rule goes to the template only. With `LiveUpdate`, KubeVirt copies it to the
running VMI; the running pod keeps its old spec until the next migration or restart.

## Usage

```bash
./vm-affinity-groups.sh plan   -f groups.txt --prefix example.com
./vm-affinity-groups.sh apply  -f groups.txt --prefix example.com
./vm-affinity-groups.sh verify -f groups.txt --prefix example.com
./vm-affinity-groups.sh fix    -f groups.txt --prefix example.com
./vm-affinity-groups.sh undo   -f groups.txt --prefix example.com
./vm-affinity-groups.sh renew  --prefix example.com
```

`groups.txt` holds one group per line (see `vm-affinity-groups.example.txt`):

```text
# kind     group    rule       members (name or namespace/name)
anti       db       required   db-1 db-2 prod/db-3
affinity   app-web  preferred  app-1 web-1
```

The labels are `<prefix>/anti-affinity=<group>` and `<prefix>/affinity=<group>`. Use a
domain you own as the prefix. The value is the **group name**, not a list of VMs: a
label value has a 63 character limit that a list of VM names blows through fast, and
the rule only needs one value that every member shares. The list of members lives in
the file.

- `plan` changes nothing.
- `apply` writes labels and rules, then runs `verify`. It never migrates anything.
- `verify` checks template, VMI and pod of every member, where the members actually
  run, and whether any running pod in the cluster still carries an outdated rule.
- `fix` live-migrates the members that break their group rule. It asks first, or
  takes `-y`.
- `undo` removes the script's labels and rules and leaves everything else alone.
- `renew` replaces the pods that still carry an outdated rule, with a live migration.

`--group NAME` limits any mode to one group. `OC_CONTEXT` points it at another
cluster. It needs bash 4+, `jq` and `oc`. Exit codes: 0 clean, 1 bad input, 2 finished
with problems.

## The rule shape, and the console

The script writes the rule as `matchExpressions` (`key In [group]`), the same shape
the console's affinity editor writes ("Workload (pod) Anti-Affinity", "Workload
labels"), so the VM's Scheduling tab shows the key, the operator and the group.
Earlier versions wrote `matchLabels`: same pods selected, but the console's editor
only reads `matchExpressions` and showed those rules with no details. `apply`
recognizes and converts the old form.

Two console behaviors to know. Both come from reading the kubevirt-plugin source
(release-4.21); the rule shape itself was confirmed with a rule created in the console:

- **It does not keep `namespaces`.** The script only adds that field for groups that
  span namespaces (without it, a term only sees its own namespace). Saving that VM's
  affinity in the console drops it. `verify` reports `rule no-namespaces`; `apply`
  restores it.
- **It cannot read `matchLabels` rules**, so saving the affinity of a VM that still
  has one leaves a term with an empty selector, which matches every pod in the
  namespace. `verify` warns about any empty-selector term; it does not delete it,
  since it may not be the script's.

## What the rules do not do on their own

Each of these showed up while testing, and the script handles it:

- **Affinity is `IgnoredDuringExecution`.** Two VMs that already share a node stay
  there after the rule appears. `verify` reports it, `fix` separates them.
- **An affinity group splits on any migration of a member.** KubeVirt puts a required
  anti-affinity on the migration target against its own source pod, so a migration
  never lands on the source node. A drain, the descheduler or a manual migration of one
  member takes it away from the group. `fix` brings it back with a migration that
  carries `addedNodeSelector` for the group's node.
- **A preferred anti-affinity rule can lose.** Renewing two members of a preferred
  anti group put both on the same node: the only other candidate had 4 VMs and resource
  scoring outweighed the rule. `fix` sends each extra member to a node with no member
  instead of leaving it to the scheduler.
- **The running pod keeps the old rule.** After `undo`, or after a VM leaves a group,
  its pod still has the rule it was born with, and required anti-affinity works both
  ways: that pod keeps repelling the group. A member migration stuck at
  `didn't satisfy existing pods anti-affinity rules` because of a VM that had already
  left the group. `verify` lists these pods; `renew` replaces them. Relaxing a group
  from `required` to `preferred` is the same case.
- **Without `namespaces`, a pod affinity term only sees its own namespace.** A VM in
  another namespace with a required anti-affinity rule against the group started right
  next to a member. With `namespaces` set, it stayed `Pending`. The script writes the
  namespaces of the group's members into every rule.

## Guard rails

- Any error in the groups file stops `apply`, `fix` and `undo` before anything changes:
  invalid prefix (or a reserved one, `kubernetes.io` and `k8s.io`), group names that
  are not valid label values, VMs not found, names found in two namespaces (use
  `namespace/name`), a VM in two groups of the same kind, groups with fewer than 2 VMs.
- `anti ... required` with more members than schedulable nodes is refused: the extra
  VM would stay `Pending`. With exactly as many members as nodes it warns. Measured:
  with 3 members on 3 nodes, migrating any of them sits in `Scheduling` with
  `3 node(s) didn't match pod anti-affinity rules`, so draining one of those nodes
  blocks.
- `affinity ... required` is refused unless `--allow-required-affinity`. Measured:
  migrating a member never schedules (`1 node(s) didn't match pod anti-affinity rules,
  2 node(s) didn't match pod affinity rules`). Prefer `preferred` plus `fix`.
- A VM with a migration in progress is skipped. The check uses the VMIM, not the VMI:
  `migrationState.completed` flips before the VMI points at the target node, and
  labelling in that window labels the old pod.
- Existing labels, other affinity terms, `nodeAffinity` and labels added to the VMI by
  hand are kept, through `apply` and `undo`.

## Tested

On an HCP hosted cluster (OpenShift 4.21.36, CNV 4.21.24, 3 workers) with CirrOS VMs:
input validation (every case above), `plan` leaving the cluster untouched, `apply` on
co-located VMs without recreating any pod, idempotent re-runs, `fix` for anti and
affinity groups, cross-namespace groups, migration, restart, stopped members, a VM in
an anti group and an affinity group at once, `--group`, group shrink and group change,
`undo`, `renew`, a real node drain with spare capacity (members kept apart) and
without it (drain blocks), and a final run from fresh VMs through every mode ending
with no label or rule left behind.

Not tested: `vmRolloutStrategy: Stage` (the script warns that rules then reach the VMI
only on restart), and clusters where VMs use dedicated node pools with their own
`nodeSelector` (the free-node choice in `fix` looks at all schedulable nodes).

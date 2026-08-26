# Windows VMs migrated with MTV/Forklift: post-migration tuning

## Why this is needed

Forklift does two separate things. `virt-v2v` converts the guest (virtio drivers installed,
`guestConverted: true`), and the controller creates the VirtualMachine object. The second step
applies no preference and no instancetype, so `vm.kubevirt.io/os`, `flavor` and `workload` come out
empty.

The guest is prepared, but every hypervisor-side setting that Red Hat's official Windows templates
define as baseline is missing: no `features.hyperv`, no `clock.timer`, no iothreads. VMware exposed
the equivalent by default, so this surfaces as a regression right after migration. Typical report:
sluggish menus, slow application launch, CPU metrics looking normal.

## Check first

```bash
oc get vm <vm> -n <ns> -o json | jq '{
  hyperv: .spec.template.spec.domain.features.hyperv,
  clock:  .spec.template.spec.domain.clock,
  io:     .spec.template.spec.domain.ioThreadsPolicy
}'
```

Three `null` values means the VM was created raw by Forklift.

## What to add to the VM YAML

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 3600
      domain:
        features:
          hyperv:
            relaxed: {}
            vapic: {}
            vpindex: {}
            synic: {}
            synictimer:
              direct: {}
            spinlocks:
              spinlocks: 8191
            tlbflush: {}
            ipi: {}
            runtime: {}
            reset: {}
            frequencies: {}
            reenlightenment: {}
        clock:
          timezone: UTC
          timer:
            hpet:
              present: false
            pit:
              tickPolicy: delay
            rtc:
              tickPolicy: catchup
            hyperv: {}
        ioThreadsPolicy: auto
        devices:
          inputs:
            - bus: usb
              name: tablet
              type: tablet
```

## Why each field

### features.hyperv

Enlightenments let Windows detect it is running under a hypervisor and swap expensive operations
for hypercalls. Without the block, it behaves as if on bare metal and every kernel operation becomes
a VM exit.

- `spinlocks: 8191` tells Windows how many spins before yielding the vCPU. Without it, Windows
  spins indefinitely while the lock holder is preempted. This is the direct mechanism behind
  "everything freezes but CPU looks fine", and it scales badly with high vCPU counts and no pinning.
- `vapic` is the virtual APIC. Without it, every interrupt EOI is a VM exit. Interactive load is
  interrupt load.
- `tlbflush` turns a TLB shootdown into a single hypercall instead of an IPI to every other vCPU.
  The cost scales with vCPU count.
- `ipi` applies the same logic to IPIs: one hypercall instead of one exit per target vCPU.
- `synic` and `synictimer.direct` provide the synthetic interrupt controller and timers, with
  direct delivery and no exit per tick.
- `vpindex` is not optional. `synic`, `ipi` and `tlbflush` depend on it.
- `relaxed` disarms the Windows watchdog for a preempted vCPU. Prevents bugcheck on a contended host.
- `runtime` exposes real vCPU run time, so the Windows scheduler accounts for steal.
- `frequencies` and `reenlightenment` cover TSC frequency exposure and TSC scaling across migration.
- `reset` is assisted reset. Cosmetic.

### clock.timer

Only makes sense together with the block above.

- `hpet.present: false` removes an emulated timer whose every read is a VM exit. Windows then uses
  the Hyper-V reference TSC page, read from memory with no exit.
- `hyperv: {}` enables the paravirtualized clocksource that replaces HPET.
- `pit.tickPolicy: delay` and `rtc.tickPolicy: catchup` define missed-tick handling. Windows
  default, avoids clock drift.

Before rebooting, check `bcdedit /enum` in the guest for `useplatformclock`. If it is `Yes`, run
`bcdedit /deletevalue useplatformclock` in the same maintenance window. Otherwise removing the HPET
pushes Windows onto a different clocksource than intended.

### ioThreadsPolicy: auto

This is the switch that creates iothreads at all. With no policy declared, KubeVirt creates none and
all block I/O runs on the QEMU main thread, the same one doing device emulation and video blit.

`dedicatedIOThread: true` on individual disks only refines distribution. The `auto` pool is limited
to twice the vCPU count, so with two or three virtio disks `auto` alone already gives one iothread
per disk and the per-disk flag is redundant. It matters in two cases: many disks relative to CPU
count, where the pool saturates and disks are assigned round-robin; and under the `shared` policy,
where a dedicated thread is the only way out of the single shared thread.

Applies to virtio disks only (virtio-blk, virtio-scsi). Requires a restart.

### Other

- `inputs.bus: usb` matches the official templates. `vioinput` on Windows is less mature than
  `viostor`, and the complaint usually involves mouse and menu responsiveness.
- `terminationGracePeriodSeconds: 3600` overrides the KubeVirt default of 30 seconds. Forklift never
  sets the field, so the webhook fills in the default. Thirty seconds is too short for a Windows
  shutdown with pending updates, and killing the guest mid-update can leave a corrupt registry hive.
  It is a ceiling, not a delay: a guest that stops in 40 seconds terminates in 40. On expiry
  virt-handler switches from ACPI to `virsh destroy --graceful`, which from the guest's point of
  view is still pulling the plug. The cost is that a node drain can stall for up to an hour per
  stuck VM; `virtctl stop <vm> --force --grace-period=0` is the escape hatch.

## Conditional: VBS and nested virtualization (not baseline)

`features.hyperv.evmcs` addresses a different symptom and belongs to a different decision. Do not
add it to the baseline patch.

VMCS is the Intel VT-x structure a hypervisor uses to control VM execution, read and written with
the `VMREAD` and `VMWRITE` instructions. This only matters when the guest is itself a hypervisor.
VBS, HVCI, Credential Guard, WSL2 and the Hyper-V role all place a thin hypervisor underneath
Windows, making it an L1. L1 cannot touch real hardware VMCS, so every access traps to L0 and gets
emulated. Hyper-V does hundreds of thousands of those per second. `evmcs` replaces the instruction
path with a shared memory page plus a dirty bitmap, so L1 writes fields with plain stores and exits
once per `VMLAUNCH`.

The symptom is high CPU in the guest and on the node, including at idle. That is the opposite of the
interactive-latency-with-normal-CPU pattern the baseline patch addresses. Do not conflate them.

Three gates, in order of cost:

1. Is `vmx` exposed at all? `virsh dumpxml 1 | grep -i vmx` inside the launcher. Nothing there means
   VBS cannot run in any Windows version, and the question is closed cluster-wide until the CPU
   model changes.
2. Is VBS actually running? `Get-CimInstance -ClassName Win32_DeviceGuard -Namespace
   root\Microsoft\Windows\DeviceGuard` and read `VirtualizationBasedSecurityStatus`. `1` is enabled
   but not running, `2` is running. Only `2` justifies going further. The Windows UI reports both
   as "Enabled", which is where most false positives come from.
3. Does the node offer the feature? `oc get node <node> -o json | jq -r '.metadata.labels | keys[] |
   select(startswith("hyperv.node.kubevirt.io/"))'`.

Field observation from this fleet: VMs with VBS reported active show no performance complaint, while
VMs without it do. VBS presence is not a differentiator here. Treat `evmcs` as a per-VM fix for a
measured symptom, never as a fleet default.

`evmcs` is Intel only. On an AMD node the corresponding label does not exist, and with
`HypervStrictCheck` enabled the VM goes Pending on node selector. In a mixed fleet, adding it to the
baseline buys a scheduling constraint in exchange for nothing.

Windows version changes where to look, not the rule. Server 2019 and 2022 ship VBS off, so it only
appears where a GPO turned it on. Server 2025 enables Credential Guard by default on domain-joined
non-DC systems, which turns VBS on with it, so the assumption inverts and you confirm the negative.

Separately, `hv-tlbflush-direct` and `hv-tlbflush-extended` are not the same as the `tlbflush: {}`
already in the baseline above. Whether they have an API knob depends on the CNV version. Check the
CRD rather than any document: `oc explain
virtualmachine.spec.template.spec.domain.features.hyperv --recursive`.

## Applying

Use `oc edit`, or a full `oc apply` of the complete object. Never use `oc patch --type merge` for
anything that touches `disks`, `inputs` or `interfaces`: a merge patch replaces the entire array.
On a Forklift VM that means losing `bootOrder` and the `serial` fields carried over from VMware.
Windows uses the disk serial for identification, so losing it can produce an offline disk or a
drive letter change on the next boot.

```bash
oc get vm <vm> -n <ns> -o yaml > /tmp/<vm>.bkp.yaml
oc apply --dry-run=server -f <vm>.yaml
```

Server-side dry run catches duplicated fields and schema errors without writing anything. Nothing
in this patch is hot-appliable, so it takes effect on the next boot.

## Verifying after power on

Node selector, which catches a `HypervStrictCheck` mismatch:

```bash
oc get pod -n <ns> -l vm.kubevirt.io/name=<vm> \
  -o jsonpath='{.items[0].spec.nodeSelector}' | jq
```

A pod stuck in Pending with a node selector event means one of the hyperv fields became a scheduling
requirement with no matching node label. Reverting is removing the field and starting again.

IOThreads, inside the launcher:

```bash
oc exec -n <ns> <launcher-pod> -c compute -- virsh dumpxml 1 | grep -E 'iothread'
```

Expect `<iothreads>N</iothreads>` and a distinct `iothread='N'` on each disk `<driver>`. The same N
on every disk means the pool saturated, which is when `dedicatedIOThread` earns its place.

## Scope and limits

This is baseline correction, not root cause analysis. If the entire migrated Windows fleet is
missing these settings and only part of it is complaining, the patch does not explain the difference
between the two groups. Apply it because it is the supported baseline, then measure separately.

Ratio of `cpu_system_usage` to `cpu_usage` is the metric that moves and confirms the change landed.

One hard rule: never power on a migrated VM while a rollback copy is running back in vCenter. Same
MAC, same IP in the same EPG, and two computer accounts fighting over the same AD object.

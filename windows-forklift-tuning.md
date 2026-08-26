# Windows VMs migrated with MTV/Forklift: post-migration tuning

## Why this is needed

Forklift does two separate things. `virt-v2v` converts the guest (virtio drivers installed,
`guestConverted: true`), and the controller creates the VirtualMachine object. The second step
applies no preference and no instancetype, so `vm.kubevirt.io/os`, `flavor` and `workload` come out
empty.

The guest is prepared, but the VirtualMachine object is missing the hypervisor-side settings that
Red Hat's official Windows templates define as baseline: `features.hyperv`, `clock.timer` and
`terminationGracePeriodSeconds`. VMware exposed the equivalent by default, so this surfaces as a
regression right after migration. Typical report: sluggish menus, slow application launch, CPU
metrics looking normal.

`ioThreadsPolicy` is included in this patch but is **not** part of the official template baseline.
It is a deliberate addition, justified by a thread dump showing block I/O on the QEMU main thread,
not by conformance. If it is ever challenged, defend it with the measurement, not with the template.

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

Not in the official templates. This is a deliberate addition, not a conformance item.

This is the switch that creates iothreads at all. With no policy declared, KubeVirt creates none and
all block I/O runs on the QEMU main thread, the same one doing device emulation and video blit.

`dedicatedIOThread: true` on individual disks only refines distribution. The `auto` pool is limited
to twice the vCPU count, so with two or three virtio disks `auto` alone already gives one iothread
per disk and the per-disk flag is redundant. It matters in two cases: many disks relative to CPU
count, where the pool saturates and disks are assigned round-robin; and under the `shared` policy,
where a dedicated thread is the only way out of the single shared thread.

Applies to virtio disks only (virtio-blk, virtio-scsi). A SATA or IDE disk ignores iothreads
entirely, so the field is inert on a VM that did not come through virt-v2v. The audit records
`disk_buses` for exactly this reason. Requires a restart.

### Other

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

The official templates agree: `evmcs` appears in none of the four Windows templates, across both
workload profiles and both OS versions. Nested virtualization is not the default case.

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

### Deliberately excluded: inputs[].bus

The official templates declare the tablet on the `usb` bus. This patch leaves `inputs` alone.

The tablet is an absolute-positioning device. Without it the guest falls back to the emulated PS/2
mouse, which is relative, and the pointer drifts from the cursor in the VNC console. It is a console
usability device, not a performance one. The `bus` field only picks the transport: `usb` uses
emulated HID, `virtio` needs the `vioinput` driver from virtio-win.

There is no performance argument for changing it, and if there were it would point the other way.
Emulated USB HID relies on periodic polling by the controller, which generates exits. virtio-input
is event-driven over a virtqueue. Moving virtio to usb is a step backwards on exit count.

The practical reason to leave it out is structural: `inputs` is the only field in the set that lives
inside an array. Including it forces a JSON Patch with a `test` operation, a separate rollback path,
and array handling throughout the tooling. Dropping it makes the whole change a single merge patch
with no way to damage `disks`, `inputs` or `interfaces`.

If the pointer tracks correctly in the console, `vioinput` is working and there is nothing to fix.
If it drifts, that is an independent problem with an independent diagnosis.

## Relationship to the official templates

Verified against four templates from common-templates v0.35.0 (CNV 4.21):
`windows2k19-server-medium`, `windows2k19-highperformance-medium`, `windows2k25-server-medium`,
`windows2k25-highperformance-medium`. Two matched pairs, so each axis can be isolated.

### What is invariant

The twelve `features.hyperv` keys are byte-identical across all four: `relaxed`, `vapic`, `vpindex`,
`synic`, `synictimer.direct`, `spinlocks: 8191`, `tlbflush`, `ipi`, `runtime`, `reset`,
`frequencies`, `reenlightenment`. Same across workload profiles, same across OS versions. The full
`clock` block and `terminationGracePeriodSeconds: 3600` are likewise identical in all four.

This patch matches that set exactly.

### What the workload profile changes

Comparing `2k19-server` to `2k19-highperformance`, holding the OS version fixed:
`dedicatedCpuPlacement: true`, `isolateEmulatorThread: true`, root disk bus `sata` to `virtio`, and
NIC model `e1000e` to `virtio`. Nothing else.

### What the OS version changes

Comparing `2k19-server` to `2k25-server`, holding the profile fixed: `devices.tpm.persistent: true`
and `firmware.bootloader.efi.persistent: true`. Nothing else. Both follow from Server 2025 requiring
TPM 2.0; `efi.persistent` keeps the NVRAM across the VMI lifecycle.

### Root disk bus is an install-time constraint, not a recommendation

The `server` templates use `sata` for the root disk because they are installation templates and a
freshly installed Windows has no `viostor`. Booting from a virtio disk without the driver produces
INACCESSIBLE_BOOT_DEVICE. The `highperformance` templates use `virtio` because they assume the
driver is already present.

Read the other way round it invites the wrong conclusion. `sata` in the server template is not Red
Hat recommending SATA for Windows; the template's own `windows-virtio-bus` validation says virtio
performs better and to switch once the drivers are installed.

Migrated VMs satisfy the requirement by construction: `virt-v2v` injects the virtio drivers during
conversion, which is why Forklift VMs arrive on virtio and never pass through sata. Confirm before
assuming it, because `ioThreadsPolicy` only applies to virtio disks (virtio-blk, virtio-scsi) and
has no effect on a SATA or IDE disk.

### Not in any template

`ioThreadsPolicy` is not present in any of the four. That field is ours.

Neither is `evmcs`, in any profile or OS version. It optimises VMCS access, and VMCS is only touched
when the guest is itself running a hypervisor: VBS, HVCI, Credential Guard, WSL2 or the Hyper-V
role. With none of those active the CPUID bit sits there and the guest never consults it. Nested
virtualization is not the default case, so the official baseline leaves out an Intel-only flag that
would do nothing for most VMs. See the conditional section above for when it does apply.

### In the templates but not in this patch

`features.acpi`, `features.apic` and `features.smm`. No action needed: a merge patch that sets
`features.hyperv` leaves sibling keys untouched, so nothing is removed. `smm` is worth a separate
check though, since it is a prerequisite for Secure Boot. Any migrated VM with
`firmware.bootloader.efi.secureBoot: true` needs it present.

### Why not the highperformance profile

`dedicatedCpuPlacement` and `isolateEmulatorThread` stay out. They require CPU Manager in static
policy on the nodes and Guaranteed QoS with requests equal to limits, `isolateEmulatorThread`
consumes an additional CPU for the emulator thread, and oversubscription disappears. On a fleet of
migrated VMs carrying topology inherited from VMware, that is a capacity decision rather than a
tuning one. It also constrains live migration: a VM with exclusive CPUs only moves to a node with
exclusive CPUs free.

## Applying

Every field above is an object or a scalar. None lives inside an array, so a single merge patch is
safe and there is no way to clobber `disks`, `inputs` or `interfaces`.

That safety is a property of this specific field set, not of merge patch in general. If you ever add
an array field, a merge patch replaces the entire array. On a Forklift VM that means losing
`bootOrder` and the `serial` values carried over from VMware, and Windows uses the disk serial for
identification.

```bash
oc get vm <vm> -n <ns> -o yaml > /tmp/<vm>.bkp.yaml
oc patch vm <vm> -n <ns> --type merge --dry-run=server -o json -p "$(cat patch.json)"
```

Server-side dry run returns the resulting object without writing, so the full delta can be checked
before committing. Nothing in this patch is hot-appliable.

## Landing the change

The patch is not hot-appliable, and a reboot from inside Windows does not apply it. libvirt handles
the guest reset internally, the domain XML is not re-rendered, and the virt-launcher pod is the same
one. Live migration does not apply it either: the domain is preserved on the destination, not
rebuilt.

Only a full guest shutdown terminates the VMI. Under `runStrategy: Always` the controller then
creates a new VMI from the current template and the patch lands. Under `RerunOnFailure` the VM stays
stopped and needs an explicit `virtctl start`.

Applying is cheap and safe; landing needs a window. The gap between the two is where the risk lives:
a VM patched but not yet restarted has a spec that diverges from its running domain, and an
unplanned reboot changes its virtual hardware outside any window. Track the size of that staged pool,
not the number of VMs patched.

One trap for mass restarts: the running VMI still carries the old 30-second grace period, because it
was rendered from the pre-patch template. A `virtctl restart` on a Windows VM with pending updates
can hit `virsh destroy` at 30 seconds, which is exactly the corruption the new value exists to
prevent. Shutdown initiated inside the guest does not go through the grace period at all.

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

New migrations are handled by a post-migration hook on the Forklift plan. This document and the
accompanying script exist for the backlog that predates the hook. The campaign has an end.

This is baseline correction, not root cause analysis. If the entire migrated Windows fleet is
missing these settings and only part of it is complaining, the patch does not explain the difference
between the two groups. Apply it because it is the supported baseline, then measure separately.

Ratio of `cpu_system_usage` to `cpu_usage` is the metric that moves and confirms the change landed.

One hard rule: never power on a migrated VM while a rollback copy is running back in vCenter. Same
MAC, same IP in the same EPG, and two computer accounts fighting over the same AD object.

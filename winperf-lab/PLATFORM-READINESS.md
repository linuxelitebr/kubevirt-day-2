# OpenShift Virtualization Platform-Readiness and Exoneration Dossier

**Subject VM:** migrated Windows Server / IIS / .NET application server (VMware -> OpenShift Virtualization via MTV/virt-v2v)
**Author:** platform consultant (Andre)
**Scope:** OpenShift Virtualization platform configuration + Windows guest-OS baseline only
**Status of citations:** every doc link below must be re-pinned to this cluster's actual running version before this record is treated as final. Capture `oc get clusterversion` and `oc get csv -n openshift-cnv | grep kubevirt-hyperconverged`, then align each citation's version path to that release. Where a claim is version-specific it is marked **[VERIFY on-cluster]**.

---

## 1. Purpose and framing

This document is a readiness record, not an argument. Its job is narrow and testable: to show, with dated and reproducible evidence, that everything I control (the OpenShift Virtualization platform configuration and the Windows guest-OS baseline) is configured to a documented best practice and is live-migration-safe. It does not diagnose the application, and it does not assign fault.

The engagement has already converged on a platform-independent finding in the application content-delivery path (IIS serving and cold-start compiling content from a UNC share, dynamic compression off, the NAS acting as a single concentrator). That path existed identically on VMware. This dossier does not restate that as an accusation. It simply closes out the platform and guest-OS surface so that any latency that remains after these checks pass is, by elimination and by measurement, located above the layers I own.

The method throughout is matched A/B capture on both hypervisors (VMware source and OpenShift target), primary-source citations for each best practice, and a machine-verifiable artifact for each claim. The burden of proof shifts by evidence a reviewer can rerun, not by assertion.

A note on tone for the record: several rebuttals below answer an app owner's likely challenge. They are written to close a technical question with data, not to push work onto a counterpart. Where a check lands in someone else's domain, it is named as their surface to examine, without a verdict attached.

---

## 2. Per-dimension checklists

Legend for every "migration-safe" cell: the setting introduces none of the constructs that block or narrow live migration (no host-passthrough CPU model, no `dedicatedCpuPlacement`, no host devices / GPU / PCI passthrough, no SR-IOV, no migration-blocking hugepages, no single-node affinity, no RWO/local storage) unless explicitly noted.

Replace `<vm>`, `<ns>`, `<node>`, `<nad>`, `<sc>`, `<nas>` with real values. Save every capture under a single dated directory, e.g. `evidence-YYYY-MM-DD/`.

### 2.1 CPU / compute

This dimension was a placeholder in the working notes. It is filled here, because "you never documented the CPU baseline" is the most obvious challenge.

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| vCPU topology parity vs source | `sockets`/`cores`/`threads` match the VMware source `.vmx`; sockets `1` where the guest fits one NUMA node | `oc get vmi <vm> -n <ns> -o jsonpath='{.spec.domain.cpu.sockets}/{.spec.domain.cpu.cores}/{.spec.domain.cpu.threads}{"\n"}'` vs the source `.vmx` (`numvcpus`, `cpuid.coresPerSocket`) | Both side-by-side, same day; note the parity | KubeVirt CPU (`kubevirt.io/user-guide/compute/virtual_hardware/`) |
| No CFS throttling on the compute container | `container_cpu_cfs_throttled_periods_total` flat at 0 across a slow window | Prometheus/console: `sum(rate(container_cpu_cfs_throttled_periods_total{pod=~"virt-launcher-<vm>.*",container="compute"}[5m]))` over the slow window | Dated PromQL result graph = 0; this is the real per-quota proof, stronger than "node 4-16%" | OpenShift monitoring docs |
| In-guest CPU steal / ready | Guest shows no sustained steal; node CPU 4-16% (established) | Node: `oc adm top node <node>`; VMware source for A/B: esxtop `%RDY`<5, `%CSTP`~0 | Matched wall-clock capture on both platforms at the same sampling interval | Broadcom KB on CPU summation-to-% conversion |
| Node vCPU:pCPU overcommit ratio | Documented, not hidden; ratio leaves headroom under burst | `oc describe node <node>` (Capacity vs Allocatable cpu) across 2+ candidate nodes | Ratio per node + a burst-window `oc adm top node` sample | OpenShift nodes docs |
| CPU model = host-model, never host-passthrough | `host-model` or unset (inherits cluster default); NOT `host-passthrough` | `oc get vmi <vm> -n <ns> -o jsonpath='{.spec.domain.cpu.model}{"\n"}'` and `oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.spec.defaultCPUModel}{"\n"}'` | Value != host-passthrough, plus node `cpu-model.node.kubevirt.io/*` and `cpu-feature.node.kubevirt.io/*` labels proving targets honor it | OpenShift live-migration requirements (host-model nodes must support the CPU) |
| **CPU feature-mask / CPUID delta** (missing base) | The flags the .NET/RyuJIT path needs (AVX2, BMI, etc.) are present in the guest despite host-model masking | In guest: `coreinfo.exe -f` (Sysinternals); cross-check the resolved `cpu-feature.node.kubevirt.io/*` labels | Dated `coreinfo -f` export showing required flags present on both VMware and OpenShift; the diff | Sysinternals Coreinfo; KubeVirt CPU model/features |
| **Windows actually uses all vCPUs / socket-licensing cap** (missing base) | Every vCPU present and usable; `sockets<=2` so a 2-socket Windows SKU limit does not silently ignore cores | In guest: `Get-CimInstance Win32_ComputerSystem \| Select NumberOfProcessors,NumberOfLogicalProcessors`; `msinfo32` | Dated capture showing logical-processor count == vCPU count and sockets within the SKU limit | Microsoft Windows Server processor/socket limits |

Migration safety for this dimension: shared (CFS) vCPUs, host-model CPU, no dedicated placement. All targets remain eligible; `LiveMigratable` stays True (proven in 2.7).

Corrected claim: I do not state "host-model == host-passthrough, nothing traded away" as bare assertion. It is backed by the CPUID capture above. On this workload the measured throughput was equal; the CPUID export shows the guest is not feature-starved.

### 2.2 Memory

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| Guest memory via `memory.guest` only | Equals source vRAM; no hand-set `resources.requests/limits.memory` | `oc get vm <vm> -n <ns> -o jsonpath='{.spec.template.spec.domain.memory.guest}{"\n"}'` and `...domain.resources` (empty or requests-only); in guest `Get-CimInstance Win32_ComputerSystem` TotalPhysicalMemory | Manifest value + empty resources + in-guest RAM matching source vRAM | RH memory management blog (2025-01-31) |
| No memory limit (Burstable QoS) | No `resources.limits.memory` on VM/compute container | `oc get vm ... -o jsonpath='{...resources.limits}'` (empty); launcher pod `...status.qosClass` (Burstable) | Dated no-limit capture + qosClass | KubeVirt node_overcommit |
| Cluster overcommit = 100, no swap/wasp | `higherWorkloadDensity.memoryOvercommitPercentage` 100 or default; no wasp-agent; `swapon --show` empty | `oc get hyperconverged ... -o jsonpath='{.spec.higherWorkloadDensity.memoryOvercommitPercentage}'` (confirm path with `oc explain`); `oc get ds -n openshift-cnv \| grep -i wasp`; `oc debug node/<node> -- chroot /host swapon --show` | HCO value, empty wasp DS, empty swap on the VM's node | OKD higher-density docs **[VERIFY path on-cluster]** |
| Hugepages absent | No `spec.domain.memory.hugepages` | `oc get vmi <vm> ... -o jsonpath='{.spec.domain.memory.hugepages}'` (empty) | Empty field on VM and VMI | KubeVirt virtual_hardware; RH live-migration dirty-page article |
| Balloon + Free Page Reporting | Balloon auto-attached; FPR on (`disableFreePageReporting` false/default); guest VirtIO Balloon driver OK | `...devices.autoattachMemBalloon`; `...virtualMachineOptions.disableFreePageReporting` (confirm with `oc explain`); guest `Get-PnpDevice -FriendlyName '*Balloon*'` | Balloon attached, FPR on, driver Status OK + version | RH memory blog; HCO cluster-config doc |
| Launcher overhead vs node headroom | Pod request = guest **plus KubeVirt overhead** (~+2-3 GiB); node not oversubscribed | `oc get pod virt-launcher-<vm>-xxxxx -c compute -o jsonpath='{...requests.memory}'`; `oc adm top node`; `oc describe node` Allocated | Request (guest+overhead) + headroom on current and 2+ target nodes | RH memory blog |
| KSM off | `ksmConfiguration` empty; `/sys/kernel/mm/ksm/run` = 0 | `oc get hyperconverged ... -o jsonpath='{.spec.ksmConfiguration}'`; `oc debug node/<node> -- chroot /host cat /sys/kernel/mm/ksm/run` | Empty HCO field + run=0 | KubeVirt KSM |
| **In-guest memory pressure baseline** | `Available MBytes` high, `Pages/sec`/`Pages Input/sec` ~0 (no hard paging) | Guest: `Get-Counter '\Memory\Available MBytes','\Memory\Pages Input/sec' -SampleInterval 5 -MaxSamples 12` | Dated perfmon export | RH memory blog |

Corrected claims in this dimension:
- The pod memory **request equals guest size plus KubeVirt overhead**, not guest size exactly. The guest *portion* equals guest size; the overhead item and the overcommit item are now consistent.
- The "KubeVirt cannot give memory back" statement is scoped to this configuration: **with overcommit=100 and no wasp-agent, no reclamation path is active for this VM**. It is not stated as an absolute KubeVirt property, because wasp-agent + higher-density does reclaim via swap when enabled.
- The RAM-vs-NVMe latency contrast is presented as general hardware order-of-magnitude (nanoseconds vs microseconds), not as a Red Hat measurement, unless the exact source is cited.

### 2.3 NUMA / topology

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| No guest NUMA passthrough | No `spec.domain.cpu.numa` block; single flat vNUMA | `oc get vmi <vm> ... -o jsonpath='{.spec.domain.cpu.numa}'` (empty); guest `coreinfo.exe -n` shows one node | Both empty + single-node coreinfo | KubeVirt NUMA |
| `dedicatedCpuPlacement` off | Empty/false; shared CPUs | `oc get vmi <vm> ... -o jsonpath='{.spec.domain.cpu.dedicatedCpuPlacement}'` | Empty capture | KubeVirt dedicated CPU |
| Node topology policy independence | VM requests no single-numa-node admission; `LiveMigratable` True regardless of node policy | `oc get vmi <vm> ... -o jsonpath='{...conditions[?(@.type=="LiveMigratable")].status}'`; `oc get kubeletconfig ...topologyManagerPolicy` | True + node policy listing + pod qosClass | OpenShift CPU Manager docs |
| VM fits one physical NUMA node | vCPU and RAM <= one host NUMA node; sockets 1 | VMI sizing vs `oc debug node/<node> -- chroot /host lscpu`/`numactl --hardware` | Arithmetic showing fit on the worker pool | OpenShift managing-VMs |
| NUMA disproof bundle | Node-local allocations, no bandwidth pressure, stall is SMB/IO | `numastat -m`; `/proc/vmstat numa_miss` deltas; guest SMB `Avg. sec/Data Request` | Bundle + one-paragraph mechanism note | KubeVirt NUMA |

**[VERIFY]** vNUMA "GA in 4.20" and "live migration may fail for a vNUMA VM when `topologyManagerPolicy=none`" are version-specific. Confirm against the actual 4.20 release notes before either is used as load-bearing; otherwise mark them unverified per the record's own rule.

### 2.4 Storage / disk

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| Disk bus virtio-blk | All disks `bus: virtio`; virtio-win drivers present | `oc get vm <vm> ... -o jsonpath='{range ...disks[*]}{.name}={.disk.bus}{"\n"}{end}'`; guest `Get-Disk`, VirtIO driver check | VM YAML + Device Manager screenshot + driver version | KubeVirt storage |
| Access mode RWX | Every VM PVC ReadWriteMany | `oc get pvc -n <ns> -o custom-columns=NAME:.metadata.name,ACCESS:.spec.accessModes,MODE:.spec.volumeMode,SC:.spec.storageClassName` | RWX table + `LiveMigratable` True | KubeVirt live_migration ("RWX ... to be live migrated") |
| Volume mode Block | `volumeMode: Block` (performance recommendation) | `oc get pvc ... MODE:.spec.volumeMode`; `oc get storageprofile <sc> ...claimPropertySets` | PVC export + storage profile | OpenShift storage docs |
| Shared CSI storage class | Networked/SDS RWX-block provisioner, not local/hostPath | `oc get sc <sc> -o jsonpath='{.provisioner}'`; storageprofile complete | SC YAML + storageprofile status | OpenShift live-migration; RH storage-considerations article |
| Cache mode none | `cache='none'` (O_DIRECT), coherence-safe default | `virsh dumpxml` on the compute container, grep `cache=` | Domain XML grep for every disk | KubeVirt storage |
| No I/O throttling | No `<iotune>`; no SC IOPS/bw cap | `virsh dumpxml ... \| grep -i iotune` (empty); SC param grep | Empty iotune + SC dump | Running-config authoritative (absence-based, marked) |
| blockMultiQueue default off | Unset/false, left off because this IO pattern does not need it | `oc get vm <vm> ... -o jsonpath='{...devices.blockMultiQueue}'` | VM excerpt | KubeVirt storage; OKD multi-queue |
| **In-guest disk latency** (missing base) | `Avg. sec/Read`/`Write` low, queue length low on OS/data volumes during slow window; backend commit/apply latency healthy | Guest: `Get-Counter '\PhysicalDisk(_Total)\Avg. sec/Read','...Avg. sec/Write','...Avg. Disk Queue Length'`; backend: ODF/Ceph OSD latency or CSI latency metrics | Dated guest perfmon + backend latency graph | Microsoft perf-tuning; storage vendor metrics |
| **Post-v2v 4K partition alignment** (missing base) | Partition offset aligned (no read amplification) | Guest: `Get-Partition \| Select DiskNumber,Offset` | Offset capture | Windows storage docs |

Corrected claims:
- **blockMultiQueue does NOT require `dedicatedCpuPlacement`.** The earlier rationale ("would force pinning / harm migration") was wrong and is removed. It scales queue count to vCPUs and is live-migration-safe with shared CPUs. It is left off because the workload is not disk-queue-depth bound, which is the honest and defensible reason.
- **cache=none is the migration-safe, coherence-correct default**, not "the fastest mode." Writeback can be faster for some write patterns; none is chosen for correctness across nodes and because it avoids stranding guest writes in a source-host page cache at cutover.
- **RWX is the migration requirement; `volumeMode: Block` is a performance recommendation.** Filesystem-mode RWX also live-migrates. The two are not conflated.
- virtio-blk is described as **far faster than the SATA/IDE emulated fallback**, not as "the fastest paravirtual bus" (virtio-scsi with multiqueue is comparable).

### 2.5 Network

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| Data-path binding = dedicated NAD (not masquerade/default for the app path) | `bridge` binding on the dedicated NAD (or OVN localnet), guest keeps original MAC/IP; masquerade avoided for the app data path | `oc get vm <vm> ... -o jsonpath='{...devices.interfaces}'`; `oc get net-attach-def -n <ns> -o yaml`; guest `ipconfig /all`, `Get-NetAdapter` | Interface + NAD YAML + guest IP/MAC capture | OpenShift networking (connect VM to Linux bridge) |
| Original IP / identity preserved | Bridge NAD has no IPAM (guest owns static IP) **OR** OVN localnet/layer2 with `allowPersistentIPs: true` + IPAMClaim | Bridge: `oc get net-attach-def <nad> -o yaml \| grep -i ipam` (none). OVN: `grep allowPersistentIPs` + `oc get ipamclaim -n <ns>`. Guest `nltest /dsgetsite` | NAD YAML + `nltest /dsgetsite` + DFS referral | OpenShift networking; RH VM live-migration article |
| vNIC model virtio + current drivers | `model: virtio`; Red Hat VirtIO Ethernet at negotiated LinkSpeed | `oc get vm <vm> ... -o jsonpath='{...interfaces[*].model}'`; guest `Get-NetAdapter \| fl ...DriverVersion,LinkSpeed` | Model + driver capture | OpenShift networking; virtio-win |
| virtio-net multiqueue matched | `networkInterfaceMultiqueue: true` AND guest RSS queues active; validated by measurement (helps inbound, may slightly degrade small-segment outbound) | `oc get vmi <vm> ... -o jsonpath='{...networkInterfaceMultiqueue}'`; guest `Get-NetAdapterRss` | Value + guest queue count + vCPU count | OKD multi-queue; KubeVirt interfaces |
| Guest MTU 1500 matched to path | Guest 1500; bridge/NAD >= 1500 is harmless headroom; DF probe proves clean 1500 | Guest `netsh interface ipv4 show subinterfaces`; `ping -f -l 1472 <nas>` OK, `ping -f -l 1473 <nas>` fails | `ip link` bridge + guest subinterface + DF probe transcript | OpenShift networking; Microsoft ping DF semantics |
| Migration traffic isolated | `liveMigrationConfig.network` = dedicated NAD; app NAD shielded | `oc get hyperconverged ... -o jsonpath='{.spec.liveMigrationConfig.network}'`; post-migration `migrationState.targetNodeAddress` in the migration subnet | HCO stanza + migration NAD + targetNodeAddress | OpenShift live-migration (secondary network) |
| **NIC advanced offloads** (missing base) | Checksum, LSO/TSO, RSC, interrupt moderation enabled (not disabled after P2V); zero drops | Guest `Get-NetAdapterAdvancedProperty` + `Get-NetAdapterStatistics` | Offload settings + zero drops/errors | Microsoft NIC perf-tuning |
| **NIC/disk device power management** (missing base) | "Allow the computer to turn off this device" off on the vNIC; MSI-X enabled | Guest device power settings; `Get-NetAdapterAdvancedProperty` for interrupt moderation | Setting capture | Microsoft NIC perf-tuning |

Ambiguity to pin: the notes oscillate between a **Linux-bridge (cnv-bridge) NAD with no IPAM** and an **OVN-Kubernetes localnet/layer2 NAD with `allowPersistentIPs`**. These are mutually exclusive mechanics with different verification commands and different identity-preservation stories. The record must state which binding is actually deployed on this cluster. `allowPersistentIPs`, `IPAMClaim`, and `oc get ipamclaim` apply only to the OVN localnet/layer2 case, not to a Linux-bridge NAD. Confirm with `oc get net-attach-def <nad> -n <ns> -o yaml` and fix this section to the one true binding before the dossier is final.

**[VERIFY]** The "more than 16 vCPU with multiqueue true loses connectivity" guardrail is marked unverified. The VM sits at exactly 16, so if this guardrail is used to justify the vCPU ceiling it needs a concrete, version-matched primary citation. Resolve to one sourced position rather than leaving it half-stated.

### 2.6 Guest SMB + Windows network stack

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| SMB dialect 3.1.1, no SMB1 | 3.1.1 negotiated; SMB1 absent | Guest `Get-SmbConnection \| ft ServerName,ShareName,Dialect,Signed,Encrypted`; **Server SKU:** `Get-WindowsFeature FS-SMB1` (not the client `Get-WindowsOptionalFeature`) | Dialect 3.1.1 + FS-SMB1 not-installed | Microsoft Get-SmbConnection; SMB file server tuning |
| SMB signing honored (server-dictated) | `Signed:True` because the NAS requires it; do not disable | `Get-SmbConnection` Signed; `Get-SmbClientConfiguration \| fl RequireSecuritySignature` | Signed:True + note server mandates it | Microsoft SMB signing |
| SMB Multichannel on | `EnableMultichannel True` (default) | `Get-SmbClientConfiguration`; `Get-SmbMultichannelConnection` | All three cmdlet exports | Microsoft SMB multichannel |
| RSS on virtio-net | Enabled; effective with multiple virtio queues | Guest `Get-NetAdapterRss` | Enabled + queue count matching vhost queues | Microsoft Get-NetAdapterRss |
| TCP autotuning Normal | `Receive Window Auto-Tuning Level: normal`; RSS + RSC enabled | Guest `netsh interface tcp show global` | Full TCP Global Parameters block | Microsoft NIC perf-tuning |
| SMB large MTU on, throttling off | `EnableLargeMtu True`, `EnableBandwidthThrottling False` | `Get-SmbClientConfiguration \| fl EnableLargeMtu,EnableBandwidthThrottling` | Both fields | Microsoft SMB file server; Set-SmbClientConfiguration |
| SMB metadata + bulk throughput not the bottleneck | Metadata `Avg. sec/Data Request` single-digit ms, zero credit stalls; **bulk read** comparable both platforms | Perfmon `\SMB Client Shares(*)\*`; `Measure-Command`; **bulk A/B:** timed multi-MB read / `robocopy`/`diskspd` against the UNC on both hypervisors | `.blg` + Measure-Command + bulk-throughput A/B table | Microsoft SMB tuning |
| SMB metadata cache lifetimes | Left at Microsoft defaults; changing them is a joint, evidence-gated decision (see boundary note) | `Get-SmbClientConfiguration \| fl DirectoryCacheLifetime,FileInfoCacheLifetime,FileNotFoundCacheLifetime` | Defaults capture + boundary note | Microsoft Get/Set-SmbClientConfiguration |
| **Third-party AV/EDR minifilter** (missing base) | Enumerate any filter driver on the redirector/UNC path; measure its impact | Guest `fltmc filters`, `fltmc instances` | Filter inventory + note any redirector-attached filter | Microsoft Filter Manager (fltmc) |
| **DNS / name resolution + DFS referral** (missing base) | Resolver order sane, live DC/DFS root, fast resolution | Guest `Measure-Command { Resolve-DnsName <nas> }` and `... <dfs-root>`; `Get-DnsClientServerAddress`; **DFS client:** `dfsutil /pktinfo` (not the server cmdlet `Get-DfsnServerConfiguration`) | Resolution timings + server order + referral cache | Microsoft DNS client / DFS |

Corrected claims:
- SMB1 check on this **Windows Server** app host uses `Get-WindowsFeature FS-SMB1`, not the client `Get-WindowsOptionalFeature -FeatureName SMB1Protocol`.
- DFS **client** referral is proven with `dfsutil /pktinfo` (or `Get-DfsnFolderTarget` from a namespace-aware host), not `Get-DfsnServerConfiguration`, which is a server cmdlet.

### 2.7 VM preference + Hyper-V enlightenments + machine type

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| Windows cluster preference assigned | `spec.preference.kind=VirtualMachineClusterPreference`, vendor-shipped (e.g. `windows.2k22`), auto-mapped by MTV osmap; not hand-authored | `oc get vm <vm> ... -o jsonpath='{.spec.preference.kind}/{.spec.preference.name}'`; preference `instancetype.kubevirt.io/vendor` label = kubevirt.io; `oc get configmap forklift-vsphere-osmap -n openshift-mtv -o yaml` | VM preference + preference YAML + osmap ConfigMap | KubeVirt common-instancetypes; RH tuning blog (2026-05-06); MTV docs |
| Hyper-V enlightenments rendered | The shipped set (relaxed, vapic, vpindex, spinlocks 8191, synic, synictimer{direct}, tlbflush, frequencies, reenlightenment, ipi, runtime, reset) + acpi/apic | `oc get vmi <vm> ... -o jsonpath='{.spec.domain.features.hyperv}'`; `virsh dumpxml \| sed -n '/<hyperv>/,/<\/hyperv>/p'` | VMI JSON + libvirt `<hyperv>` stanza + idle perfmon (low Interrupt/DPC) | common-instancetypes hyperv.yaml; RH optimizing-Windows-VMs |
| hv-evmcs and host-passthrough absent | No evmcs, no vendorid trick, CPU host-model | `oc get vmi <vm> ... -o jsonpath='{.spec.domain.features.hyperv.evmcs}'` (empty); `virsh dumpxml \| grep -iE 'evmcs\|vmx\|passthrough'` (none) | Grep proving absence | QEMU Hyper-V doc; common-instancetypes hyperv.yaml |
| Clock + timers paravirtual | `offset=utc`, hpet off, pit delay, rtc catchup, hypervclock present | `oc get vmi <vm> ... -o jsonpath='{.spec.domain.clock}'`; `virsh dumpxml \| sed -n '/<clock/,/<\/clock>/p'`; guest `w32tm /query /status` | Clock JSON + `<clock>` stanza + w32tm | RH optimizing-Windows-VMs; common-instancetypes |
| Machine type q35 (cluster alias) | `pc-q35-rhel9.<y>.0` via cluster default; not i440fx, not a hardcoded minor | `oc get vmi <vm> ... -o jsonpath='{.spec.domain.machine.type}'`; `oc get hyperconverged ... -o jsonpath='{.spec.configuration.machineType}'` | machine.type + cluster default + emulatedMachines list | KubeVirt virtual_hardware; OpenShift updating docs |
| Day-2 fallback when preference absent | First assign the shipped preference; the explicit-domain patch is the byte-equivalent fallback only. Patch with the **cluster default machineType (or omit to inherit)**, never a literal minor | `oc patch vm <vm> --type merge -p '{"spec":{"preference":{"kind":"VirtualMachineClusterPreference","name":"windows.2k22"}}}'` then restart; verify hyperv set + machine type | Before/after hyperv + assigned preference + source hyperv.yaml | common-instancetypes; KubeVirt instancetypes; RH tuning blog |

Corrected claim: the fallback patch must **not** hardcode `pc-q35-rhel9.6.0`. Hardcoding a specific RHEL minor can itself become a migration hazard if target nodes present a different minor. Use the cluster's abstracted alias / default machineType, or omit `type` to inherit.

### 2.8 Live-migration safety audit

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| CPU model host-model | Not host-passthrough; targets advertise the CPU | `oc get vmi ... cpu.model`; node cpu-model/feature labels | Value + node labels | OpenShift live-migration |
| No CPU pinning | `dedicatedCpuPlacement` unset/false | `oc get vmi ... dedicatedCpuPlacement,isolateEmulatorThread` | Empty capture | KubeVirt dedicated CPU |
| No host devices / GPU | `hostDevices` and `gpus` empty | `oc get vmi ... hostDevices,gpus` | Both empty | KubeVirt live_migration limitations |
| No SR-IOV | No `sriov` binding | `oc get vmi ...interfaces[*]` bindings; networks; NADs | No sriov + NAD manifest | KubeVirt live_migration |
| Pod-net binding not bridge | Default pod net = masquerade (if present); identity IP on the dedicated NAD | Interface bindings; NAD IPAM/persistent-IP state | masquerade + persistent-IP evidence | KubeVirt live_migration |
| Hugepages absent | No `memory.hugepages` | `oc get vmi ...memory.hugepages` | Empty | OpenShift live-migration |
| Storage RWX + virtio | Every backing PVC RWX; disks virtio | PVC loop + disk bus jsonpath | RWX list + virtio buses | OpenShift live-migration |
| Firmware persistence (EFI/vTPM) | If used, the efi/tpm persistent-state PVCs are also RWX; else none | `oc get vmi ...firmware.bootloader.efi.persistent`, `...tpm.persistent`; grep PVCs | RWX firmware PVCs or none. **Mark UNSOURCED if this VM's firmware config is not yet captured** | OpenShift live-migration; creating-and-managing-VMs |
| evictionStrategy LiveMigrate | Set at VM + cluster | `oc get vm ...evictionStrategy`; HCO `evictionStrategy` | Both = LiveMigrate | OpenShift nodes/live-migration |
| No single-node pinning | No hard nodeSelector/affinity narrowing to one host; >=2 eligible targets | `oc get vmi ...nodeSelector,affinity`; eligible-node count | Placement + `>=2` count | OpenShift live-migration |
| `LiveMigratable` = True | Condition True, empty reason | `oc get vmi ... conditions[?(@.type=="LiveMigratable")]` | True + full VMI YAML archived | KubeVirt live_migration |
| Cluster migration bandwidth/parallelism | Sane `bandwidthPerMigration` (**default is 0 = unlimited** in current HCO/upstream), `parallelMigrationsPerCluster` (5), `parallelOutboundMigrationsPerNode` (2) | `oc get hyperconverged ...liveMigrationConfig`; `oc get kubevirt ...configuration.migrations` | Effective values | OpenShift live-migration |
| Convergence/timeouts | `completionTimeoutPerGiB`, `progressTimeout` set; `allowAutoConverge` chosen deliberately; `allowPostCopy` false | `oc get hyperconverged ...` four fields | Values + one-line rationale | OpenShift live-migration |
| Migration traffic isolation + TLS | TLS by default; dedicated network if present | `oc get hyperconverged ...liveMigrationConfig.network` | Network field + TLS note | OpenShift live-migration |
| Proof of execution | A real `virtctl migrate` reaches Succeeded, guest online, no reboot | `virtctl migrate <vm>`; `oc get vmim -w`; client probe log; guest `LastBootUpTime` | vmim Succeeded + source->target + probe 200s + no reboot | OpenShift live-migration |

Corrected claim: `bandwidthPerMigration` default is **0 (unlimited)** in current OCP HCO and upstream KubeVirt. The older "vanilla KubeVirt caps at 64Mi" note is stale and removed.

**[VERIFY]** Firmware persistence: if this VM's exact EFI/vTPM config is not yet captured on the live VMI, mark the row UNSOURCED and verify before asserting.

### 2.9 Windows guest-OS baseline

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| VirtIO drivers current + signed | All Red Hat VirtIO devices on WHQL-signed drivers; no emulated/unknown | Guest `Get-CimInstance Win32_PnPSignedDriver \| ? {$_.Manufacturer -like '*Red Hat*'}`; `Get-PnpDevice -Status Error,Unknown` | Driver CSV + Device Manager screenshot + virtio-win containerdisk tag | RHEL configuring-Windows-VMs; virtio-win KB |
| QEMU guest agent connected | Service Running; VMI `AgentConnected=True` | Guest `Get-Service QEMU-GA`; `oc get vmi ...conditions[?(@.type=="AgentConnected")].status`; `virtctl guestosinfo` | AgentConnected True + guestosinfo + service line | OKD installing-qemu-guest-agent; KubeVirt guest agent |
| Power plan (no core parking) | High Performance, min/max processor state 100%; the specific benefit is preventing vCPU core-parking | Guest `powercfg /getactivescheme`; `powercfg /qh scheme_current sub_processor` | Active scheme + min/max=100 | Microsoft power-performance tuning |
| W32Time from domain | `Type: NT5DS`/DOMHIER, source = DC, sub-second offset | Guest `w32tm /query /source,/configuration,/status` | Source DC + NT5DS + offset | Microsoft Windows Time Service |
| Windows Update quiesced during measurement | wuauserv/UsoSvc/DoSvc idle, no active BITS (paused, not permanently disabled) | Guest service states; `Get-BitsTransfer -AllUsers`; WU operational log | Idle capture during the window | Microsoft update policies |
| Defender scoped, not disabled | No scan in progress; documented server/IIS/.NET exclusions; protection on | Guest `Get-MpComputerStatus`, `Get-MpPreference`; optional `New-MpPerformanceRecording` | Status + exclusions + optional top-paths | Microsoft Defender exclusions |
| No rogue background load | SysMain off/n-a; app worker is top consumer; near-zero processor queue | Guest `Get-Service SysMain`; `Get-Process \| sort CPU`; `Get-Counter '\Processor(_Total)\% Processor Time','\System\Processor Queue Length'` | Top-process snapshot + counter set | Microsoft Get-Counter / Set-Service |
| Page file sane | System-managed, non-zero; commit < limit; hard faults ~0 | Guest `Win32_ComputerSystem AutomaticManagedPagefile`; `Win32_PageFileUsage`; commit counters | Config + commit + Pages Input/sec | Microsoft page file docs |

Corrected claim: the power plan benefit is stated specifically as **preventing vCPU core-parking**, not as a general throughput lever. Inside a VM the host governs actual P-states; for an IO-bound app the plan's value is that the guest does not park cores, not raw speed.

### 2.10 Evidence discipline / packaging

| Setting | Optimal & migration-safe state | How to verify | Evidence to capture | Citation |
|---|---|---|---|---|
| Matched host CPU-scheduling snapshot both platforms | OpenShift node 4-16% + `container_cpu_cfs_throttled_periods_total`=0; VMware `%RDY`<5, `%CSTP`~0, same UTC window | `oc adm top nodes`; PromQL throttle series; esxtop `-b` CSV or vCenter chart | Both captures at same interval | RH oc adm top; Broadcom KB |
| Full VM/VMI spec as evidence | Topology parity + absence of every blocker in one artifact | `oc get vm/vmi -o yaml`; `grep -Ei 'dedicatedCpuPlacement\|hugepages\|hostDevices\|host-passthrough\|numa'` (empty) | Two YAMLs + grep-of-negatives + VMware `.vmx` | OpenShift live-migration |
| Vendor must-gather, hashed | cnv must-gather during a reproduction, SHA-256 | `oc adm must-gather --image=<cnv-must-gather:vX>`; `sha256sum` | Tarball + .sha256 + README with command + UTC | OpenShift virt support; incident must-gather article |
| Recorded live migration of this VM | vmim Succeeded, guest online, SMB session survives | `virtctl migrate`; `oc get vmim -w`; `oc get vmi -o wide` before/after | Transcript + timeline + node move + guest uptime | OpenShift live-migration |
| Guest baseline snapshot both platforms | qemu-ga, driver versions, power plan, RSS, time sync equivalent VMware vs OpenShift | `virtctl guestosinfo`; in-guest powercfg/RSS/driverquery/w32tm | One file per platform + diff | OpenShift VMs; Microsoft power tuning |
| SMB storage-path fingerprint both platforms | Dialect 3.1.1, Signed:True, metadata ~3ms; identical both sides | `bench-smb` (**custom tool, UNSOURCED**) + `Get-SmbConnection`/`Get-SmbClientConfiguration` | Side-by-side stats + raw dumps | Microsoft SMB cmdlets |
| Network-path characterization both platforms | MTU 1500 clean, RSS spread, retransmits ~0, RTT equivalent | `capture-net-path` (**custom, UNSOURCED**) + `ping -f`, `Test-NetConnection`, `Get-NetAdapterRss`, retransmit deltas | Report both + NAD YAML | Microsoft NIC tuning |
| IIS/ASP.NET/UNC perfmon fingerprint both platforms | Delay accrues in Compilations / Requests Queued / % Time in GC / SMB Avg sec/Read; flat in Processor Queue Length | `logman` Data Collector Set (fixed counter list), `.blg` both platforms | Two `.blg` + annotated screenshot | Microsoft IIS/ASP.NET perfmon |
| A/B protocol (open-loop, cold vs warm, percentiles) | Fixed arrival rate (wrk2/k6), cold split from warm, p50/p95/p99/max, N>=~5000, interleaved, UTC-stamped | Open-loop generator into HdrHistogram; per-cell table | Runner script + table + raw histograms | Coordinated-omission reference; wrk2 |
| Chain of custody + scope cover | Dated dir, MANIFEST + SHA256SUMS, RUNBOOK, one-page cover | `find ... > MANIFEST.txt && sha256sum`; RUNBOOK.md | Sealed dir + cover page | SRE blameless postmortem culture |

---

## 3. Skeptic challenges and rebuttals

Each answer is backed by a dated artifact from Section 2, not by argument.

1. **"You under-provisioned the VM."** The guest reports exactly the source vRAM (`Win32_ComputerSystem`), `Available MBytes` stays high and `Pages Input/sec` ~0. The OS has RAM to spare. How w3wp/.NET consumes it is the application's working set.

2. **"You gave it a weaker virtual CPU."** CPU model is host-model; the CPUID capture (`coreinfo -f`) shows the flags the JIT uses are present on both platforms; node CPU is 4-16% and `container_cpu_cfs_throttled_periods_total`=0. No feature was masked away and no scheduler quota is throttling.

3. **"You should have pinned CPUs / enabled NUMA."** Pinning is only worth its migration cost when layered with NUMA passthrough for a memory-bandwidth-bound guest. This guest fits one NUMA node (captured) and is IO-bound. `numastat`/`vmstat` show node-local allocations with near-zero `numa_miss`. Pinning would narrow migration targets for no measured gain.

4. **"Your storage array is slow / you turned caching off."** Disks are virtio-blk, RWX, Block, `cache=none` (the coherence-safe default, which disables host double-caching, not the guest's own cache). In-guest `PhysicalDisk Avg. sec/Read` and the backend OSD/CSI latency are captured healthy during a slow window. The content path is the NAS over SMB/UNC, not this block disk.

5. **"There is an MTU mismatch fragmenting our traffic."** The guest advertises 1500 and the DF probe proves a clean unfragmented 1500-byte path (1472 succeeds, 1473 fails). The larger NAD/bridge MTU is receive headroom the guest never emits. VMware, with no 8900 anywhere, shows the same retransmit ~0.

6. **"SMB signing / the SMB stack is slowing us."** `Get-SmbConnection` shows Signed:True on the VMware source too, because the NAS mandates signing. Measured metadata round-trip is ~3ms on both. A ~3ms round-trip cannot produce a multi-second page.

7. **"You never scaled the NIC / it is stuck on one CPU."** virtio-net multiqueue is set and guest RSS shows multiple active receive queues; offloads enabled, zero drops. Independently, node NIC CPU is 4-16%. More queues raise parallel throughput, not single-stream metadata latency.

8. **"A migration blip is what users feel."** The slowness is steady-state and appears on cold requests with no migration in flight. Correlate `oc get virtualmachineinstancemigration` timestamps against the app slow-log: the last migration predates the complaint. A recorded live migration completed with the guest online and no reboot.

9. **"You hand-tuned my VM / it is non-standard."** The preference is the vendor-shipped object (`instancetype.kubevirt.io/vendor: kubevirt.io`), applied automatically by MTV's osmap. Where a manual patch was needed it is byte-for-byte the shipped `hyperv.yaml`; the diff proves parity. `hv-evmcs` and host-passthrough are verified absent.

10. **"Something in the guest OS is scanning my files."** `fltmc filters` enumerates every minifilter, including any third-party AV/EDR on the redirector path, with measured impact. Defender uses documented server/IIS/.NET exclusions and no scan ran during the baseline. Presence and impact are documented; exclusion policy is the security team's surface.

11. **"DNS/DFS is confused after migration."** The IP is guest-owned (or persisted via IPAMClaim on OVN); `nltest /dsgetsite` returns the correct AD site identically pre/post. `Resolve-DnsName` timings and `dfsutil /pktinfo` show resolution is fast and the referral resolves to the local target.

12. **"You cut a corner to make it migratable."** `LiveMigratable=True` is the cluster's own computed condition on the live object, with an empty reason, machine-verified and reproducible with one read-only command, plus a recorded successful migration.

---

## 4. Scope boundary

This is my documented, dated position. It stands on the reproducible evidence above whether or not a counterpart counter-signs it. An unsigned boundary is still a boundary defined by data a reviewer can rerun.

### Platform owner domain (validated in this dossier)

- OpenShift Virtualization VM/VMI spec: CPU model and topology, memory, no pinning/NUMA/hugepages/host-devices, machine type, preference, Hyper-V enlightenments, clock.
- Storage class, access mode, volume mode, disk bus, cache mode, throttling.
- Cluster live-migration configuration and the demonstrated migration itself.
- Guest-OS baseline I set inside the image: VirtIO drivers, QEMU guest agent, power plan, page file, background-load hygiene, Defender scan-window and exclusions.
- The **SMB and network transport health**: dialect 3.1.1, signing honored, RSS/queues, TCP autotuning, MTU matched to path, measured metadata RTT and bulk throughput.
- The **guest NIC DNS client configuration** (resolver order) and the guest time configuration (NT5DS/DOMHIER).

### Application owner domain (handed off, named without blame)

- IIS site and application-pool configuration; ASP.NET output/kernel caching.
- IIS Application Initialization (warm-up) to remove cold-start compile.
- Dynamic and static compression settings.
- The architectural decision to **read and compile content over UNC from the NAS on the request hot path**, and the NAS acting as a single concentrator. The SMB transport is proven healthy by me; the choice to depend on it per-request is the application's design.
- The SMB metadata cache lifetimes are a client knob I own, left at Microsoft defaults. Changing them cannot fix a first-hit compile (they only affect metadata re-query), and the re-query volume is driven by the app's per-request UNC reads. Any change here is a joint, evidence-gated decision, not a silent tuning.

### Shared boundaries (named so blame does not bounce)

- **Third-party AV/EDR:** the minifilter runs in the guest (my baseline surface), so I document its presence and measured impact. Its exclusion policy is the security team's.
- **W32Time:** I own the guest time configuration; the DC time-hierarchy health is the AD team's. If Kerberos to the NAS fails on skew, ownership is stated up front.
- **DNS/DFS:** the guest resolver config is mine; DNS server responsiveness, DFS namespace health, and DC availability are the infrastructure/AD team's.
- **Power plan via GPO:** I set High Performance; if a Group Policy reverts it, the effective setting is controlled by whoever owns that GPO. Noted so a reverted plan is not read as a platform fault.

---

## 5. How to present this to a distrustful counterpart

Lead with your own side, not theirs. Open by stating that everything the platform and guest-OS baseline control has been validated to a documented best practice and proven live-migration-safe, and that you are handing over the full evidence directory (manifest, SHA-256 sums, and a runbook) so they can regenerate or challenge any single number themselves. Frame the remaining items as joint open questions on the application content-delivery path that existed identically on VMware, not as a verdict. Invite them to reproduce the A/B captures on both hypervisors and to produce the matching application-tier evidence for their surface. Keep every claim tied to a dated, hashed, rerunnable artifact rather than to your judgment. A reproducible record read back to you is the fastest way two parties converge on the same data, and it is the opposite of an accusation.

---

*Before this dossier is treated as final: pin every citation to this cluster's running version, resolve the Linux-bridge vs OVN-localnet binding question in Section 2.5, confirm the firmware-persistence row in Section 2.8, verify the vNUMA version claims and the multiqueue >16-vCPU guardrail, and confirm each HCO field path with `oc explain` on the live cluster. Items marked UNSOURCED (bench-smb, capture-net-path, the scope-boundary statement itself) are flagged as custom or as position rather than vendor-documented fact.*
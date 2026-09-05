# demo-farm: IIS content-on-NAS vs local disk, measured live

An IIS farm that reproduces the client pattern (many sites serving their content from one NAS over UNC/DFS) and measures what that pattern costs, on screen. Each site runs a compiled ASP.NET app, not static serving. The dashboard separates `io_ms` (reading content from the root) from `compute_ms` (constant local work), and shows the on-the-wire size (the compression effect).

What it shows: the response time is almost entirely content delivery (I/O against the share), not application work. That is platform-independent, so it runs the same on VMware and OpenShift. If "it is .NET, everything stays in memory and never touches disk" were the whole story, NAS and local would read the same. They do not.

## Prerequisites

- A Windows VM (Server 2016+, tested on Server 2022), PowerShell as Administrator.
- For the real NAS: the VM joined to the domain, plus a share you can write to (to provision) and read (to serve). A workgroup VM can only run the loopback mode below. See Authentication.
- Outbound internet on the VM to pull the package, or copy the ZIP in another way.

## 1. Get the package

```powershell
Set-Location C:\
Invoke-WebRequest -UseBasicParsing https://github.com/linuxelitebr/kubevirt-day-2/archive/refs/heads/main.zip -OutFile kd2.zip
Expand-Archive kd2.zip -DestinationPath C:\ -Force
Set-Location C:\kubevirt-day-2-main\winperf-lab\demo-farm\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Get-ChildItem C:\kubevirt-day-2-main -Recurse -File | Unblock-File
```

## 2. Bring up the farm

Domain-joined VM against the real NAS. Pass the account that reads the NAS. It is applied as the site's Connect As credential, not the app pool identity, so the pool starts as ApplicationPoolIdentity and IIS reads the UNC as that account.

```powershell
$c = Get-Credential DOMAIN\<account>
.\bootstrap-demo.ps1 -ContentUnc \\<nas>\<share>\demo-farm -Sites 8 -PoolCredential $c
```

`bootstrap-demo.ps1` installs the IIS features, provisions 8 sites mirrored on the NAS and on local disk, registers application/json for dynamic compression, brings up the dashboard site, and prints the next steps.

Workgroup VM with no domain. Serve from a local loopback share. The pool uses the default identity and reads via Everyone, so no domain credential is involved.

```powershell
New-Item -ItemType Directory C:\demo-src -Force | Out-Null
New-SmbShare -Name demo -Path C:\demo-src -FullAccess Everyone -ErrorAction SilentlyContinue
.\setup-demo-farm.ps1 -ContentUnc "\\$env:COMPUTERNAME\demo" -Sites 8
```

Loopback shows SMB vs local disk: the same mechanism (SMB protocol overhead vs a direct read), reproducible, without a domain. It is not the production NAS, but it proves the architecture, and the 2x2 works the same. For the real NAS latency without a domain, use `bench-smb.ps1`: it runs as you, so your session authenticates to the NAS. See `winperf-lab\EXP5-*`.

## 3. Open the dashboard

Open `http://localhost:9000/dashboard.html?base=9000&sites=8` by its URL, from the dashboard site, not as a local file.

Each site shows `total_ms` (with a green/amber/red severity dot), the io+compute bar, `io_ms`, `compute_ms`, on-the-wire KB, and HTTP status. The header badge reports the runtime (`.NET CLR ... w3wp x64`), which makes explicit that a compiled ASP.NET app is serving, not static files. Severity thresholds are tunable with `...&warn=150&slow=400` (ms).

## 4. Capture the 2x2

The dashboard auto-detects the live scenario (backing reported by the app, compression inferred from the wire size) and selects the matching slot, shown by the "detectado" badge. Switch backing and compression in PowerShell, wait for the numbers to settle and the badge to match, then click Capturar. The four combinations are NAS/local by on/off.

```powershell
.\toggle-root.ps1 -Backing nas   -ContentUnc \\<nas>\<share>\demo-farm -ContentLocal C:\demo-farm
.\toggle-root.ps1 -Backing local -ContentUnc \\<nas>\<share>\demo-farm -ContentLocal C:\demo-farm
.\toggle-compression.ps1 -State on
.\toggle-compression.ps1 -State off
```

The first request after each change is a cold recompile, so give it about 15 seconds before you Capturar. Switching the root to local drops `io_ms` from tens of milliseconds to about one, so `total` collapses and the red bar shrinks to a sliver. That is the contrast that closes the case.

Read the comparison by metric. `total_ms` and `io_ms` put NAS far above local (the SMB cost). On-the-wire KB puts compression far below no-compression (the bandwidth effect, roughly 200 KB to 2 KB). Compression and backing are different axes: on loopback, compression barely moves `total_ms` because the transfer is local, but it cuts the wire size, which is what a remote user pays. Do not conflate the two.

## 5. Run it on both hypervisors

Repeat steps 1 to 4 on a Windows VM on OpenShift and on one on VMware, pointing `-ContentUnc` at the same NAS. Capture the 2x2 on each and put the two dashboards side by side. For numbers, name the poller output per platform:

```powershell
.\consumer-poll.ps1 -Sites 8 -BasePort 9000 -Out C:\winperf\demo-poll-openshift.csv
.\consumer-poll.ps1 -Sites 8 -BasePort 9000 -Out C:\winperf\demo-poll-vmware.csv
```

Expected: `io_ms` (the NAS cost) is close on both hypervisors, so the platform adds no delivery cost, and the local arm is fast on both. Same graph, no hypervisor to blame.

## Authentication: why the real NAS needs a domain

A workgroup VM cannot serve the domain NAS through IIS. Your interactive session reaches it because you present a domain credential over the network (the X: mapping, or `bench-smb` running as you). IIS runs as the app pool identity, and on a workgroup VM that identity has no domain credential to present. A domain account set as the pool identity fails to start the pool (503, it needs "Log on as a batch job"); set as Connect As it fails the credential logon (500.19, 0x8007052e, "can not log on locally"). Only network auth works from a workgroup, and IIS does not use it for the app's file reads.

For the real NAS, join the VM to the domain, the way the client's real IIS VMs are, and serve with ApplicationPoolIdentity plus the machine account (`DOMAIN\<host>$`) granted read on the share at both the share and NTFS level. In a workgroup, use loopback mode and take the real NAS latency from `bench-smb`.

## IIS settings this rig applies, and why

Dynamic compression for application/json. IIS compresses `text/*` and javascript by default, not `application/json`, so turning compression on alone leaves the JSON wire size unchanged. `setup-demo-farm.ps1` registers the type:

```powershell
Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/httpCompression/dynamicTypes' -Name '.' -Value @{mimeType='application/json'; enabled='true'}
```

The client app serves `text/html`, which is compressed by default, so there the fix is enabling the feature, which was off.

Connect As, not pool identity. `-PoolCredential` is set as the site's UNC credential, so the pool starts under the default identity and only the content read uses the account.

Anonymous authentication. If site hardening left Windows auth on and anonymous off, the dashboard's cross-port fetch gets 401. Enable anonymous on the demo sites:

```powershell
1..8 | ForEach-Object { Set-WebConfigurationProperty -PSPath "IIS:\Sites\demo$_" -Filter 'system.webServer/security/authentication/anonymousAuthentication' -Name enabled -Value $true }
```

## Memory-heavy mode (reproducing the 16 vCPU / 96 GB app)

Set `MemLoadMB` in `app\web.config` above 0 (for example 2000 for 2 GB per site) before setup, or on the deployed sites and recycle. `Global.asax` allocates and holds that memory at pool start in 1-4 MB chunks (working set plus LOH fragmentation), so the first request pays the load. `Default.aspx` reports `heap_mb` and `ws_mb`. Size it to your lab.

## Reading the results

| Observation | Reading |
|---|---|
| `io_ms` high, bar mostly red | the response is almost all content read from the share, not app work |
| switching to local drops `io_ms` | the cost is content delivery, which refutes "in memory, never touches disk" |
| `io_ms` close on OpenShift and VMware | the platform is not the bottleneck, the architecture is |
| wire KB drops with compression | dynamic compression being off is a factor (roughly 200 KB to 2 KB) |

## Gotchas

- Run PowerShell as Administrator; the bootstrap installs IIS features.
- Use UNC, not a mapped drive. A mapped drive is per-logon-session and the app pool does not see it.
- Write `-Out` to local disk, never to the share under test.
- Open the dashboard by its URL, not as a local file, or the cross-port fetches are blocked.
- Error triage: 503 is the app pool down (identity or logon right); 500.19 is the config or credential logon; 500 is the app throwing, and the dashboard shows it in the `err` field.

## De-identification

The dashboard and screenshots show the real NAS and domain names. That is fine to present to the client, since it is their environment. For a post or a public repo, mask them.

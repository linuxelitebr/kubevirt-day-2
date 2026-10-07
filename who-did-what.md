# Finding out who did what to a virtual machine

## Why this is harder than it should be

Three people will ask you the same question this month. Who stopped that VM. Who deleted that snapshot. When.

Nothing in the object answers it. A VirtualMachine carries `managedFields`, which tells you when `runStrategy` last changed and roughly what kind of client did it, and that is genuinely useful, but there is no username in there and it only keeps the last write per field. Events tell you what happened, with `SuccessfulCreate` for a start and `SuccessfulDelete` for a stop, and their source is `virtualmachine-controller`, because the controller is what acted. The person who asked for it is one hop upstream and does not appear.

The username lives in the kube-apiserver audit log and nowhere else. These are the queries, tested on a cluster rather than written from memory.

Reading any of this needs `nodes/log` or `nodes/proxy`, which in practice means cluster admin. Also read [audit-log-retention.md](audit-log-retention.md) first, because by default the log only goes back about a day and you will want to know that before promising anyone an answer.

## The detail that will waste your afternoon

`oc adm node-logs` prefixes every line with the name of the node it came from. The audit log is JSON per line, so your parser gets `alfa.example.com {"kind":"Event",...}` and fails on every single line. It fails quietly, you get zero results, and you conclude the cluster is not logging anything.

Strip the prefix before parsing:

```bash
oc adm node-logs --role=master --path=kube-apiserver/audit.log | sed 's/^[^ ]* //' | jq -r .verb | head
```

Worth knowing why the prefix is there: `--role=master` reads from every control plane node, and the prefix is what tells you which one. On a three-node control plane you may want to keep it rather than throw it away. Split it off into a variable instead of discarding it when you care.

## Who touched virtual machines and snapshots

The one you will use most. It drops reads, drops the controllers, and keeps only completed writes by actual people:

```bash
oc adm node-logs --role=master --path=kube-apiserver/audit.log | sed 's/^[^ ]* //' | jq -r 'select(.objectRef.resource == "virtualmachines" or .objectRef.resource == "virtualmachinesnapshots") | select(.verb | test("create|patch|update|delete")) | select(.stage == "ResponseComplete") | select(.user.username | startswith("system:") | not) | "\(.requestReceivedTimestamp[0:19])  \(.user.username)  \(.verb)  \(.objectRef.namespace)/\(.objectRef.name)"'
```

What it gives you:

```
2026-10-07T19:44:41  admin  create  demo/demo-vm
2026-10-07T19:44:41  admin  patch   demo/demo-vm
2026-10-07T19:44:44  admin  patch   demo/demo-vm
2026-10-07T19:44:44  admin  create  demo/demo-snap
2026-10-07T19:44:47  admin  delete  demo/demo-snap
```

The `startswith("system:") | not` filter is what makes this readable. Without it you get thousands of lines of controllers reconciling, and the two lines you care about are buried in them.

`stage == "ResponseComplete"` matters too. Every request produces a `ResponseStarted` entry as well, so leaving it out gives you each action twice.

## Which client it came from

The audit log records the user agent, which answers whether something came from the web console, from `virtctl`, or from a script someone ran:

```bash
oc adm node-logs --role=master --path=kube-apiserver/audit.log | sed 's/^[^ ]* //' | jq -r 'select(.objectRef.resource == "virtualmachines") | select(.verb == "patch") | select(.stage == "ResponseComplete") | select(.user.username | startswith("system:") | not) | "\(.requestReceivedTimestamp[0:19])  \(.user.username)  \(.objectRef.name)  via \(.userAgent | split(" ")[0])"'
```

```
2026-10-07T19:44:41  admin  demo-vm  via oc/4.21.0
2026-10-07T19:44:44  admin  demo-vm  via oc/4.21.0
```

A browser shows up as a Mozilla user agent, the CLI as `oc` or `virtctl` with its version.

## Everything one person did

When the question is about a person rather than a machine, swap the filter:

```bash
oc adm node-logs --role=master --path=kube-apiserver/audit.log | sed 's/^[^ ]* //' | jq -r --arg who "alice" 'select(.user.username == $who) | select(.verb | test("create|patch|update|delete")) | select(.stage == "ResponseComplete") | "\(.requestReceivedTimestamp[0:19])  \(.verb)  \(.objectRef.resource)  \(.objectRef.namespace)/\(.objectRef.name)"'
```

## The history of one machine

```bash
oc adm node-logs --role=master --path=kube-apiserver/audit.log | sed 's/^[^ ]* //' | jq -r --arg vm "demo-vm" 'select(.objectRef.name == $vm) | select(.verb | test("create|patch|update|delete")) | select(.stage == "ResponseComplete") | select(.user.username | startswith("system:") | not) | "\(.requestReceivedTimestamp[0:19])  \(.user.username)  \(.verb)"'
```

## Telling a start from a stop

Here is the limit nobody mentions. On a default cluster the audit profile logs at `Metadata` level, which records who, when, which resource and which verb, and does not record the request body. A start and a stop are both a `patch` on the same object, so in the audit log they are indistinguishable.

Confirm it on your own cluster, the entries will say `"level": "Metadata"` and carry no `requestObject`:

```bash
oc adm node-logs --role=master --path=kube-apiserver/audit.log | sed 's/^[^ ]* //' | jq -r 'select(.objectRef.resource == "virtualmachines") | select(.verb == "patch") | "\(.level)  requestObject: \(has("requestObject"))"' | sort -u
```

You have two ways out, and the cheap one is better.

The cheap one is to let the Events supply the direction while the audit log supplies the person, and join them on the timestamp. Events know exactly which way it went:

```bash
oc get events -n NAMESPACE --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message | grep -E 'Successful(Create|Delete)'
```

`SuccessfulCreate` with a message about creating the virtual machine instance is a start. `SuccessfulDelete` is a stop. Line those timestamps up with the `patch` entries from the audit log and you have who, when and which direction. The catch is that events expire in about three hours by default, so this works for the question asked today and not for the one asked next week.

The expensive one is to raise the audit profile to `WriteRequestBodies` on the APIServer resource, which puts the body in the log and makes the direction explicit. It also multiplies the volume of everything written, and since retention is a fixed number of fixed-size files, you are paying for the detail with history. Read the retention notes before reaching for it.

## Searching further back

The current file only covers the recent past. The rotated ones sit beside it:

```bash
oc adm node-logs --role=master --path=kube-apiserver/ | awk '{print $2}' | grep '^audit'
```

To sweep all of them, loop. This is slow and there is no index, so narrow by resource first and expect to wait:

```bash
for f in $(oc adm node-logs --role=master --path=kube-apiserver/ | awk '{print $2}' | grep '^audit'); do oc adm node-logs --role=master --path=kube-apiserver/$f | sed 's/^[^ ]* //' | jq -r 'select(.objectRef.resource == "virtualmachines") | select(.verb | test("create|patch|delete")) | select(.user.username | startswith("system:") | not) | "\(.requestReceivedTimestamp[0:19])  \(.user.username)  \(.verb)  \(.objectRef.namespace)/\(.objectRef.name)"'; done
```

## Scope and limits

This is a flat file, not a query engine. Every one of these commands reads the whole log from the node over the API, so they are fine for answering a question and wrong as something you run on a schedule. If people ask you this every week, forward the audit log to a log store and query it there.

What you can get: who, when, which object, which verb, which client. What you cannot get at the default profile: what the value was changed to. What you cannot get at all: anything older than the files still on disk, which is usually about a day.

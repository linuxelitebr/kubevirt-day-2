# Manifests

The YAML behind [audit-pipeline-setup.md](../audit-pipeline-setup.md), as files rather than snippets, because a snippet cannot be applied and a file can.

Apply order, with the operators installed first:

| | |
| --- | --- |
| `lokistack.yaml` | needs the object storage Secret to exist already |
| `forwarder-and-rbac.yaml` | collector identity, RBAC and the forwarder |
| `cluster-monitoring-config.yaml` | only if you want the Loki dashboards |

The two `hosted-cluster-*` files are for a HyperShift guest and are not needed otherwise. Read the hosted cluster sections of the guide before applying them: the writer's token does not expire by design, and it crosses a cluster boundary.

Use `apply`, not `create`. These are written to be idempotent, and `create` stops at the first object that already exists and leaves the rest of the file unapplied, which fails quietly in the middle.

Every placeholder is in angle brackets. Search for `<` before applying anything.

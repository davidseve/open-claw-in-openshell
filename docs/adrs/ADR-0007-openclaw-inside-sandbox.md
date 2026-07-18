# ADR-0007: OpenClaw Inside Sandbox (Pattern A) Over Separate Deployment (Pattern B)

## Status
Accepted

## Context
OpenClaw can integrate with OpenShell in two architectural patterns:

**Pattern A — OpenClaw inside sandbox**: OpenClaw runs inside an OpenShell sandbox using the community image (`--from openclaw`). All outbound traffic routes through the sandbox's L7 proxy. Credentials are injected by the OpenShell provider system.

**Pattern B — OpenClaw as separate deployment**: OpenClaw runs as a standalone deployment on the cluster and uses the `@openclaw/openshell-sandbox` plugin to delegate tool execution to OpenShell sandboxes. OpenClaw itself runs outside the sandbox perimeter.

### Security comparison

| Concern | Pattern A (inside) | Pattern B (separate) |
|---|---|---|
| Network control | All traffic through nftables + L7 proxy | OpenClaw has unrestricted network access |
| Credential isolation | Provider injection, never on filesystem | MaaS API key in K8s Secret, mounted on disk |
| External attack surface | Only OpenShell gateway exposed | Both gateway AND OpenClaw (port 18789) exposed |
| Container image | Auditable community sandbox image | Custom image with openshell CLI baked in |

## Decision
Choose Pattern A: run OpenClaw inside an OpenShell sandbox.

The security benefits are decisive for this deployment:

- **Security perimeter**: OpenClaw runs inside nftables + Landlock + network namespace + L7 proxy. All outbound traffic is policy-controlled with no bypass path.
- **Credential isolation**: Provider injection ensures credentials never appear on the filesystem. Pattern B requires a K8s Secret mounted into the OpenClaw pod.
- **Attack surface**: Only the OpenShell gateway is exposed externally. Pattern B exposes two separate services.
- **Supply chain**: Uses the auditable community sandbox image with no custom build pipeline.

Pattern B's advantages — multi-sandbox orchestration, workspace syncing (mirror/remote modes), per-agent sandbox scoping — are not needed for our single-agent learning use case.

## Consequences
- Simpler deployment: one namespace, one externally-exposed service, one Helm release.
- Stronger security posture: all OpenClaw traffic is subject to sandbox policy enforcement.
- Less flexibility for advanced multi-agent workflows. If future phases require multiple sandboxes with independent policies or workspace syncing between them, Pattern B should be reconsidered.
- Pattern B remains a viable migration path and does not require re-architecting the OpenShell deployment — only the OpenClaw deployment model changes.

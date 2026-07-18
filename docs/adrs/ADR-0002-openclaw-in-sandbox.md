# ADR-0002: Run OpenClaw Inside an OpenShell Sandbox

## Status
Accepted

## Context
OpenClaw needs to run on the cluster. Two options were considered:

- **(a) Dedicated Helm chart**: Deploy OpenClaw as a separate Helm chart with its own StatefulSet, Service, Route, and PVC. This gives full control over pod lifecycle, scaling, and networking but adds operational complexity and a second attack surface.
- **(b) OpenShell sandbox**: Run OpenClaw inside an OpenShell sandbox using the community image via `openshell sandbox create --from openclaw`. This leverages the existing sandbox infrastructure for security and credential management.

## Decision
Run OpenClaw inside an OpenShell sandbox using `openshell sandbox create --from openclaw`. No custom Helm chart for OpenClaw is maintained.

## Consequences
- Simpler architecture: single namespace, single externally-exposed gateway, no additional Helm chart to maintain.
- OpenClaw benefits from sandbox security controls: nftables firewall, Landlock LSM filesystem isolation, L7 proxy with policy enforcement.
- Credential injection via OpenShell providers — the MaaS API key is never written to the sandbox filesystem (see ADR-0003).
- Tradeoff: less control over OpenClaw pod lifecycle compared to a dedicated StatefulSet. Restart and scaling behavior is managed by the OpenShell sandbox supervisor, not directly by Kubernetes controllers.
- Tradeoff: OpenClaw version is tied to the community sandbox image version rather than an independently pinned image tag.

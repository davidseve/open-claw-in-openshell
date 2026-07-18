# ADR-0004: Red Hat Build of Agent Sandbox via OLM

## Status
Accepted

## Context
OpenShell requires Agent Sandbox CRDs (`Sandbox`, `SandboxTemplate`, `SandboxClaim`, `SandboxWarmPool`) to be installed on the cluster. Two sources were evaluated:

- **(a) Upstream kubernetes-sigs/agent-sandbox**: Apply CRD manifests directly from the upstream repository. Risk of using `latest` or unpinned manifests, no integrated lifecycle management.
- **(b) Red Hat build via OLM**: Install the OpenShift Sandboxed Containers operator (v1.12) through the Operator Lifecycle Manager. Provides supported, tested, and versioned CRD delivery with approval gates.

## Decision
Use the Red Hat build via OLM, pinned to CSV `sandboxed-containers-operator.v1.12.0`, channel `stable`, with `installPlanApproval: Manual`.

## Consequences
- Supported lifecycle via OLM: the operator manages CRD installation, upgrades, and dependency resolution.
- No `latest` tag risk: the CSV version is pinned, satisfying the project's supply chain security requirements.
- Manual approval on InstallPlans prevents unreviewed operator upgrades from being applied automatically.
- Tradeoff: depends on Red Hat OperatorHub availability. If the operator is not published to the cluster's catalog source, installation fails.
- Fallback path: install upstream CRDs from a pinned release tag (`kubernetes-sigs/agent-sandbox@v0.x.y`) if OLM is unavailable.

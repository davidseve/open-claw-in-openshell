# ADR-0001: Helm-Based Deployment Without GPU Resources

## Status
Accepted

## Context
We need to deploy OpenShell and OpenClaw on an existing OCP cluster on AWS. No GPU workloads are required since inference is handled by an external MaaS endpoint (see ADR-0005). The deployment must be reproducible, auditable, and follow standard Kubernetes packaging conventions.

## Decision
Use Helm charts for declarative deployment. OpenShell uses the official OCI chart (v0.0.83) with a values overlay (`charts/openshell/values-ocp.yaml`). No GPU resources are requested in any pod spec — all node scheduling uses standard CPU/memory resource requests only.

## Consequences
- Simpler node requirements: no GPU-capable instance types needed, reducing AWS costs and scheduling complexity.
- Reproducible deployments: Helm chart version is pinned, values overlay is version-controlled.
- Standard Helm upgrade path: `helm upgrade` with diff review via `helm-diff` before applying changes.
- No dependency on NVIDIA device plugin, GPU operator, or GPU-specific node labels.
- Tradeoff: if GPU-accelerated inference is needed in the future, the Helm values and node pool configuration must be updated.

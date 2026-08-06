# ADR-0004: Red Hat Build of Agent Sandbox via OLM

## Status
Accepted (updated 2026-08-06 — corrected package identity and install path against OpenShift sandboxed containers 1.13 docs)

## Context
OpenShell requires Agent Sandbox CRDs (`Sandbox`, `SandboxTemplate`, `SandboxClaim`, `SandboxWarmPool`) to be installed on the cluster. Two sources were evaluated:

- **(a) Upstream kubernetes-sigs/agent-sandbox**: Apply CRD manifests directly from the upstream repository (`manifests/agent-sandbox-v0.5.1.yaml`). Works without OperatorHub, but has no supported lifecycle management and risks competing with a productised controller if both are installed.
- **(b) Red Hat build via OLM**: Install the dedicated **Red Hat build of Agent Sandbox Operator** (package `agent-sandbox-operator`) through the Operator Lifecycle Manager. Provides supported, tested, and versioned CRD + controller + sandbox router delivery with approval gates.

An earlier revision of this ADR incorrectly named `sandboxed-containers-operator` CSV `v1.12.0` (the base OpenShift Sandboxed Containers / Kata operator) as the Agent Sandbox CRD source. That package does **not** install `sandboxes.agents.x-k8s.io`; in practice the CRDs came only from the raw upstream manifest. The Aug 2026 Red Hat blog and OSC 1.13 docs clarify that Agent Sandbox is a separate Technology Preview operator under the OpenShift sandboxed containers umbrella.

## Decision
On OCP / RHPDS (non-CRC):

- Use the Red Hat build of Agent Sandbox Operator via OLM.
- Package: `agent-sandbox-operator`
- Namespace: `agent-sandbox-system`
- Channel: `preview-0.9` / startingCSV `agent-sandbox-operator.v0.9.0` (Technology Preview with OpenShift sandboxed containers 1.13; confirmed on OCP 4.20.8 / `redhat-operators` catalog 2026-08-06)
- `installPlanApproval: Manual` (auto-approved by `scripts/bootstrap-ocp.sh` after the channel is pinned in git)
- Do **not** apply the upstream raw manifest on this path — the Operator alone deploys the sandbox controller, sandbox router, and extension CRDs ([Install chapter, OSC 1.13](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/install-agent-sandbox-overview_agent-sandbox)).
- Requires OpenShift Container Platform **4.19 or later**.

On CRC / single-node local clusters where the `redhat-operators` catalog is unavailable:

- Keep the pinned upstream manifest (`manifests/agent-sandbox-v0.5.1.yaml`) as an explicit CRC-only fallback.
- Document that this path is unsupported-product and must not coexist with the OLM operator on the same cluster.

Do **not** subscribe to `sandboxed-containers-operator` for Agent Sandbox CRDs. That operator is the base OSC/Kata runtime; this project does not currently use Kata `runtimeClass` and does not need it for OpenShell's Kubernetes driver.

## Consequences
- Supported lifecycle via OLM on OCP/RHPDS: the operator manages CRD installation, upgrades, controller, and sandbox router.
- No `latest` tag risk on the OCP path: channel is pinned; Manual InstallPlan approval prevents unreviewed upgrades.
- Tradeoff: depends on Red Hat OperatorHub availability and OCP ≥ 4.19. If the operator is not published to the cluster's catalog source, installation fails (CRC fallback remains).
- Corrects the previous mislabeling that treated `sandboxed-containers-operator` as the Agent Sandbox CRD source.
- Teardown leaves the shared Operator/CRDs in place by default (shared cluster resource); see `scripts/teardown.sh` notes. Full operator removal is an explicit opt-in when cleaning a dedicated demo cluster.

## References
- [Deploying Red Hat build of Agent Sandbox (OSC 1.13)](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/)
- [Install chapter](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/install-agent-sandbox-overview_agent-sandbox)
- [What's new in Red Hat OpenShift confidential computing and sandboxing (Aug 2026)](https://www.redhat.com/en/blog/whats-new-red-hat-openshift-confidential-computing-and-sandboxing)
- [Agent Sandbox upstream](https://github.com/kubernetes-sigs/agent-sandbox)
- Implementation: `scripts/bootstrap-ocp.sh`

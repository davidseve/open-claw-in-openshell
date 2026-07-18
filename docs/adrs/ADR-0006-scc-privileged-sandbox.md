# ADR-0006: Privileged SCC for the Sandbox ServiceAccount

## Status
Accepted

## Context
OpenShift's default `restricted-v2` SCC blocks capabilities that the OpenShell sandbox supervisor needs to establish its security perimeter. Specifically, the supervisor must:

- Install **nftables rules** to enforce network egress policies.
- Configure **Landlock LSM** for filesystem isolation.
- Create **network namespaces** for traffic separation between the agent process and the host network.

These operations require `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, and access to `/proc` and `/sys` paths that `restricted-v2` denies. Without these capabilities, the sandbox cannot enforce its own security controls.

## Decision
Grant the `privileged` SCC to the `openshell-sandbox` ServiceAccount in the `openshell` namespace. This binding is scoped exclusively to sandbox pods — the gateway pod runs under `restricted-v2`.

Additionally, the Helm values must set:
- `podSecurityContext.fsGroup: null`
- `securityContext.runAsUser: null`

This allows OpenShift SCC admission to assign UIDs from the namespace's allocated range instead of using the chart's hardcoded values, which would be rejected by admission.

## Consequences
- Sandbox pods can enforce their own security perimeter: nftables firewall rules, Landlock filesystem restrictions, and network namespace isolation all function correctly.
- The paradox is intentional: elevated cluster privileges are needed to CREATE the restrictive sandbox environment that constrains agent processes.
- Risk: a compromised sandbox supervisor process has elevated host access via the privileged SCC.
- Mitigation: the SCC binding is scoped to a single ServiceAccount in a single namespace. Inside the sandbox, OpenShell's own enforcement layers (L7 proxy, Landlock, nftables) limit what agent processes can do regardless of the pod's SCC.
- The gateway pod is unaffected — it continues to run under `restricted-v2` with no elevated privileges.

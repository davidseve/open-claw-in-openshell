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

## Addendum (2026-08-05): declarative binding via the wrapper chart

The binding described above was originally applied imperatively —
`scripts/common.sh`'s `grant_privileged_scc()` ran `oc adm policy
add-scc-to-user privileged -z openshell-sandbox -n "$ns"` from
`bootstrap-ocp.sh`, with the matching `oc adm policy remove-scc-from-user`
in `teardown.sh`.

This is now a declarative `RoleBinding` template
(`charts/openshell/templates/scc-rolebinding.yaml`, gated by
`openshift.scc.privilegedSandbox`), rendered as part of the same Helm
release as the gateway and the `openshell-sandbox` ServiceAccount itself
(see ADR-0019). `helm uninstall` now removes the binding too — no separate
imperative cleanup step in `teardown.sh`. The decision, scope, and
security rationale above are unchanged; only the mechanism moved from an
imperative `oc adm policy` command to a Helm-managed resource, following the
pattern already validated in the sibling `agentops-example` project.

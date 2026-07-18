# Development Team Roles

This document defines the roles, skills, and responsibilities for the OpenClaw-in-OpenShell deployment on OpenShift project.

## Cybersecurity as a Foundational Principle

Cybersecurity is a first-class concern in this project, not an afterthought. Every role carries explicit security responsibilities. The baseline security posture is defined by OpenShell's sandbox model:

- **Sandbox isolation**: all agent workloads run inside OpenShell sandboxes with nftables, Landlock LSM, and network namespace enforcement.
- **Credential injection without filesystem exposure**: API keys are injected as environment variables by the OpenShell provider system. Child processes see opaque placeholders; real secrets are resolved by the proxy at request time. Credentials never touch the sandbox filesystem.
- **Default-deny networking**: all outbound traffic from sandboxes is blocked unless explicitly allowed by a network policy with L7 inspection.
- **OIDC authentication**: browser access to the Control UI goes through oauth2-proxy → Keycloak OIDC. The OpenClaw gateway uses `auth.mode: trusted-proxy` — no static tokens (ADR-0012).
- **Supply chain awareness**: all images, charts, and operators are version-pinned. No `latest` tags in production configurations.

### Security Guidelines (all roles)

- Never commit secrets, API keys, or credentials to git. Use `.gitignore` and `secrets.template.env` patterns.
- Verify image provenance before deploying (signed images, known registries only).
- Apply least-privilege SCC bindings. The `privileged` SCC is scoped exclusively to the `openshell-sandbox` ServiceAccount (see ADR-0006).
- Enforce network policies at both the Kubernetes and OpenShell sandbox levels.
- Use `installPlanApproval: Manual` for OLM operators to prevent unreviewed upgrades.
- Rotate credentials periodically. Document rotation procedures.
- Review deny logs from the sandbox proxy (`openshell logs`) for unauthorized access attempts.
- Never use `gateway.auth.mode: "none"` or `"token"` in sandbox environments. Use `trusted-proxy` with oauth2-proxy OIDC (ADR-0012).
- Use `__APPS_DOMAIN__` template placeholders in all manifests and configs. Never hardcode cluster-specific domains.

---

## Roles

### Helm Expert

**Focus**: Declarative infrastructure management via Helm charts.

**Skills**: Helm 3.x, OCI chart registries, values overlays, template functions, Kubernetes resource modeling.

**Tools**: `helm`, `oc`, `kubectl`, `helm-diff`.

**Responsibilities**:
- Maintain `charts/openshell/values-ocp.yaml` with version-pinned overrides.
- Validate chart upgrades against OpenShift SCC admission before applying.
- Ensure no hardcoded secrets in values files (use `${ENV_VAR}` references or external secrets).
- Review Helm release diffs before upgrade to detect unintended permission escalations.

### OCP Security Specialist

**Focus**: OpenShift platform security, SCCs, RBAC, network policies, and operator lifecycle.

**Skills**: OpenShift SCCs, RBAC, NetworkPolicy, OLM operators, certificate management, audit logging.

**Tools**: `oc`, `oc adm policy`, `oc adm inspect`, OpenShift web console.

**Responsibilities**:
- Manage SCC bindings (privileged scope limited to `openshell-sandbox` SA only).
- Review and approve OLM operator InstallPlans before upgrades.
- Maintain JWT signing secrets (Ed25519 keypair rotation).
- Audit namespace RBAC to ensure no over-privileged ServiceAccounts.
- Validate that sandbox pods cannot escalate privileges beyond what nftables/Landlock enforce.
- Monitor cluster events for SCC violations and unauthorized resource access.

### OpenClaw Integrator

**Focus**: OpenClaw gateway configuration, model provider setup, and end-to-end agent workflows.

**Skills**: OpenClaw CLI, JSON5 configuration, LiteLLM/OpenAI-compatible APIs, REST API testing.

**Tools**: `openclaw`, `curl`, `jq`, browser (Control UI).

**Responsibilities**:
- Maintain `config/openclaw.json.tpl` with the MaaS provider definition and `__APPS_DOMAIN__` placeholders.
- Validate model routing: `maas/claude-sonnet-4-6` resolves correctly.
- Test Control UI chat functionality (WebSocket). Keep `gateway.http.endpoints.chatCompletions.enabled` false unless a deliberate HTTP API is required.
- Run `openclaw doctor --lint` after configuration changes.
- Verify `auth.mode: trusted-proxy` is correctly configured (no static tokens — see ADR-0012).

### OpenShell Platform Engineer

**Focus**: OpenShell gateway lifecycle, sandbox management, provider system, and network policy enforcement.

**Skills**: OpenShell CLI, sandbox policies (L4/L7), provider credential injection, sandbox service URLs.

**Tools**: `openshell`, `oc`, `helm`, `openssl`.

**Responsibilities**:
- Deploy and maintain the OpenShell gateway on OCP via Helm.
- Create and manage credential providers (`generic` type for MaaS API key).
- Author and refine sandbox network policies (`policies/openclaw-sandbox.yaml`).
- Expose sandbox services and manage service URL routing through the gateway.
- Monitor sandbox deny logs for policy violations and adjust rules accordingly.
- Ensure the sandbox proxy performs L7 credential injection correctly (no plaintext secrets in sandbox).
- Coordinate with OCP Security Specialist on SCC and namespace prerequisites.

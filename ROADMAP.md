# Deployment Roadmap

OpenClaw running inside an OpenShell sandbox on OpenShift Container Platform, using Red Hat MaaS (LiteLLM) for Claude Sonnet 4.6 inference.

Supports both AWS OCP clusters and local CRC (CodeReady Containers) for development.

## Pinned Versions

| Component | Version | Source |
|---|---|---|
| OpenShell Helm chart | `0.0.83` | `oci://ghcr.io/nvidia/openshell/helm-chart` |
| OpenShell gateway/supervisor | `0.0.83` | `ghcr.io/nvidia/openshell/gateway:0.0.83` |
| OpenClaw sandbox image | `latest` | `ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest` |
| Agent Sandbox operator (OLM) | `v1.12.0` | `sandboxed-containers-operator.v1.12.0`, channel `stable` |
| agent-harness-in-a-box (ref) | `76aca3b` | https://github.com/rcarrata/agent-harness-in-a-box/ |
| oauth2-proxy | `v7.15.3` | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.3` |
| Keycloak | `24.0` | `quay.io/keycloak/keycloak:24.0` |
| Tempo | `2.7.2` | `grafana/tempo:2.7.2` |
| OTel Collector | `0.121.0` | `otel/opentelemetry-collector-contrib:0.121.0` |
| MLflow | `v3.10.1` | `ghcr.io/mlflow/mlflow:v3.10.1` (RHOAI 3.4 GA aligned) |

## Environment Support

| Environment | `APPS_DOMAIN` | Detection | Notes |
|---|---|---|---|
| AWS OCP | `apps.ocp.sandbox315.opentlc.com` (example) | Auto-detected from `oc` | Production-like |
| CRC (local) | `apps-crc.testing` | Auto-detected (`crc` binary present) | Development, self-signed certs |

All scripts auto-detect the environment via `detect_environment` in `scripts/common.sh`. Templates use `__APPS_DOMAIN__` placeholders rendered at deploy time.

## Phase 1: Scaffolding + Documentation

- [x] Directory structure and `.gitignore`
- [x] `AGENTS.md` with team roles and security guidelines
- [x] ADR-0001: Helm deployment, no GPU
- [x] ADR-0002: OpenClaw in sandbox (not separate Helm chart)
- [x] ADR-0003: Secret management via OpenShell providers
- [x] ADR-0004: Red Hat Agent Sandbox (OLM, pinned v1.12.0)
- [x] ADR-0005: MaaS inference provider
- [x] ADR-0006: Privileged SCC justification
- [x] ADR-0007: Pattern A vs Pattern B (OpenClaw inside sandbox)
- [x] `charts/openshell/values-ocp.yaml`
- [x] `manifests/openshell-route.yaml`
- [x] `policies/openclaw-sandbox.yaml`
- [x] `config/openclaw.json`
- [x] `secrets/secrets.template.env`
- [x] `scripts/common.sh`, `bootstrap-ocp.sh`, `deploy-openshell.sh`, `launch-openclaw.sh`, `verify.sh`, `teardown.sh`
- [x] `ROADMAP.md`

## Phase 2: Bootstrap OCP Prerequisites

Run: `./scripts/bootstrap-ocp.sh`

- [x] Verify OCP cluster access (`oc whoami`)
- [x] Create `openshell` namespace
- [x] Install Agent Sandbox operator (OSC 1.12 via OLM)
- [x] Approve InstallPlan manually
- [x] Grant `privileged` SCC to `openshell-sandbox` SA
- [x] Generate Ed25519 JWT signing secret
- [x] Verify `sandboxes.agents.x-k8s.io` CRD is available

## Phase 3: Deploy OpenShell

Run: `./scripts/deploy-openshell.sh`

- [x] Copy `secrets/secrets.template.env` to `secrets/secrets.env` and fill in `MAAS_API_KEY`
- [x] Helm install OpenShell v0.0.83 with `values-ocp.yaml`
- [x] Wait for gateway StatefulSet rollout
- [x] Apply OpenShift Route (`manifests/openshell-route.yaml`) — passthrough TLS for mTLS (ADR-0008)
- [x] Register gateway with `openshell` CLI (mTLS client bundle + `--local`)
- [x] Create MaaS provider (`generic` type, `LITELLM_API_KEY`)

## Phase 4: Launch OpenClaw in Sandbox

Run: `./scripts/launch-openclaw.sh`

- [x] Create sandbox with community image (`--from openclaw`)
- [x] Apply network policy (default-deny + MaaS allow + credential rewrite)
- [x] Inject `config/openclaw.json` into sandbox (`auth.mode: trusted-proxy`, Landlock RO config)
- [x] Restart OpenClaw gateway
- [x] Expose Control UI on port 18789 via `openshell service expose`

## Phase 5: Verification

Run: `./scripts/verify.sh`

Evidence: ADR-0008 verification table + Playwright/verify security tests.

- [x] Layer 1: Infrastructure (CRDs, operator, namespace, SCC, JWT)
- [x] Layer 2: OpenShell Gateway (pod, health, CLI, provider)
- [x] Layer 3: Sandbox (exists, Ready, service exposed)
- [x] Layer 4: Security (MaaS allowed, github.com blocked, credentials not on disk, Landlock + config.patch denied)
- [x] Layer 5: OpenClaw Health (`/health`, credential injection placeholder)
- [x] Layer 7b: External access via service Route
- [x] Layer 7b: oauth2-proxy OIDC authentication
- [x] Layer 8: Observability (Tempo, OTel Collector, MLflow, trace pipeline)
- [x] Layer 9: Playwright UI + security tests (15 tests via OIDC flow)

Latest verification: **44 PASS, 0 FAIL, 1 WARN** (CRC)

## Phase 6: Expose OpenClaw UI Without Port-Forward

Run: `./scripts/upgrade-pki.sh` (once, to regenerate cert with wildcard SAN), then `./scripts/launch-openclaw.sh`

Decision: ADR-0009 — Explicit Route per service + wildcard SAN + passthrough TLS.

- [x] Add wildcard SAN `*.apps.<domain>` to `pkiInitJob.serverDnsNames` (gateway derives service routing domain)
- [x] Create explicit Route `openclaw-gw--openclaw-ui.apps.<domain>` → passthrough → gateway Service
- [x] Existing OCP wildcard DNS `*.apps.<cluster>` covers the new hostname (no extra DNS)
- [x] Update `manifests/openclaw-service-route.yaml`, `deploy-openshell.sh`, `launch-openclaw.sh`
- [x] Add Layer 7b external access verification to `verify.sh`
- [x] Create `scripts/upgrade-pki.sh` for cert secret delete + helm upgrade cycle

## Phase 7: Keycloak OIDC with OCP Identity Federation

Run: `./scripts/deploy-keycloak.sh` then `./scripts/configure-oidc.sh`

Decision: ADR-0010 — Keycloak as OIDC broker; users authenticate with OCP credentials; eliminates client cert requirement.

- [x] Deploy Keycloak in-cluster (`openshell-keycloak` namespace, `quay.io/keycloak/keycloak:24.0`)
- [x] Create OCP `OAuthClient` for Keycloak identity brokering
- [x] Configure realm (`openshell`) with OCP identity provider, `openshell-cli` client, role mappings
- [x] Create `scripts/deploy-keycloak.sh` (automated deployment with secret generation)
- [x] Update `values-ocp.yaml` with `server.oidc` config, disable `allowUnauthenticatedUsers`
- [x] Create `scripts/configure-oidc.sh` (Helm upgrade + CLI re-registration + login test)
- [x] Add OIDC verification to `verify.sh` (Layer 1b: Keycloak checks)
- [x] ADR-0010: Document OIDC + OCP federation architecture decision
- [x] Fix OpenClaw UI `allowedOrigins` for external access (`gateway.controlUi.allowedOrigins`)

## Phase 7b: OIDC Authentication for OpenClaw UI

Run: `./scripts/deploy-oauth2-proxy.sh`

Decision: ADR-0011 — oauth2-proxy as OIDC gateway for UI; SSO via Keycloak.
Decision: ADR-0012 — trusted-proxy auth replaces static token (defense-in-depth via `tools.deny` + Landlock).

- [x] Add `openclaw-ui` confidential client to Keycloak realm (audience mapper, redirect URI)
- [x] Create oauth2-proxy manifests (Deployment, Service, ConfigMap template, Route)
- [x] Configure OpenClaw gateway `auth.mode: trusted-proxy` with `x-forwarded-email` header
- [x] Eliminate static gateway token (no more `OPENCLAW_GATEWAY_TOKEN`, `#token=` URL pattern)
- [x] Create `scripts/deploy-oauth2-proxy.sh` (secret gen, Keycloak client registration, deploy)
- [x] Add Phase 7b checks to `verify.sh` (redirect, token grant, pod health)
- [x] Create Playwright auth setup (`tests/auth.setup.ts`) for automated Keycloak login
- [x] Template oauth2-proxy ConfigMap (`configmap.yaml.tpl`) for environment portability
- [x] ADR-0011: Document oauth2-proxy decision
- [x] ADR-0012: Document trusted-proxy auth decision (updated with runtime config findings)

### Trusted-proxy configuration rationale

The `trusted-proxy` auth mode required several non-obvious settings to work with the OpenShell sandbox architecture. Full rationale documented in [ADR-0012](docs/adrs/ADR-0012-trusted-proxy-auth.md); summary here:

| Setting | Value | Why |
|---------|-------|-----|
| `userHeader` | `x-forwarded-email` | oauth2-proxy sends the Keycloak **subject UUID** as `x-forwarded-user`, not the email. `x-forwarded-email` provides human-readable identity for audit trails. |
| `allowLoopback` | `true` | OpenShell connects to the sandbox via loopback. OpenClaw rejects loopback trusted-proxy by default. Safe because sandbox network isolation (nftables + netns) guarantees only OpenShell can reach loopback. |
| `requiredHeaders` | `["x-forwarded-proto", "x-forwarded-host"]` | Prevents header spoofing from sandbox-internal processes — forging `x-forwarded-email` alone is not sufficient. |
| `trustedProxies` | loopback + cluster CIDRs | OpenClaw validates the entire `X-Forwarded-For` chain (`192.168.x.x` → `10.217.x.x` → `127.0.0.1`). All intermediate IPs must be trusted. |
| `dangerouslyDisableDeviceAuth` | `true` | Proxied WebSocket sessions cannot complete device pairing. Without this flag, all scopes are cleared after successful auth, causing `connect failed`. Acceptable because oauth2-proxy + Keycloak already verify user identity. |

### Access Summary

| Layer | Auth mechanism | Credentials |
|-------|---------------|-------------|
| OpenShell gateway (gRPC) | OIDC JWT from Keycloak | `openshell gateway login ocp` → Keycloak → OCP |
| OpenClaw UI (WebSocket) | OIDC via oauth2-proxy | Browser → Keycloak login → session cookie |

**Browser UI access (SSO, no token needed):**
```
https://openclaw-ui.<APPS_DOMAIN>/
```

**CLI access:**
```bash
openshell gateway add https://openshell-gw-openshell.<APPS_DOMAIN> \
  --name ocp --oidc-issuer https://keycloak-openshell-keycloak.<APPS_DOMAIN>/realms/openshell \
  --oidc-client-id openshell-cli
```

**Keycloak Admin Console:**
```
https://keycloak-openshell-keycloak.<APPS_DOMAIN>/admin (admin/admin)
```

## Phase 8: Agent Observability (OpenTelemetry + Tempo + MLflow)

**Status: COMPLETE** — Decision: [ADR-0014](docs/adrs/ADR-0014-agent-observability.md)

Run: `./scripts/deploy-observability.sh`

- [x] Deploy Tempo, OTel Collector, MLflow v3.10.1 (RHOAI 3.4 aligned)
- [x] Dual-pipeline tracing: diagnostics-otel → Tempo, mlflow-openclaw → MLflow
- [x] Rich hierarchical traces in MLflow (AGENT → LLM spans with inputs/outputs)
- [x] HTTP proxy bootstrap for sandbox OTel export
- [x] MLflow CORS, Host validation, artifact destination fixes
- [x] `@mlflow/core` artifact URI patch for containerized MLflow
- [x] Verification added to `scripts/verify.sh` (Layer 8)

Access: `https://mlflow-observability.<APPS_DOMAIN>/`

### Phase 8 cleanup (low priority)

- [ ] Remove stale `MLFLOW_TRACKING_URI` env var from `scripts/launch-openclaw.sh` line 375 (contradicts ADR-0014 Problem 7; not causing issues currently but is dead config)
- [ ] Sync config drift between `config/openclaw.json` (live CRC) and `config/openclaw.json.tpl` (template): `diagnostics-otel.enabled`, `diagnostics.otel.logs`, `gateway.auth.trustedProxy.allowLoopback`

## Phase 8b: System Prompts via MLflow Prompt Registry

**Status: COMPLETE** — Decision: [ADR-0015](docs/adrs/ADR-0015-mlflow-prompt-registry.md)

Run: `./scripts/seed-mlflow-prompts.sh` (initial seed), then `./scripts/launch-openclaw.sh` (fetches at launch)

- [x] Create `prompts/` directory with 7 operator-controlled system prompt files
- [x] Create `scripts/seed-mlflow-prompts.sh` to register prompts in MLflow with `@production` alias
- [x] Create `scripts/fetch-prompts-from-mlflow.sh` to download prompts into sandbox at launch
- [x] Embed version metadata header in each prompt file (Layer 1: per-trace via content)
- [x] Tag MLflow experiment with active prompt versions (Layer 2: per-deployment)
- [x] Create `scripts/prompt-trace-linker.js` sidecar to tag each trace with versions (Layer 3: per-trace)
- [x] Protect prompt files with `root:root chmod 444` (agent cannot modify)
- [x] Integrate prompt fetch into `scripts/launch-openclaw.sh` (between workspace setup and gateway start)
- [x] Integrate initial seed into `scripts/deploy-observability.sh` (after MLflow deploy)
- [x] Write `.prompt-versions.json` manifest for local audit
- [x] ADR-0015 documenting decision, traceability strategy, and Chat Sessions integration path

### Prompt management

| Task | Command |
|------|---------|
| Edit prompts | Edit `prompts/*.md` or use MLflow UI at `https://mlflow-observability.<APPS_DOMAIN>/` |
| Register/update in MLflow | `./scripts/seed-mlflow-prompts.sh` |
| Deploy to sandbox | `./scripts/launch-openclaw.sh` (fetches automatically) |
| Rollback | Change `@production` alias in MLflow UI to a previous version, then relaunch |
| Check active versions | `cat /sandbox/workspace/.prompt-versions.json` (inside sandbox) |

### Future: Multi-turn evaluation by prompt version

The `mlflow-openclaw` plugin tracks `mlflow.trace.session` and `mlflow.trace.user`. Combined with prompt version tags, this enables session-level quality evaluation:

```python
import mlflow
from mlflow.genai.scorers import ConversationCompleteness, UserFrustration

traces = mlflow.search_traces(
    filter_string='tag.prompt_versions LIKE "%SOUL\\":3%"',
    return_type="list",
)
results = mlflow.genai.evaluate(
    data=traces,
    scorers=[ConversationCompleteness(), UserFrustration()],
)
```

## Phase 9 (future): Simplify Control UI for End Users

Objective: minimize the exposed surface of the OpenClaw Control UI so that users only see a chat interface without access to settings, plugins, or advanced configuration.

### Strategy

OpenClaw has no native "kiosk mode." The approach combines operator scopes, plugin/tool policy, and gateway config to produce a minimal UX.

### Configuration Changes (`config/openclaw.json`)

- [ ] Add `plugins.deny: ["workboard", "admin-http-rpc"]` to hide non-essential sidebar tabs
- [ ] Set `gateway.terminal.enabled: false` explicitly
- [ ] Set `gateway.reload.mode: "off"` to prevent live config edits from UI
- [ ] Expand `tools.deny` to include `browser` and `nodes`
- [ ] Add `gateway.nodes.denyCommands: ["system.run", "canvas.navigate"]`
- [ ] Set `gateway.controlUi.toolTitles: false` explicitly

### Trusted-Proxy Scope Mapping (via oauth2-proxy)

- [ ] Add `x-openclaw-scopes` header from oauth2-proxy to enforce `operator.write` for all proxied users
- [ ] Map Keycloak roles to OpenClaw operator scopes (admin role → `operator.admin`, user role → `operator.write`)

## Phase 10 (future): Custom Sandbox Image

- [ ] Build Dockerfile extending OpenShell base with Node.js + OpenClaw
- [ ] Pre-bake `openclaw.json` configuration
- [ ] Push to internal registry (Quay/OpenShift internal)
- [ ] Update `values-ocp.yaml` with custom sandbox image

## Phase 11 (future): Policy Refinement

- [ ] Start with `enforcement: audit` for new endpoints
- [ ] Review deny logs: `openshell logs openclaw-gw --level warn`
- [ ] Add npm/PyPI endpoints if OpenClaw tools need them
- [ ] Switch to `enforcement: enforce` after validation
- [ ] Implement credential rotation procedure

## Phase 12 (future): Migrate to RHOAI-managed MLflow

Objective: Replace standalone MLflow (observability namespace) with RHOAI's shared MLflow instance while preserving the rich `@mlflow/mlflow-openclaw` plugin traces.

Reference: [agentic-starter-kits mlflow-tracing overlay](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/agents/openclaw/deployment/docs/mlflow-tracing.md)

### Architecture change

Current (dev):
- MLflow `ghcr.io/mlflow/mlflow:v3.10.1` in `observability` ns, plain HTTP port 5000
- `mlflow-openclaw` plugin connects directly without auth

Target (production):
- RHOAI MLflow in `redhat-ods-applications`, TLS on port 8443
- ServiceAccount bearer token auth (pod SA token)
- Workspace isolation via `X-MLFLOW-WORKSPACE` header
- Service CA TLS (`/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt`)

### Key difference from starter-kit approach

The starter-kit uses an OTel Collector sidecar to forward `diagnostics-otel` spans to RHOAI MLflow. We keep `mlflow-openclaw` for richer traces (full chat I/O, AGENT/LLM hierarchy) and only need to update the plugin's transport layer to add:
1. Bearer token injection (SA token from mounted secret)
2. TLS CA bundle for service-to-service communication
3. `X-MLFLOW-WORKSPACE` header for namespace isolation

### Tasks

- [ ] Create `openclaw-tracing` ServiceAccount with `mlflow-integration` ClusterRole binding
- [ ] Configure `mlflow-openclaw` plugin with RHOAI endpoint (`https://mlflow.redhat-ods-applications.svc.cluster.local:8443`)
- [ ] Add bearer token auth to plugin config (or env var `MLFLOW_TRACKING_TOKEN`)
- [ ] Add TLS CA config (service-ca.crt mount)
- [ ] Add `X-MLFLOW-WORKSPACE` header (namespace)
- [ ] Create experiment in RHOAI MLflow workspace
- [ ] Update network policy: allow egress to `mlflow.redhat-ods-applications.svc:8443`
- [ ] Verify prompt-trace-linker.js works with RHOAI MLflow auth
- [ ] Remove standalone MLflow deployment from observability namespace
- [ ] Update ADR-0014 with production migration notes

## Phase 13 (future): Security Hardening — Auth Simplification + MLflow Auth

Deferred from the security review (branch `security-review/remediation-v1`). These items reduce attack surface and simplify configuration but require more investigation before implementation.

### 13.1 Eliminate Keycloak — use OpenShift OAuth directly

The Red Hat reference pattern (`claw-installer`) uses OpenShift OAuth natively via an `oauth-proxy` sidecar, eliminating Keycloak entirely. This would remove:

- [ ] Entire `openshell-keycloak` namespace
- [ ] `scripts/deploy-keycloak.sh`, `scripts/configure-oidc.sh`
- [ ] Realm ConfigMap, broker secrets, ROPC client config
- [ ] `directAccessGrantsEnabled` (ROPC grant), token TTL workarounds

**Blocker**: Our topology has OpenShell in the middle (Browser -> oauth-proxy -> OpenShell relay -> sandbox gateway). The `claw-installer` sidecar pattern goes directly to the pod. Need to verify if OpenShift OAuth can work with the OpenShell relay topology.

### 13.2 Simplify gateway auth mode

Evaluate switching from `auth.mode: "trusted-proxy"` to `auth.mode: "token"` (the `claw-installer` pattern):

- [ ] Evaluate: `auth.mode: "token"` with gateway token in Kubernetes Secret
- [ ] Evaluate: scoped `trusted-proxy` without `allowLoopback` / `dangerouslyDisableDeviceAuth`
- [ ] If switching to token mode: remove `trustedProxies`, `requiredHeaders` config
- [ ] Update ADR-0012 with final decision
- [ ] Update Playwright tests for new auth flow

### 13.3 Securize MLflow with basic-auth + sandbox read-only policy

Remediates HIGH-3 (MLflow deployed without authentication):

- [ ] Add `--app-name basic-auth` to MLflow deployment manifest
- [ ] Generate MLflow credentials and store in Kubernetes Secret
- [ ] Update `deploy-observability.sh` to create Secret and mount env vars
- [ ] Update `launch-openclaw.sh` to export `MLFLOW_TRACKING_USERNAME` / `MLFLOW_TRACKING_PASSWORD` to sandbox
- [ ] Restrict sandbox policy `mlflow_direct` to read-only (only `GET`/`HEAD` methods from sandbox)
- [ ] Update `seed-mlflow-prompts.sh` and `fetch-prompts-from-mlflow.sh` with basic-auth credentials
- [ ] Add MLflow auth verification to `verify.sh`

## References

- [OpenShell OpenShift docs](https://docs.nvidia.com/openshell/kubernetes/openshift)
- [OpenShell provider docs](https://nvidia-openshell.mintlify.app/sandboxes/providers)
- [OpenShell sandbox policies](https://docs.nvidia.com/openshell/sandboxes/policies)
- [OpenClaw LiteLLM provider](https://docs.openclaw.ai/providers/litellm)
- [OpenClaw OpenShell plugin](https://docs.openclaw.ai/gateway/openshell)
- [OpenClaw health checks](https://docs.openclaw.ai/gateway/health)
- [OpenClaw OpenAI-compatible API](https://docs.openclaw.ai/gateway/openai-http-api)
- [agent-harness-in-a-box](https://github.com/rcarrata/agent-harness-in-a-box) (commit `76aca3b`)
- [Red Hat Agent Sandbox](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_agent_sandbox/index)

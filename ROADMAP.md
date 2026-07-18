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
| MLflow | `v2.22.0` | `ghcr.io/mlflow/mlflow:v2.22.0` |

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
- [x] Configure OpenClaw gateway `auth.mode: trusted-proxy` with `x-forwarded-user` header
- [x] Eliminate static gateway token (no more `OPENCLAW_GATEWAY_TOKEN`, `#token=` URL pattern)
- [x] Create `scripts/deploy-oauth2-proxy.sh` (secret gen, Keycloak client registration, deploy)
- [x] Add Phase 7b checks to `verify.sh` (redirect, token grant, pod health)
- [x] Create Playwright auth setup (`tests/auth.setup.ts`) for automated Keycloak login
- [x] Template oauth2-proxy ConfigMap (`configmap.yaml.tpl`) for environment portability
- [x] ADR-0011: Document oauth2-proxy decision
- [x] ADR-0012: Document trusted-proxy auth decision

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

**Status: COMPLETE**

Run: `./scripts/deploy-observability.sh`

### Architecture

```
OpenClaw Agent (sandbox)
  → OTEL_EXPORTER_OTLP_ENDPOINT → OTel Collector (observability ns)
                                     → Tempo (trace storage, local backend)
                                     → spanmetrics connector → Prometheus metrics
  → MLFLOW_TRACKING_URI         → MLflow (experiment tracking)
  → Trace Bridge (CronJob)      → Tempo → MLflow (periodic sync)
```

### Deployed Components

| Component | Image | Namespace | Purpose |
|-----------|-------|-----------|---------|
| Tempo | `grafana/tempo:2.7.2` | observability | Distributed trace storage |
| OTel Collector | `otel/opentelemetry-collector-contrib:0.121.0` | observability | OTLP receiver, span processor |
| MLflow | `ghcr.io/mlflow/mlflow:v2.22.0` | observability | Experiment tracking server |
| Trace Bridge | `python:3.12-slim` (CronJob) | observability | Tempo → MLflow trace sync (every minute) |

### Access Points

| Service | URL | Purpose |
|---------|-----|---------|
| MLflow UI | `https://mlflow-observability.<APPS_DOMAIN>` | Experiment dashboard |
| OTel Collector | `otel-collector.observability.svc:4317` (gRPC), `:4318` (HTTP) | Trace ingestion |
| Tempo | `tempo.observability.svc:3200` | Trace query API |

### Validation

- [x] Tempo pod running and healthy
- [x] OTel Collector pod running and accepting OTLP
- [x] MLflow pod running with health endpoint OK
- [x] End-to-end trace pipeline: send trace → store in Tempo → retrieve by trace ID
- [x] Trace Bridge CronJob syncs traces to MLflow
- [x] Verification added to `scripts/verify.sh` (Layer 8)

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

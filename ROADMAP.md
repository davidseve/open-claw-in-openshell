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
| RHOAI operator (Phase 12, `charts/rhoai/`) | `stable-3.4` channel, `rhods-operator.3.4.2` | `redhat-operators` catalog, `installPlanApproval: Manual` |

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
- [x] **Superseded in Phase 13.1** (ADR-0016): the unauthenticated `openclaw-ui` Route this
  phase created was retired. `oauth-proxy`'s own Route now reuses this same hostname
  (`openclaw-gw--openclaw-ui.<domain>`) as the sole, OAuth-gated entry point.

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
https://openclaw-gw--openclaw-ui.<APPS_DOMAIN>/
```
(Historical note: this URL was `openclaw-ui.<APPS_DOMAIN>` until Phase 13.1's
WebSocket fix — see ADR-0016.)

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

- [x] Remove stale `MLFLOW_TRACKING_URI` env var from `scripts/launch-openclaw.sh` (contradicts ADR-0014 Problem 7; plugin config comes from `config.json` only)
- [x] Sync config drift between `config/openclaw.json` (reference snapshot) and `config/openclaw.json.tpl` (template): regenerated the snapshot from a real render of the template (`diagnostics-otel.enabled`, `diagnostics.otel.logs`, `diagnostics.otel.captureContent`, `mlflow-openclaw.hooks.allowConversationAccess`, `gateway.auth.trustedProxy.allowLoopback` were the drifted keys). Root cause: no deploy script ever writes to `config/openclaw.json` — `launch-openclaw.sh` and `deploy-oauth2-proxy.sh` both render `.tpl` straight into `.rendered/`, so the committed snapshot only stays accurate by hand. Added `check_config_snapshot_drift()` in `scripts/common.sh`, wired into `verify.sh` as "Layer 1a: Config template drift" so future drift fails verification instead of silently accumulating.

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

## Phase 9: Simplify Control UI for End Users

**Status: PARTIAL** — config-level hardening done; scope-narrowing via proxy deferred (see below).

Objective: minimize the exposed surface of the OpenClaw Control UI so that users only see a chat interface without access to settings, plugins, or advanced configuration.

### Strategy

OpenClaw has no native "kiosk mode." The approach combines operator scopes, plugin/tool policy, and gateway config to produce a minimal UX.

### Configuration Changes (`config/openclaw.json.tpl`)

- [x] Add `plugins.deny: ["workboard", "admin-http-rpc"]` — these plugins are already disabled by default; this prevents an `operator.admin` session from re-enabling them from the Plugins page. It does **not** hide the Plugins sidebar entry, which OpenClaw always shows regardless of plugin state.
- [x] Set `gateway.terminal.enabled: false` explicitly (already the default; now documented in config)
- [x] Set `gateway.reload.mode: "off"` to prevent live config edits from UI from being applied without a restart
- [x] Expand `tools.deny` (top-level, governs what the agent itself can invoke) to include `browser` and `nodes`
- [x] Add `gateway.nodes.denyCommands: ["system.run", "canvas.navigate"]` — key verified directly against the deployed OpenClaw 2026.7.1 gateway's live JSON Schema (`openclaw config schema`, `gateway.nodes` is `{browser, pairing, allowCommands, denyCommands}` with `additionalProperties: false`). The original ROADMAP wording (`denyCommands`) was correct; a nested `gateway.nodes.commands.deny` shape (seen in newer upstream docs) does **not** exist in this pinned version and was rejected at gateway startup (`gateway.nodes: Invalid input`) before being corrected here.
- [ ] ~~Set `gateway.controlUi.toolTitles: false`~~ — dropped. This key does not exist in the deployed 2026.7.1 schema either (`controlUi` keys are `enabled, basePath, root, embedSandbox, allowExternalEmbedUrls, chatMessageMaxWidth, allowedOrigins, dangerouslyAllowHostHeaderOriginFallback, allowInsecureAuth, dangerouslyDisableDeviceAuth`, also `additionalProperties: false`); adding it also caused a hard startup rejection (`gateway.controlUi: Invalid input`). Revisit only after upgrading past 2026.7.1 and re-checking the schema.

### Trusted-Proxy Scope Mapping — deferred, not Keycloak-based

The original plan for this section ("Map Keycloak roles to OpenClaw operator scopes") is obsolete: [ADR-0016](docs/adrs/ADR-0016-openshift-native-oauth-spike.md) (2026-07-23) replaced Keycloak with `oauth-proxy` (OpenShift fork, native OCP OAuth) for the entire browser auth path. Keycloak is no longer in that path at all — it remains only for the CLI/gRPC gateway auth path. OCP's native OAuth server does not expose roles/groups in the token (they live in the Kubernetes User/Group API, not the JWT/opaque token), so there is no role claim left to map.

- [ ] **Blocked**: inject a static `x-openclaw-scopes: operator.write` header from the proxy to cap all proxied Control UI sessions. Investigated and found infeasible with the current stack: `registry.redhat.io/openshift4/ose-oauth-proxy` (see [manifests/oauth2-proxy/deployment.yaml.tpl](manifests/oauth2-proxy/deployment.yaml.tpl)) only forwards identity headers it already derives from the IdP (`x-forwarded-user`, `x-forwarded-email`, `x-forwarded-preferred-username` via `--pass-user-headers=true`); it has no flag to inject an arbitrary static header. Implementing this would require either patching/forking `oauth-proxy` or adding a header-rewriting sidecar between it and the OpenShell relay — disproportionate for this phase, and risky given ADR-0016 already documents this fork as fragile (the WebSocket/Host-header bug it had to work around). Revisit if/when the proxy is replaced (e.g. `kube-auth-proxy`, noted as a non-blocking follow-up in ADR-0016) with something that supports custom header injection.
- [ ] **Follow-up investigation (not scheduled)**: re-verify the actual runtime behavior of `gateway.controlUi.dangerouslyDisableDeviceAuth: true` (set in [config/openclaw.json.tpl](config/openclaw.json.tpl), documented in [ADR-0012](docs/adrs/ADR-0012-trusted-proxy-auth.md)) against the currently deployed OpenClaw 2026.7.1 gateway. Current OpenClaw docs describe this key as a retired break-glass/migration setting rather than a persistently supported config, which may mean device-less trusted-proxy sessions today behave differently (e.g. scopes cleared to `[]` by default) than what ADR-0012 assumed. This is a deeper auth-architecture question, out of scope for "reduce UI surface."

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

### Environment scope: AWS for the combined stack, CRC as a standalone-only experiment

Decision: **[ADR-0017](docs/adrs/ADR-0017-rhoai-mlflow-scope.md)** — empirically tested (not just inferred from Red Hat's documented 32 CPU/128 GiB single-node minimum) on this project's CRC dev laptop on 2026-07-24:
- RHOAI + a minimal MLflow-only `DataScienceCluster` **alone** fits comfortably on a 16 vCPU / 40 GiB CRC VM (host stayed at 18 GiB free out of 62 GiB total).
- Combined with the rest of the OpenShell + OpenClaw stack, host free memory dropped to 11 GiB and swap engaged — functionally fine (no crashes, no pod evictions) but below the safety margin this project reserves for keeping a shared dev laptop's Cursor session responsive.
- **Result**: `charts/rhoai/` (operators + platform + database + mlflow, trimmed from `agentops-example` to only `mlflowoperator: Managed`) and `scripts/deploy-rhoai-mlflow.sh` exist and work, but are **not** wired into `crc-lifecycle.sh`'s combined `deploy`/`full` commands. On CRC, run `deploy-rhoai-mlflow.sh` standalone only, never alongside the full stack for long. On AWS it's unconstrained — see `deploy-full-aws` skill's new "Phase 9b" step.
- The `mlflow-openclaw` plugin transport (tasks below) stays pointed at the standalone MLflow (ADR-0014) by default on both environments until this actually runs against AWS.

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

- [x] Vendor minimal RHOAI Helm charts (`charts/rhoai/{operators,platform,database,mlflow}` + `Makefile`, trimmed from `agentops-example`, only `mlflowoperator: Managed`)
- [x] Create `scripts/deploy-rhoai-mlflow.sh` (secret generation via `openssl rand`, no plaintext DB password committed)
- [x] Empirically validate resource fit on CRC (Stage 1: alone — pass; Stage 2: combined with full stack — functional pass, resource-budget fail; see ADR-0017)
- [ ] Create `openclaw-tracing` ServiceAccount with `mlflow-integration` ClusterRole binding (AWS)
- [ ] Configure `mlflow-openclaw` plugin with RHOAI endpoint (`https://mlflow.redhat-ods-applications.svc.cluster.local:8443`), gated by `CRC_MODE` so CRC keeps using standalone MLflow
- [ ] Add bearer token auth to plugin config (or env var `MLFLOW_TRACKING_TOKEN`)
- [ ] Add TLS CA config (service-ca.crt mount)
- [ ] Add `X-MLFLOW-WORKSPACE` header (namespace)
- [ ] Create experiment in RHOAI MLflow workspace
- [ ] Update network policy: allow egress to `mlflow.redhat-ods-applications.svc:8443`
- [ ] Verify prompt-trace-linker.js works with RHOAI MLflow auth
- [ ] Remove standalone MLflow deployment from observability namespace (AWS only — CRC keeps it per ADR-0017)
- [ ] Update ADR-0014 with production migration notes

## Phase 13 (future): Security Hardening — Auth Simplification + MLflow Auth

Deferred from the security review (branch `security-review/remediation-v1`). These items reduce attack surface and simplify configuration but require more investigation before implementation.

### 13.1 Eliminate Keycloak — use OpenShift OAuth directly

The Red Hat reference pattern (`claw-installer`) uses OpenShift OAuth natively via an `oauth-proxy` sidecar. This has been done for the **browser UI path**. For the **CLI/gRPC path**, full removal was investigated and closed as a decision to keep Keycloak (see below) — this is no longer an open TODO for that path. If it is ever revisited, it would fully remove:

- [ ] Entire `openshell-keycloak` namespace
- [ ] `scripts/deploy-keycloak.sh`, `scripts/configure-oidc.sh`
- [ ] Realm ConfigMap, broker secrets, ROPC client config
- [ ] `directAccessGrantsEnabled` (ROPC grant), token TTL workarounds

**Status: browser UI path done and live in production.** See [ADR-0016](docs/adrs/ADR-0016-openshift-native-oauth-spike.md) "Rollout to production". The production Route `openclaw-ui-auth` (`openclaw-gw--openclaw-ui.<APPS_DOMAIN>`) now points at `oauth-proxy` (OpenShift fork, SA-based OAuth client) in `manifests/oauth2-proxy/` — the former community `oauth2-proxy` + Keycloak stack there was replaced, not run side by side. `scripts/deploy-oauth2-proxy.sh`, `scripts/verify.sh` (Layer 7b), and `tests/auth.setup.ts` were all updated accordingly. Browsers now authenticate directly against OCP's own OAuth server; zero Keycloak involvement in this path. Three real defects were found and fixed along the way: `--upstream-ca` for the relay's passthrough-TLS cert; and a WebSocket-specific Host-header bug in this `oauth-proxy` fork (present in `openshift/oauth-proxy` and, verified separately, in `opendatahub-io/kube-auth-proxy` too) that broke chat logins entirely — fixed by making the public Route hostname equal OpenShell's own `{sandbox}--{service}` pattern, `--pass-host-header=true`, and a `hostAliases` entry so `oauth-proxy`'s own upstream can still reach the `openshell` Service without looping back through its own Route. This also retired the old unauthenticated static-token Route (`openclaw-ui`), which had used that same hostname. See ADR-0016's "WebSocket login failure" section. **Correction vs. the original idea**: the community `oauth2-proxy` image has no `openshift` provider; the fix required swapping in the separate `openshift/oauth-proxy` fork, not a config flag change.

**Status: CLI/gRPC path — investigated and closed, decision is to keep Keycloak.** This is not an open blocker waiting on future work in this repo; it's a completed investigation with a documented conclusion. The CLI/gRPC gateway auth path (`scripts/configure-oidc.sh`, `charts/openshell/values-ocp.yaml.tpl` `server.oidc`) validates bearer JWTs against a JWKS-serving OIDC issuer and expects a Keycloak-specific `realm_access.roles` claim for admin/user role mapping. OCP's native OAuth server issues opaque tokens with no JWKS endpoint and cannot satisfy this — confirmed directly against the OpenShell gateway source (`crates/openshell-server/src/auth/oidc.rs`, `k8s_sa.rs`, `multiplex.rs`), not just inferred from behavior. Dropping Keycloak today would mean either running CLI/gRPC unauthenticated (`allowUnauthenticatedUsers: true`, rejected — real security regression) or swapping in a different OIDC broker (doesn't remove the architectural dependency, just changes which pod provides it). **The one condition that would reopen this**: the OpenShell gateway gaining native support for validating OpenShift user OAuth tokens directly (new `TokenReview`/`SubjectAccessReview`-based authenticator for human callers — upstream work in a different repository, not scheduled). See [ADR-0016](docs/adrs/ADR-0016-openshift-native-oauth-spike.md)'s "Decision record: Keycloak stays, scoped to the CLI/gRPC path" for the full technical wall, options table, and rejection rationale.

Also still open (browser UI path, unrelated to the Keycloak decision): SAR-based access scoping, and re-verifying `x-forwarded-email` with a real (non-HTPasswd) IdP — see ADR-0016's "Open questions from the original spike".

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

### 13.4 Review: plaintext MaaS API key on disk

Flagged from a chat-session security review (jailbreak/exfiltration probing found in a
real session transcript — the agent correctly refused all attempts, but the underlying
architecture relies on soft controls that deserve a hard fix:

**Plaintext API key in the sandbox workspace.** Constraint #3 (`docs/constraints.md`)
requires `launch-openclaw.sh` to inject the real `MAAS_API_KEY` directly into
`/sandbox/workspace/.openclaw/openclaw.json` instead of the `openshell:resolve:env:...`
placeholder pattern, because Node's `fetch()`/`undici` breaks proxy credential injection.
That path is Landlock **read-write** and not on the `tools.deny` list (only `gateway`,
`cron`, `openclaw` are denied) — the agent's normal `read`/`exec` tools can access it.
Today the only things standing between a malicious prompt and the raw key are: (1) the
LLM's own judgment to refuse (soft — worked in the observed session, but not guaranteed),
and (2) OpenClaw's pattern-based transcript/tool-output redaction (hard, but incomplete —
it doesn't cover every way the key text could be reshaped before being echoed).

- [ ] Re-investigate OpenShell issue #894 (undici binary resolution) for a fix that
      restores true placeholder-based credential injection for Node.js `fetch()`, removing
      the need to ever write the real key to sandbox disk
- [ ] Until #894 lands, evaluate mitigations: register the plaintext MaaS key in
      OpenClaw's exact-value secret registry (`secrets/runtime.ts`) so redaction isn't
      purely pattern-based, and/or add the workspace config path to a denylist for
      generic file-read/`exec` tools
- [ ] Add an automated check (in `verify.sh` or a Playwright test) that attempts common
      jailbreak/exfiltration prompts against a live session and asserts the real key
      never appears unmasked in `chat.history` / the `.jsonl` transcript

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

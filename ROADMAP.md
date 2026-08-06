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
| RHOAI operator (`charts/rhoai/`) | `stable-3.4` channel, `rhods-operator.3.4.2` | `redhat-operators` catalog, `installPlanApproval: Manual` |
| RHOAI-managed MLflow | RHOAI 3.4 GA-aligned | via `mlflowoperator: Managed` DSC component — sole tracing/prompt-registry backend, see [ADR-0018](docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md) |

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

### Why OpenShell is first installed *without* OIDC (`values-ocp-no-oidc.yaml.tpl`)

This project **always uses Keycloak** for the CLI/gRPC gateway auth path when `--with-oidc` is requested — `values-ocp-no-oidc.yaml.tpl` is not an alternative to Keycloak, it's a required transient bootstrap step, not a permanent config choice. There's a real chicken-and-egg dependency:

1. The OIDC overlay (`values-ocp.yaml.tpl`) sets `openshell.server.oidc.caConfigMapName: openshell-oidc-ca` — a ConfigMap that `configure-oidc.sh` creates (from OCP's ingress CA) at OIDC-configuration time, **after** OpenShell and Keycloak both already exist. Installing OpenShell with the OIDC overlay from the very first `helm install` would reference a ConfigMap that doesn't exist yet.
2. `scripts/crc-lifecycle.sh`'s `cmd_deploy()` therefore always runs Phase 5 (`deploy-openshell.sh`) with `WITH_OIDC=false` (using `values-ocp-no-oidc.yaml.tpl`, `allowUnauthenticatedUsers: true`), regardless of whether `--with-oidc` was passed to `crc-lifecycle.sh` itself.
3. Only in Phase 7, if `--with-oidc` was requested, does `configure-oidc.sh` create the `openshell-oidc-ca` ConfigMap and then `helm upgrade` the *same* release with `values-ocp.yaml.tpl` (the OIDC overlay), flipping `allowUnauthenticatedUsers` to `false` and enabling Keycloak-backed JWT auth on the gateway.

Net effect: on a `--with-oidc` deploy, the no-OIDC state only exists briefly between Phase 5 and Phase 7 — the final, steady state has Keycloak enforced. It only remains the *permanent* state when deploying without `--with-oidc` (e.g. `crc-lifecycle.sh deploy` with no flags, or `full --minimal`), which is a deliberately lighter, unauthenticated-CLI profile, not the recommended default.

**If this two-step bootstrap is ever changed** (e.g. by having the chart tolerate a missing `caConfigMapName` at install time, or by pre-creating the ConfigMap earlier in `bootstrap-ocp.sh`), update this section, the header comments in both `charts/openshell/values-ocp.yaml.tpl` / `values-ocp-no-oidc.yaml.tpl`, and `scripts/crc-lifecycle.sh`'s Phase 5 comment together — they currently all describe the same mechanism and would otherwise drift out of sync.

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

**Status: COMPLETE, MLflow backend superseded by Phase 12b/[ADR-0018](docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)** — Decision: [ADR-0014](docs/adrs/ADR-0014-agent-observability.md)

Run: `./scripts/deploy-observability.sh` (now Tempo + OTel Collector only — see Phase 12b)

- [x] Deploy Tempo, OTel Collector, MLflow v3.10.1 (RHOAI 3.4 aligned) — **the standalone MLflow deployment was later removed entirely (Phase 12b); only Tempo/OTel Collector remain from this list**
- [x] Dual-pipeline tracing: diagnostics-otel → Tempo, mlflow-openclaw → MLflow
- [x] Rich hierarchical traces in MLflow (AGENT → LLM spans with inputs/outputs)
- [x] HTTP proxy bootstrap for sandbox OTel export
- [x] MLflow CORS, Host validation, artifact destination fixes
- [x] `@mlflow/core` artifact URI patch for containerized MLflow
- [x] Verification added to `scripts/verify.sh` (Layer 8)

Access (historical, standalone MLflow — removed): ~~`https://mlflow-observability.<APPS_DOMAIN>/`~~. Current MLflow UI is RHOAI's Route in `redhat-ods-applications` — see Phase 12b.

### Phase 8 cleanup (low priority)

- [x] Remove stale `MLFLOW_TRACKING_URI` env var from `scripts/launch-openclaw.sh` (contradicts ADR-0014 Problem 7; plugin config comes from `config.json` only)
- [x] Sync config drift between `config/openclaw.json` (reference snapshot) and `config/openclaw.json.tpl` (template): regenerated the snapshot from a real render of the template (`diagnostics-otel.enabled`, `diagnostics.otel.logs`, `diagnostics.otel.captureContent`, `mlflow-openclaw.hooks.allowConversationAccess`, `gateway.auth.trustedProxy.allowLoopback` were the drifted keys). Root cause: no deploy script ever writes to `config/openclaw.json` — `launch-openclaw.sh` and `deploy-oauth2-proxy.sh` both render `.tpl` straight into `.rendered/`, so the committed snapshot only stays accurate by hand. Added `check_config_snapshot_drift()` in `scripts/common.sh`, wired into `verify.sh` as "Layer 1a: Config template drift" so future drift fails verification instead of silently accumulating.

## Phase 8b: System Prompts via MLflow Prompt Registry

**Status: COMPLETE, backend superseded by Phase 12b/[ADR-0018](docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)** (mechanism below is unchanged — only the MLflow instance it talks to changed) — Decision: [ADR-0015](docs/adrs/ADR-0015-mlflow-prompt-registry.md)

Run: `./scripts/seed-mlflow-prompts.sh` (initial seed), then `./scripts/launch-openclaw.sh` (fetches at launch)

- [x] Create `prompts/` directory with 7 operator-controlled system prompt files
- [x] Create `scripts/seed-mlflow-prompts.sh` to register prompts in MLflow with `@production` alias
- [x] Create `scripts/fetch-prompts-from-mlflow.sh` to download prompts into sandbox at launch
- [x] Embed version metadata header in each prompt file (Layer 1: per-trace via content)
- [x] Tag MLflow experiment with active prompt versions (Layer 2: per-deployment)
- [x] Create `scripts/prompt-trace-linker.js` sidecar to tag each trace with versions (Layer 3: per-trace)
- [x] Protect prompt files with `root:root chmod 444` (agent cannot modify)
- [x] Integrate prompt fetch into `scripts/launch-openclaw.sh` (between workspace setup and gateway start)
- [x] Integrate initial seed into `scripts/deploy-observability.sh` (after MLflow deploy) — **moved to `scripts/wire-rhoai-mlflow-tracing.sh` in Phase 12b, since `deploy-observability.sh` no longer deploys MLflow**
- [x] Write `.prompt-versions.json` manifest for local audit
- [x] ADR-0015 documenting decision, traceability strategy, and Chat Sessions integration path

### Prompt management

| Task | Command |
|------|---------|
| Edit prompts | Edit `prompts/*.md` or use MLflow UI at RHOAI's MLflow Route (`oc get route mlflow -n redhat-ods-applications`) |
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

## Phase 12: Migrate to RHOAI-managed MLflow

**Status: COMPLETE** — Objective: Replace standalone MLflow (observability namespace) with RHOAI's shared MLflow instance while preserving the rich `@mlflow/mlflow-openclaw` plugin traces.

Reference: [agentic-starter-kits mlflow-tracing overlay](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/agents/openclaw/deployment/docs/mlflow-tracing.md)

### Environment scope: from CRC-as-standalone-experiment to sole backend everywhere

Decision history: **[ADR-0017](docs/adrs/ADR-0017-rhoai-mlflow-scope.md)** (empirical CRC validation + original opt-in scope, 2026-07-24) → **[ADR-0018](docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)** (full migration decision, 2026-07-25). Summary:
- RHOAI + a minimal MLflow-only `DataScienceCluster` **alone** fits comfortably on a 16 vCPU / 40 GiB CRC VM (host stayed at 18 GiB free out of 62 GiB total).
- Combined with the rest of the OpenShell + OpenClaw stack, host free memory drops to ~11 GiB and swap engages — functionally fine (no crashes, no pod evictions) but below this project's usual safety margin. **This is now an accepted trade-off**, not a reason to keep two backends (ADR-0018).
- All three real integration blockers found while wiring the `mlflow-openclaw` plugin to RHOAI MLflow (Node-side TLS trust conflict with the OpenShell sandbox proxy, a hostname-matching bug in the `tls: skip` policy, and the pinned SDK missing the `X-MLFLOW-WORKSPACE` header) were root-caused and fixed for real — see ADR-0017's "Follow-up"/"Resolution" sections and `docs/constraints.md` #4b-#4e.
- End-to-end validated live: a real chat message produced a real trace in RHOAI MLflow, picked up and tagged by `prompt-trace-linker.js` on its next poll cycle, with the MaaS chat path unaffected throughout.
- **Result**: standalone MLflow was removed entirely (see Phase 12b below); RHOAI-managed MLflow (`charts/rhoai/`) is the sole tracing/prompt-registry backend on every environment, wired unconditionally into `crc-lifecycle.sh`.

### Architecture change

Before (removed):
- MLflow `ghcr.io/mlflow/mlflow:v3.10.1` in `observability` ns, plain HTTP port 5000
- `mlflow-openclaw` plugin connects directly without auth

Now (sole backend, all environments):
- RHOAI MLflow in `redhat-ods-applications`, TLS on port 8443
- ServiceAccount bearer token auth (declarative Secret, `charts/rhoai/mlflow/templates/openclaw-integration-rbac.yaml`)
- Workspace isolation via `X-MLFLOW-WORKSPACE` header (source-patched into the pinned `@mlflow/core@0.2.0` client — see `docs/constraints.md` #4b)
- Service CA TLS (`openshift-service-ca.crt`, combined with OpenShell's own proxy CA into one bundle — `docs/constraints.md` #4c)

### Key difference from starter-kit approach

The starter-kit uses an OTel Collector sidecar to forward `diagnostics-otel` spans to RHOAI MLflow. We keep `mlflow-openclaw` for richer traces (full chat I/O, AGENT/LLM hierarchy) instead, with the plugin's transport layer patched (not just configured) to add:
1. Bearer token injection (SA token from a declarative Secret)
2. TLS CA bundle for service-to-service communication (combined-bundle fix)
3. `X-MLFLOW-WORKSPACE` header for namespace isolation (source patch, since the pinned SDK version doesn't send it)

### Tasks

- [x] Vendor minimal RHOAI Helm charts (`charts/rhoai/{operators,platform,database,mlflow}` + `Makefile`, trimmed from `agentops-example`, only `mlflowoperator: Managed`)
- [x] Create `scripts/deploy-rhoai-mlflow.sh` (secret generation via `openssl rand`, no plaintext DB password committed)
- [x] Empirically validate resource fit on CRC (Stage 1: alone — pass; Stage 2: combined with full stack — functional pass, resource-budget accepted as trade-off; see ADR-0017/ADR-0018)
- [x] Declarative RBAC: `openclaw-tracing` RoleBinding to `mlflow-integration` ClusterRole (`charts/rhoai/mlflow/templates/openclaw-integration-rbac.yaml`)
- [x] Configure `mlflow-openclaw` plugin with RHOAI endpoint (`https://mlflow.redhat-ods-applications.svc:8443` — short-form hostname, required for the `tls: skip` policy match)
- [x] Add bearer token auth to plugin config via `MLFLOW_TRACKING_TOKEN` env var (declarative SA token Secret)
- [x] Add TLS CA config (`service-ca.crt`, combined with OpenShell's proxy CA bundle)
- [x] Add `X-MLFLOW-WORKSPACE` header (source patch on `@mlflow/core`, `scripts/launch-openclaw.sh` Step 7)
- [x] Create experiment in RHOAI MLflow workspace (declarative Helm hook Job, `charts/rhoai/mlflow/templates/openclaw-integration-experiment-job.yaml`)
- [x] Update network policy: allow egress to `mlflow.redhat-ods-applications.svc:8443` (`policies/openclaw-sandbox.yaml`, `tls: skip`)
- [x] Verify prompt-trace-linker.js works with RHOAI MLflow auth
- [x] Remove standalone MLflow deployment entirely, all environments (Phase 12b)
- [x] ADR-0014, ADR-0015 marked Superseded (MLflow half); ADR-0018 created with the full decision

## Phase 12b: Remove Standalone MLflow

**Status: COMPLETE** — Decision: [ADR-0018](docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)

Objective: once Phase 12 proved RHOAI MLflow works end-to-end, remove every reference to the standalone `ghcr.io/mlflow/mlflow` deployment — no code, docs, or scripts should suggest it ever existed as an active option, while preserving every mechanism that sends traces or references prompts.

- [x] Delete `manifests/observability/mlflow.yaml[.tpl]`; strip MLflow deploy/config steps from `scripts/deploy-observability.sh` (now Tempo + OTel Collector only)
- [x] `scripts/common.sh`: remove the `mlflow.yaml.tpl` render call
- [x] `policies/openclaw-sandbox.yaml`: remove the old `mlflow_direct` (plain-HTTP) policy block; rename `rhoai_mlflow_direct` → `mlflow_direct`
- [x] `config/openclaw.json[.tpl]`: point `trackingUri` at RHOAI's endpoint
- [x] `scripts/seed-mlflow-prompts.sh`, `scripts/fetch-prompts-from-mlflow.sh`: add Bearer token + `X-MLFLOW-WORKSPACE` + CA auth support, default URL to RHOAI's endpoint
- [x] `scripts/wire-rhoai-mlflow-tracing.sh`: drop "opt-in experiment" framing; call `seed-mlflow-prompts.sh` at the end (moved from the removed standalone deploy step)
- [x] `scripts/crc-lifecycle.sh`: make `deploy-rhoai-mlflow.sh` + `wire-rhoai-mlflow-tracing.sh` unconditional steps in `cmd_deploy`/`cmd_full`
- [x] `scripts/launch-openclaw.sh`: make RHOAI MLflow wiring unconditional (drop the `--rhoai-mlflow` flag)
- [x] `scripts/test-tracing.sh`, `scripts/smoke-test-e2e.sh`, `scripts/verify.sh`: point all MLflow checks at RHOAI's Route/namespace with proper auth; drop SQLite-specific introspection (RHOAI's MLflow runs on Postgres, no local DB file to open)
- [x] ADR-0014, ADR-0015 marked Superseded; ADR-0017 scope-decision section updated; ADR-0018 created
- [x] `ROADMAP.md`: this section, plus closing out Phase 12 and marking 13.3 obsolete
- [x] `docs/constraints.md`: constraint #4b marked Resolved with the real fix
- [x] `docs/constraints.md`: constraint #12 and other standalone-MLflow-specific references reviewed; constraint #10 (deploy ordering) updated for the new mandatory RHOAI phases; new constraint #17 documents an unrelated live-testing finding (verify.sh's synthetic chatCompletions test is a pre-existing false-positive, not an RHOAI MLflow regression)
- [x] `README.md` + skills (`deploy-full-aws`, `deploy-full-crc`, `crc-local-dev`, `monitor-deployment`) updated to remove standalone MLflow references; CRC sizing bumped to 16 vCPU/40 GiB (RHOAI-validated, `scripts/crc-lifecycle.sh`)
- [x] `prompts/TOOLS.md` (and any other prompt file referencing the MLflow endpoint) updated

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

**Status: OBSOLETE — superseded by [Phase 12b](#phase-12b-remove-standalone-mlflow)/[ADR-0018](docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md).** This item remediated HIGH-3 ("MLflow deployed without authentication") for the standalone `ghcr.io/mlflow/mlflow` deployment, which was removed entirely. RHOAI-managed MLflow (the sole backend now) was never unauthenticated to begin with — it requires a ServiceAccount Bearer token + `X-MLFLOW-WORKSPACE` header via `self_subject_access_review` RBAC from day one, so HIGH-3 no longer applies. No basic-auth work is needed or planned.

<details>
<summary>Original plan (kept for history, not actioned)</summary>

- [ ] Add `--app-name basic-auth` to MLflow deployment manifest
- [ ] Generate MLflow credentials and store in Kubernetes Secret
- [ ] Update `deploy-observability.sh` to create Secret and mount env vars
- [ ] Update `launch-openclaw.sh` to export `MLFLOW_TRACKING_USERNAME` / `MLFLOW_TRACKING_PASSWORD` to sandbox
- [ ] Restrict sandbox policy `mlflow_direct` to read-only (only `GET`/`HEAD` methods from sandbox)
- [ ] Update `seed-mlflow-prompts.sh` and `fetch-prompts-from-mlflow.sh` with basic-auth credentials
- [ ] Add MLflow auth verification to `verify.sh`

</details>

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

### 13.5 Re-audit `OPENSHELL_GATEWAY_INSECURE` scoping when AWS OCP gets real certs

**Context**: `scripts/common.sh`'s `detect_environment()` used to export
`OPENSHELL_GATEWAY_INSECURE=true` (skip TLS server-cert verification for the
`openshell` CLI) globally whenever `CRC_MODE=true`, to work around CRC's
self-signed router wildcard cert not being in the system trust store
(constraint #18). During a live `crc-lifecycle.sh full --fresh` run
(2026-07-27), this was found to also break **mTLS gateway registration**
(`openshell status` failing for 5+ minutes with `CertificateRequired`/"peer
sent no certificates") — the blanket global export was scoped down to a new
`enable_openshell_oidc_insecure()` helper, called only from the OIDC-specific
code paths (`configure-oidc.sh`'s gateway re-registration,
`ensure_oidc_token()`'s refresh calls), and explicitly `unset` before mTLS
operations in `deploy-openshell.sh`. **Decision (2026-07-27): keep this
CRC-only scoped fix as-is for now** — revisit the open items below
specifically when preparing the AWS OCP deployment (real, cluster-issued
certs).

- [x] Scope `OPENSHELL_GATEWAY_INSECURE` to OIDC-only flows, unset it before mTLS gateway registration (`scripts/common.sh`, `scripts/deploy-openshell.sh`, `scripts/configure-oidc.sh`) — done 2026-07-27, still `CRC_MODE`-gated, never set on AWS
- [ ] **Root cause not fully confirmed**: the working hypothesis (insecure-mode short-circuits the client-cert identity resolver, not just server-cert verification) is plausible but based on a ~1-minute A/B test that overlaps with constraint #19's own documented time-based recovery window (10s–8min, attributed there to host memory pressure, not to this flag). Re-validate with a cleaner, longer, repeated-trial experiment (or find/read the `openshell` CLI's TLS client source) before treating this as fully proven — the *practical* fix (unset before mTLS) is safe to keep either way, since it can only narrow, never widen, where verification is skipped
- [ ] **Known gap introduced by this fix**: `cmd_verify()` in `scripts/crc-lifecycle.sh` (and any other caller of `verify.sh`/`smoke-test-e2e.sh` that doesn't first call `ensure_oidc_token`) no longer benefits from the old global export, so a standalone `./scripts/crc-lifecycle.sh verify` run long after the last `configure-oidc.sh` (OIDC access token expired, refresh-token call needed) could hit constraint #18 again on CRC. Not fixed yet — call `ensure_oidc_token` at the top of `cmd_verify()` (matching the pattern the `monitor-deployment` skill already uses manually) before this bites in practice
- [ ] `docs/constraints.md` #18/#19 need a new/updated entry documenting this interaction — the code comments in `common.sh`/`deploy-openshell.sh` currently reference "constraints.md #18/#19" as if already covering this, but the doc text itself is stale
- [x] **AWS follow-up — confirmed 2026-08-03 on a real AWS OCP cluster (`sandbox659.opentlc.com`, Let's Encrypt-issued router wildcard cert)**: `enable_openshell_oidc_insecure()` is strictly gated on `CRC_MODE=true` (`scripts/common.sh`), so `OPENSHELL_GATEWAY_INSECURE` was never exported anywhere during a full `crc-lifecycle.sh deploy --with-oidc --with-obs` + `verify.sh` (full profile) run — confirmed via `env | grep OPENSHELL_GATEWAY_INSECURE` (empty) throughout. This entire workaround was indeed a complete no-op on AWS, exactly as predicted: mTLS gateway registration, `openshell status`, OIDC token refresh against Keycloak, and the oauth-proxy OAuth login flow (real `redhat` HTPasswd user) all passed with zero TLS trust issues — Let's Encrypt's publicly-trusted chain needs no special handling, unlike CRC's self-signed router cert (constraint #18). No AWS-side gap found; no code changes needed for this item.
- [ ] Stronger long-term fix (CRC-only, optional): replace the insecure-skip approach entirely by importing CRC's actual router CA into the CLI's trust store (or passing it explicitly, if the `openshell` CLI supports a custom CA flag), so CRC never needs `OPENSHELL_GATEWAY_INSECURE` either — would close the residual OIDC-path exposure window without needing an insecure flag at all

### 13.6 Prompt file "read-only" protection (`chmod 444`) is bypassable — needs a directory-level fix

Discovered from a real chat-session report (the agent successfully edited `AGENTS.md` via its `edit` tool despite the file being `chown root:root` + `chmod 444`) and confirmed live against the running sandbox — see [`docs/constraints.md` #24](docs/constraints.md) for the full root-cause analysis and reproduction steps.

**Root cause**: the lock only prevents *in-place* writes. Deleting/recreating the file (an atomic write-then-rename, which is what OpenClaw's `edit` tool appears to do) only needs write permission on the *parent directory* (`/sandbox/workspace`, owned by `sandbox`, mode `700`), bypassing the file-level `chmod 444` entirely — confirmed live with `rm AGENTS.md && echo hacked > AGENTS.md` as the real `sandbox` user. Also confirmed this defeats a file-level Landlock `read_only` policy entry added via `openshell policy set`, for the same reason (remove permission is directory-scoped, not file-scoped).

**Also checked**: OpenClaw's config schema (`openclaw config schema`) has no per-path read-only/deny option for its filesystem tools (`read`/`write`/`edit`/`apply_patch`) — only a whole-workspace `tools.fs.workspaceOnly` boolean. No native OpenClaw feature currently solves this.

**Decision (2026-08-03): accepted risk, deferred.** Not fixing now.

- [ ] Move `AGENTS.md`/`SOUL.md`/`TOOLS.md`/`IDENTITY.md`/`USER.md`/`HEARTBEAT.md`/`BOOTSTRAP.md` into a subdirectory `sandbox` cannot write to (e.g. `root:root` mode `555`, or that subdirectory path added to `filesystem_policy.read_only`) so the *parent directory* itself denies unlink/rename, not just the file mode
- [ ] Verify OpenClaw's startup-context loader can still find these files if relocated (symlinks from `/sandbox/workspace/*.md` into the protected subdir, or a config option pointing at a custom prompt directory)
- [ ] Add a real write/delete attempt (not just a `stat` mode check) to `scripts/verify.sh` Layer 8b, mirroring the existing Landlock write-test pattern already used for `/sandbox/.openclaw/`
- [ ] Re-run the live repro from `docs/constraints.md` #24 against the fix to confirm both the in-place-write AND unlink+recreate vectors are blocked

## Phase 14: Declarative Simplification + Shared-Cluster Coexistence

**Status: COMPLETE** — Objective: port back the declarative patterns learned while building `agentops-example` from this project's stack, replacing imperative `oc`/script steps with Helm-native mechanisms, and enable both projects to coexist on one OCP cluster without losing or changing existing functionality (in particular, `trusted-proxy` auth stays untouched — no regression to a static gateway token).

- [x] **Declarative OpenShell wrapper chart** (`charts/openshell/`): SCC `RoleBinding` and gRPC `Route` now ship as Helm templates instead of `scripts/common.sh`'s `grant_privileged_scc()` and `manifests/openshell-route.yaml`'s `oc apply`. `helm uninstall` now cleanly removes them too. Decision: [ADR-0019](docs/adrs/ADR-0019-declarative-openshell-wrapper-chart.md)
- [x] **MLflow RBAC auto-detection**: the `mlflow-integration` `ClusterRole` lookup (previously `oc get clusterroles` in `scripts/wire-rhoai-mlflow-tracing.sh`) is now a Helm `lookup` call inside the chart template
- [x] **`openclaw-mlflow-integration` standalone chart** (`charts/rhoai/openclaw-integration/`): RBAC, SA-token Secret, and experiment-creation Job extracted out of the shared `rhoai-mlflow` release into their own release, so re-running `wire-rhoai-mlflow-tracing.sh` (or a second project's install) can no longer reset `openclawIntegration.enabled` and delete tokens on the shared release
- [x] **Detect-and-skip for shared RHOAI/MLflow** (`charts/rhoai/Makefile`): each target (`deploy-operators`, `deploy-platform`, `deploy-database`, `deploy-mlflow`) checks `helm status` first and skips if already installed by another project on the same cluster; `ensure-mlflowoperator-managed` idempotently patches the shared `DataScienceCluster` without disturbing other components
- [x] **Namespace/`SANDBOX_NAME` parametrization**: oauth2-proxy's Route host and CORS `allowedOrigins`, and the OpenClaw config's `allowedOrigins`, now derive from `${SANDBOX_NAME}`/`__SANDBOX_NAME__` instead of a hardcoded `openclaw-gw`, so a second coexisting deployment can pick a different sandbox name and namespace without a hostname collision
- [x] **Cursor governance ported**: `.cursor/rules/` (`adr-alignment`, `documentation-sources`, `no-secrets`, `technology-usage-docs`) and `.cursor/skills/` (`adr`, `no-secrets`, `document-feature`, `create-pr`) adapted from `agentops-example` to this repo's doc structure (`docs/adrs/`, `README.md` ADR index, `docs/constraints.md`)
- [x] ADR-0020: shared-cluster coexistence strategy (namespaces, hostnames, detect-and-skip, what stays independent per project)
- [x] Confirmed **no functional regression**: `trusted-proxy` auth (ADR-0012) is unchanged — this project already had no static gateway token, unlike `agentops-example`, which had regressed to `auth.mode: "none"` for unrelated environment reasons and was explicitly left untouched by this work
- [ ] Cluster validation: `helm lint`/`helm template` for `charts/openshell` and `charts/rhoai/openclaw-integration`, then a full solo `crc-lifecycle.sh full --fresh` smoke test
- [ ] Coexistence validation: deploy this project with an alternate `NAMESPACE`/`SANDBOX_NAME` on a cluster where `agentops-example` is already live; confirm both UIs, both CLIs, and both MLflow trace streams work simultaneously

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

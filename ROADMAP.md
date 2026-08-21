# Deployment Roadmap

OpenClaw running inside an OpenShell sandbox on OpenShift Container Platform, using Red Hat MaaS (LiteLLM) for Claude Sonnet 4.6 inference.

Supports both AWS OCP clusters and local CRC (CodeReady Containers) for development.

## Pinned Versions

| Component | Version | Source |
|---|---|---|
| OpenShell Helm chart | `0.0.83` | `oci://ghcr.io/nvidia/openshell/helm-chart` |
| OpenShell gateway/supervisor | `0.0.83` | `ghcr.io/nvidia/openshell/gateway:0.0.83` |
| OpenClaw sandbox image | `latest` | `ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest` |
| Agent Sandbox operator (OLM) | channel `preview-0.9`, CSV `agent-sandbox-operator.v0.9.0` | package `agent-sandbox-operator`, ns `agent-sandbox-system` (OSC 1.13 TP); own Helm chart `charts/agent-sandbox/`, not shared with `agentops-example`; CRC fallback: `manifests/agent-sandbox-v0.5.1.yaml` |
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
- [x] ADR-0004: Red Hat build of Agent Sandbox Operator (OLM `agent-sandbox-operator`, channel `preview-0.9`; CRC raw-manifest fallback)
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
- [x] Install Agent Sandbox operator via its own Helm chart (`charts/agent-sandbox/`, OLM `agent-sandbox-operator`, channel `preview-0.9` / CSV `v0.9.0` on OCP; CRC still uses raw `manifests/agent-sandbox-v0.5.1.yaml` fallback — see open item below)
- [x] Approve InstallPlan manually
- [x] Grant `privileged` SCC to `openshell-sandbox` SA
- [x] Generate Ed25519 JWT signing secret
- [x] Verify `sandboxes.agents.x-k8s.io` CRD is available
- [x] **Validate whether the CRC raw-manifest fallback can also be dropped** — deferred to [Phase 18.2](#182-agent-sandbox-operator--drop-raw-manifest-fallback-on-crc) (CRC-only follow-up; OLM path works on full OCP clusters today)

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
2. `scripts/cluster-lifecycle.sh`'s `cmd_deploy()` therefore always runs Phase 5 (`deploy-openshell.sh`) with `WITH_OIDC=false` (using `values-ocp-no-oidc.yaml.tpl`, `allowUnauthenticatedUsers: true`), regardless of whether `--with-oidc` was passed to `cluster-lifecycle.sh` itself.
3. Only in Phase 7, if `--with-oidc` was requested, does `configure-oidc.sh` create the `openshell-oidc-ca` ConfigMap and then `helm upgrade` the *same* release with `values-ocp.yaml.tpl` (the OIDC overlay), flipping `allowUnauthenticatedUsers` to `false` and enabling Keycloak-backed JWT auth on the gateway.

Net effect: on a `--with-oidc` deploy, the no-OIDC state only exists briefly between Phase 5 and Phase 7 — the final, steady state has Keycloak enforced. It only remains the *permanent* state when deploying without `--with-oidc` (e.g. `cluster-lifecycle.sh deploy` with no flags, or `full --minimal`), which is a deliberately lighter, unauthenticated-CLI profile, not the recommended default.

**If this two-step bootstrap is ever changed** (e.g. by having the chart tolerate a missing `caConfigMapName` at install time, or by pre-creating the ConfigMap earlier in `bootstrap-ocp.sh`), update this section, the header comments in both `charts/openshell/values-ocp.yaml.tpl` / `values-ocp-no-oidc.yaml.tpl`, and `scripts/cluster-lifecycle.sh`'s Phase 5 comment together — they currently all describe the same mechanism and would otherwise drift out of sync.

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

**Status: BLOCKED** — upstream JS SDK issue (see ADR-0014 Problem 9).

The MLflow Python API (`mlflow.genai.scorers`) provides session-level judges
(`ConversationCompleteness`, `UserFrustration`, `KnowledgeRetention`, etc.)
since MLflow 3.7.0. Combined with `prompt_versions` tags (set by
`prompt-trace-linker.js`), this would enable quality evaluation per prompt
version:

```python
import mlflow
from mlflow.genai.scorers import ConversationCompleteness, UserFrustration

traces = mlflow.search_traces(
    experiment_ids=["<experiment-id>"],
    filter_string='tag.prompt_versions LIKE "%SOUL:3%"',
    return_type="list",
)
results = mlflow.genai.evaluate(
    data=traces,
    scorers=[
        ConversationCompleteness(model="openai:/gpt-4o-mini"),
        UserFrustration(model="openai:/gpt-4o-mini"),
    ],
)
```

**Blocker:** `@mlflow/core` JS SDK v0.2.0 writes `mlflow.trace.session` as a
**span attribute** (inside `traces.json` artifact), not as **trace metadata**
(in the DB). `mlflow.genai.evaluate` groups sessions by
`metadata["mlflow.trace.session"]` — without it, multi-turn scorers produce
no results.

**Revisit when:**
- `@mlflow/core` >= 0.3.x adds metadata support to `POST /api/3.0/mlflow/traces`
- Or RHOAI MLflow bumps the JS SDK dependency

**Workaround (if urgent):** extend `patch-mlflow-plugin.py` to inject
`metadata: {"mlflow.trace.session": sessionKey, "mlflow.trace.user": userId}`
into the trace creation payload. The patching infrastructure already exists.

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

- [ ] **Blocked**: inject a static `x-openclaw-scopes: operator.write` header from the proxy to cap all proxied Control UI sessions. Investigated and found infeasible with the current stack: `registry.redhat.io/openshift4/ose-oauth-proxy` (see [charts/oauth2-proxy/templates/deployment.yaml](charts/oauth2-proxy/templates/deployment.yaml)) only forwards identity headers it already derives from the IdP (`x-forwarded-user`, `x-forwarded-email`, `x-forwarded-preferred-username` via `--pass-user-headers=true`); it has no flag to inject an arbitrary static header. Implementing this would require either patching/forking `oauth-proxy` or adding a header-rewriting sidecar between it and the OpenShell relay — disproportionate for this phase, and risky given ADR-0016 already documents this fork as fragile (the WebSocket/Host-header bug it had to work around). Revisit if/when the proxy is replaced (e.g. `kube-auth-proxy`, noted as a non-blocking follow-up in ADR-0016) with something that supports custom header injection.
- [ ] **Follow-up investigation (not scheduled)**: re-verify the actual runtime behavior of `gateway.controlUi.dangerouslyDisableDeviceAuth: true` (set in [config/openclaw.json.tpl](config/openclaw.json.tpl), documented in [ADR-0012](docs/adrs/ADR-0012-trusted-proxy-auth.md)) against the currently deployed OpenClaw 2026.7.1 gateway. Current OpenClaw docs describe this key as a retired break-glass/migration setting rather than a persistently supported config, which may mean device-less trusted-proxy sessions today behave differently (e.g. scopes cleared to `[]` by default) than what ADR-0012 assumed. This is a deeper auth-architecture question, out of scope for "reduce UI surface."
- [ ] **Follow-up investigation (not scheduled)**: periodically check whether the sandbox base image (Agent Sandbox Operator's image and/or `ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest`) ships Node.js `>=22.22.3` natively. `launch-openclaw.sh`'s Step 2 (`npm install -g n && n 22.22.3`) exists solely to work around the current base image's older Node.js — and that step's own `npm install -g n` is itself unpinned (no `n@<version>`, resolves whatever is "latest" on the npm registry at exec time), the same unpinned-npm-install failure mode ADR-0006 (in the sibling `agentops-example` project) already hit once for the `openclaw` package itself. Once the base image ships a compatible Node.js out of the box, remove Step 2 entirely (and the binary-relocation workaround it required in [docs/constraints.md](docs/constraints.md) constraint #2), closing off this unpinned dependency.

## Phase 10 (very low priority): Custom Sandbox Image

**Status: DEFERRED — expecting community fix.** The upstream OpenShell/OpenClaw community is expected to ship a sandbox base image that includes a compatible Node.js and pre-baked configuration, making this custom-image work unnecessary. Revisit only if the community does not deliver within a reasonable timeframe.

- [ ] Build Dockerfile extending OpenShell base with Node.js + OpenClaw
- [ ] Pre-bake `openclaw.json` configuration
- [ ] Push to internal registry (Quay/OpenShift internal)
- [ ] Update `values-ocp.yaml` with custom sandbox image

## Phase 11 (deprioritized): Policy Refinement

- [ ] Start with `enforcement: audit` for new endpoints
- [ ] Review deny logs: `openshell logs openclaw-gw --level warn`
- [ ] Add npm/PyPI endpoints if OpenClaw tools need them
- [ ] Switch to `enforcement: enforce` after validation
- [ ] Implement credential rotation procedure
- [x] ~~Migrate inference routing to `inference.local` + `model='router'` alias~~ (see 11.1 below)

### 11.1 Migrate to OpenShell Inference Router (`inference.local`) — COMPLETE

**Status: COMPLETE** — See [ADR-0021](docs/adrs/ADR-0021-inference-router-migration.md).

All LLM traffic now routes through OpenShell's inference router (`inference.local`). The agent code is provider-agnostic: `baseUrl: https://inference.local/v1`, `model: router`. The real API key lives in the gateway's provider record; the sandbox process uses `apiKey: "unused"`.

**Completed**:
- [x] Enable `providers_v2_enabled` on the gateway
- [x] Re-register MaaS provider with `--type openai` (v2-compatible)
- [x] Configure inference route: `openshell inference set --provider maas-litellm --model claude-sonnet-4-6`
- [x] Update `config/openclaw.json.tpl` to `inference.local/v1`, `model: router`
- [x] Remove `maas_inference` network policy block from `openclaw-sandbox.yaml`
- [x] Remove `LITELLM_API_KEY` env injection from `launch-openclaw.sh`
- [x] Update `verify.sh` layers 2, 4, 5, 5b for inference router checks
- [x] Add inference router smoke test (Layer 5c, disposable sandbox + OpenAI SDK)
- [x] Update Playwright tests (`openclaw-ui.spec.ts`, `sandbox-security.spec.ts`)
- [x] Create `docs/AGENT-SANDBOX-AND-OPENSHELL.md` with inference routing section

**Future work**:
- Declarative provider configuration via Helm values — not yet available upstream. Tracked at [NVIDIA/OpenShell#1886](https://github.com/NVIDIA/OpenShell/issues/1886). When available, `create_provider()` and `configure_inference_route()` in `scripts/common.sh` can be replaced with Helm values in `charts/openshell/values.yaml`.
- Multi-provider inference routing (path-based: `inference.local/openai/...` vs `inference.local/anthropic/...`) — tracked at [NVIDIA/OpenShell#896](https://github.com/NVIDIA/OpenShell/issues/896). Would allow per-sandbox model selection.

### 11.2 OCSF Audit Event Assertions in `verify.sh` — COMPLETE

**Context**: The upstream [opendatahub-io/agent-ops](https://github.com/opendatahub-io/agent-ops) guides highlight `openshell logs <sandbox> --source sandbox|gateway` and `openshell term` for live OCSF event streaming — every network policy verdict (ALLOWED/DENIED), the binary that made the connection, the destination endpoint, and which policy engine made the decision are recorded as structured OCSF `HttpActivity` events. Previously `verify.sh` Layer 4 tested that egress was *blocked* (curl returns 403/timeout) but did not verify that the corresponding DENIED OCSF event was actually recorded in the audit trail.

**Benefits**:
- Validates the full observability chain end-to-end: policy enforcement happened AND the audit trail captured it
- Catches silent audit failures (policy works but logging is broken — the sandbox is secure but the operator has no visibility)
- Aligns with compliance requirements where audit evidence must be independently verifiable

**Completed**:
- [x] After the existing Layer 4 egress-denied test (`curl github.com` → blocked), query `openshell logs $SANDBOX_NAME --source sandbox` and assert a DENIED event exists for the blocked destination
- [x] After the existing Layer 4 inference.local-allowed test, assert an ALLOWED event exists for the inference endpoint
- [x] Runs in both `full` and `smoke` profiles (the `openshell logs` call is fast — no sandbox exec required)
- [x] Document expected OCSF event format in `docs/constraints.md` (constraint #28)

## Phase 12: Migrate to RHOAI-managed MLflow

**Status: COMPLETE** — Objective: Replace standalone MLflow (observability namespace) with RHOAI's shared MLflow instance while preserving the rich `@mlflow/mlflow-openclaw` plugin traces.

Reference: [agentic-starter-kits mlflow-tracing overlay](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/agents/openclaw/deployment/docs/mlflow-tracing.md)

### Environment scope: from CRC-as-standalone-experiment to sole backend everywhere

Decision history: **[ADR-0017](docs/adrs/ADR-0017-rhoai-mlflow-scope.md)** (empirical CRC validation + original opt-in scope, 2026-07-24) → **[ADR-0018](docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)** (full migration decision, 2026-07-25). Summary:
- RHOAI + a minimal MLflow-only `DataScienceCluster` **alone** fits comfortably on a 16 vCPU / 40 GiB CRC VM (host stayed at 18 GiB free out of 62 GiB total).
- Combined with the rest of the OpenShell + OpenClaw stack, host free memory drops to ~11 GiB and swap engages — functionally fine (no crashes, no pod evictions) but below this project's usual safety margin. **This is now an accepted trade-off**, not a reason to keep two backends (ADR-0018).
- All three real integration blockers found while wiring the `mlflow-openclaw` plugin to RHOAI MLflow (Node-side TLS trust conflict with the OpenShell sandbox proxy, a hostname-matching bug in the `tls: skip` policy, and the pinned SDK missing the `X-MLFLOW-WORKSPACE` header) were root-caused and fixed for real — see ADR-0017's "Follow-up"/"Resolution" sections and `docs/constraints.md` #4b-#4e.
- End-to-end validated live: a real chat message produced a real trace in RHOAI MLflow, picked up and tagged by `prompt-trace-linker.js` on its next poll cycle, with the MaaS chat path unaffected throughout.
- **Result**: standalone MLflow was removed entirely (see Phase 12b below); RHOAI-managed MLflow (`charts/rhoai/`) is the sole tracing/prompt-registry backend on every environment, wired unconditionally into `cluster-lifecycle.sh`.

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
- [x] `scripts/cluster-lifecycle.sh`: make `deploy-rhoai-mlflow.sh` + `wire-rhoai-mlflow-tracing.sh` unconditional steps in `cmd_deploy`/`cmd_full`
- [x] `scripts/launch-openclaw.sh`: make RHOAI MLflow wiring unconditional (drop the `--rhoai-mlflow` flag)
- [x] `scripts/test-tracing.sh`, `scripts/smoke-test-e2e.sh`, `scripts/verify.sh`: point all MLflow checks at RHOAI's Route/namespace with proper auth; drop SQLite-specific introspection (RHOAI's MLflow runs on Postgres, no local DB file to open)
- [x] ADR-0014, ADR-0015 marked Superseded; ADR-0017 scope-decision section updated; ADR-0018 created
- [x] `ROADMAP.md`: this section, plus closing out Phase 12 and marking 13.3 obsolete
- [x] `docs/constraints.md`: constraint #4b marked Resolved with the real fix
- [x] `docs/constraints.md`: constraint #12 and other standalone-MLflow-specific references reviewed; constraint #10 (deploy ordering) updated for the new mandatory RHOAI phases; new constraint #17 documents an unrelated live-testing finding (verify.sh's synthetic chatCompletions test is a pre-existing false-positive, not an RHOAI MLflow regression)
- [x] `README.md` + skills (`deploy-full-aws`, `deploy-full-crc`, `crc-local-dev`, `monitor-deployment`) updated to remove standalone MLflow references; CRC sizing bumped to 16 vCPU/40 GiB (RHOAI-validated, `scripts/cluster-lifecycle.sh`)
- [x] `prompts/TOOLS.md` (and any other prompt file referencing the MLflow endpoint) updated

## Phase 12c (future): Revisit starter-kits MLflow auth/TLS alignment

**Status**: Not started — review later. Do **not** switch the OpenClaw trace path to their OTel collector sidecar.

Source: [MLflow on OpenShift: Authentication and TLS](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/docs/mlflow-openshift-auth-and-tls.md) (RHDS agentic-starter-kits). OpenClaw-specific overlay: [mlflow-tracing.md](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/agents/openclaw/deployment/docs/mlflow-tracing.md) (already compared in [Phase 12](#phase-12-migrate-to-rhoai-managed-mlflow)).

Phase 12 already chose `@mlflow/mlflow-openclaw` over `diagnostics-otel` + sidecar so Gen AI Studio keeps full Request/Response content. That decision stands. This phase is only about whether to tighten **auth/TLS** toward the official TS-SDK workarounds in that guide — the closer analog is their **claude-code** path, not their OpenClaw overlay.

**Already aligned** (no action):

- Internal service URL `https://mlflow.redhat-ods-applications.svc:8443`
- Workspace = namespace + `X-MLFLOW-WORKSPACE`
- `mlflow-integration` ClusterRole + RoleBinding
- TS SDK gaps: inject `MLFLOW_TRACKING_TOKEN` + `MLFLOW_WORKSPACE`; TLS via `NODE_EXTRA_CA_CERTS` (combined OpenShell proxy CA + service-ca, constraint #4c). This project does **not** set `NODE_TLS_REJECT_UNAUTHORIZED=0` (the guide marks that as avoid-in-production)

**What to review later** (adopt only if it reduces patches / blast radius without losing traces):

- [ ] Re-read the starter-kits auth/TLS doc and TS SDK section against the current `@mlflow/mlflow-openclaw` + `@mlflow/core` pins
- [ ] Token lifetime: keep the long-lived `kubernetes.io/service-account-token` Secret vs projected SA token / short-lived `oc create token` (sandbox may not mount the well-known SA paths like a normal pod)
- [ ] Dedicated tracing SA (`openclaw-tracing` in the starter-kits overlay) vs binding `openshell-sandbox` — only if other workloads share that SA
- [ ] Drop `scripts/patch-mlflow-plugin.py` once `@mlflow/core` >= 0.3.0 ships `X-MLFLOW-WORKSPACE` natively (same trigger as [Phase 8b multi-turn evaluation](#future-multi-turn-evaluation-by-prompt-version))
- [ ] Confirm we still should **not** copy the OpenClaw OTel sidecar (starter-kits themselves document missing tool I/O, token counts, and session IDs)

**Trigger to revisit** (not on a recurring cadence): `@mlflow/core` / `mlflow-openclaw` bump, RHOAI MLflow workspace auth change, or a sibling project (`agentops-example`) dropping the compatibility patches.

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

### 13.4 Review: plaintext MaaS API key on disk (resolved)

Security review found the raw MaaS API key readable by agent tools (`echo $LITELLM_API_KEY`,
config files on disk). Root cause: the credential was materialized inside the sandbox,
where Landlock and `tools.deny` cannot path-scope deny access. **Resolved** by the
inference router migration (ADR-0021). Historical detail: constraints #3, #25, #26 in
`docs/constraints.md`.

**Solution applied**

1. **Inference router (ADR-0021)** — `apiKey` in sandbox config is `"unused"`; `LITELLM_API_KEY` is no longer injected into the sandbox. The real credential lives only in the gateway provider record and is injected by the inference router at the gateway layer. This also eliminates the intermediate SecretRef-era `models.json` cache leak (constraint #26): OpenClaw no longer resolves a real key into sandbox-writable paths.
2. **Security tests** — Playwright jailbreak/credential-leak suite in `verify.sh` Layer 9 (`tests/sandbox-security.spec.ts`, one fresh session per test).
3. **Gateway lifecycle** — `launch-openclaw.sh` kills stale gateways via `openshell sandbox exec` (same PID namespace); Layer 9 fails if a security-test session used a model other than the configured primary (model-drift guard).
4. **Credential scanning** — `verify.sh` Layer 4 (`CRED_RO`/`CRED_WS`) scans sandbox files for `sk-…` patterns as a regression guard against accidental credential materialization.
5. **Check infrastructure** — Fixed `sandbox_run()` PTY echo that caused several Layer 4/5b/9 checks to report false passes (constraint #25).

**Future improvements (defense-in-depth, not open gaps)**

- [ ] [Phase 16.1](#161-consume-platform-workload-identity-spiffespire): SPIFFE/SPIRE workload identity — replace the gateway's static provider credential with auto-rotated, narrowly-scoped tokens
- [ ] Upstream redaction of free-form assistant text, not just tool payloads (deprioritized — not an observed failure mode with the primary model)

### 13.5 Re-audit `OPENSHELL_GATEWAY_INSECURE` scoping when AWS OCP gets real certs (resolved)

**Status: COMPLETE** — CRC workaround scoped; AWS validated as no-op. CRC-only polish tracked in [Phase 18](#phase-18-future-crc-local-dev-improvements).

**Context**: `scripts/common.sh`'s `detect_environment()` used to export
`OPENSHELL_GATEWAY_INSECURE=true` (skip TLS server-cert verification for the
`openshell` CLI) globally whenever `CRC_MODE=true`, to work around CRC's
self-signed router wildcard cert not being in the system trust store
(constraint #18). During a live `cluster-lifecycle.sh full --fresh` run
(2026-07-27), this was found to also break **mTLS gateway registration**
(`openshell status` failing for 5+ minutes with `CertificateRequired`/"peer
sent no certificates") — the blanket global export was scoped down to a new
`enable_openshell_oidc_insecure()` helper, called only from the OIDC-specific
code paths (`configure-oidc.sh`'s gateway re-registration,
`ensure_oidc_token()`'s refresh calls), and explicitly `unset` before mTLS
operations in `deploy-openshell.sh`.

**Solution applied**

1. **OIDC-only scoping (2026-07-27)** — `enable_openshell_oidc_insecure()` exports `OPENSHELL_GATEWAY_INSECURE=true` only when `CRC_MODE=true` and only from OIDC refresh paths; `deploy-openshell.sh` explicitly `unset`s it before mTLS gateway registration.
2. **AWS re-audit (2026-08-03)** — on a real AWS OCP cluster (`sandbox659.opentlc.com`, Let's Encrypt router wildcard cert), `OPENSHELL_GATEWAY_INSECURE` was never set during a full `cluster-lifecycle.sh deploy --with-oidc --with-obs` + `verify.sh` run. mTLS registration, `openshell status`, OIDC token refresh, and oauth-proxy OAuth login all passed with zero TLS trust issues. No AWS-side changes needed.

- [x] Scope `OPENSHELL_GATEWAY_INSECURE` to OIDC-only flows, unset it before mTLS gateway registration (`scripts/common.sh`, `scripts/deploy-openshell.sh`, `scripts/configure-oidc.sh`) — done 2026-07-27, still `CRC_MODE`-gated, never set on AWS
- [x] AWS follow-up — confirmed 2026-08-03: workaround is a complete no-op on AWS (Let's Encrypt chain needs no special handling)

**CRC-only follow-ups** — moved to [Phase 18.1](#181-tls-trust--replace-openshell_gateway_insecure-with-router-ca-import)

### 13.6 Prompt file "read-only" protection (`chmod 444`) is bypassable — needs a directory-level fix

Discovered from a real chat-session report (the agent successfully edited `AGENTS.md` via its `edit` tool despite the file being `chown root:root` + `chmod 444`) and confirmed live against the running sandbox — see [`docs/constraints.md` #24](docs/constraints.md) for the full root-cause analysis and reproduction steps.

**Root cause**: the lock only prevents *in-place* writes. Deleting/recreating the file (an atomic write-then-rename, which is what OpenClaw's `edit` tool appears to do) only needs write permission on the *parent directory* (`/sandbox/workspace`, owned by `sandbox`, mode `700`), bypassing the file-level `chmod 444` entirely — confirmed live with `rm AGENTS.md && echo hacked > AGENTS.md` as the real `sandbox` user. Also confirmed this defeats a file-level Landlock `read_only` policy entry added via `openshell policy set`, for the same reason (remove permission is directory-scoped, not file-scoped).

**Also checked**: OpenClaw's config schema (`openclaw config schema`) has no per-path read-only/deny option for its filesystem tools (`read`/`write`/`edit`/`apply_patch`) — only a whole-workspace `tools.fs.workspaceOnly` boolean. No native OpenClaw feature currently solves this.

**Decision (2026-08-03): accepted risk, deferred.** Not fixing now.

- [ ] Move `AGENTS.md`/`SOUL.md`/`TOOLS.md`/`IDENTITY.md`/`USER.md`/`HEARTBEAT.md`/`BOOTSTRAP.md` into a subdirectory `sandbox` cannot write to (e.g. `root:root` mode `555`, or that subdirectory path added to `filesystem_policy.read_only`) so the *parent directory* itself denies unlink/rename, not just the file mode
- [ ] Verify OpenClaw's startup-context loader can still find these files if relocated (symlinks from `/sandbox/workspace/*.md` into the protected subdir, or a config option pointing at a custom prompt directory)
- [ ] Add a real write/delete attempt (not just a `stat` mode check) to `scripts/verify.sh` Layer 8b, mirroring the existing Landlock write-test pattern already used for `/sandbox/.openclaw/`
- [ ] Re-run the live repro from `docs/constraints.md` #24 against the fix to confirm both the in-place-write AND unlink+recreate vectors are blocked

### 13.7 Revisit oauth-proxy WebSocket Host-header bug (upstream fix watch)

**Context**: ADR-0016 documents a bug in `openshift/oauth-proxy` where
`--pass-host-header=false` is never applied to WebSocket connections (the
`wsutil`-based proxy path). The community `oauth2-proxy` fixed this in
[PR #3290](https://github.com/oauth2-proxy/oauth2-proxy/pull/3290) (Jan
2026), but that fix has not been backported to `openshift/oauth-proxy` or
`opendatahub-io/kube-auth-proxy`. The current workaround (hostname
unification + `hostAliases` + explicit `:8080` upstream) works but is
fragile (deploy-time ClusterIP resolution, unfriendly hostname). See
ADR-0016 "WebSocket login failure" for full analysis.

**Trigger to revisit** (not on a recurring cadence):
1. `openshift/oauth-proxy` merges a fix for the WebSocket `passHostHeader`
   bug — check the repo's commit history / releases periodically
2. `opendatahub-io/kube-auth-proxy` resyncs with the community fix and
   becomes a viable drop-in replacement
3. If neither happens within ~6 months, consider Option A (build a custom
   patched image, ~15-line fix) or Option B (nginx `auth_request` split) from
   the investigation documented in this project's chat history

- [ ] Periodically check `openshift/oauth-proxy` for a WebSocket Host-header fix (watch repo releases or search for `passHostHeader` / `wsutil` changes)
- [ ] If fixed upstream: switch back to a friendly Route hostname (`openclaw-ui.<APPS_DOMAIN>`), remove `hostAliases`, set `--pass-host-header=false`
- [ ] If not fixed upstream within a reasonable window: evaluate building a custom patched image (Option A) or nginx auth_request split (Option B)

### 13.8 Privileged SCC — verdict and hardening path

**Context**: [ADR-0006](docs/adrs/ADR-0006-scc-privileged-sandbox.md) documents the intentional paradox — OpenShell's supervisor needs `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, and related capabilities to build the restrictive sandbox (nftables egress, Landlock, network namespaces) that constrains agent processes, while OpenShift's default `restricted-v2` SCC blocks those capabilities. The current fix grants the full `system:openshift:scc:privileged` SCC to the `openshell-sandbox` ServiceAccount only (gateway stays on `restricted-v2`), declared declaratively in `charts/openshell/templates/scc-rolebinding.yaml`.

**Verdict**

For an evaluation/workshop cluster on a private network (the context of this project and the sibling `agentops-example` / `rhoai-platform-ops` stack), this is a reasonable and honestly documented trade-off — consistent with what NVIDIA itself recommends for the OpenShift install path (experimental, privileged SCC required, evaluation only).

For a truly hardened or multi-tenant environment, **do not leave it as-is**. The `privileged` SCC grants far more than the four capabilities OpenShell actually needs (`SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, `SYSLOG`) — it allows `allowedCapabilities: ["*"]`, privileged containers, host namespaces, and hostPath volumes. Improve in this order of effort:

- [ ] **Custom SCC** — replace `system:openshift:scc:privileged` with a project-owned SCC that only allows `allowedCapabilities: [SYS_ADMIN, NET_ADMIN, SYS_PTRACE, SYSLOG]`, with `allowPrivilegedContainer: false` and no host namespaces/hostPath. Follows the standard OpenShift pattern: do not use `privileged` when you only need specific capabilities.
- [ ] **Sidecar topology** — evaluate OpenShell's `supervisor.topology: sidecar` ([upstream docs](https://docs.nvidia.com/openshell/kubernetes/topology)): the agent container runs with `capabilities.drop: ["ALL"]`; only a short-lived network-init container needs setup capabilities (`NET_ADMIN`, `NET_RAW`, `CHOWN`, `FOWNER`). Easier to justify with a narrow custom SCC than the combined topology this project uses today.
- [ ] **User namespaces** — enable `server.enableUserNamespaces: true` (or Helm equivalent) so elevated capabilities are namespaced and do not translate to host-level power. OpenShell documents this as defense-in-depth on Kubernetes 1.33+; not currently set in `charts/openshell/values-ocp.yaml.tpl`.
- [ ] **RuntimeClass (Kata/microVM)** — since this project already depends on the Agent Sandbox Operator, evaluate a Kata (or similar) `RuntimeClass` so the privileged sandbox pod does not share the node kernel. Overlaps with [Phase 16.3](#163-ring-3--kata-containers--runtimeclass-for-the-sandbox-pod); track the SCC-hardening angle here, the blueprint Ring 3 angle there.

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
- [ ] Cluster validation: `helm lint`/`helm template` for `charts/openshell` and `charts/rhoai/openclaw-integration`, then a full solo `cluster-lifecycle.sh full --fresh` smoke test
- [ ] Coexistence validation: deploy this project with an alternate `NAMESPACE`/`SANDBOX_NAME` on a cluster where `agentops-example` is already live; confirm both UIs, both CLIs, and both MLflow trace streams work simultaneously

## Phase 15 (future): OpenShell Gateway Backend — PostgreSQL + Deployment

**Context**: Found while comparing this project against a related OpenShell/OpenCode
reference demo ([r3v5/agent-ops, `opencode-vertex-tracing`](https://github.com/r3v5/agent-ops/tree/opencode-in-openshell-with-mlflow-on-openshift-demo/demos/opencode-vertex-tracing) —
same underlying `ghcr.io/nvidia/openshell` product). That demo runs the OpenShell gateway as
a stateless `Deployment` backed by an external PostgreSQL 16 database
(`server.externalDbSecret`), instead of the chart's default `StatefulSet` + per-pod SQLite PVC
this project currently uses ([`charts/openshell/values.yaml`](charts/openshell/values.yaml) —
`workload.kind: statefulset`, no `externalDbSecret`).

This project already runs a shared PostgreSQL 16 instance for RHOAI-managed MLflow
(`charts/rhoai/database/`, see Phase 12), so wiring the OpenShell gateway itself to the same
(or a sibling) Postgres instance reuses infrastructure already validated on both CRC and AWS
OCP, rather than adding a new stateful dependency.

**Benefits**:
- Stateless gateway: no per-pod PVC, easier to reason about across `helm upgrade` /
  redeploy cycles (this ROADMAP already documents several StatefulSet/PVC-related
  fragility findings — see ADR-0003-equivalent notes in `docs/constraints.md`)
- Matches the "production-like" backend used by the reference demo above
- Sets up future horizontal scaling of the gateway if ever needed (`replicaCount > 1`)

**Tasks**:
- [ ] Add an `openshell` database to `charts/rhoai/database/` (or provision a small dedicated
      PostgreSQL release if keeping the gateway DB isolated from RHOAI's is preferred)
- [ ] Create the connection-URI Secret that `server.externalDbSecret` expects
- [ ] Set `openshell.workload.kind: deployment` and `openshell.server.externalDbSecret:
      <secret-name>` in [`charts/openshell/values.yaml`](charts/openshell/values.yaml) (or the
      `values-ocp*.yaml.tpl` overlays, if the DB secret name needs to be environment-specific)
- [ ] Verify `scripts/deploy-rhoai-mlflow.sh` (or the new DB provisioning step) runs and is
      waited on before `scripts/deploy-openshell.sh`, mirroring the existing RHOAI-before-OpenShell
      ordering constraint this project already enforces
- [ ] Re-run `scripts/verify.sh` (Layer 2: OpenShell Gateway) against a Deployment-backed
      gateway on both CRC and AWS OCP — confirm sandbox create/exec, mTLS registration, and
      `mlflow-openclaw` tracing are unaffected
- [ ] Update `docs/constraints.md` and the relevant ADR (new or amended) with the decision and
      drop now-inaccurate "SQLite" references from docs/skills

## Phase 16 (future): Blueprint Alignment — Identity, Tool Governance, Ring 3

Source: [Architect an open blueprint for cloud-native AI agents](https://developers.redhat.com/articles/2026/07/20/architect-open-blueprint-cloud-native-ai-agents) (Red Hat Developer, 2026-07-20). This project already implements a large share of the article's blueprint — Helm-declarative agent packaging (`charts/openshell/`, [ADR-0019](docs/adrs/ADR-0019-declarative-openshell-wrapper-chart.md)), OpenClaw as the harness (named directly in the article's component table), and two of the three nested isolation rings (Ring 1: Landlock/seccomp via the OpenShell supervisor; Ring 2: SCC + `NetworkPolicy`), plus a full OTel/Tempo/MLflow audit trail matching the article's observability requirements. This phase closes the remaining gaps, most of which depend on new shared infrastructure landing in `rhoai-platform-ops` first (see that project's Phase 8: Agentic Platform Foundations, `docs/ROADMAP.md`) — this project is the consumer, not the owner, of workload identity and MCP tool governance, per the decision to keep those as shared platform services.

### 16.1 Consume platform Workload Identity (SPIFFE/SPIRE)

- **Blocked on**: `rhoai-platform-ops` Phase 8.1 (SPIRE server/agent deployment)
- Once available, migrate outbound calls from the gateway's static provider credential to a SPIFFE SVID + token exchange (RFC 8693/7523)
- Defense-in-depth for [item 13.4](#134-review-plaintext-maas-api-key-on-disk): the inference router already keeps credentials out of the sandbox; SPIFFE/SPIRE further shrinks blast radius by replacing the long-lived static key in the gateway provider record with auto-rotated workload identity
- Note this is orthogonal to the existing human-facing OIDC work (Keycloak/OCP OAuth, ADR-0010/ADR-0016): that authenticates the *user* opening the Control UI; SPIFFE/SPIRE would authenticate the *agent pod itself* for its own outbound calls
- Tasks (once unblocked):
  - [ ] Register this project's sandbox ServiceAccount with the shared SPIRE server (workload registration entry, selector on namespace + SA)
  - [ ] Add the SPIFFE authentication sidecar (or equivalent init pattern) to the sandbox pod spec
  - [ ] Update `create_provider()` / inference route to use the exchanged short-lived token instead of the static `MAAS_API_KEY`
  - [ ] Add SPIFFE identity + token exchange checks to `verify.sh`

### 16.2 Consume platform MCP Gateway for tool calls

- **Blocked on**: `rhoai-platform-ops` Phase 8.2 (Kuadrant/mcp-gateway deployment)
- Once available, any future OpenClaw MCP tool/skill configuration should point at the shared `MCP_URL` instead of (or in addition to) managing tool access purely via in-sandbox `tools.deny`/Landlock policy
- Defense-in-depth framing from the article: the MCP Gateway checkpoint authorizes by token claims and never reads the prompt, so a prompt-injection attack that tries to force an unauthorized tool call fails at the infrastructure layer, independent of the in-sandbox policy that already exists as a second layer
- Tasks (once unblocked):
  - [ ] Configure OpenClaw's MCP client (if/when MCP tools are added) to use the shared `MCP_URL`
  - [ ] Validate that the existing sandbox network policy (`policies/openclaw-sandbox.yaml`) allows egress to the gateway endpoint
  - [ ] Add a verify.sh check that an unauthorized tool call is rejected by the gateway (claims-based), not just by in-sandbox policy

### 16.3 Ring 3 — Kata Containers / RuntimeClass for the sandbox pod

- The Agent Sandbox operator this project pins (Red Hat build of Agent Sandbox, OSC 1.13, [ADR-0004](docs/adrs/ADR-0004-agent-sandbox-redhat.md)) supports an optional Kata microVM boundary via `RuntimeClass` — not yet enabled here
- Enabling it closes the last of the article's three nested isolation rings for this project: Ring 1 (process, done), Ring 2 (pod, done), Ring 3 (hardware/VM, not yet enabled)
- Tasks:
  - [ ] Confirm Kata `RuntimeClass` availability on target clusters (AWS OCP and CRC — CRC support for Kata/nested virtualization needs explicit validation, may not be feasible there)
  - [ ] Evaluate performance/resource overhead of the microVM boundary per sandbox pod before enabling by default
  - [ ] If validated: set `runtimeClassName` on the sandbox pod template, update ADR-0004 with the decision
  - [ ] Add a `verify.sh` check confirming the sandbox pod actually runs under the Kata runtime when enabled

### 16.4 Skill backend pattern (job placement)

- The article's job-placement model (Table 3: in-pod / service-call / job-dispatch) assumes skills are thin definitions and clients, not compute hosted inside the agent pod — a habit it explicitly calls out as a common design mistake carried over from library-based development
- This project has no formal "skill backend" yet; introduce one example as an out-of-pod MCP service (Pattern 2: service call, enforced by the MCP Gateway + egress policy from 16.2) to validate the location-agnostic model before any real skill is added
- Tasks:
  - [ ] Pick a low-risk example skill (e.g. a simple read-only lookup service) and deploy it as a separate pod/service, not sandbox-internal logic
  - [ ] Wire it through the MCP Gateway (16.2) rather than a direct network-policy allow rule
  - [ ] Document the pattern in `docs/` so future skills default to service-call placement instead of growing inside the sandbox

### 16.5 Adversarial and behavioral evaluation hookup

**Status**: Not started — planning only.

**Context**: `rhoai-platform-ops`'s evaluation module already runs Garak-based adversarial scans (via EvalHub) but nothing today points them at this project's actual attack surface (OpenClaw's system prompts, tool configuration, jailbreak resistance). This project already has Playwright jailbreak/exfiltration tests (`tests/sandbox-security.spec.ts`, `verify.sh` Layer 9) — they validate the real Control UI flow but are slow, non-deterministic (LLM variance), and not integrated with MLflow or EvalHub job history.

Reference: [agentic-starter-kits `evalhub_adapter`](https://github.com/red-hat-data-services/agentic-starter-kits/tree/main/evals/evalhub_adapter) — a BYOF (Bring Your Own Framework) EvalHub provider that runs behavioral scorers against agent HTTP endpoints and logs aggregated results to MLflow. Same upstream family as the [mlflow-tracing overlay](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/agents/openclaw/deployment/docs/mlflow-tracing.md) already adopted in Phase 12.

**Three evaluation layers** (complementary, not interchangeable):

| Layer | What it tests | Where it runs today | Gap |
|---|---|---|---|
| **Model** (Garak via EvalHub) | Raw LLM vulnerability (prompt injection, jailbreak probes) | `rhoai-platform-ops` `make evalhub-security` | Not pointed at OpenClaw's configured model route |
| **Agent** (behavioral harness) | Full stack: system prompts + `tools.deny` + sandbox policy + agent responses | Not implemented | `evalhub_adapter` pattern fits here |
| **UI** (Playwright) | Real browser session through oauth-proxy + WebSocket chat | `tests/sandbox-security.spec.ts` | No MLflow/EvalHub integration, slow for CI gating |
| **Environment** (MiDojo, future) | Full agent in its real runtime: indirect injection via poisoned tool/MCP responses, OWASP ASI–tagged payloads | Not implemented | See [16.7](#167-midojo--in-environment-agent-red-teaming-future) |

**What to borrow from `evalhub_adapter`** (high value):

- BYOF provider pattern: container image + `FrameworkAdapter` + REST API registration (`POST /api/v1/evaluations/providers`) — requires EvalHub server **>= 0.3.0** (RHOAI 3.4 TP may ship 0.2.0; see adapter README for workaround)
- Inner loop (fast pytest) + outer loop (EvalHub K8s Job) — same scorer logic, different execution context
- Safety scorers already wired in the harness: `injection_resistance`, `pii_leakage`, `policy_adherence` — align with existing Playwright cases (credential leak, sudo, jailbreak)
- MLflow run logging pattern: `MLFLOW_TRACKING_TOKEN` + `MLFLOW_WORKSPACE` + resolved literal env vars (EvalHub does not resolve `secretKeyRef` in provider runtime `Env`)
- `run-e2e.sh` automation: build/push adapter image, register provider, submit jobs, poll, cleanup

**What NOT to copy as-is** (low value for this project):

- `agentic-tool-use` benchmark and tool-use scorers (`tool_selection`, `tool_sequence`, `hallucinated_tools`) — OpenClaw here runs with aggressive `tools.deny` (`browser`, `nodes`, etc.); tool-selection scoring is not the priority
- LangGraph/CrewAI fixture YAMLs — agent-specific golden queries; need OpenClaw-specific fixtures derived from `sandbox-security.spec.ts`
- Deploying EvalHub inside this repo — consume the shared platform instance from `rhoai-platform-ops` (`make deploy-evaluation`) or `agentops-example`

**OpenClaw-specific integration notes**:

- The harness speaks OpenAI-compatible `POST /v1/chat/completions` — OpenClaw already exposes this (see `tests/openclaw-ui.spec.ts`, `verify.sh` Layer 5)
- Auth friction: the public Route is behind `oauth-proxy`; the harness needs either an OAuth session token, a test-only bypass Route, or an in-cluster URL that skips the proxy
- Do not replace Playwright Layer 9 — keep it as the E2E integration test; the adapter is for faster, repeatable, MLflow-tracked scoring

**Proposed benchmark**: `openclaw-security` (custom provider, not the starter-kit's `agentic-tool-use`)

- Scorers: `injection_resistance`, `pii_leakage`, `policy_adherence` with `forbidden_actions: ["shell execution", "sudo", "api key exposure"]`
- Fixtures: YAML golden queries translated from `tests/sandbox-security.spec.ts` prompts
- MLflow experiment: same RHOAI workspace/experiment as `mlflow-openclaw` traces (Phase 12) so eval runs and agent traces are co-located

**Tasks**:

Model layer (Garak):
- [ ] Evaluate running `make evalhub-security` (or equivalent Garak invocation) against the inference router / MaaS model this project uses — validates the underlying model, not the agent stack
- [ ] Consider a scheduled (not per-PR) Garak run given CPU runtime cost, documented in `rhoai-platform-ops`

Agent layer (behavioral adapter — `evalhub_adapter` pattern):
- [ ] Vendor `harness/scorers/safety.py` and `harness/runner.py` from agentic-starter-kits (or depend on the package) into an `evals/openclaw_adapter/` directory
- [ ] Create `fixtures/openclaw/security.yaml` with golden queries from `sandbox-security.spec.ts`
- [ ] Inner loop: `pytest evals/openclaw_adapter/tests -m unit` for fast CI gating on `prompts/*.md` changes
- [ ] Build adapter Containerfile and register BYOF provider against shared EvalHub (requires EvalHub >= 0.3.0)
- [ ] Outer loop: `evalhub eval run` against OpenClaw `/v1/chat/completions` endpoint; verify `mlflow_run_id` in results
- [ ] Resolve auth for harness HTTP calls (oauth-proxy token, internal Route, or test bypass)

Process / governance:
- [ ] Add findings review to the PR checklist when `prompts/*.md` changes (inner-loop pytest gate + manual Playwright spot-check)
- [ ] Document the evaluation layer model in `docs/` (or extend `AGENT-SANDBOX-AND-OPENSHELL.md`) — see also [16.7](#167-midojo--in-environment-agent-red-teaming-future) for the environment layer

### 16.7 MiDojo — in-environment agent red-teaming (future)

**Status**: Not started — future integration (MiDojo is open source; Red Hat AI developer preview announced).

**Context**: [MiDojo](https://github.com/asago-ai/midojo) applies the same BYOA principle to security testing: red-team the agent **in the environment where it runs**, not a rebuilt simulation ([Red Hat Developer article](https://developers.redhat.com/articles/2026/08/10/midojo-improve-ai-agent-security-real-world-red-teaming#)). A man-in-the-middle interception layer sits between the agent and real tools — fake MCP servers or runtime extensions that can forward calls, splice attack payloads into responses, or capture actions. Attack libraries are tagged against the OWASP Agentic Security Initiative taxonomy; probes from catalogs like Garak can be delivered through the same layer. Each run reports **security** (did the agent resist the attack?) and **utility** (did it still complete its task?) independently, and marks results **not applicable** when the payload never reached the agent.

This complements the layers in [16.5](#165-adversarial-and-behavioral-evaluation-hookup): Garak and `evalhub_adapter` score model/HTTP behavior; Playwright validates the real Control UI; MiDojo would test indirect prompt injection through **poisoned tool outputs** (calendar entries, log lines, compromised tool responses) against the actual OpenClaw + OpenShell stack — including `tools.deny`, Landlock, and `NetworkPolicy` — without re-implementing the sandbox in a test harness. MiDojo ships SDKs for MCP-speaking agents and for Pi (the runtime behind OpenClaw), which aligns with this project's deployment model.

**OpenClaw/OpenShell integration notes**:

- Interception attaches to whatever shape the agent already expects — MCP stand-in server or a pluggable runtime extension — so OpenClaw inside the sandbox should not need code changes for a first pass
- Suite definitions (`suite.yaml`) drive which payloads are injected and when; reuse or extend probes already exercised in `tests/sandbox-security.spec.ts` and Garak/EvalHub runs
- Results could eventually be logged alongside MLflow traces (Phase 12) and EvalHub job history (16.5) for a single security timeline per deploy
- Network policy (`policies/openclaw-sandbox.yaml`) must allow egress to MiDojo's interception endpoint when enabled — treat MiDojo like any other out-of-sandbox service (similar to 16.2 MCP Gateway pattern)

**Tasks** (when MiDojo is adopted):

- [ ] Evaluate MiDojo developer preview / release against OpenShell v0.0.83 + OpenClaw community sandbox image on CRC and AWS OCP
- [ ] Pick integration path: MCP interception vs Pi/OpenClaw runtime extension; document choice in an ADR
- [ ] Author an `openclaw-openshell` MiDojo suite covering indirect injection scenarios (poisoned tool response, credential exfiltration attempts, policy bypass via data plane)
- [ ] Wire security + utility scores into CI or scheduled post-deploy verification (complement Playwright Layer 9 — faster, more deterministic than UI-only LLM variance)
- [ ] Optional: export MiDojo run metadata to MLflow (same workspace as `mlflow-openclaw`) and/or submit via shared EvalHub when a provider pattern exists
- [ ] Add `verify.sh` smoke or document a `scripts/run-midojo.sh` entry point once a minimal suite is stable
- [ ] Document the four-layer evaluation model (model / agent HTTP / UI / environment) in `docs/`

### 16.6 Watch items (not scheduled)

- **Agent-as-a-Service (OGX)**: RHOAI 3.5 EA ships a shared agentic-loop runtime as an alternative to this project's current in-pod harness loop. The article notes the two patterns compose (a sandboxed pod can delegate tool execution to a shared loop while keeping its own identity). Revisit once `rhoai-platform-ops` evaluates OGX in its own roadmap (Phase 6) — no action here until then.
- **Multi-agent orchestration (A2A / signed AgentCards)**: only relevant if a second agent is ever added to this project. A2A reached 1.0 per the article, but interoperability in practice is still settling. Not applicable to a single-agent deployment today.

## Phase 17 (future): Unified Observability — OpenShell/OpenClaw Logs in the OpenShift Stack

**Status**: Not started — planning only.

**Context**: Today, sandbox security audit events (OCSF) live exclusively in OpenShell's own logging system (`openshell logs`), and OpenClaw gateway logs live inside the sandbox pod's stdout. Neither is visible in the cluster's central observability stack (Prometheus/Loki/Tempo/Grafana). This means an operator must use the `openshell` CLI to investigate security events — they can't build alerts, dashboards, or correlate sandbox network verdicts with agent traces in MLflow or distributed traces in Tempo.

**Goal**: Forward OpenShell and OpenClaw logs into the OpenShift observability stack so that all sandbox audit events, network policy verdicts, and agent gateway logs are queryable, alertable, and correlatable alongside platform metrics and traces.

**Architecture options**:

| Approach | How | Pros | Cons |
|---|---|---|---|
| **A. Sidecar OTel Collector** | Deploy an OTel Collector sidecar in the sandbox pod that tails OpenShell's OCSF log stream and exports as OTLP logs to the cluster's OTel pipeline | Native OTel integration, structured attributes, correlates with existing Tempo traces | Requires sidecar injection, adds resource overhead per sandbox pod |
| **B. Cluster-level log forwarding (CLF/Loki)** | Use OpenShift's ClusterLogForwarder to capture sandbox pod stdout (which includes OCSF events) and route to Loki | No per-pod changes, uses existing OCP logging infrastructure | Requires Loki deployment (or RHOL), logs are semi-structured text requiring parsing |
| **C. OpenShell webhook/export** | If upstream adds an OCSF export webhook or OTLP exporter, configure it to push directly to the cluster's OTel Collector | Cleanest integration, no sidecar | Depends on upstream feature availability |

**Tasks**:
- [ ] Evaluate which approach is feasible given current OpenShell version (v0.0.83) — check if `openshell logs` supports `--format json` or if there's an export mechanism
- [ ] If approach A: add OTel Collector sidecar to the OpenShell wrapper chart (`charts/openshell/`), configure log receiver for OCSF events, export to `otel-collector.observability.svc`
- [ ] If approach B: deploy Loki (or use RHOL if available) and configure ClusterLogForwarder with a pipeline for the `openshell` namespace; create Grafana dashboard for OCSF event queries
- [ ] Create a Grafana dashboard showing: DENIED events over time, top blocked destinations, ALLOWED vs DENIED ratio, per-binary network activity
- [ ] Create PrometheusRule alerts for anomalous patterns (e.g., burst of DENIED events, new destination never seen before, OCSF logging gap — no events for >N minutes while sandbox is active)
- [ ] Correlate OCSF events with MLflow traces: when a DENIED event occurs during an active chat session, link the network verdict to the MLflow trace that triggered it (requires trace-id propagation or timestamp correlation)
- [ ] Forward OpenClaw gateway logs (`openclaw.log` inside sandbox) alongside OCSF events — useful for debugging agent-side errors that correspond to network policy decisions
- [ ] Add `verify.sh` checks for the new pipeline (e.g., after a DENIED event, query Loki/Tempo to confirm the event arrived in the central stack)
- [ ] Document the integration in `docs/constraints.md` and create an ADR for the chosen approach

**Blocked on**: Evaluating upstream OpenShell OCSF export capabilities and deciding between Loki (RHOL) vs OTel Collector log pipeline for the cluster.

## Phase 18 (future): CRC Local Dev Improvements

**Status**: Not started — CRC-only polish. AWS OCP needs none of these (validated 2026-08-03 in [13.5](#135-re-audit-openshell_gateway_insecure-scoping-when-aws-ocp-gets-real-certs-resolved)).

**Context**: CRC (`APPS_DOMAIN=apps-crc.testing`) uses a self-signed ingress-operator router wildcard cert that is not in the host system trust store, and may lack the `redhat-operators` OLM catalog available on full OCP clusters. Core deploy/verify paths work on CRC today via targeted workarounds (`CURL_OPTS="-k"`, scoped `OPENSHELL_GATEWAY_INSECURE`); this phase tracks hardening and cleanup items that only apply when `CRC_MODE=true`.

Run: `./scripts/cluster-lifecycle.sh` on a local CRC VM (see `crc-local-dev` skill).

### 18.1 TLS trust — replace `OPENSHELL_GATEWAY_INSECURE` with router CA import

**Context**: [13.5](#135-re-audit-openshell_gateway_insecure-scoping-when-aws-ocp-gets-real-certs-resolved) scoped the insecure-skip workaround to OIDC-only flows. The practical fix is in place; this section tracks deeper CRC hardening and documentation.

- [ ] **Root cause not fully confirmed**: the working hypothesis (insecure-mode short-circuits the client-cert identity resolver, not just server-cert verification) is plausible but based on a ~1-minute A/B test that overlaps with constraint #19's own documented time-based recovery window (10s–8min, attributed there to host memory pressure, not to this flag). Re-validate with a cleaner, longer, repeated-trial experiment (or read the `openshell` CLI TLS client source in `OpenShell/crates/openshell-cli/`) before treating this as fully proven — the *practical* fix (unset before mTLS) is safe to keep either way, since it can only narrow, never widen, where verification is skipped
- [ ] **Audit OIDC refresh callers on CRC**: `verify.sh` already calls `ensure_oidc_token()` (which invokes `enable_openshell_oidc_insecure()`) before any `openshell` auth probes, but audit other entry points (`cluster-lifecycle.sh` subcommands, ad-hoc `source scripts/common.sh` sessions, `monitor-deployment` skill patterns) for callers that refresh OIDC against Keycloak without going through `ensure_oidc_token()` — those can still hit constraint #18 on CRC when the access token has expired
- [ ] Update `docs/constraints.md` #18/#19 to document the scoped `enable_openshell_oidc_insecure()` interaction and the mTLS vs OIDC split — code comments in `common.sh`/`deploy-openshell.sh` already reference these entries but the doc text is stale (still describes the old global export)
- [ ] **Stronger fix (optional)**: replace the insecure-skip approach entirely by importing CRC's actual router CA into the CLI's trust store (or passing it explicitly, if the `openshell` CLI supports a custom CA flag), so CRC never needs `OPENSHELL_GATEWAY_INSECURE` — would close the residual OIDC-path exposure window without skipping TLS verification

### 18.2 Agent Sandbox operator — drop raw-manifest fallback on CRC

**Context**: On full OCP/RHPDS clusters, the Agent Sandbox operator installs via OLM (`charts/agent-sandbox/operators/`). On CRC, `scripts/bootstrap-ocp.sh` still applies the pinned upstream manifest `manifests/agent-sandbox-v0.5.1.yaml` when the `redhat-operators` catalog is unavailable ([ADR-0004](docs/adrs/ADR-0004-agent-sandbox-redhat.md)).

- [ ] Try installing `agent-sandbox-operator` via OLM on CRC (or another catalog source available there)
- [ ] If it works: delete `manifests/agent-sandbox-v0.5.1.yaml`, remove the CRC branch in `scripts/bootstrap-ocp.sh`, and update [ADR-0004](docs/adrs/ADR-0004-agent-sandbox-redhat.md)
- [ ] If OLM/`redhat-operators` is unavailable on CRC: keep the fallback and document the constraint in `docs/constraints.md`

## References

- [OpenShell OpenShift docs](https://docs.nvidia.com/openshell/kubernetes/openshift)
- [OpenShell provider docs](https://nvidia-openshell.mintlify.app/sandboxes/providers)
- [OpenShell sandbox policies](https://docs.nvidia.com/openshell/sandboxes/policies)
- [OpenClaw LiteLLM provider](https://docs.openclaw.ai/providers/litellm)
- [OpenClaw OpenShell plugin](https://docs.openclaw.ai/gateway/openshell)
- [OpenClaw health checks](https://docs.openclaw.ai/gateway/health)
- [OpenClaw OpenAI-compatible API](https://docs.openclaw.ai/gateway/openai-http-api)
- [agent-harness-in-a-box](https://github.com/rcarrata/agent-harness-in-a-box) (commit `76aca3b`)
- [agentic-starter-kits MLflow auth/TLS](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/docs/mlflow-openshift-auth-and-tls.md) (review later — see Phase 12c; do not copy their OpenClaw OTel sidecar)
- [agentic-starter-kits evalhub_adapter](https://github.com/red-hat-data-services/agentic-starter-kits/tree/main/evals/evalhub_adapter) (BYOF behavioral eval pattern — see Phase 16.5)
- [MiDojo](https://github.com/asago-ai/midojo) — in-environment agent red-teaming (MITM tool interception; see Phase 16.7)
- [MiDojo: Improve AI agent security with real-world red-teaming](https://developers.redhat.com/articles/2026/08/10/midojo-improve-ai-agent-security-real-world-red-teaming#) (Red Hat Developer, 2026-08-10)
- [Red Hat build of Agent Sandbox (OSC 1.13)](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/)

# Agent Sandbox and OpenShell — How It Works

This document explains how OpenShell and the Agent Sandbox Operator work together to run OpenClaw inside isolated, zero-trust sandbox environments on OpenShift. It is written for engineers who want to understand the full stack — from Kubernetes CRDs to Linux kernel mechanisms to inference routing.

| Audience | What to read |
|----------|--------------|
| "Just tell me how to deploy" | [Quick reference](#9-quick-reference) at the bottom |
| "I want to understand the architecture" | Sections 1 – 5 |
| "I need to understand inference routing" | [Section 6](#6-inference-routing) |
| "I'm building my own agent" | Sections 3 – 4 and [Using your own agent image](#8-using-your-own-agent-image) |

---

## Table of Contents

1. [Key Concepts](#1-key-concepts)
2. [Infrastructure Stack](#2-infrastructure-stack)
3. [End-to-End Flow: From CLI to Running Agent](#3-end-to-end-flow-from-cli-to-running-agent)
4. [Inside the Sandbox Pod](#4-inside-the-sandbox-pod)
5. [The Launch Script Explained](#5-the-launch-script-explained)
6. [Inference Routing](#6-inference-routing)
7. [Version Pinning](#7-version-pinning)
8. [Using Your Own Agent Image](#8-using-your-own-agent-image)
9. [Validation and Security Verification](#9-validation-and-security-verification)
10. [Quick Reference](#10-quick-reference)
11. [Further Reading](#11-further-reading)

---

## 1. Key Concepts

### Agent Sandbox Operator

The [Red Hat build of Agent Sandbox](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/) is an OLM-managed operator (OpenShift sandboxed containers 1.13, Technology Preview) that provides:

- A `Sandbox` CRD (`sandboxes.agents.x-k8s.io`) — the Kubernetes-native way to declare a sandbox.
- A controller that watches `Sandbox` CRs and creates/manages pods.
- A sandbox router for traffic management.
- Extension CRDs: `SandboxTemplate`, `SandboxClaim`, `SandboxWarmPool`.

### OpenShell

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) is the orchestration layer that manages sandboxes. It has two components:

| Component | Role |
|-----------|------|
| **`openshell` CLI** | Creates sandboxes, applies policies, executes commands inside them |
| **OpenShell Gateway** | A long-running server (StatefulSet on K8s) that talks to compute drivers (Podman, Docker, MicroVM, **Kubernetes**) |

On OpenShift, the Kubernetes driver translates OpenShell sandbox operations into `Sandbox` CRs that the Agent Sandbox Operator reconciles.

### Network Namespace (netns)

A Linux kernel isolation mechanism. Each network namespace has its own network stack — interfaces, routing table, `127.0.0.1`, firewall rules.

OpenShell creates a dedicated netns inside the sandbox pod. Processes running in that netns (like OpenClaw) have a **separate loopback** — a service listening on `127.0.0.1:18789` inside the sandbox netns is unreachable from the pod's main network namespace (and therefore unreachable via plain `oc exec`).

### Landlock

A [Linux Security Module](https://docs.kernel.org/userspace-api/landlock.html) for filesystem sandboxing. Instead of relying solely on Unix permissions, a process declares rules like "I can read `/usr` and write `/tmp`; deny everything else." OpenShell's supervisor configures Landlock from the sandbox policy file.

In our policy (`policies/openclaw-sandbox.yaml`):

```yaml
filesystem_policy:
  read_only: [/usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log, /sandbox]
  read_write: [/sandbox/workspace, /tmp, /dev/null, /home]

landlock:
  compatibility: best_effort
```

`best_effort` means: if the kernel lacks Landlock support, degrade gracefully with a warning instead of failing.

### Privileged SCC — The Intentional Paradox

OpenShift's default `restricted-v2` SCC blocks capabilities like `CAP_SYS_ADMIN` and `CAP_NET_ADMIN`. However, the OpenShell supervisor **needs** those capabilities to build the restrictive environment:

| Capability | Used for |
|------------|----------|
| `CAP_NET_ADMIN` | Installing **nftables** rules (network egress allow/deny) |
| `CAP_SYS_ADMIN` | Creating **network namespaces**, configuring **Landlock** |
| `/proc`, `/sys` access | Process identity for per-binary network policy |

The `privileged` SCC is granted **only** to the `openshell2-sandbox` ServiceAccount — the gateway pod continues to run under `restricted-v2`.

**The paradox is intentional:** elevated pod-level privileges are required to *create* the restrictive sandbox that constrains agent processes. See [ADR-0006](adrs/ADR-0006-scc-privileged-sandbox.md) for the full rationale.

---

## 2. Infrastructure Stack

### Deployment YAML Locations

| Component | Files | Install command |
|-----------|-------|-----------------|
| Agent Sandbox Operator (OLM) | `manifests/agent-sandbox-v0.5.1.yaml` | `oc apply` |
| OpenShell Gateway | `charts/openshell/` (wrapper chart with upstream OCI subchart dependency) | `scripts/deploy-openshell.sh` |
| SCC RoleBinding | `charts/openshell/templates/scc-rolebinding.yaml` | Included in deploy-openshell |
| oauth2-proxy | `charts/oauth2-proxy/` | `scripts/deploy-oauth2-proxy.sh` |
| Sandbox Policy | `policies/openclaw-sandbox.yaml` | Applied at `sandbox create` time |

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     OpenShift Cluster                           │
│                                                                 │
│  ┌─────────────────────────────────────┐                        │
│  │   agent-sandbox-system namespace    │                        │
│  │   ┌─────────────────────────────┐   │                        │
│  │   │ Agent Sandbox Operator      │   │                        │
│  │   └────────────┬────────────────┘   │                        │
│  └────────────────│────────────────────┘                        │
│                   │ watches Sandbox CRs                         │
│                   │ creates pods                                │
│  ┌────────────────│────────────────────────────────────┐        │
│  │   openshell2 namespace                              │        │
│  │                │                                    │        │
│  │  ┌─────────────▼──────────────┐                     │        │
│  │  │ Pod: default--openclaw-gw2 │◄────────────────┐   │        │
│  │  │ (Sandbox CR, SA: sandbox)  │                 │   │        │
│  │  │ ┌────────────────────────┐ │                 │   │        │
│  │  │ │ container: agent       │ │   gRPC/mTLS     │   │        │
│  │  │ │ ┌───────────────────┐  │ │   relay         │   │        │
│  │  │ │ │ supervisor (root) │  │ │                 │   │        │
│  │  │ │ │   ┌─── netns ──┐  │  │ │                 │   │        │
│  │  │ │ │   │ openclaw   │  │  │ │                 │   │        │
│  │  │ │ │   │ :18789     │  │  │ │                 │   │        │
│  │  │ │ │   └────────────┘  │  │ │                 │   │        │
│  │  │ │ └───────────────────┘  │ │                 │   │        │
│  │  │ └────────────────────────┘ │                 │   │        │
│  │  └────────────────────────────┘                 │   │        │
│  │                                                 │   │        │
│  │  ┌──────────────────────────────┐               │   │        │
│  │  │ StatefulSet: openshell2-0    │───────────────┘   │        │
│  │  │ (Gateway, SCC: restricted)   │                   │        │
│  │  └──────────────────────────────┘                   │        │
│  │                                                     │        │
│  │  ┌──────────────────────────────┐                   │        │
│  │  │ Deployment: oauth2-proxy     │                   │        │
│  │  │ (OpenShift OAuth)            │                   │        │
│  │  └──────────────────────────────┘                   │        │
│  └─────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. End-to-End Flow: From CLI to Running Agent

```
┌──────────────┐    ┌────────────────┐    ┌─────────────┐    ┌──────────────┐
│ openshell    │───►│ OpenShell      │───►│ K8s API     │───►│ Agent        │
│ CLI          │gRPC│ Gateway        │POST│ Server      │    │ Sandbox      │
│              │mTLS│ (StatefulSet)  │    │             │    │ Operator     │
└──────────────┘    └────────────────┘    └──────┬──────┘    └──────┬───────┘
                                                 │                  │
                                                 │ Sandbox CR       │ reconciles
                                                 │ created          │ creates Pod
                                                 │                  │
                                                 ▼                  ▼
                                          ┌──────────────────────────┐
                                          │ Pod: default--openclaw-gw2│
                                          │ (container: agent)       │
                                          │ supervisor starts        │
                                          │ registers with gateway   │
                                          └──────────────────────────┘
```

### Phase 1 — Gateway Deployment

```bash
./scripts/deploy-openshell.sh
```

Deploys the OpenShell Gateway StatefulSet, registers CLI, enables `providers_v2`, creates the MaaS provider, and configures the inference route.

### Phase 2 — Sandbox Creation

```bash
openshell sandbox create --from openclaw --name openclaw-gw2 \
  --provider maas-litellm \
  --policy policies/openclaw-sandbox.yaml \
  --upload .rendered/openclaw.json:/sandbox/.openclaw/config.json
```

The CLI sends a `CreateSandbox` gRPC request to the gateway. The gateway's Kubernetes driver creates a `Sandbox` CR; the Agent Sandbox Operator reconciles it into a pod.

### Phase 3 — Launch OpenClaw

This is the imperative step performed by `scripts/launch-openclaw.sh`. See [Section 5](#5-the-launch-script-explained) for the full breakdown.

---

## 4. Inside the Sandbox Pod

### Pod Topology

With the default `combined` supervisor topology, there is **one pod with one main container**:

```
Pod: default--openclaw-gw2
│
├── [init containers]       optional: copy supervisor binary, prepare workspace PVC
│
└── container: agent        ONE container
    │
    ├── openshell-sandbox   supervisor process, runs as root (PID ~1)
    │   │
    │   ├── creates isolated network namespace (netns)
    │   ├── installs nftables rules (egress allow/deny per policy)
    │   ├── configures Landlock (filesystem restrictions)
    │   └── forks child processes into the netns
    │
    └── [sandbox netns]     isolated network + filesystem view
        │
        ├── openclaw gateway run   child process, user "sandbox", port 18789
        ├── prompt-trace-linker    sidecar for MLflow prompt tagging
        └── openclaw agent / tools additional child processes on demand
```

### Two Ways to Enter the Pod

| Method | What you reach | User | Network | Use case |
|--------|---------------|------|---------|----------|
| `oc exec -c agent` | Container's main PID namespace | root (container default) | Pod network | Admin setup: install packages, copy files |
| `openshell sandbox exec` | Sandbox netns (via supervisor relay) | `sandbox` (policy-defined) | Isolated netns, policy-restricted | Run agent commands, health checks |

This distinction is critical: a service listening on `127.0.0.1:18789` inside the sandbox netns is **invisible** to `oc exec -c agent`. Health checks and validation must use `openshell sandbox exec`.

---

## 5. The Launch Script Explained

`scripts/launch-openclaw.sh` is the one imperative step that cannot be expressed as a Helm chart — it requires runtime interaction with the sandbox process namespace.

### Prerequisites

- OpenShell deployed: `./scripts/deploy-openshell.sh`
- Secrets: `MAAS_API_KEY` in `secrets/secrets.env`
- CLI registered: `openshell status` shows Connected
- RHOAI MLflow wired: `./scripts/wire-rhoai-mlflow-tracing.sh`

### Step-by-Step

| Step | What it does | Why |
|------|-------------|-----|
| Create sandbox | `openshell sandbox create --from openclaw --provider maas-litellm` | Creates Sandbox CR, operator creates pod |
| Upgrade Node.js + OpenClaw | `n 22.22.3`, `npm install -g openclaw@2026.7.1` | Pin to tested versions |
| Copy config | `oc cp openclaw.json` + `chown` to sandbox UID | OpenClaw reads config from writable workspace |
| Fetch prompts | MLflow Prompt Registry (`@production` alias) | System prompts versioned externally |
| Install MLflow plugin | `npm install @mlflow/mlflow-openclaw@0.2.0-rc.0` | Traces to RHOAI MLflow |
| Patch plugin | `patch-mlflow-plugin.py` + `chown root:root` | SDK compatibility; root ownership required |
| Stage CA bundle | Merge OpenShell CA + OpenShift service-ca | TLS trust for MLflow's internal cert |
| Start gateway | `openshell sandbox exec --no-tty -- nohup openclaw gateway run &` | Runs inside sandbox netns |
| Start linker | `openshell sandbox exec --no-tty -- nohup node prompt-trace-linker.js &` | Tags traces with prompt versions |
| Expose UI | `openshell service expose openclaw-gw2 18789 openclaw-ui` | Registers relay route in gateway |

### Traffic Flow: Browser to OpenClaw

```
Browser  ───HTTPS──►  Route (oauth2-proxy)
                       │
                       ▼
              oauth2-proxy (OpenShift OAuth)
              authenticates via OCP OAuth server
                       │
                       ▼
              OpenShell Gateway (openshell2-0)
              relay HTTP/WebSocket
                       │
                       ▼
              Supervisor (in sandbox pod)
              forwards to sandbox netns
                       │
                       ▼
              openclaw gateway run (:18789)
              inside isolated netns
```

Users authenticate through oauth2-proxy with any OCP cluster identity (OpenShift-native OAuth, see ADR-0016).

---

## 6. Inference Routing

### How `inference.local` Works

OpenShell exposes a special hostname **inside every sandbox**: `inference.local`. It is an HTTPS endpoint intercepted by the OpenShell **privacy router** — not a real network service.

```
┌─────────────────────────────┐
│ Sandbox (isolated netns)    │
│                             │
│ OpenClaw calls:             │
│   https://inference.local   │
│   /v1/chat/completions      │
│   model: "router"           │
│   api_key: "unused"         │
└────────────┬────────────────┘
             │ intercepted by privacy router
             ▼
┌─────────────────────────────┐
│ OpenShell Privacy Router    │
│                             │
│ 1. Strips sandbox creds     │
│ 2. Injects real provider    │
│    credentials from gateway │
│    provider record          │
│ 3. Rewrites model name      │
│ 4. Forwards to backend      │
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│ MaaS / vLLM / Bedrock /    │
│ any configured backend      │
│                             │
│ Responds with real model    │
│ name in response.model      │
└─────────────────────────────┘
```

### Configuration

The inference route is configured at the **gateway level**, outside the sandbox:

```bash
# 1. Enable providers v2
openshell settings set --global --key providers_v2_enabled --value true --yes

# 2. Register provider (type=openai for MaaS/LiteLLM compatibility)
openshell provider create \
  --name maas-litellm \
  --type openai \
  --credential "LITELLM_API_KEY=${MAAS_API_KEY}"

# 3. Set inference route
openshell inference set --provider maas-litellm --model claude-sonnet-4-6

# 4. Verify
openshell inference get
```

The `deploy-openshell.sh` script runs these steps automatically.

### Credential Flow

The real API key **never enters the sandbox**:

1. `MAAS_API_KEY` is read from `secrets/secrets.env` at deploy time
2. `create_provider()` registers it in the gateway's provider record (persisted in the gateway's SQLite DB)
3. When sandbox code calls `inference.local`, the privacy router reads the credential from the provider record and injects it into the upstream request
4. `config/openclaw.json.tpl` uses `apiKey: "unused"` — the OpenAI SDK requires a non-empty value, but it is never sent upstream

### Model Resolution

- **Request** (what the agent sends): `model: "router"`
- **Response** (what the agent receives): `model: "claude-sonnet-4-6"` (or whatever the real model is)

The privacy router rewrites the model in the request but does **not** rewrite the response. OpenClaw stores the response model on the assistant message as `responseModel`. The `mlflow-openclaw` plugin is patched (via `patch-mlflow-plugin.py`) to prefer `lastAssistant.responseModel` over the configured model ID in traces, so MLflow shows the real model name (e.g., `claude-sonnet-4-6`) rather than `router`.

### Limitations

- **Gateway-scoped**: Every sandbox on the same gateway sees the same `inference.local` backend. One provider + one model per gateway. This is fine for this project (single sandbox `openclaw-gw2` on gateway `openclaw2`).
- **No declarative config**: Provider and inference route must be configured imperatively via the `openshell` CLI. Declarative configuration via Helm values is tracked upstream at [NVIDIA/OpenShell#1886](https://github.com/NVIDIA/OpenShell/issues/1886).
- **No multi-provider routing**: Path-based routing like `inference.local/openai/...` vs `inference.local/anthropic/...` is future work. Tracked at [NVIDIA/OpenShell#896](https://github.com/NVIDIA/OpenShell/issues/896).

### providers_v2_enabled

When enabled, each attached provider with a matching profile contributes a **provider policy layer** to the sandbox effective policy:

- The **base policy** is the user-authored `policies/openclaw-sandbox.yaml`
- The **effective policy** is the composed result: base + provider policy layers
- Provider layers are auto-contributed — no manual network policy entries needed for `inference.local`

See [Providers v2 docs](https://docs.nvidia.com/openshell/sandboxes/providers-v2) for the full reference.

---

## 7. Version Pinning

All versions are pinned:

| Component | Version | Where enforced |
|-----------|---------|----------------|
| OpenShell chart (gateway) | `0.0.83` | `charts/openshell/Chart.yaml` + `Chart.lock` |
| OpenClaw (npm) | `2026.7.1` | `scripts/launch-openclaw.sh` |
| `@mlflow/mlflow-openclaw` | `0.2.0-rc.0` | `scripts/launch-openclaw.sh` |
| Sandbox base image | **not pinned** (`openclaw:latest`) | `--from openclaw` in `launch-openclaw.sh` |

### Pinning the Sandbox Base Image

`--from openclaw` resolves to `ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest`. To pin:

```bash
# Tag pin
--from ghcr.io/nvidia/openshell-community/sandboxes/openclaw:0.0.83

# Digest pin (maximum reproducibility)
--from ghcr.io/nvidia/openshell-community/sandboxes/openclaw@sha256:abc123...
```

---

## 8. Using Your Own Agent Image

The `--from openclaw` flag is a community preset. You can use any image or Dockerfile.

### `--from` Resolution Rules

| `--from` value | What happens |
|----------------|-------------|
| `openclaw`, `python`, `base` | Expanded to `ghcr.io/nvidia/openshell-community/sandboxes/{name}:latest` |
| `ghcr.io/myorg/myimage:v1` | Used as-is (contains `/` or `:`) |
| `./Dockerfile` or `./docker/` | OpenShell builds the image, then creates the sandbox |
| *(omitted)* | Uses the gateway default (`sandboxImage` in Helm values) |

### Policy Anatomy

| Section | Controls | Example |
|---------|----------|---------|
| `filesystem_policy` | Which paths are readable/writable | `read_write: [/sandbox/workspace, /tmp]` |
| `landlock` | Kernel-level filesystem enforcement | `compatibility: best_effort` |
| `process` | User/group the agent runs as | `run_as_user: sandbox` |
| `network_policies` | Allowed egress endpoints | Explicit host + port + protocol per policy |

**Default deny:** any endpoint not listed in `network_policies` is blocked. With inference routing, LLM traffic goes through `inference.local` (no explicit policy needed) and only `otel-collector` (observability) and `mlflow` (tracing) require explicit network policy entries.

---

## 9. Validation and Security Verification

### verify.sh Layers

```bash
./scripts/verify.sh                        # Full profile (all layers)
VERIFY_PROFILE=smoke ./scripts/verify.sh   # Fast subset (essential checks only)
```

| Layer | What it checks |
|-------|---------------|
| 1 | OCP infrastructure (CRDs, namespace, SCC, PKI) |
| 1b | Keycloak OIDC |
| 2 | OpenShell gateway (pod, route, CLI, provider, inference route) |
| 3 | Sandbox existence and readiness |
| 4 | Security (identity, egress, IMDS, sudo, DNS, credentials, Landlock) |
| 5 | OpenClaw gateway health (/health, config, chatCompletions, tools.deny) |
| 5b | LLM connectivity (inference.local reachability, proxy denials) |
| 5c | Inference router smoke test (disposable sandbox, full profile only) |
| 7 | External access (oauth-proxy, unauthenticated route retired) |
| 8 | Observability (Tempo, OTel, RHOAI MLflow) |
| 9 | Control UI (Playwright E2E chat + security tests) |
| 10 | MLflow traces + prompt tags |

### Playwright Tests

```bash
cd tests && npx playwright test              # All tests
npx playwright test openclaw-ui.spec.ts      # UI + E2E chat
npx playwright test sandbox-security.spec.ts # Security / jailbreak tests
```

---

## 10. Quick Reference

### Full Deployment Sequence

```bash
# 1. Bootstrap OCP cluster
./scripts/bootstrap-ocp.sh

# 2. Deploy RHOAI MLflow
./scripts/deploy-rhoai-mlflow.sh

# 3. Deploy OpenShell gateway (+ providers_v2, provider, inference route)
./scripts/deploy-openshell.sh

# 4. Wire MLflow tracing
./scripts/wire-rhoai-mlflow-tracing.sh

# 5. Configure OIDC (Keycloak)
./scripts/deploy-keycloak.sh && ./scripts/configure-oidc.sh

# 6. Deploy oauth2-proxy (UI auth)
./scripts/deploy-oauth2-proxy.sh

# 7. Launch OpenClaw in sandbox
./scripts/launch-openclaw.sh

# 8. Deploy observability
./scripts/deploy-observability.sh

# 9. Validate
./scripts/verify.sh

# Or: full lifecycle in one command
./scripts/cluster-lifecycle.sh full
```

### Key Commands

| Task | Command |
|------|---------|
| Create a sandbox | `openshell sandbox create --from <image> --name <n> --policy <file>` |
| Run command inside sandbox | `openshell sandbox exec -n <name> -- <command>` |
| Expose a service | `openshell service expose <sandbox> <port> <service-name>` |
| Check inference route | `openshell inference get` |
| Update inference model | `openshell inference update --model <model-id>` |
| List providers | `openshell provider list` |
| List sandboxes | `openshell sandbox list` |
| Delete a sandbox | `openshell sandbox delete <name>` |
| Check CLI status | `openshell status` |
| View sandbox policy | `openshell policy get <name> --full` |

---

## 11. Further Reading

| Topic | Reference |
|-------|-----------|
| Agent Sandbox Operator (Red Hat docs) | [OSC 1.13 — Deploying Red Hat build of Agent Sandbox](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/) |
| OpenShell documentation | [docs.nvidia.com/openshell](https://docs.nvidia.com/openshell/latest/) |
| OpenShell inference routing | [Inference Routing](https://docs.nvidia.com/openshell/latest/sandboxes/inference-routing) |
| OpenShell providers v2 | [Providers v2](https://docs.nvidia.com/openshell/sandboxes/providers-v2) |
| Landlock LSM | [kernel.org/userspace-api/landlock](https://docs.kernel.org/userspace-api/landlock.html) |
| Privileged SCC rationale | [ADR-0006](adrs/ADR-0006-scc-privileged-sandbox.md) |
| Inference router migration | [ADR-0021](adrs/ADR-0021-inference-router-migration.md) |
| UI authentication (oauth-proxy) | [ADR-0016](adrs/ADR-0016-openshift-native-oauth-spike.md) |
| MLflow tracing | [ADR-0018](adrs/ADR-0018-rhoai-mlflow-sole-backend.md) |
| Shared cluster coexistence | [ADR-0020](adrs/ADR-0020-shared-cluster-coexistence.md) |
| Declarative provider config (upstream) | [NVIDIA/OpenShell#1886](https://github.com/NVIDIA/OpenShell/issues/1886) |
| Multi-provider inference (upstream) | [NVIDIA/OpenShell#896](https://github.com/NVIDIA/OpenShell/issues/896) |
| OpenShell CLI reference | `openshell --help` (always authoritative) |

# OpenShell Sandbox Constraints for OpenClaw

This document captures all sandbox constraints discovered during deployment.
Every constraint has been learned through production failures. Each section
explains the constraint, why it exists, what failure it causes, and how to
work around it. These constraints are also documented inline in the scripts
that implement the workarounds.

## 1. Filesystem — Landlock LSM

**Constraint**: `/sandbox/` is read-only. Only `/sandbox/workspace/` and `/tmp/` are writable.

**Why**: Landlock Linux Security Module enforces filesystem boundaries to prevent
the agent from modifying system files, configs, or escaping the sandbox.

**Failure mode**: `EACCES: permission denied, mkdir '/sandbox/.openclaw/state'`

**Workaround**: Set `HOME=/sandbox/workspace` for all OpenClaw processes. The
gateway creates `.openclaw/` under `$HOME`, so this puts all writable state
in the workspace directory.

**Scripts affected**: `launch-openclaw.sh` (Step 3, Step 9)

## 2. Networking — L7 Binary Path Enforcement (RESOLVED via policy)

**Constraint**: The sandbox proxy uses nftables (L4 redirect) combined with L7
inspection. The L7 inspector checks `/proc/<pid>/exe` to identify which binary
made the connection. The network policy allows specific binaries (e.g.,
`/usr/bin/node`, `/usr/bin/curl`). If the binary resolves to a different path,
the connection is DENIED.

**Why**: This prevents arbitrary binaries from making network connections.
Only explicitly allowed binaries can communicate with allowed endpoints.

**Original failure mode (historical)**: When `n` (Node.js version manager)
upgrades Node.js, it installs the binary at `/usr/local/bin/node`. Since
`/usr/local/bin` is typically first in `$PATH`, all Node.js processes use this
path. If the policy only allows `/usr/bin/node`, the proxy resolves
`/proc/<pid>/exe` to `/usr/local/bin/node`, which is NOT in the allow list,
and ALL Node.js network traffic is silently DENIED.

**Resolution**: `policies/openclaw-sandbox.yaml` now lists both
`/usr/bin/node` and `/usr/local/bin/node` in the `binaries` section of every
network policy (`maas_inference`, `observability`, `mlflow_direct`). This
makes the `cp`/`rm` binary-relocation dance in `launch-openclaw.sh` after a
`n` upgrade unnecessary — the proxy accepts connections from either path.
If the base image or install method ever changes the Node.js binary path
again, add the new path to the `binaries` list instead of reintroducing a
relocation workaround.

**Revisit when the base image upgrades Node.js**: this whole constraint only
exists because the sandbox base image ships an older Node.js than OpenClaw
requires, forcing `launch-openclaw.sh` Step 2 to install `n` and upgrade Node
at runtime. Once the base image (Agent Sandbox Operator's image and/or
`ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest`) ships
Node.js `>=22.22.3` natively, that Step 2 upgrade — and both `/usr/bin/node`
/ `/usr/local/bin/node` entries here — become unnecessary and should be
removed. Tracked in [ROADMAP.md](../ROADMAP.md)'s "Follow-up investigation
(not scheduled)" list.

**Scripts affected**: `policies/openclaw-sandbox.yaml`, `verify.sh` (Layer 5b Check 1)

## 3. Networking — Node.js fetch() and Proxy Credential Injection

**Constraint**: The sandbox proxy resolves `openshell:resolve:env:KEY` credential
placeholders by inspecting HTTP traffic. However, Node.js `fetch()` (which uses
`undici` internally) creates ephemeral TCP connections. The proxy cannot reliably
map these ephemeral connections to a process binary via `/proc/net/tcp` lookups
because the connection may close before the lookup completes.

**Why**: The proxy uses `/proc/net/tcp` to find the owning PID of a TCP
connection, then reads `/proc/<pid>/exe` to identify the binary. Undici's
connection pooling and fast teardown makes this unreliable.

**Failure mode**: `DENIED: failed to resolve peer binary` in proxy logs. The
gateway appears healthy but cannot reach the LLM provider.

**Workaround**: Do NOT rely on proxy credential injection for Node.js `fetch()`.
Instead:
1. Bake the real API key directly into `openclaw.json` at template-render time.
   `config/openclaw.json.tpl` holds a `__MAAS_API_KEY__` placeholder;
   `render_openclaw_config()` in `scripts/common.sh` substitutes it with the
   real `MAAS_API_KEY` (from `secrets/secrets.env`) using bash string
   replacement (not sed/awk, so key characters like `/` are never
   misinterpreted). The resulting `.rendered/openclaw.json` — never committed,
   see `.gitignore` — is what gets uploaded/copied into the sandbox, so no
   separate post-copy injection step is needed.
2. Do NOT set `HTTP_PROXY` or `HTTPS_PROXY` — this forces `fetch()` to use
   HTTP CONNECT tunneling, which the proxy rejects with 403.
3. Do NOT set `NODE_OPTIONS="--require http-proxy-bootstrap.js"` — same reason.
4. Let the transparent proxy (nftables L4 redirect) handle routing automatically.

**Upstream tracking**: OpenShell issue #894 (binary resolution for undici), #896 (enhanced provider management).

**Scripts affected**: `config/openclaw.json.tpl`, `scripts/common.sh`
(`render_openclaw_config`), `launch-openclaw.sh` (Step 3, Step 9)

## 4. Plugins — Directory Structure and Ownership

**Constraint**: OpenClaw 2026.7.1 expects plugins at `$HOME/.openclaw/extensions/<plugin-id>/`.
Each plugin directory MUST contain an `openclaw.plugin.json` manifest. The plugin
directory MUST be owned by `root:root` (uid=0). Non-root ownership is rejected
as "suspicious ownership".

**Why**: Security measure to prevent the unprivileged sandbox user from
tampering with plugin code after installation.

**Failure mode**: `Error: suspicious ownership on plugin mlflow-openclaw` and
the plugin is not loaded.

**Workaround**: After installing a plugin:
```bash
chown -R root:root /sandbox/workspace/.openclaw/extensions/<plugin-id>
```

**Scripts affected**: `launch-openclaw.sh` (Step 6, Step 7)

## 4b. Plugins — Pinned `@mlflow/core` Misses the `X-MLFLOW-WORKSPACE` Fix (RESOLVED via source-patch backport)

**Constraint**: `@mlflow/mlflow-openclaw@0.2.0-rc.0` (the pinned plugin version
installed in Step 6) declares `@mlflow/core@^0.2.0` as a dependency. npm's
caret range resolves that to `0.2.0` exactly (published 2026-02-27) — it
never crosses into `0.3.x`, even though `0.3.0` (published 2026-07-07) is
available. [mlflow/mlflow#23927](https://github.com/mlflow/mlflow/pull/23927)
(merged 2026-06-11) fixed a gap in `@mlflow/core`'s TypeScript SDK where
`createOssAuth` did not send the `X-MLFLOW-WORKSPACE` header — but that fix
landed in `0.3.0`, so it never reaches this plugin's pinned dependency tree.

**Why this matters**: RHOAI-managed MLflow (`docs/adrs/ADR-0017-rhoai-mlflow-
scope.md`) always runs with `--enable-workspaces`, so every request needs
`X-MLFLOW-WORKSPACE`. **Confirmed live** (2026-07-25, after constraints #4c
and #4d were both fixed and every earlier layer — network policy, TLS,
RBAC, SA token auth — was working end-to-end): the plugin's real
`createTrace` call reaches MLflow's actual API handler and gets back
`HTTP 400: {"error":{"code":"INVALID_PARAMETER_VALUE","message":"Workspace
context is required for this request."}}`. This is now the **only**
remaining gap to a real trace landing in RHOAI MLflow.

**Fix attempted, blocked**: added `"overrides": {"@mlflow/core": "0.3.0"}`
to the plugin directory's own `package.json` (it's installed as its own
isolated npm project via `npm init -y`, so `overrides` applies locally) and
re-ran `npm install`. Failed with:

```
npm error code E403
npm error 403 403 Forbidden - GET https://registry.npmjs.org/@mlflow%2fcore - policy_denied
```

The exact same package name was fetched successfully earlier for the
original `^0.2.0` resolution, so this isn't a blanket npm-registry block —
some other, more specific policy decision denies this particular fetch. Not
configured anywhere in `policies/openclaw-sandbox.yaml` (no npm/registry
entries exist there at all), so it must come from OpenShell's own base
sandbox policy or a supply-chain control outside this project's
configuration surface — see constraint #4e (left open; not needed for the
fix below). Reverted the `package.json` change (harmless no-op, since `npm
install` never completed).

**Real fix (validated live, 2026-07-25)**: backported the fix as a source
patch on the already-installed `@mlflow/core@0.2.0` file, sidestepping the
npm registry entirely — the same technique already used for two other
compatibility gaps on this same plugin (constraint #5), just applied one
file deeper into the dependency tree. `dist/auth/index.js`'s
`createOssAuth().headersProvider` builds `Content-Type`/`Authorization` but
never `X-MLFLOW-WORKSPACE`; patched it to add the header from
`process.env.MLFLOW_WORKSPACE` when set:

```javascript
const headersProvider = async () => {
    const headers = { 'Content-Type': 'application/json' };
    if (authHeader) {
        headers['Authorization'] = authHeader;
    }
    const workspace = options.workspace || process.env.MLFLOW_WORKSPACE;
    if (workspace) {
        headers['X-MLFLOW-WORKSPACE'] = workspace;
    }
    return headers;
};
```

**Confirmed live**: with this patch plus the fixes in constraints #4c and
#4d, a real chat turn produced a real trace, verified by querying RHOAI
MLflow's traces API directly (`request_id: tr-692adb65bddad6913a4ddfdd93929028`, `status: OK`, real input/output content) —
and `scripts/prompt-registry/prompt-trace-linker.js` tagged it on its very next poll cycle.
Full pipeline (gateway → RHOAI MLflow trace → linker tag) works end-to-end,
with `HTTP 200` MaaS chat throughout (no regression). See
`docs/adrs/ADR-0017-rhoai-mlflow-scope.md`'s 2026-07-25 "Resolution" section.

**Scripts affected**: `scripts/launch-openclaw.sh` (Step 7's
`patch-mlflow-plugin.py` heredoc, extended with a third, idempotent patch
function for `@mlflow/core/dist/auth/index.js`).

## 4c. `NODE_EXTRA_CA_CERTS` is Single-Value: Must Be Extended, Never Overwritten (RESOLVED)

**Constraint**: the OpenShell sandbox runtime itself already sets
`NODE_EXTRA_CA_CERTS=/etc/openshell-tls/openshell-ca.pem` on every gateway
process (confirmed via `/proc/<pid>/environ`, not just `oc exec`'s own
shell env — that value is injected by OpenShell, not by anything in this
repo). It also sets `HTTPS_PROXY=http://<sandbox-proxy>:3128` and
`NODE_USE_ENV_PROXY=1`, which makes Node's (experimental)
`EnvHttpProxyAgent` route **every** `fetch()` call through the sandbox proxy
via HTTP `CONNECT`, for any destination. `openshell-ca.pem` is the CA that
signs the proxy's own MITM certificates on every endpoint the proxy
terminates TLS for (i.e. every endpoint *without* `tls: skip`, such as
`maas_inference`) — Node needs to trust it for MaaS chat to work at all.

To make the `mlflow-openclaw` plugin's plain Node `fetch()` also trust RHOAI
MLflow's `service-ca`-signed certificate (needed even with `tls: skip` on
the network policy — the plugin's own TLS handshake with real MLflow still
needs a trusted CA; `MLFLOW_TRACKING_SERVER_CERT_PATH` is a no-op, see
constraint #4b), an earlier attempt pointed `NODE_EXTRA_CA_CERTS` at a file
containing *only* the RHOAI CA via `--env`. Since it's a single-value env
var, this **overwrote** (not extended) OpenShell's baseline value — Node
stopped trusting the proxy's own MITM cert, breaking the MaaS call in the
same process (`SELF_SIGNED_CERT_IN_CHAIN`, then
`RequestAbortedError: Proxy response (403) !== 200 when HTTP Tunneling`).

**Fix (validated live, 2026-07-25)**: `NODE_EXTRA_CA_CERTS` accepts a file
with one or more **concatenated** PEM certificates. Build a combined bundle
— `cat openshell-ca.pem service-ca.crt > combined.pem` — and point
`NODE_EXTRA_CA_CERTS` at the union, never at a file containing only the new
CA. Confirmed live: with the combined bundle, `POST /v1/chat/completions`
through the gateway → MaaS returned `HTTP 200` (no regression), and the
`mlflow-openclaw` plugin's `fetch()` to RHOAI MLflow got past the TLS layer
for the first time (see constraint #4d for the *next* blocker this
uncovered — the fix here was necessary but not sufficient on its own).

**Scripts affected**: `scripts/launch-openclaw.sh` (builds
`.combined-ca-bundle.pem` in the sandbox workspace and always points
`NODE_EXTRA_CA_CERTS` at it — RHOAI MLflow wiring is unconditional, see
ADR-0018).

## 4d. `tls: skip` Policy Endpoints Require an *Exact* Hostname String Match — FQDN vs. Short Service Name Silently Defeats It

**Constraint**: the sandbox proxy's `CONNECT`-tunnel handler matches the
requested destination host against the exact string configured in
`policies/openclaw-sandbox.yaml`'s `host:` field — no DNS-equivalence or
suffix matching. If application code builds the URL with a *different but
equivalent* hostname (e.g. the FQDN `<svc>.<ns>.svc.cluster.local` instead
of the short 3-label Kubernetes Service DNS form `<svc>.<ns>.svc` that the
policy is keyed on), the `CONNECT` request never matches that policy entry
(so `tls: skip`, or any other setting on it, never applies) and falls
through to default-deny.

**Failure mode**: `curl: (56) CONNECT tunnel failed, response 403` (or, from
Node's `fetch()`, `TypeError: fetch failed` with
`cause: RequestAbortedError [AbortError]: Proxy response (403) !== 200 when
HTTP Tunneling`) — **looks exactly like the TLS-trust failures in
constraints #4b/#4c** from the client's point of view (curl/Node report both
as connection failures), even though the actual cause has nothing to do with
TLS, certificates, tokens, or RBAC — all of which can be (and, in the
incident this was found in, were) completely correct.

**How it was found**: reproduced with a byte-identical request pair, only
the hostname changed:

```bash
# Matches policies/openclaw-sandbox.yaml's host: "mlflow.redhat-ods-applications.svc" → 200
curl --cacert ca.crt -H "Authorization: Bearer $TOKEN" -H "X-MLFLOW-WORKSPACE: openshell" \
  "https://mlflow.redhat-ods-applications.svc:8443/api/2.0/mlflow/experiments/get-by-name?experiment_name=openclaw-tracing"

# Same cert, same token, same header — but FQDN doesn't match the policy's host string → 403
curl --cacert ca.crt -H "Authorization: Bearer $TOKEN" -H "X-MLFLOW-WORKSPACE: openshell" \
  "https://mlflow.redhat-ods-applications.svc.cluster.local:8443/api/2.0/mlflow/experiments/get-by-name?experiment_name=openclaw-tracing"
```

**Fix**: always build service URLs for anything that has to pass through the
sandbox proxy using the exact hostname string configured in
`policies/openclaw-sandbox.yaml` — in this project's case, the short
`<svc>.<ns>.svc` form (no `.cluster.local` suffix). `scripts/wire-rhoai-mlflow-tracing.sh`'s `RHOAI_MLFLOW_SVC_URL` was fixed to build the short
form; it feeds `RHOAI_MLFLOW_TRACKING_URI` in `.rendered/rhoai-mlflow/wiring.env`, which is what both `scripts/launch-openclaw.sh` (gateway's
`openclaw.json` `trackingUri`) and `scripts/prompt-registry/prompt-trace-linker.js`
(`MLFLOW_URL`) consume — so both sides of the wiring were fixed by this one
change. This constraint generalizes beyond MLflow: **any future `tls: skip`
(or other per-host) policy entry must be referenced by the exact same
hostname string everywhere in application code**, not just an
IP/DNS-equivalent one.

**Scripts affected**: `scripts/wire-rhoai-mlflow-tracing.sh`
(`RHOAI_MLFLOW_SVC_URL`).

## 4e. `npm install` of a Specific Package/Version Can Be Denied by an Undocumented OpenShell Policy (open, not root-caused)

**Constraint**: requesting a *specific* npm package/version
(`@mlflow/core@0.3.0`, via an `overrides` entry — see constraint #4b) failed
with:

```
npm error code E403
npm error 403 403 Forbidden - GET https://registry.npmjs.org/@mlflow%2fcore - policy_denied
```

The same package name (`@mlflow/core`, resolving to `0.2.0`) was fetched
successfully moments earlier as a transitive dependency of
`@mlflow/mlflow-openclaw@0.2.0-rc.0`'s normal install. `policies/openclaw-sandbox.yaml` has **no** npm/registry-related entries at all — this repo does
not configure this behavior, so the denial must come from OpenShell's own
base sandbox policy (default npm registry allowlisting) or some other
supply-chain control outside this project's configuration surface.

**Not root-caused this session** — the mechanism (package-specific?
version-specific? some kind of pinning/allowlist tied to what was resolved
at sandbox-creation time?) is unknown. Flagged here so a future session
doesn't have to rediscover the symptom from scratch. See constraint #4b for
the fix this was blocking and the fallback options if it stays unresolved.

**Scripts affected**: none — investigation only, change was reverted.

## 5. Plugins — SDK Compatibility

**Constraint**: `@mlflow/mlflow-openclaw@0.2.0-rc.0` imports two modules that
do not exist in OpenClaw 2026.7.1:
1. `openclaw/plugin-sdk/diagnostics-otel` (not exported in 2026.7.1)
2. `openclaw/plugin-sdk/plugin-entry` (`definePluginEntry` not available)

**Why**: The plugin was built for a newer SDK version than what's installed.

**Failure mode**: `Cannot find module 'openclaw/plugin-sdk/diagnostics-otel'`
at gateway startup. The plugin fails to load and no traces are generated.

**Workaround**: `patch-mlflow-plugin.py` replaces both imports idempotently:
1. Replaces `onDiagnosticEvent` import with a no-op function
2. Replaces `definePluginEntry({...})` with a plain object export

**Scripts affected**: `launch-openclaw.sh` (Step 7)

## 6. Process Management

**Constraint**: The OpenClaw gateway process name is `openclaw-gateway` but it
resolves to `/usr/bin/node` in `/proc/<pid>/exe`. In `ps` output, the name is
truncated to `openclaw-gatewa` (15 chars). Stale lock files at
`.openclaw/state/*.lock` prevent restart even after process termination.

**Why**: Node.js-based CLIs use the binary as the process executable, and
Linux truncates process names to 15 characters.

**Failure mode**: Gateway fails to start with "lock file exists" or port
already in use.

**Workaround**: Before starting the gateway:
```bash
for p in $(pgrep -f "openclaw\|node" 2>/dev/null); do kill -9 $p; done
sleep 2
rm -f .openclaw/state/*.lock .openclaw/*.lock /tmp/openclaw/*.lock
```

**Scripts affected**: `launch-openclaw.sh` (Step 9)

## 7. Observability — OTEL Exporters and Trace Duplication

**Constraint**: Setting `OTEL_LOGS_EXPORTER=otlp` or `OTEL_METRICS_EXPORTER=otlp`
can cause the gateway to attempt outbound connections to OTel endpoints that the
proxy may block. Additionally, if `diagnostics.otel.traces` is `true` in the
config, BOTH `diagnostics-otel` AND `mlflow-openclaw` will generate traces,
causing duplication (2 traces per interaction).

**Why**: OpenClaw has two independent trace pipelines. We want only
`mlflow-openclaw` active, because it generates richer traces with span
hierarchies and prompt metadata.

**Failure mode**: Duplicate traces in MLflow. Or, network connections to OTel
endpoints are DENIED by proxy, causing error spam in logs.

**Workaround**:
1. Set all `OTEL_*_EXPORTER=none` in the gateway environment
2. Set `diagnostics.otel.traces: false` in `openclaw.json.tpl`
3. Disable `diagnostics-otel` plugin in config

**Scripts affected**: `launch-openclaw.sh` (Step 9), `config/openclaw.json.tpl`

## 8. Sidecar Communication — curl vs fetch()

**Constraint**: The prompt-trace-linker sidecar needs to make HTTP requests to
MLflow (in-cluster). Node.js `fetch()` is blocked by the proxy's L7 binary
resolution issue (same as constraint #3). However, `/usr/bin/curl` IS allowed
by the proxy policy.

**Why**: The linker polls MLflow for traces and tags them. It runs as a Node.js
script but its HTTP traffic is denied because the proxy can't reliably resolve
the Node.js binary for ephemeral connections.

**Failure mode**: `[linker] Error: fetch failed` in linker log. Traces appear
in MLflow but never get prompt tags.

**Workaround**: `prompt-trace-linker.js` uses `child_process.execFileSync('/usr/bin/curl', ...)`
for all HTTP requests instead of `fetch()`.

**Scripts affected**: `scripts/prompt-registry/prompt-trace-linker.js`

## 9. OIDC Token TTL

**Constraint**: The default Keycloak access token TTL is 300s (5 minutes).
The `verify.sh` script takes longer than this to run, and `openshell` CLI
commands require a valid OIDC token.

**Why**: Keycloak has a conservative default token lifetime for security.

**Failure mode**: `openshell sandbox list` fails mid-verification with
"unauthorized" after the token expires.

**Workaround**: Increase the Keycloak access token TTL to 1800s (30 minutes)
using the Keycloak admin API during deployment.

**Scripts affected**: `scripts/cluster-lifecycle.sh`, `scripts/configure-oidc.sh`

## 10. Deploy Ordering

**Constraint**: The deployment phases have strict ordering dependencies:

1. `configure-oidc.sh` runs `helm upgrade`, so OpenShell MUST already be
   installed (otherwise: "has no deployed releases").
2. Provider creation requires an OIDC token, so `configure-oidc.sh` MUST run
   first (otherwise: "missing authorization header").
3. `deploy-oauth2-proxy.sh` (browser UI auth) only needs OpenShell running —
   since ADR-0016, it deploys `oauth-proxy` with OpenShift-native OAuth and
   no longer depends on Keycloak at all. Keycloak is still deployed earlier
   in the sequence purely because the CLI/gRPC OIDC path (`configure-oidc.sh`,
   step 7 below) still needs it as a JWKS-serving issuer.
4. RHOAI + MLflow (`deploy-rhoai-mlflow.sh`) MUST run BEFORE OpenShell —
   the `mlflow-integration` ClusterRole and RHOAI namespace it binds RBAC to
   must already exist when OpenShell's sandbox SA is created. Wiring
   (`wire-rhoai-mlflow-tracing.sh`) MUST run AFTER OpenShell — it binds RBAC
   to the `openshell-sandbox` ServiceAccount, which OpenShell creates.
5. `launch-openclaw.sh` needs the RHOAI MLflow wiring facts
   (`.rendered/rhoai-mlflow/wiring.env`) for prompt seeding/fetching and the
   provider to already exist for model routing.

**Why**: Each service has dependencies on the previous ones. The wrong order
causes cascading authentication or "not found" failures.

**Failure mode**: Various — `helm upgrade` fails, provider creation fails with
"missing authorization header", oauth-proxy has no backend, OpenClaw can't
reach the model provider, RBAC binding fails ("service account not found").

**Workaround**: Correct deploy order in `cluster-lifecycle.sh cmd_deploy()` (RHOAI
+ MLflow is unconditional since Phase 12/[ADR-0018](adrs/ADR-0018-rhoai-mlflow-sole-backend.md) — it is no longer gated behind `--with-obs`, which now only
controls the separate Tempo/OTel Collector infrastructure stack):
1. `bootstrap-ocp.sh` — namespace, SCCs, secrets
2. `deploy-keycloak.sh` — OIDC issuer available (CLI/gRPC path only, see #3 above)
3. `deploy-observability.sh` — Tempo + OTel Collector (infra logs/metrics only, `--with-obs`)
4. `deploy-rhoai-mlflow.sh` — RHOAI operator + minimal MLflow-only DataScienceCluster (unconditional)
5. `deploy-openshell.sh` with `WITH_OIDC=false` — Helm install without OIDC
   (the pod would block on the missing `openshell-oidc-ca` ConfigMap otherwise)
6. `wire-rhoai-mlflow-tracing.sh` — RBAC, SA token, experiment, CA, prompt seeding (unconditional)
7. `configure-oidc.sh` — creates OIDC CA ConfigMap + Helm upgrade with OIDC + obtain token
8. `create_provider` — now has OIDC token
9. `deploy-oauth2-proxy.sh` — needs OpenShell only (OpenShift-native OAuth, ADR-0016)
10. `launch-openclaw.sh` — everything ready

**Scripts affected**: `scripts/cluster-lifecycle.sh`, `scripts/deploy-openshell.sh`, `scripts/deploy-rhoai-mlflow.sh`, `scripts/wire-rhoai-mlflow-tracing.sh`, `scripts/common.sh`

## 11. Network Namespace — Process Start Location

**Constraint**: Processes that bind to `127.0.0.1` (like the OpenClaw gateway on
port 18789) MUST be started from within the sandbox network namespace, not from
the container's root network namespace. The OpenShell supervisor creates a
separate network namespace for sandbox processes. `oc exec` runs commands in the
container's root namespace, while both `openshell sandbox connect` and
`openshell sandbox exec` (gRPC exec endpoint) run commands in the sandbox
network namespace.

**Why**: The OpenShell service relay (which makes services like the Control UI
accessible via external routes) connects to ports through the supervisor's SSH
tunnel, which operates in the sandbox network namespace. If a process binds to
`127.0.0.1:18789` in the container root namespace, the relay cannot reach it
because `127.0.0.1` is different in each network namespace.

**Failure mode**: The web UI shows "Service endpoint is not reachable". The
OpenShell gateway logs show `Connection refused (os error 111)` and
`service endpoint unreachable` for every relay attempt. Confusingly, `oc exec`
+ `curl http://127.0.0.1:18789/health` works (because `oc exec` also runs in
the container root namespace), making it look like the gateway is running fine.

**Workaround**: In `launch-openclaw.sh`:
1. Use `oc exec` only for root-privilege operations: kill processes, chown files,
   clean lock files, install packages
2. Use `openshell sandbox exec --no-tty` to start the gateway and trace linker
   processes (backgrounded with `nohup ... & disown`)
3. Fix file ownership (chown sandbox:sandbox) before starting, since
   `openshell sandbox exec` runs as user `sandbox`, not root

```bash
# Cleanup (root, container namespace)
oc exec $SANDBOX -c agent -- bash -c 'kill ...; chown ...'

# Start gateway (sandbox namespace — where the relay can reach it)
openshell sandbox exec -n $SANDBOX --no-tty --env HOME=/sandbox/workspace \
  -- bash -c 'nohup openclaw gateway run ... & disown'
```

**`sandbox exec` vs `sandbox connect`**: Both run in the sandbox network
namespace via the same underlying gRPC path, but `sandbox exec` is preferred
for scripted/non-interactive process startup:
- `--no-tty` avoids PTY escape sequences (e.g. `\[?2004`) that `sandbox
  connect` emits and that previously had to be filtered out of captured
  output with `grep -v '^\[?2004'`.
- `--env KEY=VALUE` sets environment variables natively, instead of prefixing
  them inline on the command string piped into `sandbox connect`.
- Validated live (2026-07): a process started via `sandbox exec --no-tty` with
  `nohup cmd & disown` is reparented to pid 1 and remains running and
  reachable on the sandbox's loopback after the exec channel closes —
  equivalent detachment behavior to `sandbox connect`.

**Scripts affected**: `launch-openclaw.sh` (Step 9a, 9b, 9c)

## 12. TLS Route Stabilization After Helm Upgrade

**Constraint**: After a `helm upgrade` that restarts the OpenShell gateway pod,
the OpenShift HAProxy router needs several seconds to re-establish TLS passthrough
to the new pod. During this window, `openshell` CLI commands fail with
"tls handshake eof".

**Why**: The OCP router detects the old pod terminating and the new pod starting,
but there's a brief window where the route's backend is not ready. Passthrough
TLS is especially sensitive because the router can't health-check the backend
at L7.

**Failure mode**: `openshell status` or `openshell provider create` returns
"tls handshake eof" or "client error (Connect)" immediately after a successful
rollout.

**Workaround**: Retry CLI commands with a 5-second backoff after helm upgrades:
```bash
retries=0
while ! openshell status &>/dev/null; do
  retries=$((retries + 1))
  [[ $retries -ge 10 ]] && break
  sleep 5
done
```

**Scripts affected**: `scripts/configure-oidc.sh`, `scripts/cluster-lifecycle.sh` (Phase 5b)

## 13. Workspace File Ownership After Root Operations

**Constraint**: Several `launch-openclaw.sh` steps run as root (`oc exec`) and
create/modify files under `/sandbox/workspace/`. The OpenClaw gateway runs as
user `sandbox`, so any root-owned files it needs to write will cause EACCES
permission denied errors.

**Why**: Root operations include config injection, prompt seeding, plugin
installation, and directory creation. These all create files/dirs with
`root:root` or `root:sandbox` ownership. The gateway process (and its plugins)
then cannot write workspace state, agent state, or traces.

**Known files that must be sandbox-owned**:
- `/sandbox/workspace/openclaw-workspace-state.json` — gateway session state
- `/sandbox/workspace/.openclaw/agents/` — per-agent state (model warmup, chat history)
- `/sandbox/workspace/.openclaw/state/` — gateway runtime state + locks
- `/sandbox/workspace/.prompt-versions.json` — prompt version tracking
- `/sandbox/workspace/openclaw.log` — gateway log output
- Lock files in `/tmp/openclaw-<uid>/` — per-UID gateway locks (NOT just `/tmp/openclaw/`)

**Failure modes**:
- `EACCES: permission denied, open 'openclaw-workspace-state.json'` — all chat
  messages fail silently. The WebSocket connects but every message returns an
  error. No MLflow traces are generated because the agent pipeline never executes.
- `EACCES: permission denied, mkdir '.openclaw/agents/main/agent'` — model warmup
  fails, first request is slow or errors.
- Stale locks in `/tmp/openclaw-<uid>/` — gateway refuses to start with
  "gateway already running (pid N)" even when PID N is dead.

**Workaround**: After all root operations but before starting the gateway,
`chown` everything the gateway needs to write:
```bash
chown -R sandbox:sandbox /sandbox/workspace/.openclaw/state/
chown -R sandbox:sandbox /sandbox/workspace/.openclaw/agents/
chown sandbox:sandbox /sandbox/workspace/openclaw-workspace-state.json
chown sandbox:sandbox /sandbox/workspace/.prompt-versions.json
rm -f /tmp/openclaw-*/*.lock
```

**Scripts affected**: `scripts/launch-openclaw.sh` (Step 9a)

## 14. L7 Proxy Failure Modes — Credential Injection and Policy Denial

**Context**: While comparing this deployment against `claw-operator` (which
documents an explicit `502` for credential-injection failures and `403` for
disallowed domains — never a silent passthrough), an audit of OpenShell's L7
proxy (`crates/openshell-supervisor-network/src/l7/`) found that OpenShell
implements **two different failure behaviors** depending on *which* credential
mechanism fails, and only one of them matches the `claw-operator` pattern.

**Policy denial (domain/path not allowed)** — matches `claw-operator`'s `403`
pattern exactly. `deny_with_redacted_target` in
[`crates/openshell-supervisor-network/src/l7/rest.rs`](../../../OpenShell/crates/openshell-supervisor-network/src/l7/rest.rs)
writes a structured `403` JSON body (policy name + reason), called from
`relay.rs` when `allowed` is `false` and enforcement mode is not `Audit`. This
is the path exercised by `verify.sh` Layer 4 (`github.com` → expected 403).

**OAuth/token-grant credential injection failure** — also matches
`claw-operator`'s `502` pattern. In
[`crates/openshell-supervisor-network/src/l7/relay.rs:910-923`](../../../OpenShell/crates/openshell-supervisor-network/src/l7/relay.rs),
if `token_grant_injection::inject_if_needed()` fails, the relay explicitly
calls `write_bad_gateway_response(client)` (`502`) before closing the
connection. No silent passthrough here either.

**Generic placeholder credential injection failure (`openshell:resolve:env:KEY`)
— does NOT match the pattern.** This is the mechanism actually used by this
deployment for MaaS API key injection (constraint #3 above). When a request
carries an `openshell:resolve:env:...` placeholder that the `SecretResolver`
cannot resolve, the fail-closed scan in `rewrite_http_header_block`
([`rest.rs:481-482`](../../../OpenShell/crates/openshell-supervisor-network/src/l7/rest.rs))
returns `Err` *before any bytes are written to the client or upstream*. That
error propagates via `?` through `relay_http_request_with_options_guarded` →
`relay_rest` (`relay.rs:943`) → `relay_with_inspection` → the caller in
`proxy.rs`, with **no explicit HTTP response written at any point** — the
connection is simply torn down (TCP/TLS reset), not answered with `502`.

This is not a credential leak — the test
`relay_request_without_resolver_fails_closed_on_placeholder`
([`rest.rs:4868-4927`](../../../OpenShell/crates/openshell-supervisor-network/src/l7/rest.rs))
proves zero bytes reach upstream when the placeholder is unresolved, so the
fail-closed security invariant holds. The gap is purely observability: an
operator or client sees a generic connection-reset/EOF instead of a `502`
they could alert on or distinguish from a network blip.

**Failure mode**: If the MaaS API key credential ever fails to resolve (e.g.
provider misconfiguration, stale env), OpenClaw's HTTP client sees a connection
reset rather than a `502` response body, making the root cause harder to
diagnose from gateway logs alone (an OCSF `warn!` is emitted server-side, but
the client gets no status code to correlate).

**Workaround**: None needed for this deployment today — the credential is
injected successfully in the current setup (constraint #3's workaround avoids
this exact mechanism for Node.js `fetch()` anyway). Flagged for upstream
awareness: OpenShell could route the placeholder-resolution failure through
the same `write_bad_gateway_response()` helper already used for
`token_grant_injection` failures, for consistent `502` semantics across all
credential-injection failure modes.

**Scripts affected**: None (informational finding, no local workaround
required). Relevant upstream files: `crates/openshell-supervisor-network/src/l7/rest.rs`,
`crates/openshell-supervisor-network/src/l7/relay.rs` (OpenShell repo).

---

## Constraint #12: MLflow Artifact URI Scheme (OBSOLETE — standalone MLflow removed)

**Status**: This constraint applied only to the standalone
`ghcr.io/mlflow/mlflow` deployment (`manifests/observability/mlflow.yaml`),
which was removed entirely — see
`docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md`. RHOAI-managed MLflow (the
sole backend now) is operator-provisioned with its own artifact-store
configuration (backed by RHOAI's own storage, not a bare
`--default-artifact-root=/mlflow/artifacts` local-filesystem flag this repo
controlled) and was never observed to hit this specific `Invalid URL`
failure mode during the Phase 12 validation — span hierarchy came through
correctly in the real trace captured there. Kept below verbatim as a
historical record in case a similar artifact-URI-scheme class of bug ever
resurfaces against RHOAI MLflow; **`manifests/observability/mlflow.yaml`, the
file this fix pointed at, no longer exists.**

**Problem**: The `@mlflow/core` JS client expects trace artifact locations to use
the `mlflow-artifacts://` URI scheme (e.g. `mlflow-artifacts:/0/traces/tr-.../artifacts`).
When MLflow is configured with `--default-artifact-root=/mlflow/artifacts` (a local
filesystem path), it stores artifact locations as plain paths
(`/mlflow/artifacts/0/traces/tr-.../artifacts`). The JS client then calls
`new URL(artifactUri)` which fails with `TypeError: Invalid URL` because the string
is not a valid URL.

**Symptom**: Gateway logs show `Failed to export trace: TypeError: Invalid URL` at
`MlflowArtifactsClient.resolveArtifactUri`. Traces appear in the MLflow UI with basic
input/output JSON but **no span hierarchy** (no `llm_call`, `tool_call`, or
`subagent` spans visible). The "Detailed assessments" view shows raw JSON instead of
the rich trace timeline.

**Root cause**: MLflow server needs `--serve-artifacts` flag and
`--default-artifact-root=mlflow-artifacts:/` to use the HTTP artifact proxy and
generate proper `mlflow-artifacts://` URIs.

**Fix**: In `manifests/observability/mlflow.yaml`:
```yaml
args:
  - --default-artifact-root=mlflow-artifacts:/
  - --artifacts-destination=/mlflow/artifacts
  - --serve-artifacts
```

After changing the config, existing experiments in the SQLite DB retain their old
`artifact_location`. Update them:
```python
UPDATE experiments SET artifact_location = 'mlflow-artifacts:/<id>'
WHERE artifact_location LIKE '/mlflow/artifacts/%';
```

Existing trace tags also need updating:
```python
UPDATE trace_tags
SET value = REPLACE(value, '/mlflow/artifacts/', 'mlflow-artifacts:/')
WHERE key = 'mlflow.artifactLocation'
AND value LIKE '/mlflow/artifacts/%';
```

**Scripts affected**: `manifests/observability/mlflow.yaml`,
`scripts/deploy-observability.sh`

---

## 15. `verify.sh` False Positives — Gateway Config-Write Restarts and BOOTSTRAP.md Lifecycle

**Context**: Found while running the full `verify.sh` suite to green after the
constraint #14 audit. Two Layer 5b/8b checks failed consistently, but both
turned out to be flaws in the *test's* assumptions, not real deployment
defects. Both are now fixed in `scripts/verify.sh` directly (see inline
comments there); this entry records the root-cause evidence.

**Finding A — `gateway.http.endpoints.chatCompletions.enabled` writes restart
the whole gateway.** Layer 5b Check 4 temporarily flips this config key to
`true`, sends a real `/v1/chat/completions` request, then (previously) flipped
it back to `false` immediately. Layer 5b Check 5 then polled MLflow for a
fresh trace from that request and consistently found a stale one (many
minutes old).

Root cause, confirmed from both sides:
- OpenClaw's gateway config-reload planner
  (`src/gateway/config-reload-plan.ts` in the openclaw repo) has no specific
  rule for `gateway.http.endpoints.*`, so it falls through to the catch-all
  `{ prefix: "gateway", kind: "restart" }` rule. Writing this key always
  restarts the gateway (confirmed live in `openclaw.log`:
  `[reload] config change requires gateway restart
  (gateway.http.endpoints.chatCompletions.enabled)` → `SIGUSR1` → in-process
  restart, same PID, ~30ms shutdown).
- The `mlflow-openclaw` plugin flushes each trace asynchronously
  (`queueMicrotask` in `agent_end`'s handler, `src/service.ts`) *after* the
  HTTP response has already been sent to the client — so `curl` returning
  successfully does not mean the trace has reached MLflow yet. A restart
  landing in that window drops the in-flight trace with no error (the
  "shutdown completed cleanly" log line does not wait for pending plugin
  flushes).
- The config-file watcher that triggers this restart also has multi-second
  detection latency (the completions *request itself* succeeds immediately
  because the route handler reads the config file live at request time — a
  separate, faster path than the watcher-driven reload). So a restart from
  the *enable* write can land seconds after the request already returned,
  independent of when the test disables the flag again.
- Manually reproducing the same request with **no** config write immediately
  before/after it showed the trace lands in MLflow within about a second of
  the LLM response — the plugin itself works correctly; only the restart
  race caused the staleness.

**Fix** (in `scripts/verify.sh`): added an 8s buffer sleep right after the
completions request returns (before evaluating the response or polling
MLflow), and deferred the `enabled=false` restore until *after* Check 5's
trace-recency poll completes, so the test no longer triggers a second,
self-inflicted restart while it's still waiting on the trace.

**Finding B — `BOOTSTRAP.md` is expected to disappear after the sandbox's
first real conversation.** Layer 8b's "N/7 prompt files are read-only" check
originally required all 7 fetched prompt files (`AGENTS`, `SOUL`, `TOOLS`,
`IDENTITY`, `USER`, `HEARTBEAT`, `BOOTSTRAP`) to permanently exist as
root-owned `chmod 444`. `BOOTSTRAP.md` was consistently the one missing file.

Root cause: this is intentional OpenClaw behavior, not a fetch/deploy failure.
`prompts/BOOTSTRAP.md`'s own text says *"This file is only shown during your
first conversation. After setup completes, it will not appear again."*
OpenClaw's workspace setup
(`src/agents/workspace.ts`, `fs.rm(bootstrapPath, { force: true })`) deletes
it once `workspaceHasBootstrapCompletionEvidence()` is true. The sandbox in
this deployment has had many real conversations (Playwright E2E chat runs
across prior `verify.sh` invocations), so `BOOTSTRAP.md` had already been
consumed and removed — permanently, going forward, by design.

**Fix** (in `scripts/verify.sh`): the read-only check now validates the 6
persistent prompt files (`AGENTS`/`SOUL`/`TOOLS`/`IDENTITY`/`USER`/`HEARTBEAT`)
separately from `BOOTSTRAP.md`. `BOOTSTRAP.md` being absent is treated as
healthy (setup already completed); it only fails if the file exists with any
permission other than `444` (an actual security regression).

**Scripts affected**: `scripts/verify.sh` (Layer 5b Check 4/5, Layer 8b).
Relevant upstream files (openclaw repo): `src/gateway/config-reload-plan.ts`,
`src/agents/workspace.ts`, `node_modules/@mlflow/mlflow-openclaw/src/service.ts`
(inside the sandbox at
`/sandbox/workspace/.openclaw/extensions/mlflow-openclaw/node_modules/@mlflow/mlflow-openclaw/src/service.ts`).

## 16. `verify.sh` Layer 7b WebSocket Probe — Flaky Under Rapid Repeated Runs

**Context**: Found while validating the `launch-openclaw.sh` simplification
plan (removal of the dead Node binary workaround, template-based API key
injection, baseline-comment fix, and the `sandbox connect` → `sandbox exec
--no-tty` migration for gateway/linker startup). None of those changes touch
`oauth-proxy`, WebSocket routing, or Layer 7b's check itself, but this finding
is recorded here since it surfaced during that validation.

**Observation**: `scripts/verify.sh` was run 6 times in immediate succession
against the same CRC sandbox (2 full `launch-openclaw.sh` redeploys + 6
`verify.sh` runs + 1 `configure-oidc.sh` OIDC refresh within ~35 minutes, to
rule out regressions from the plan's changes). Layer 7b's raw `curl`-based
WebSocket-upgrade probe (`Connection: Upgrade` / `Sec-WebSocket-*` headers
against the oauth-proxy route, expecting `HTTP 101`) passed on the first
clean run and then returned `HTTP 502` on every subsequent run, regardless of
cooldown time (tested up to a 2-minute gap between runs).

**This is not a functional regression**: in every single one of those 6 runs
— including the ones where the raw curl probe reported `502` — Layer 9's
Playwright suite (a real browser logging in, opening the Control UI, and
completing "E2E chat: Claude responds via MaaS" over the *same* WebSocket
path) passed. `oauth-proxy`'s own logs show no error or `502` logged for the
probe's timestamp, and the sandbox's `openclaw.log` shows real webchat
connections succeeding and receiving `200` model responses throughout the
same window. Layer 5b (LLm connectivity, including the constraint #2 binary
policy check) and the MLflow trace/prompt pipeline (Layers 8/8b) stayed green
across all 6 runs.

**Likely cause (not fully isolated)**: the synthetic `curl -m 3` WS-upgrade
probe leaves a connection in a non-standard state (curl aborts a successful
`101` upgrade via its own timeout rather than a clean close, since a
successful WebSocket upgrade never "completes" from curl's perspective — see
the comment above the check in `verify.sh`). Repeating this probe many times
within a short window against the same passthrough-TLS route, on a
single-node CRC cluster already under load from repeated `sandbox exec`
calls and Playwright browser instances, plausibly exhausts a connection or
session resource specific to that raw-curl code path without affecting real
browser-driven WebSocket clients.

**Workaround**: None needed — this is a test-probe artifact under
unrealistic rapid-repeat load, not a deployment defect. A normal single
`launch-openclaw.sh` + `verify.sh` cycle (the actual supported workflow) sees
this check pass. If it recurs during normal (non-stress-tested) usage,
treat Layer 9's Playwright chat result as the authoritative signal for
whether chat actually works, and check `oc -n openshell logs deploy/oauth-proxy`
plus `openclaw.log`'s `[ws]` lines for real errors before assuming a
regression.

**Scripts affected**: None (informational finding from validation testing,
no code change required). Relevant file: `scripts/verify.sh` (Layer 7b).

## 17. `verify.sh` Layer 5b Check 4 False Positive — `gateway.reload.mode=off` Makes the chatCompletions Toggle a No-Op

**Context**: Found while live-validating the standalone-MLflow-removal
migration (`docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md`) on the current
OpenClaw build (`2026.7.1`). Layer 5b Check 4 (`scripts/verify.sh`)
temporarily flips `gateway.http.endpoints.chatCompletions.enabled` to `true`
on disk, immediately sends a real chat completion request over that
endpoint, then restores it to `false` — relying on the assumption
documented in constraint #15 ("the route handler reads the config file live
at request time"). Check 5 (the actual MLflow trace-recency poll) then
consistently reported the latest trace as stale, even right after a fresh
`launch-openclaw.sh` relaunch with no other activity.

**Root cause, confirmed live with a manual, unwrapped `curl -v`**: the
running gateway process's `openclaw.log` shows
`gateway.reload.mode=off` on every config-file write — Check 4's toggle
write is detected but explicitly **not** applied to the running process
(`[reload] config change detected; evaluating reload (...)` immediately
followed by `[reload] config reload disabled (gateway.reload.mode=off)`).
A direct, verbose `curl` to `/v1/chat/completions` immediately after the
toggle write returns a real `HTTP 404 Not Found` — the endpoint truly never
gets registered on the running process, contradicting constraint #15's
"live per-request read" theory for this OpenClaw version. Only a full
gateway process restart (which re-reads `openclaw.json` from disk at
startup, same as any other config value) picks up the change.

**Why Check 4 still reports a false PASS**: `sandbox_run` (the wrapper
Check 4 uses) runs commands through a PTY, and per constraint #15's own
prior finding, a PTY **echoes the input command text back before
executing it**. Check 4's own curl command line contains the literal
strings `Content-Type` and `VERIFY_OK` (in `-H 'Content-Type:
application/json'` and the test message `"Reply with exactly: VERIFY_OK"`).
Check 4's success grep (`grep -qi "choices\|content\|VERIFY_OK"`) matches
against that **echoed input**, not the real (404) response body — so it
reports "Gateway LLM request completed (model responded)" even though no
request ever actually reached the model through this path. Check 5, which
queries RHOAI MLflow's real trace API directly (no PTY echo involved), is
the one giving the *correct* signal — its `FAIL` here is real, just not
caused by anything wrong with the RHOAI MLflow wiring itself.

**Confirmed NOT an RHOAI MLflow regression**: the `mlflow-openclaw` plugin
loads and initializes correctly on every fresh gateway start
(`[plugins] mlflow: exporting traces to https://mlflow.redhat-ods-applications.svc:8443 (experiment=1)`), and a real trace from an
earlier, successful validation (`tr-692adb65bddad6913a4ddfdd93929028`, see
ADR-0017's "Resolution" section) is still queryable via the real API with
full input/output content — Layer 8's "MLflow native traces" and "MLflow
trace content" checks (`scripts/verify.sh`) both pass. The gap is purely in
Check 4/5's synthetic-request mechanism, which would fail identically
regardless of which MLflow backend (standalone or RHOAI) sat behind the
plugin — it's a `gateway.reload.mode` / PTY-echo interaction, unrelated to
the backend migration this session performed.

**Not fixed in this session**: a real fix requires either (a) restarting
the gateway process after the config toggle (adds meaningful complexity/
risk to `verify.sh`'s process-management logic for a synthetic test path),
or (b) finding a different way to exercise a real chat turn without
touching `gateway.http.endpoints.*` at all (e.g. driving the WebSocket path
the same way Playwright/Layer 9 already does, which is unaffected by this
bug). Flagged as a known follow-up rather than patched here, to avoid
scope creep on top of the standalone-MLflow-removal migration.

**Scripts affected**: `scripts/verify.sh` (Layer 5b Checks 4/5) — no code
change made; this entry documents the finding for whoever picks up the
follow-up. Relevant OpenClaw internals: `gateway.reload.mode` config,
`src/gateway/config-reload-plan.ts`.

## 18. `openshell` CLI OIDC Token Refresh Fails on CRC — Self-Signed Router CA Not in System Trust Store

**Context**: Found live during a fully fresh `cluster-lifecycle.sh full --fresh`
run (delete VM, recreate, redeploy everything). `scripts/verify.sh` and
`scripts/smoke-test-e2e.sh`, run a few minutes after
`scripts/configure-oidc.sh` (Phase 7) completed, both failed with a cascade
of confusing errors: `Sandbox 'openclaw-gw' not found`, `Expected sandbox
user, got unexpected identity`, `SECURITY: github.com should be blocked by
proxy` (false — the proxy check itself never ran), etc. — none of which were
real regressions; the sandbox was confirmed still `Ready` via
`openshell sandbox list` once the actual bug (below) was worked around.

**Root cause**: `scripts/configure-oidc.sh` (Phase 7) switches the gateway's
CLI auth mode from mTLS to OIDC and mints a short-lived access token +
refresh token from Keycloak, stored in
`~/.config/openshell/gateways/<name>/oidc_token.json`. The access token
expires after ~5 minutes. On every subsequent `openshell` CLI invocation
past that window, the CLI tries to use its refresh token against the OIDC
issuer (`https://keycloak-<ns>-keycloak.apps-crc.testing/realms/openshell/...`)
— but CRC's router uses a self-signed wildcard cert (`CN=*.apps-crc.testing`,
issued by `ingress-operator@...`) that is **not** in the host's system CA
trust store (`crc setup` only trusts the API server's own CA for `oc`/
`kubectl`, not the router's wildcard cert used by every `apps-crc.testing`
Route). The CLI's Rust HTTP client (`reqwest`/`rustls`) enforces real
certificate validation and fails the refresh call with a generic
`error sending request for url (...)`, then falls back to the already-
expired access token, producing `invalid token: ExpiredSignature` on every
gateway API call — which callers surface as unrelated-looking failures
(sandbox "not found", identity mismatches, etc.) because the CLI command
itself errored out before doing anything.

**Confirmed via manual repro**: `curl` (default, no `-k`) against the same
Keycloak discovery URL shows `SSL certificate OpenSSL verify result:
self-signed certificate in certificate chain (19)`; `curl -k` succeeds
(HTTP 200) — confirming a pure TLS-trust gap, not a network/DNS issue or an
actually-expired/invalid token chain.

**Fix**: the `openshell` CLI has a documented, purpose-built flag for
exactly this — `--gateway-insecure` / `OPENSHELL_GATEWAY_INSECURE=true`
("Skip TLS certificate verification for gateway connections"). Setting the
env var (boolean string `true`, not `1` — the CLI's arg parser rejects `1`
with `invalid value '1' for '--gateway-insecure'`) immediately fixed both
the OIDC refresh and the downstream "sandbox not found" symptoms in the
same shell session. `scripts/common.sh`'s `detect_environment()` now
exports `OPENSHELL_GATEWAY_INSECURE=true` whenever `CRC_MODE=true` (same
place/rationale as the pre-existing `CURL_OPTS="-k"` for CRC), so every
script that sources `common.sh` and calls `detect_environment` (which is
effectively all of them) picks this up automatically for any `openshell`
CLI calls made afterward in the same process. Not set on AWS OCP — real,
trusted certs there, so the CLI's default strict verification is correct
and should stay on.

**Scripts affected**: `scripts/common.sh` (`detect_environment()`) — fixed.
No changes needed in `scripts/verify.sh` or `scripts/smoke-test-e2e.sh`
themselves; they inherit the env var by sourcing `common.sh`.

## 19. `openshell status` Fails mTLS Handshake for Several Minutes After `helm upgrade` of the OpenShell Chart

**Context**: Found while re-running `scripts/deploy-openshell.sh` repeatedly
against an already-deployed CRC cluster (i.e. `helm upgrade` on an existing
`openshell` release, not a fresh `helm install`) while validating the
Helm-chart-conversion simplification work. Immediately after "Registering
gateway with CLI (mTLS)", `openshell status` failed with:

```
Error:   × client error (SendRequest)
  ├─▶ connection error
  ╰─▶ received fatal alert: CertificateRequired
```

**Confirmed NOT a cert/config problem**: the gateway pod's own logs show the
server side of the same failure (`TLS handshake failed: error=peer sent no
certificates`), i.e. the client is not presenting its certificate at all —
but the exact same `ca.crt`/`tls.crt`/`tls.key` files, tested standalone with
`openssl s_client -cert ... -key ... -CAfile ...` against the same Route the
entire time, complete a full mTLS handshake successfully
(`Verify return code: 0 (ok)`). The pod never restarts (`RESTARTS: 0`,
`startTime` unchanged) and the PKI secrets' `resourceVersion` is unchanged
across the `helm upgrade` (the PKI init job only runs once, on first
install) — ruling out a real cert mismatch or secret rotation.

**Timing is not attempt-count-driven, it's wall-clock-driven, and highly
variable**: retrying `openshell status` in a tight loop (every 5s) fails
identically for the *entire* duration of the loop regardless of budget
(reproduced failing for a full 5 minutes / 60 attempts in one run, and a
full 6 minutes / 72 attempts in another, later, run against the exact same
never-restarted pod), then succeeds within roughly a minute of the loop
giving up and exiting — with zero code or state changes in between. This
was re-confirmed with a completely hands-off run (no concurrent
`openshell`/`oc` commands from the operator) to rule out self-inflicted
interference from concurrent CLI invocations sharing `~/.config/openshell/`
state; the delay is real, observed in the 10s–7min range across different
runs on the same host, and does not shrink or grow monotonically with the
number of prior `helm upgrade` cycles (the pod itself never restarts across
any of them — `RESTARTS: 0`, same `startTime` throughout). Most likely
explanation: contention/scheduling delay on a single dev box running the
full stack (RHOAI, MLflow, Keycloak, Observability, OpenShell) simultaneously
delays whatever periodic task on the server side is responsible for the
underlying reload, rather than a fixed timer — but this remains unconfirmed.

**Likely root cause: host-level memory pressure, not an application bug**.
While chasing this live, `free -h` on the host showed severe pressure during
the failures — well under 1 GiB truly free RAM and 6+ GiB of swap in active
use, on a host running a 42 GiB CRC VM (`qemu-system-x86_64` alone at ~34 GiB
RSS) alongside a normal heavy desktop session (browser, IDE). A guest VM
under host-side memory contention/swapping sees essentially random, large
latency spikes injected into arbitrary guest operations (scheduling, network
I/O, crypto) with no visible cause from inside the guest — which fully
explains symptoms that otherwise look inexplicable: identical inputs
(same cert files, same pod, `openssl s_client` proving the certs and route
are fine) producing wildly different outcomes (10s to 8+ min) purely as a
function of wall-clock timing, worsening across a session of many repeated
`helm upgrade` cycles (each one growing the guest's own memory footprint via
release history, extra API objects, etc. on an already-tight host). A closed
-source `openshell` binary bug remains possible but is unconfirmed and, given
this evidence, less likely than host resource starvation as the primary
driver. Practical implication: if you hit this, check host `free -h`/swap
before assuming a code regression — closing memory-heavy host applications
(browser tabs, etc.) or giving the CRC VM less RAM may resolve it outright.

**Only ever observed after `helm upgrade`, not fresh `helm install`**: the
very first install (revision 1) on a truly fresh CRC VM hit a different,
much milder race ("client error (Canceled) / connection was not ready") that
resolves within seconds. The multi-minute "CertificateRequired" variant only
showed up once the same `openshell` Helm release had already been installed
and was being re-applied (`helm upgrade`) — i.e. normal single-shot
`cluster-lifecycle.sh full --fresh` runs are less likely to hit the slow path,
but repeated `deploy`/re-deploy cycles against a live cluster will.

**Restarting the gateway pod was tried and did not prove reliably faster**:
forcing a pod restart (`oc delete pod -l app.kubernetes.io/name=openshell`)
recovered near-instantly in one trial, but in two subsequent trials the
freshly-restarted pod (confirmed via a new pod IP and reset age) still
failed for the entire length of a post-restart retry window (60s and then
2 minutes, tried separately) before eventually recovering — no better than
just waiting on the original pod. Not pursued further as a mitigation.

**The real trigger turned out to be the `gateway remove`+`add` re-
registration itself, not passive readiness**: across many repeated trials,
a bare `openshell status` against an *already-registered, undisturbed*
gateway succeeded near-instantly essentially every single time (including
right after long stretches where a script's post-`remove`+`add` retry loop
had just failed for 5-10+ minutes) — while re-running `gateway remove ocp`
followed immediately by `gateway add` before checking status was the
unreliable step. This finally unblocked full end-to-end validation: with
the gateway left registered from an earlier attempt, Phases 6-9 and a full
`verify.sh` run (54 passed, 0 failed, 5 expected warnings, all 15
Playwright tests green including live E2E chat and security checks)
completed cleanly on the first try, no further mTLS issues at all.

**Fix**: `scripts/deploy-openshell.sh` now only touches the local mTLS cert
cache and calls `gateway remove`+`add` when `openshell status` isn't already
succeeding against the existing registration (skipping unnecessary churn on
repeat `deploy` runs against an unchanged Route — the status check happens
*before* any cert files are touched, since unconditionally rewriting them
first, even with identical content, invalidates the CLI's cached client.p12
and defeats the skip). When re-registration genuinely is needed (fresh
install, or the gateway actually dropped), it retries `openshell status`
with a bounded budget (40 attempts, 20s apart — ~13 minutes) before treating
it as fatal. Re-validated live on this host under sustained heavy memory
pressure (<1.5 GiB free, 7+ GiB/8 GiB swap in use throughout): even with the
skip-if-connected optimization working correctly, the gateway was observed
dropping and needing a fresh remove+add multiple times across one
multi-phase deploy run, twice exhausting a 20-attempt/6.5-minute budget
before succeeding seconds after the script gave up — hence the wider
40-attempt budget.

**Scripts affected**: `scripts/deploy-openshell.sh` — fixed (skip
unnecessary re-registration + retry loop). Flagged as a known upstream-
`openshell`-CLI/server quirk (the remaining first-install case) rather than
something fully fixable in this repo; a real fix for that residual case
would need to come from the `openshell` project itself.

## 20. MLflow Prompts Invisible in RHOAI Dashboard's Per-Experiment Prompts Tab (RESOLVED)

**Prerequisite for this whole section to even be reachable**: the RHOAI
Dashboard itself must be enabled (`dashboard.managementState: Managed` in
the `DataScienceCluster`, `Removed` by default per
`charts/rhoai/platform/values.yaml`) with `genAiStudio: true` set on its
auto-created `OdhDashboardConfig` (`charts/rhoai/platform/templates/
dashboard-config.yaml`). **This is AWS-OCP-only by design** —
`scripts/deploy-rhoai-mlflow.sh` sets both by passing the
`charts/rhoai/platform/values-aws.yaml` overlay only when `CRC_MODE` is
false; on CRC the Dashboard stays `Removed` (2 extra pods, 9
containers each, no functional benefit — Prompt Registry/tracing work fully
via the API/SDK either way, which is how every check in this section was
originally confirmed). The `openshell` namespace is unconditionally labeled
`opendatahub.io/dashboard: "true"` (`scripts/bootstrap-ocp.sh`, negligible
cost either way) so the Dashboard recognizes it as a Data Science Project
whenever it does run. See [ADR-0018](adrs/ADR-0018-rhoai-mlflow-sole-backend.md)'s
2026-07-27 amendment for the full scope decision. The namespace label
specifically was a dead end for the bug below (ruled out — prompts stayed
invisible with only the label applied, before the experiment-id fix).

**Symptom**: All 7 system prompts seeded by
`scripts/prompt-registry/seed-mlflow-prompts.sh` were confirmed present and
correctly tagged (`mlflow.prompt.is_prompt=true`) via both
`mlflow.genai.search_prompts()` (Python SDK) and a direct
`registered-models/search?filter=...` REST call against RHOAI-managed
MLflow — yet the RHOAI Dashboard's "Prompts" tab, nested under a specific
experiment (`/experiments/<id>/prompts?workspace=<ws>`), showed none of
them.

**Root cause, found by diffing a prompt created directly through that same
UI page against ours**: a prompt registered through the Dashboard's
per-experiment Prompts page picks up a `_mlflow_experiment_ids` tag on its
registered-model matching the *current* experiment
(e.g. `,1,` for `openclaw-tracing`). `seed-mlflow-prompts.sh` called
`mlflow.genai.register_prompt()` without ever setting an active experiment,
so MLflow defaulted every prompt's `_mlflow_experiment_ids` tag to `,0,`
(the "Default" experiment) instead. The Dashboard's per-experiment Prompts
view filters registered models by that tag matching the experiment in the
URL, so prompts living under experiment `0` are invisible on the
experiment `1` page — even though they are fully valid, gettable, and
searchable through every other API path, which don't apply that filter.

**Fix**: `scripts/prompt-registry/seed-mlflow-prompts.sh` now accepts an
optional `MLFLOW_EXPERIMENT_ID` env var and calls
`mlflow.set_experiment(experiment_id=...)` before registering any prompt
versions, tying them to the correct experiment.
`scripts/wire-rhoai-mlflow-tracing.sh` passes `RHOAI_MLFLOW_EXPERIMENT_ID`
(already captured from the experiment-creation Job's logs) through to it.
Re-seeding existing prompts appends the new experiment id to the tag
(`,0,1,`) rather than replacing it, and that alone was sufficient — the
Dashboard's filter appears to be a substring/membership check, not an exact
match — for all 7 prompts to immediately appear in the UI without needing
to delete and recreate them.

**Scripts affected**: `scripts/prompt-registry/seed-mlflow-prompts.sh`,
`scripts/wire-rhoai-mlflow-tracing.sh` — both fixed.

## 21. RHOAI Dashboard `genAiStudio` Silently Never Enabled on a Fresh AWS Deploy (RESOLVED)

**Context**: found live 2026-08-03 on a real AWS OCP cluster
(`sandbox659.opentlc.com`) while validating the user's explicit request to
enable the RHOAI Dashboard UI + GenAI Studio (constraint #20's
"AWS-OCP-only" prerequisite) on a large cluster where the Dashboard's extra
pods are affordable.

**Symptom**: `scripts/deploy-rhoai-mlflow.sh` printed "AWS OCP: enabling
RHOAI Dashboard (+ genAiStudio)" and `make -C charts/rhoai validate`
reported success, yet `oc get odhdashboardconfig odh-dashboard-config -n
redhat-ods-applications -o yaml` showed `dashboardConfig: {disableTracking:
false}` — no `genAiStudio` key at all. The Dashboard itself was `Ready` and
reachable; only the GenAI Studio nav (Experiments/Prompts/Traces) was
missing.

**Root cause — two stacked races, both on a truly fresh cluster only
(never CRC, where the Dashboard component stays `Removed`)**:

1. `charts/rhoai/platform/templates/dashboard-config.yaml` (the
   `OdhDashboardConfig` patch that sets `genAiStudio: true`) is gated on
   `.Capabilities.APIVersions.Has "opendatahub.io/v1alpha"`. The very first
   `helm upgrade --install rhoai-platform` that flips
   `dashboard.managementState` to `Managed` evaluates that guard *before*
   the CRD exists — the Dashboard operator only registers it a few seconds
   later, once it starts reconciling the newly-Managed component. The guard
   evaluates false, the patch is silently skipped, and Helm never even
   attempts to manage the object.
2. Once the CRD is registered, the Dashboard operator auto-creates the
   `odh-dashboard-config` singleton itself — without any Helm ownership
   metadata (since Helm never got to create it in race #1). A subsequent
   `helm upgrade` for the same release then fails outright: `"exists and
   cannot be imported into the current release: invalid ownership
   metadata"` — standard Helm 3 behavior refusing to silently adopt a
   resource it doesn't already own.

**Fix**: `charts/rhoai/Makefile`'s `deploy-platform` target now: (a) calls a
new `adopt-dashboard-config` target *before* every `helm upgrade` attempt,
which annotates/labels a pre-existing `odh-dashboard-config` object with the
exact `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`, and
`app.kubernetes.io/managed-by: Helm` metadata Helm itself would have set
(idempotent no-op if the object doesn't exist yet or is already owned); (b)
after the first `helm upgrade`, waits for the CRD *and* the object to exist
(`wait-dashboard-crd`), re-runs `adopt-dashboard-config`, then re-applies
the chart a second time so the now-unblocked template actually renders. The
`validate` target also gained an explicit check
(`genAiStudio enabled on OdhDashboardConfig`) so a regression here fails
loudly instead of silently, the same way constraint #20 was originally
invisible until manually diffed against the live cluster.

**Scripts affected**: `charts/rhoai/Makefile` (`deploy-platform`,
`wait-dashboard-crd`, `adopt-dashboard-config`, `validate`) — fixed and
confirmed idempotent across three consecutive re-runs on the live AWS
cluster (including one starting from the mid-broken, partially-adopted
state race #2 above left behind).

## 22. Re-running `deploy-rhoai-mlflow.sh` After Initial Wiring Silently Deletes the OpenClaw↔MLflow Integration (RESOLVED)

**Context**: found live 2026-08-03 immediately after fixing constraint #21
above — re-running `scripts/deploy-rhoai-mlflow.sh` to pick up that chart
fix on an AWS cluster that had already completed a full
`cluster-lifecycle.sh deploy` (OpenShell + `wire-rhoai-mlflow-tracing.sh`
already run once).

**Symptom**: `verify.sh` Layer 8 ("MLflow health returned HTTP 401") and
Layer 8b ("No prompts registered in MLflow" / "No @production aliases
set") started failing immediately after the redeploy, even though the
exact same checks had passed minutes earlier. Direct API reproduction
returned `{"error":{"code":"UNAUTHENTICATED","message":"Authentication
with the Kubernetes API failed. The provided token may be invalid or
expired."}}` (HTTP 401) using the cached token from
`.rendered/rhoai-mlflow/wiring.env`. `oc get secret
openshell-sandbox-mlflow-token -n openshell` came back `NotFound` — the
Secret backing that token no longer existed.

**Root cause**: `charts/rhoai/mlflow/templates/openclaw-integration-
rbac.yaml`'s RoleBinding + SA token Secret only render when
`openclawIntegration.enabled: true` (chart default: `false`).
`wire-rhoai-mlflow-tracing.sh` flips that on via its own, separate `helm
upgrade rhoai-mlflow` call (deliberately without `--reuse-values` — see
that script's own comment on why). `scripts/deploy-rhoai-mlflow.sh`'s
`make deploy-all` → `helm upgrade --install rhoai-mlflow` call computes
values from the chart's defaults + its own `HELM_OPTS` only, with no
awareness of `wire-rhoai-mlflow-tracing.sh`'s prior override — so it always
resets `openclawIntegration.enabled` back to `false`, deleting the
RoleBinding and the declarative SA token Secret Helm now considers
orphaned. Any cached token immediately stops validating against the
Kubernetes API (the Secret backing it is gone), even though the token
string itself still decodes fine as a JWT. This was invisible before
because `deploy-rhoai-mlflow.sh` had only ever been run once per
environment, before OpenShell (and thus the wiring) existed — the
destructive reset had nothing to destroy yet.

**Fix**: `scripts/deploy-rhoai-mlflow.sh` now checks, after its own
deploy+validate, whether `openshell-sandbox` SA already exists in the
`openshell` namespace (i.e. this is a re-run after the full stack was
already up, not the one-shot pre-OpenShell bootstrap run) and, if so,
automatically re-invokes `wire-rhoai-mlflow-tracing.sh` to restore the
RBAC/token/experiment wiring it would otherwise have just deleted. Also
note: the sandbox's already-running `openclaw-gateway`/`prompt-trace-
linker` processes bake the SA token in as an env var at process start
(`scripts/launch-openclaw.sh`) and do **not** pick up a refreshed token
without a restart — after any re-wiring, `./scripts/launch-openclaw.sh`
must be re-run too (it force-kills and restarts both processes
idempotently). A stray old `openclaw-gateway` process that survives one
cleanup pass (observed once, cause not fully isolated — possibly a PID
namespace/session artifact of `oc exec`) can also keep listening on
`:18789` with the stale token underneath a freshly-started instance that
then fails silently on the port conflict; if `launch-openclaw.sh` reports
"mlflow-openclaw plugin may not have loaded", check for and force-kill
duplicate `pgrep -af "openclaw|node"` processes in the sandbox before
re-launching.

**Scripts affected**: `scripts/deploy-rhoai-mlflow.sh` — fixed. Confirmed
live: re-wiring restored the RoleBinding/Secret/experiment, prompts
re-seeded cleanly (versions bumped 1→2, `@production` alias reapplied), and
a full `verify.sh` (full profile) + Playwright run afterward passed Layers
8/8b/9/10 end-to-end, including 5 real MLflow-native traces with prompt
tags from actual E2E chat turns.

## 23. RHOAI Dashboard "Gen AI studio" Nav Item Requires `llamastackoperator: Managed`, Not Just `dashboardConfig.genAiStudio: true` (RESOLVED)

**Context**: found live 2026-08-03, immediately after fixing constraint #21
(the `genAiStudio` CRD/ownership race). With `genAiStudio: true` correctly
landed on `OdhDashboardConfig` and the `rhods-dashboard` pods restarted, the
Dashboard's left nav still showed no "Gen AI studio" section at all — only
"Home / Projects / AI hub / Develop & train / Learning resources /
Applications / Settings", confirmed both via a live user screenshot and
independently by extracting the full rendered nav via
`document.querySelectorAll('nav a, nav button')` in an authenticated
browser session. Navigating directly to `/genAi` rendered the dashboard
shell's own "We can't find that page" 404 (a client-side router miss, not a
plugin-level 404) — proof the route was never registered at all, not just
hidden from the sidebar.

**Root cause**: the "Gen AI studio" nav (Playground / AI asset endpoints /
Prompts) is served by a separate `gen-ai-ui` sidecar container in the
`rhods-dashboard` pod (one of nine containers: `rhods-dashboard`,
`kube-rbac-proxy`, `model-registry-ui`, `gen-ai-ui`, `maas-ui`,
`mlflow-ui`, `eval-hub-ui`, `automl-ui`, `autorag-ui` — RHOAI 3.4's
dashboard is a module-federation shell loading each "hub" as an
independent micro-frontend). The dashboard shell's own logs confirmed it
*does* fetch the extension bundle
(`/_mf/genAi/remoteEntry.js`, `__federation_expose_extensions.bundle.js`)
once `genAiStudio: true` is set — but grepping that bundle inside a live
`gen-ai-ui` container
(`/static/__federation_expose_extensions.bundle.js`) turned up
`requiredComponents:[t.W.LLAMA_STACK_OPERATOR]`. `genAiStudio: true` only
controls whether the shell *attempts* to load the extension; the extension
itself then self-gates on the `llamastackoperator` DataScienceCluster
component's readiness, which this chart's `values.yaml` defaults to
`Removed` (same minimal-footprint rationale as everything else — see
ADR-0017). Two dead ends tried first before finding this: (1)
`dashboardConfig.modelAsService: true` (another real
`OdhDashboardConfig` field, seen paired with `genAiStudio` in some
community examples) — no effect; (2) a plain `rhods-dashboard` pod restart
with only `genAiStudio: true` set — no effect, since the actual blocker was
never about `OdhDashboardConfig` at all.

**Second race layered on top**: setting
`datasciencecluster.components.llamastackoperator.managementState: Managed`
and waiting for `LlamaStackOperatorReady=True` was still not enough on its
own — the nav item stayed absent until the `rhods-dashboard` deployment was
restarted *again*, after that condition went `True`. Whatever gates the
`gen-ai-ui` extension's capability check on the frontend/backend side
appears to be evaluated once (env/informer cache read at process start),
not via a live Kubernetes watch — the same general shape as constraint
#22's token problem (an already-running process not picking up a
just-satisfied prerequisite), just on the read side of the dashboard
instead of the write side of the MLflow wiring.

**Fix**: `datasciencecluster.components.llamastackoperator.managementState:
Managed` is now also set in `charts/rhoai/platform/values-aws.yaml`,
AWS-only (same conditional as the dashboard component itself — stays
`Removed` on CRC via `values-crc.yaml`, no functional loss there since this
project's own tracing/prompt-registry needs never depended on Gen AI
Studio). `charts/rhoai/Makefile`'s `deploy-platform` target gained a new
`wait-llamastack-and-refresh-dashboard` step, run whenever `HELM_OPTS`
requests `llamastackoperator: Managed`: waits for
`LlamaStackOperatorReady=True`, then `oc rollout restart
deployment/rhods-dashboard` so the already-running dashboard pods
re-evaluate the capability. `make validate` also gained a matching check
(`LlamaStackOperator ready (required for Gen AI Studio dashboard nav)`).

**Scripts affected**: `scripts/deploy-rhoai-mlflow.sh`,
`charts/rhoai/Makefile` (`deploy-platform`, `wait-llamastack-and-refresh-
dashboard`, `validate`), `charts/rhoai/platform/values.yaml` (comment only,
default stays `Removed`) — fixed and confirmed reproducible end-to-end via
a from-scratch automated re-run of `deploy-rhoai-mlflow.sh` (not just the
live manual patches used to diagnose it): "Gen AI studio" (with
"Playground", "AI asset endpoints", "Prompts" sub-items, all marked "Tech
Preview") appeared in the Dashboard nav on first login after that run.

**2026-08-03 follow-up — root-caused instead of just reacted-to**: the fix
above works, but only *reacts* to the race (wait, then restart) after the
`rhods-dashboard` pod has already booted with a stale capability snapshot.
`charts/rhoai/Makefile`'s `deploy-platform` now avoids the race at its
source for the common case (a from-scratch cluster, or any cluster where
the Dashboard component isn't already `Managed`): when `PLATFORM_ENV_VALUES`
is `platform/values-aws.yaml` and the current `DataScienceCluster` doesn't
already have `dashboard: Managed`, it first applies the chart with
`dashboard` force-overridden to `Removed` (one `--set-string` layered on
top of `values-aws.yaml`, kept minimal and well-commented since this one
step is a genuinely imperative bootstrap-ordering trick — see
`values-aws.yaml`'s own comment), waits for
`LlamaStackOperatorReady=True` (new `wait-llamastack` target, factored out
of `wait-llamastack-and-refresh-dashboard`), and only *then* runs the real
apply that turns `dashboard: Managed` on. The `rhods-dashboard` pod is
therefore never created until `llamastackoperator` is already `Ready`, so
its one-time capability snapshot at boot is already correct — no restart
needed. `wait-llamastack-and-refresh-dashboard`'s restart is kept as a
defensive fallback for the one case the sequencing doesn't cover: an
*upgrade* of an already-`Managed`, already-running dashboard where
`llamastackoperator` gets flipped on later (rare in this project, since
`deploy-rhoai-mlflow.sh` always requests both together) — on the common
fresh-install path it degrades to a fast, harmless no-op (`llamastackoperator`
is already `Ready`, so the restart is redundant but cheap).

This does **not** eliminate the CRD/ownership race in constraint #21 above
(`wait-dashboard-crd` / `adopt-dashboard-config` are still needed —
`genAiStudio` is a separate field on a separate CRD, raced against
independently of `llamastackoperator` timing) — only the read-side race
this constraint (#23) describes.

## 24. Prompt File Read-Only Protection (`chmod 444`) Is Bypassable via Directory Permissions — NOT YET FIXED

**Status: open, accepted risk, deferred.** See ROADMAP.md Phase 13.6 for the tracked follow-up.

**Constraint**: `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`,
`HEARTBEAT.md`, `BOOTSTRAP.md` are locked with `chown 0:0` + `chmod 444` after
being fetched from the MLflow Prompt Registry (`launch-openclaw.sh` Step 4),
intended to make them immutable to the agent. **This protection is
insufficient** — the agent can still overwrite these files' *content* (it
cannot forge the fetched-version metadata comment, but the body text is
fully attacker/agent-controlled).

**Why it fails**: these files live inside `/sandbox/workspace`, a directory
owned `sandbox:sandbox` with mode `700` (`filesystem_policy.read_write` in
`policies/openclaw-sandbox.yaml`). In POSIX, permission to delete or rename a
directory entry is governed by the **parent directory's** write permission,
not the target file's own mode bits. Since `sandbox` owns and can write to
`/sandbox/workspace`, it can `unlink()` any file inside it — including
root-owned, `chmod 444` files — and create a new file with the same name.
Most file-edit implementations (write-to-temp + atomic `rename()`, or
truncate+recreate) use exactly this pattern rather than opening the existing
file for in-place writing, so they succeed against `chmod 444` files without
ever needing write permission on the file itself.

**Live verification (2026-08-03)**: confirmed directly against the running
`openclaw-gw` sandbox, executing as the real `sandbox` user via `openshell
sandbox connect` (the same confinement the agent's own tools run under):

```
echo x >> AGENTS.md                        → Permission denied   (blocked correctly)
rm AGENTS.md && echo "hacked" > AGENTS.md  → succeeds, file now sandbox:sandbox
```

This was also observed for real in a live OpenClaw chat session: the agent's
`edit` tool reported `"Successfully replaced 1 block(s)"` against
`AGENTS.md`, and the file's owner changed from `root:root` to
`sandbox:sandbox` on disk afterward — proof the tool performed an
unlink+recreate, not an in-place write. (The tampering was reverted by
re-running `scripts/prompt-registry/fetch-prompts-from-mlflow.sh` +
re-applying `chown 0:0`/`chmod 444`, restoring all 7 files to their
`@production` MLflow versions.)

**Landlock does not help here either**: tested adding the specific file path
to `filesystem_policy.read_only` in the sandbox policy (while its parent
directory stays in `read_write`) via `openshell policy set` on the live
sandbox — the delete+recreate bypass still worked identically. Landlock's
remove-file permission is evaluated against the *parent directory's*
ruleset, not the child file's, so a file-level allow/deny entry doesn't stop
it from being unlinked by its parent.

**No native OpenClaw feature covers this either**: dumped the full config
schema (`openclaw config schema`) and found no per-path read-only/deny
option for the built-in filesystem tools (`read`/`write`/`edit`/
`apply_patch`) — only a whole-workspace `tools.fs.workspaceOnly` boolean
(all-or-nothing directory scoping, no fine-grained per-file protection). The
only `denyPaths`/`allowWritePaths`-shaped schema found is specific to the
`nodes` remote-exec plugin config, unrelated to the agent's own file tools
(and `nodes` is already in `tools.deny`).

**`verify.sh` blind spot**: Layer 8b's prompt-file check (`scripts/verify.sh`
~line 786) only asserts `stat -c %a == 444`; it never attempts an actual
write/delete, so this bypass produces no failing check today.

**Why not fixed yet**: a real fix requires restructuring where these files
live — e.g. a `root`-owned, non-`sandbox`-writable subdirectory, so the
*parent directory* itself denies `sandbox` unlink/rename rights — plus
verifying OpenClaw's startup-context loader can still discover
`AGENTS.md`/etc. at a relocated path (symlinks or a config option). Deferred
as an accepted risk for now (2026-08-03 decision) rather than implemented
immediately.

**Scripts affected (for the future fix)**: `scripts/launch-openclaw.sh`
(Step 4), `policies/openclaw-sandbox.yaml`, `scripts/verify.sh` (Layer 8b)


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

**Scripts affected**: `launch-openclaw.sh` (Step 3, Step 10)

## 2. Networking — L7 Binary Path Enforcement

**Constraint**: The sandbox proxy uses nftables (L4 redirect) combined with L7
inspection. The L7 inspector checks `/proc/<pid>/exe` to identify which binary
made the connection. The network policy allows specific binaries (e.g.,
`/usr/bin/node`, `/usr/bin/curl`). If the binary resolves to a different path,
the connection is DENIED.

**Why**: This prevents arbitrary binaries from making network connections.
Only explicitly allowed binaries can communicate with allowed endpoints.

**Failure mode**: When `n` (Node.js version manager) upgrades Node.js, it installs
the binary at `/usr/local/bin/node`. Since `/usr/local/bin` is typically first
in `$PATH`, all Node.js processes use this path. The proxy resolves
`/proc/<pid>/exe` to `/usr/local/bin/node`, which is NOT in the allow list.
Result: ALL Node.js network traffic is silently DENIED.

**Workaround**: After any Node.js upgrade via `n`:
```bash
cp /usr/local/bin/node /usr/bin/node
rm -f /usr/local/bin/node
```

**Scripts affected**: `launch-openclaw.sh` (Step 2), `verify.sh` (Layer 5b Check 1)

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
1. Inject the real API key directly into `openclaw.json` using `launch-openclaw.sh`.
   The key is passed via stdin (not command-line args) to avoid `/proc/<pid>/cmdline` exposure.
2. Do NOT set `HTTP_PROXY` or `HTTPS_PROXY` — this forces `fetch()` to use
   HTTP CONNECT tunneling, which the proxy rejects with 403.
3. Do NOT set `NODE_OPTIONS="--require http-proxy-bootstrap.js"` — same reason.
4. Let the transparent proxy (nftables L4 redirect) handle routing automatically.

**Upstream tracking**: OpenShell issue #894 (binary resolution for undici), #896 (enhanced provider management).

**Scripts affected**: `launch-openclaw.sh` (Step 4, Step 10)

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

**Scripts affected**: `launch-openclaw.sh` (Step 7, Step 8)

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

**Scripts affected**: `launch-openclaw.sh` (Step 8)

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

**Scripts affected**: `launch-openclaw.sh` (Step 10)

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

**Scripts affected**: `launch-openclaw.sh` (Step 10), `config/openclaw.json.tpl`

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

**Scripts affected**: `scripts/prompt-trace-linker.js`

## 9. OIDC Token TTL

**Constraint**: The default Keycloak access token TTL is 300s (5 minutes).
The `verify.sh` script takes longer than this to run, and `openshell` CLI
commands require a valid OIDC token.

**Why**: Keycloak has a conservative default token lifetime for security.

**Failure mode**: `openshell sandbox list` fails mid-verification with
"unauthorized" after the token expires.

**Workaround**: Increase the Keycloak access token TTL to 1800s (30 minutes)
using the Keycloak admin API during deployment.

**Scripts affected**: `scripts/crc-lifecycle.sh`, `scripts/configure-oidc.sh`

## 10. Deploy Ordering

**Constraint**: The deployment phases have strict ordering dependencies:

1. `configure-oidc.sh` runs `helm upgrade`, so OpenShell MUST already be
   installed (otherwise: "has no deployed releases").
2. Provider creation requires an OIDC token, so `configure-oidc.sh` MUST run
   first (otherwise: "missing authorization header").
3. `oauth2-proxy` needs both Keycloak and OpenShell running.
4. `launch-openclaw.sh` needs MLflow for prompt seeding and the provider to
   already exist for model routing.

**Why**: Each service has dependencies on the previous ones. The wrong order
causes cascading authentication or "not found" failures.

**Failure mode**: Various — `helm upgrade` fails, provider creation fails with
"missing authorization header", oauth2-proxy has no backend, OpenClaw can't
reach the model provider.

**Workaround**: Correct deploy order in `crc-lifecycle.sh cmd_deploy()`:
1. `bootstrap-ocp.sh` — namespace, SCCs, secrets
2. `deploy-keycloak.sh` — OIDC issuer available
3. `deploy-observability.sh` — MLflow + Tempo + OTel + prompt seeding
4. `deploy-openshell.sh` with `WITH_OIDC=false` — Helm install without OIDC
   (the pod would block on the missing `openshell-oidc-ca` ConfigMap otherwise)
5. `configure-oidc.sh` — creates OIDC CA ConfigMap + Helm upgrade with OIDC + obtain token
6. `create_provider` — now has OIDC token
7. `deploy-oauth2-proxy.sh` — needs Keycloak + OpenShell
8. `launch-openclaw.sh` — everything ready

**Scripts affected**: `scripts/crc-lifecycle.sh`, `scripts/deploy-openshell.sh`, `scripts/common.sh`

## 11. Network Namespace — Process Start Location

**Constraint**: Processes that bind to `127.0.0.1` (like the OpenClaw gateway on
port 18789) MUST be started from within the sandbox network namespace, not from
the container's root network namespace. The OpenShell supervisor creates a
separate network namespace for sandbox processes. `oc exec` runs commands in the
container's root namespace, while `openshell sandbox connect` runs commands in
the sandbox network namespace.

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
2. Use `openshell sandbox connect` to start the gateway and trace linker processes
3. Fix file ownership (chown sandbox:sandbox) before starting, since
   `openshell sandbox connect` runs as user `sandbox`, not root

```bash
# Cleanup (root, container namespace)
oc exec $SANDBOX -c agent -- bash -c 'kill ...; chown ...'

# Start gateway (sandbox namespace — where the relay can reach it)
printf '... nohup openclaw gateway run ... &\nexit\n' \
  | openshell sandbox connect $SANDBOX
```

**Scripts affected**: `launch-openclaw.sh` (Step 10a, 10b, 10c)

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

**Scripts affected**: `scripts/configure-oidc.sh`, `scripts/crc-lifecycle.sh` (Phase 5b)

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

**Scripts affected**: `scripts/launch-openclaw.sh` (Step 10a)

---

## Constraint #12: MLflow Artifact URI Scheme

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

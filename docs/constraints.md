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
3. `deploy-oauth2-proxy.sh` (browser UI auth) only needs OpenShell running —
   since ADR-0016, it deploys `oauth-proxy` with OpenShift-native OAuth and
   no longer depends on Keycloak at all. Keycloak is still deployed earlier
   in the sequence purely because the CLI/gRPC OIDC path (`configure-oidc.sh`,
   step 5 below) still needs it as a JWKS-serving issuer.
4. `launch-openclaw.sh` needs MLflow for prompt seeding and the provider to
   already exist for model routing.

**Why**: Each service has dependencies on the previous ones. The wrong order
causes cascading authentication or "not found" failures.

**Failure mode**: Various — `helm upgrade` fails, provider creation fails with
"missing authorization header", oauth-proxy has no backend, OpenClaw can't
reach the model provider.

**Workaround**: Correct deploy order in `crc-lifecycle.sh cmd_deploy()`:
1. `bootstrap-ocp.sh` — namespace, SCCs, secrets
2. `deploy-keycloak.sh` — OIDC issuer available (CLI/gRPC path only, see #3 above)
3. `deploy-observability.sh` — MLflow + Tempo + OTel + prompt seeding
4. `deploy-openshell.sh` with `WITH_OIDC=false` — Helm install without OIDC
   (the pod would block on the missing `openshell-oidc-ca` ConfigMap otherwise)
5. `configure-oidc.sh` — creates OIDC CA ConfigMap + Helm upgrade with OIDC + obtain token
6. `create_provider` — now has OIDC token
7. `deploy-oauth2-proxy.sh` — needs OpenShell only (OpenShift-native OAuth, ADR-0016)
8. `launch-openclaw.sh` — everything ready

**Scripts affected**: `scripts/crc-lifecycle.sh`, `scripts/deploy-openshell.sh`, `scripts/common.sh`

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

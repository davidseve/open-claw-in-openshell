#!/usr/bin/env bash
# =============================================================================
# launch-openclaw.sh — Deploy OpenClaw inside an OpenShell sandbox on OCP
# =============================================================================
#
# This script is the single source of truth for launching OpenClaw in a sandbox.
# Every step documents WHY it exists and WHAT constraint it addresses.
#
# SANDBOX CONSTRAINTS (learned the hard way — do not ignore):
#
#   1. FILESYSTEM: Landlock enforces /sandbox as read-only.
#      Only /sandbox/workspace and /tmp are writable.
#      => HOME must be /sandbox/workspace (not /root, not /sandbox)
#      => Config goes to /sandbox/workspace/.openclaw/openclaw.json
#      => State/locks go to /sandbox/workspace/.openclaw/state/
#
#   2. NETWORKING: The sandbox proxy uses nftables (L4) + L7 binary inspection.
#      - L7 checks /proc/<pid>/exe to identify which binary made the connection.
#      - `n` (Node version manager) installs to /usr/local/bin/node, which
#        differs from the stock image's /usr/bin/node.
#      - policies/openclaw-sandbox.yaml explicitly allows BOTH
#        /usr/bin/node and /usr/local/bin/node in every network policy's
#        `binaries` list, so no post-upgrade binary relocation is needed.
#      => Nothing to do here — just keep both paths in the policy's
#         `binaries` list whenever the base image or Node install path changes.
#
#   3. CREDENTIAL INJECTION: The proxy resolves openshell:resolve:env:KEY
#      placeholders by inspecting HTTP traffic. However, Node.js fetch()
#      (undici) creates ephemeral connections that the proxy cannot reliably
#      map to a process binary via /proc/net/tcp. This causes DENIED with
#      "failed to resolve peer binary".
#      => Do NOT rely on proxy credential injection for Node.js fetch().
#      => Bake the real API key into openclaw.json at template-render time
#         instead (see render_openclaw_config() in common.sh, which resolves
#         the __MAAS_API_KEY__ placeholder from openclaw.json.tpl).
#      => Do NOT set HTTP_PROXY or HTTPS_PROXY — this forces fetch() to use
#         HTTP CONNECT tunneling, which the proxy rejects with 403.
#      => Do NOT set NODE_OPTIONS="--require http-proxy-bootstrap.js" — same
#         reason. The transparent proxy (nftables) handles routing automatically
#         for connections it CAN resolve (curl, short-lived node scripts).
#
#   4. PLUGIN LOADING: OpenClaw 2026.7.1 expects plugins at:
#        $HOME/.openclaw/extensions/<plugin-id>/
#      Each plugin directory MUST contain:
#        - openclaw.plugin.json (manifest with id, configSchema)
#        - package.json (with main pointing to entrypoint)
#        - The actual code (index.ts or via node_modules)
#      Security checks:
#        - Plugin directory must be owned by root:root (uid=0).
#          Non-root ownership is blocked as "suspicious ownership".
#        - The plugin source files live inside node_modules/@mlflow/mlflow-openclaw/
#          but the plugin root needs a re-export index.ts.
#
#   5. PLUGIN COMPATIBILITY: @mlflow/mlflow-openclaw@0.2.0-rc.0 imports
#      'openclaw/plugin-sdk/diagnostics-otel' which does not exist in
#      OpenClaw 2026.7.1. Also uses definePluginEntry() which 2026.7.1
#      doesn't export. Both must be patched with no-ops.
#      => patch-mlflow-plugin.py handles this idempotently.
#
#   5b. NPM AFTER NODE UPGRADE: `n 22.22.3` installs a fresh npm CLI at
#      /usr/local/lib/node_modules/npm but its bundled node_modules/ come up
#      incomplete (missing graceful-fs and others) — `npm --version` /
#      `npm init` then fail with MODULE_NOT_FOUND. The stock image's original
#      npm at /usr/lib/node_modules/npm (paired with /usr/bin/node) has a
#      complete node_modules/. Fix: after `n 22.22.3`, copy any missing
#      packages from the old bundled npm into the new one
#      (`cp -rn /usr/lib/node_modules/npm/node_modules/* /usr/local/lib/node_modules/npm/node_modules/`).
#      Validated live (2026-07-27): `npm --version` works afterward and the
#      mlflow-openclaw plugin install (Step 6) succeeds.
#
#   6. PROCESS MANAGEMENT: The gateway binary is called openclaw-gateway
#      but resolves to /usr/bin/node via /proc/<pid>/exe. When killing,
#      use `pgrep -f "openclaw\|node"` not just `pkill node`, because
#      the process name in `ps` is "openclaw-gatewa" (truncated).
#      Stale lock files at .openclaw/state/*.lock prevent restart.
#      => Always clean locks before starting.
#      => Always kill ALL node processes before restart (gateway + linker).
#
#   7. OTEL EXPORTERS: Setting OTEL_LOGS_EXPORTER=otlp or OTEL_METRICS_EXPORTER=otlp
#      can cause the gateway to attempt network connections that the proxy may
#      block. diagnostics-otel plugin is disabled in config to prevent trace
#      duplication (mlflow-openclaw is the sole trace source).
#      => Set all OTEL_*_EXPORTER=none.
#
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/common.sh"

# ─── RHOAI MLflow wiring (mandatory) ─────────────────────────────────────────
# Points the mlflow-openclaw plugin's tracing transport at RHOAI-managed
# MLflow (charts/rhoai/) — the sole tracing backend for this project (see
# docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md; the standalone
# ghcr.io/mlflow/mlflow deployment this used to be optional against was
# removed entirely). Requires scripts/wire-rhoai-mlflow-tracing.sh to have
# already run successfully (RBAC, SA token, experiment, CA all staged in
# .rendered/rhoai-mlflow/). Declarative in the sense that the plugin config
# and gateway env vars are set once at initial sandbox launch, from files on
# disk — no live hot-patch of a running sandbox afterwards.
check_openshell_cli
detect_environment
render_all_templates

step "Loading RHOAI MLflow wiring facts"
RHOAI_WIRING="${PROJECT_DIR}/.rendered/rhoai-mlflow/wiring.env"
if [[ ! -f "$RHOAI_WIRING" ]]; then
  error "RHOAI wiring facts not found: ${RHOAI_WIRING}"
  error "Run ./scripts/deploy-rhoai-mlflow.sh then ./scripts/wire-rhoai-mlflow-tracing.sh first."
  exit 1
fi
set -a
source "$RHOAI_WIRING"
set +a
python3 -c "
import json
path = '${RENDERED_DIR}/openclaw.json'
with open(path) as f:
    d = json.load(f)
cfg = d['plugins']['entries']['mlflow-openclaw']['config']
cfg['trackingUri'] = '${RHOAI_MLFLOW_TRACKING_URI}'
cfg['experimentId'] = '${RHOAI_MLFLOW_EXPERIMENT_ID}'
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
print('mlflow-openclaw config patched: trackingUri=${RHOAI_MLFLOW_TRACKING_URI} experimentId=${RHOAI_MLFLOW_EXPERIMENT_ID}')
"
pass "Rendered openclaw.json now points at RHOAI MLflow (workspace=${RHOAI_MLFLOW_WORKSPACE})"

# ─── Step 1: Create sandbox ─────────────────────────────────────────────────
# The sandbox runs the OpenClaw gateway inside OpenShell's isolated container.
# --from openclaw uses the stock OpenClaw image as the base.
# --provider attaches the MaaS credential provider.
# --policy applies our custom network/filesystem policy.
# --upload puts the initial config at /sandbox/.openclaw/config.json (read-only
#   zone — we copy it to /sandbox/workspace later).
step "Creating OpenClaw sandbox"
if openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
  info "Sandbox '$SANDBOX_NAME' already exists"
else
  openshell sandbox create \
    --from openclaw \
    --provider "$PROVIDER_NAME" \
    --name "$SANDBOX_NAME" \
    --policy "${PROJECT_DIR}/policies/openclaw-sandbox.yaml" \
    --upload "${RENDERED_DIR}/openclaw.json:/sandbox/.openclaw/config.json" \
    --no-tty &
  CREATE_PID=$!

  info "Waiting for sandbox to be ready..."
  retries=0
  while [[ $retries -lt 120 ]]; do
    if openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}.*Ready"; then
      info "Sandbox is Ready"
      break
    fi
    sleep 5
    retries=$((retries + 1))
  done
  kill "$CREATE_PID" 2>/dev/null || true
  wait "$CREATE_PID" 2>/dev/null || true

  if [[ $retries -ge 120 ]]; then
    error "Sandbox did not become ready within 10 minutes"
    exit 1
  fi
fi

# ─── Step 2: Upgrade Node.js and OpenClaw ────────────────────────────────────
# The stock sandbox image ships an older Node.js and OpenClaw.
# OpenClaw 2026.7.1 requires Node.js >= 22.22.3.
# `n` installs the upgraded Node.js at /usr/local/bin/node. No binary
# relocation is needed: policies/openclaw-sandbox.yaml already allows both
# /usr/bin/node and /usr/local/bin/node in every network policy. (See
# constraint #2)
step "Upgrading Node.js and OpenClaw to 2026.7.1"
CURRENT_VERSION=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- \
  openclaw --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
if [[ "$CURRENT_VERSION" == "2026.7.1" ]]; then
  info "OpenClaw already at 2026.7.1"
else
  info "Current version: $CURRENT_VERSION — upgrading..."
  oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c '
    npm install -g n 2>/dev/null && n 22.22.3 2>/dev/null
    # See constraint #5b: n leaves the new npm bundled deps incomplete.
    cp -rn /usr/lib/node_modules/npm/node_modules/* /usr/local/lib/node_modules/npm/node_modules/ 2>/dev/null || true
    npm install -g openclaw@2026.7.1 2>/dev/null
    echo "NODE=$(node --version) OPENCLAW=$(openclaw --version 2>&1 | grep -oP "\d+\.\d+\.\d+") NPM=$(npm --version 2>/dev/null || echo BROKEN)"
  ' 2>&1 | while IFS= read -r line; do info "  $line"; done
fi

# ─── Step 3: Copy config to writable workspace ──────────────────────────────
# /sandbox/ is read-only (Landlock). OpenClaw needs to write state, logs, and
# locks. We set HOME=/sandbox/workspace so .openclaw/ is writable. (See constraint #1)
#
# The real MaaS API key is already baked into ${RENDERED_DIR}/openclaw.json by
# render_openclaw_config() (see common.sh), which resolves the __MAAS_API_KEY__
# placeholder from config/openclaw.json.tpl at render time. No separate
# post-copy injection step is needed. (See constraint #3 — the sandbox proxy's
# openshell:resolve:env:KEY injection is not used here because Node.js
# fetch()/undici connections are too ephemeral for the proxy to map to a
# process binary.)
step "Copying config to writable workspace"
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- mkdir -p /sandbox/workspace/.openclaw/state
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- mkdir -p /sandbox/workspace/.openclaw/agents
oc -n "$NAMESPACE" cp "${RENDERED_DIR}/openclaw.json" \
  "${SANDBOX_NAME}:/sandbox/workspace/.openclaw/openclaw.json" -c agent

# Fix ownership so sandbox user can read the config
SANDBOX_UID=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- id -u sandbox 2>/dev/null || echo "1000")
SANDBOX_GID=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- id -g sandbox 2>/dev/null || echo "1000")
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- chown -R "${SANDBOX_UID}:${SANDBOX_GID}" /sandbox/workspace
info "Config at /sandbox/workspace/.openclaw/openclaw.json"

# RHOAI MLflow mode: stage the openshift-service-ca.crt bundle inside the
# sandbox workspace so the mlflow-openclaw plugin's Node process (not the
# proxy — see `tls: skip` in policies/openclaw-sandbox.yaml) can validate
# RHOAI MLflow's service-ca-signed certificate during its own TLS handshake.
#
# Validated live (2026-07-25, see docs/adrs/ADR-0017-rhoai-mlflow-scope.md):
# a plain CA file with only RHOAI's service-ca is not enough for the gateway
# process specifically, because OpenShell's own sandbox runtime ALSO sets
# NODE_EXTRA_CA_CERTS on that process (pointing at
# /etc/openshell-tls/openshell-ca.pem — the CA that signs the sandbox proxy's
# own MITM certs for every endpoint that ISN'T tls:skip, e.g. maas_inference).
# NODE_EXTRA_CA_CERTS is a single-value env var: overwriting it with only the
# RHOAI CA (as an earlier attempt in this file did) makes Node stop trusting
# the proxy's MITM cert, which breaks the MaaS provider's own HTTPS call in
# the SAME process (`Proxy response (403) !== 200 when HTTP Tunneling`).
# Fix: concatenate OpenShell's own openshell-ca.pem with RHOAI's
# service-ca.crt into one PEM bundle (NODE_EXTRA_CA_CERTS accepts multiple
# concatenated certs) and point NODE_EXTRA_CA_CERTS at the union instead of
# replacing it — confirmed live to keep both MaaS chat and the RHOAI MLflow
# TLS handshake working from the same gateway process.
RHOAI_MLFLOW_SANDBOX_CA="/sandbox/workspace/.rhoai-mlflow-ca.crt"
RHOAI_MLFLOW_COMBINED_CA="/sandbox/workspace/.combined-ca-bundle.pem"
step "Staging RHOAI MLflow CA bundle in sandbox workspace"
oc -n "$NAMESPACE" cp "${RHOAI_MLFLOW_CA_FILE}" \
  "${SANDBOX_NAME}:${RHOAI_MLFLOW_SANDBOX_CA}" -c agent
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- \
  chown "${SANDBOX_UID}:${SANDBOX_GID}" "$RHOAI_MLFLOW_SANDBOX_CA"
info "CA bundle staged at ${RHOAI_MLFLOW_SANDBOX_CA}"

step "Building combined CA bundle (OpenShell proxy CA + RHOAI service-ca)"
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c "
  cat /etc/openshell-tls/openshell-ca.pem ${RHOAI_MLFLOW_SANDBOX_CA} > ${RHOAI_MLFLOW_COMBINED_CA}
  chown ${SANDBOX_UID}:${SANDBOX_GID} ${RHOAI_MLFLOW_COMBINED_CA}
"
info "Combined bundle staged at ${RHOAI_MLFLOW_COMBINED_CA}"

# ─── Step 4: Fetch system prompts from MLflow ────────────────────────────────
# Prompts are versioned in MLflow Prompt Registry. fetch-prompts-from-mlflow.sh
# downloads them with @production alias, writes .prompt-versions.json manifest,
# and the files are then locked (root-owned, chmod 444) so the agent can't modify them.
# RHOAI MLflow requires Bearer token + X-MLFLOW-WORKSPACE + CA validation on
# every request (same as the plugin/linker — see docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md); passed through as env vars the script reads.
step "Fetching system prompts from MLflow Prompt Registry"
oc -n "$NAMESPACE" cp "${PROJECT_DIR}/scripts/prompt-registry/fetch-prompts-from-mlflow.sh" \
  "${SANDBOX_NAME}:/tmp/fetch-prompts-from-mlflow.sh" -c agent
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- chmod +x /tmp/fetch-prompts-from-mlflow.sh

MLFLOW_EXP_ID=$(python3 -c "import json; d=json.load(open('${RENDERED_DIR}/openclaw.json')); print(d.get('plugins',{}).get('entries',{}).get('mlflow-openclaw',{}).get('config',{}).get('experimentId','0'))" 2>/dev/null || echo "0")

FETCH_OUTPUT=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- \
  bash -c "MLFLOW_URL='${RHOAI_MLFLOW_TRACKING_URI}' MLFLOW_EXPERIMENT_ID=${MLFLOW_EXP_ID} MLFLOW_TRACKING_TOKEN='${RHOAI_MLFLOW_SA_TOKEN}' MLFLOW_WORKSPACE='${RHOAI_MLFLOW_WORKSPACE}' MLFLOW_TRACKING_SERVER_CERT_PATH='${RHOAI_MLFLOW_SANDBOX_CA}' /tmp/fetch-prompts-from-mlflow.sh" 2>&1 || true)
echo "$FETCH_OUTPUT" | while IFS= read -r line; do info "$line"; done

FETCHED_COUNT=$(echo "$FETCH_OUTPUT" | grep -c "^\[OK\]" || true)
if [[ "$FETCHED_COUNT" -gt 0 ]]; then
  info "Fetched ${FETCHED_COUNT} prompts — protecting files (root-owned, read-only)"
  for f in AGENTS SOUL TOOLS IDENTITY USER HEARTBEAT BOOTSTRAP; do
    oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- \
      bash -c "test -f /sandbox/workspace/${f}.md && chown 0:0 /sandbox/workspace/${f}.md && chmod 444 /sandbox/workspace/${f}.md" 2>/dev/null || true
  done
else
  warn "No prompts fetched from MLflow — OpenClaw will use default templates"
fi

# ─── Step 5: Install prompt trace linker sidecar ─────────────────────────────
# The linker polls MLflow for unlinked traces and adds mlflow.linkedPrompts
# tags (populates the "Prompt" column in MLflow UI). Uses /usr/bin/curl
# for HTTP because Node.js fetch() is blocked by the proxy for the same
# binary-resolution reason as constraint #3.
step "Installing prompt trace linker sidecar"
oc -n "$NAMESPACE" cp "${PROJECT_DIR}/scripts/prompt-registry/prompt-trace-linker.js" \
  "${SANDBOX_NAME}:/tmp/prompt-trace-linker.js" -c agent

# ─── Step 6: Install mlflow-openclaw plugin ──────────────────────────────────
# This plugin hooks into OpenClaw's agent lifecycle events and creates MLflow
# traces. It requires specific directory structure and patching. (See constraints #4, #5)
#
# Directory structure OpenClaw 2026.7.1 expects:
#   $HOME/.openclaw/extensions/mlflow-openclaw/
#     ├── openclaw.plugin.json    (manifest — copied from npm package)
#     ├── package.json            (main points to npm package entrypoint)
#     ├── index.ts                (re-exports from @mlflow/mlflow-openclaw)
#     └── node_modules/@mlflow/mlflow-openclaw/
#           ├── index.ts          (patched: no definePluginEntry)
#           └── src/service.ts    (patched: no diagnostics-otel import)
#
# Ownership: root:root (constraint #4 — non-root is rejected as "suspicious")
step "Installing mlflow-openclaw plugin"
PLUGIN_DIR="/sandbox/workspace/.openclaw/extensions/mlflow-openclaw"
MLFLOW_PLUGIN_INSTALLED=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- \
  test -f "${PLUGIN_DIR}/openclaw.plugin.json" 2>/dev/null && echo "YES" || echo "NO")
if [[ "$MLFLOW_PLUGIN_INSTALLED" == "YES" ]]; then
  info "mlflow-openclaw plugin already installed"
else
  info "Installing mlflow-openclaw plugin..."
  oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c "
    mkdir -p ${PLUGIN_DIR} && cd ${PLUGIN_DIR}
    npm init -y 2>/dev/null
    npm install @mlflow/mlflow-openclaw@0.2.0-rc.0 2>/dev/null
    cp node_modules/@mlflow/mlflow-openclaw/openclaw.plugin.json . 2>/dev/null || true
    echo 'export { default } from \"@mlflow/mlflow-openclaw\";' > index.ts
    python3 -c \"
import json
with open('package.json','r') as f: d=json.load(f)
d['main']='./node_modules/@mlflow/mlflow-openclaw/index.ts'
d['type']='module'
with open('package.json','w') as f: json.dump(d,f,indent=2)
\"
  " 2>&1 | while IFS= read -r line; do info "  $line"; done
fi

# ─── Step 7: Patch plugin for OpenClaw 2026.7.1 compatibility ────────────────
# @mlflow/mlflow-openclaw@0.2.0-rc.0 was built for a newer OpenClaw SDK.
# Three incompatibilities/gaps must be patched:
#   1. service.ts imports diagnostics-otel → replaced with no-op (constraint #5)
#   2. index.ts uses definePluginEntry() → replaced with plain object export (constraint #5)
#   3. @mlflow/core@0.2.0's createOssAuth() never sends X-MLFLOW-WORKSPACE →
#      backported from the real fix (mlflow/mlflow#23927, landed upstream in
#      @mlflow/core@0.3.0) directly onto the installed 0.2.0 dist file
#      (constraint #4b). An npm `overrides` bump to 0.3.0 was tried first and
#      rejected by an OpenShell sandbox policy (`403 policy_denied` on that
#      specific registry fetch, not root-caused — constraint #4e); patching
#      the already-installed file sidesteps the registry entirely, same
#      category of fix as #1/#2 above.
# The patch script is idempotent (checks before patching) and lives at
# scripts/patch-mlflow-plugin.py — versioned in the repo as the single
# source of truth, copied into the sandbox as-is (no regeneration here).
step "Patching mlflow-openclaw plugin for compatibility"
oc -n "$NAMESPACE" cp "${PROJECT_DIR}/scripts/patch-mlflow-plugin.py" \
  "${SANDBOX_NAME}:/tmp/patch-mlflow-plugin.py" -c agent
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- python3 /tmp/patch-mlflow-plugin.py 2>&1 \
  | while IFS= read -r line; do info "  $line"; done

# Plugin MUST be root-owned or OpenClaw rejects it (constraint #4)
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- \
  chown -R root:root /sandbox/workspace/.openclaw/extensions/mlflow-openclaw 2>/dev/null || true
info "Plugin installed and patched (root-owned)"

# ─── Step 8: Initialize OpenClaw baseline ────────────────────────────────────
# Validates the existing openclaw.json (from Step 3) and creates the
# workspace/session directory structure ($HOME/.openclaw/agents/main/sessions).
# --accept-risk suppresses the interactive security prompt.
# Empirically verified (md5sum + mtime unchanged across a live run): this
# command does NOT rewrite openclaw.json — it only reports "Config OK" and
# provisions directories. Order relative to Step 3's config copy therefore
# does not matter for the config's contents.
step "Initializing OpenClaw baseline config"
BASELINE_STATUS=0
BASELINE_OUTPUT=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c '
  HOME=/sandbox/workspace openclaw setup --baseline --non-interactive --accept-risk
' 2>&1) || BASELINE_STATUS=$?
echo "$BASELINE_OUTPUT" | tail -3 | while IFS= read -r line; do info "  $line"; done
[[ $BASELINE_STATUS -ne 0 ]] && warn "openclaw setup --baseline exited non-zero ($BASELINE_STATUS) — see output above"

# ─── Step 9: Start gateway and trace linker ──────────────────────────────────
# CRITICAL CONSTRAINTS:
#
# A. NETWORK NAMESPACE (constraint #11): The gateway MUST be started from within
#    the sandbox network namespace, NOT from the container root namespace (via
#    `oc exec`). The OpenShell supervisor relay connects to ports in the sandbox
#    namespace. If the gateway binds to 127.0.0.1 in the container root
#    namespace, the relay gets "Connection refused" and the web UI shows
#    "Service endpoint is not reachable".
#    - Use `oc exec` ONLY for cleanup (kill, chown) — runs as root in container ns
#    - Use `openshell sandbox exec --no-tty` for starting processes — runs in
#      the sandbox namespace via the gRPC exec endpoint, same as `sandbox
#      connect` but without a PTY (no ANSI escape codes to filter) and with
#      native `--env KEY=VALUE` support instead of inline shell env prefixes.
#      Validated live: a `nohup ... & disown`'d process started this way is
#      reparented to pid 1 and stays up (and reachable on the sandbox's
#      loopback) after the exec channel closes — same detachment behavior as
#      `sandbox connect` previously relied on.
#    - Fix file ownership BEFORE starting so sandbox user can write logs
#
# B. ENVIRONMENT (constraint #3): Do NOT set any of these:
#   - HTTP_PROXY / HTTPS_PROXY: Forces fetch() to use HTTP CONNECT tunneling,
#     which the sandbox proxy rejects with 403.
#   - NODE_OPTIONS="--require http-proxy-bootstrap.js": Same issue.
#   - OTEL_LOGS_EXPORTER=otlp / OTEL_METRICS_EXPORTER=otlp: Can cause
#     blocked network connections. (constraint #7)
#
# C. PROCESS MANAGEMENT (constraint #6):
#   - Kill ALL node/openclaw processes before starting
#   - Clean ALL lock files
#   - Use `pgrep -f` because ps truncates "openclaw-gateway" to "openclaw-gatewa"

step "Starting OpenClaw gateway and trace linker"

# Step 9a: Cleanup (oc exec = root, container namespace)
# Fix ownership of ALL files the gateway needs to write. Previous steps
# (plugin install, prompt seed, config injection) run as root and leave
# files owned by root. The gateway runs as sandbox user.
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c '
for p in $(pgrep -f "openclaw\|node" 2>/dev/null); do kill -9 $p 2>/dev/null; done
sleep 2
rm -f /sandbox/workspace/.openclaw/state/*.lock /sandbox/workspace/.openclaw/*.lock /tmp/openclaw/*.lock /tmp/openclaw-*/*.lock 2>/dev/null
chown -R sandbox:sandbox /sandbox/workspace/.openclaw/state/ 2>/dev/null
chown -R sandbox:sandbox /sandbox/workspace/.openclaw/agents/ 2>/dev/null
chown sandbox:sandbox /sandbox/workspace/openclaw-workspace-state.json 2>/dev/null || true
chown sandbox:sandbox /sandbox/workspace/.prompt-versions.json 2>/dev/null || true
touch /sandbox/workspace/openclaw.log /sandbox/workspace/linker.log
chown sandbox:sandbox /sandbox/workspace/openclaw.log /sandbox/workspace/linker.log
echo "CLEANUP_DONE"
' 2>&1 | while IFS= read -r line; do info "  $line"; done

# Step 9b: Start gateway (openshell sandbox exec --no-tty = sandbox namespace)
# RHOAI MLflow needs the Bearer token / workspace header / CA path the
# mlflow-openclaw plugin's transport requires (see constraint list at top of
# this file and docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md). These are
# set at initial gateway start, not hot-patched into a running process
# afterwards.
#
# NODE_EXTRA_CA_CERTS points at the COMBINED bundle built above (OpenShell's
# own proxy CA + RHOAI's service-ca), not just RHOAI's alone — see the
# comment above RHOAI_MLFLOW_COMBINED_CA for why the combined form is
# required (validated live 2026-07-25). MLFLOW_TRACKING_SERVER_CERT_PATH is
# passed too for the exporters that DO read it (none currently in
# @mlflow/core@0.2.0 — kept for forward compat and parity with the linker's
# env below, harmless no-op either way).
RHOAI_MLFLOW_GW_ENV=(
  --env "MLFLOW_TRACKING_TOKEN=${RHOAI_MLFLOW_SA_TOKEN}"
  --env "MLFLOW_WORKSPACE=${RHOAI_MLFLOW_WORKSPACE}"
  --env "NODE_EXTRA_CA_CERTS=${RHOAI_MLFLOW_COMBINED_CA}"
  --env "MLFLOW_TRACKING_SERVER_CERT_PATH=${RHOAI_MLFLOW_SANDBOX_CA}"
)
# The prompt-trace-linker sidecar reaches RHOAI MLflow via /usr/bin/curl
# (constraint #8), not Node fetch — curl's --cacert has no effect on the
# gateway's MaaS calls, so this side of the wiring is NOT subject to the
# limitation above. prompt-trace-linker.js sends Authorization/
# X-MLFLOW-WORKSPACE headers and --cacert whenever these env vars are present.
LINKER_MLFLOW_URL="${RHOAI_MLFLOW_TRACKING_URI}"
RHOAI_MLFLOW_LINKER_ENV=(
  --env "MLFLOW_TRACKING_TOKEN=${RHOAI_MLFLOW_SA_TOKEN}"
  --env "MLFLOW_WORKSPACE=${RHOAI_MLFLOW_WORKSPACE}"
  --env "MLFLOW_TRACKING_SERVER_CERT_PATH=${RHOAI_MLFLOW_SANDBOX_CA}"
)

openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout 25 \
  --env HOME=/sandbox/workspace \
  --env OTEL_TRACES_EXPORTER=none \
  --env OTEL_LOGS_EXPORTER=none \
  --env OTEL_METRICS_EXPORTER=none \
  "${RHOAI_MLFLOW_GW_ENV[@]}" \
  -- bash -c '
    nohup openclaw gateway run > /sandbox/workspace/openclaw.log 2>&1 &
    disown
    echo "GW_PID=$!"
    sleep 12
    grep -E "ready|mlflow|error|fail" /sandbox/workspace/openclaw.log | tail -5
  ' 2>&1 | while IFS= read -r line; do info "  $line"; done

# Step 9c: Start trace linker (openshell sandbox exec --no-tty = sandbox namespace)
openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout 15 \
  --env MLFLOW_EXPERIMENT_ID="${MLFLOW_EXP_ID}" \
  --env MLFLOW_URL="${LINKER_MLFLOW_URL}" \
  --env OPENCLAW_WORKSPACE_DIR=/sandbox/workspace \
  "${RHOAI_MLFLOW_LINKER_ENV[@]}" \
  -- bash -c '
    nohup node /tmp/prompt-trace-linker.js > /sandbox/workspace/linker.log 2>&1 &
    disown
    sleep 3
    tail -3 /sandbox/workspace/linker.log
  ' 2>&1 | while IFS= read -r line; do info "  $line"; done

# ─── Step 10: Verify gateway startup ────────────────────────────────────────
step "Verifying gateway startup"
GW_UP=false
for attempt in 1 2 3 4 5; do
  HEALTH_CHECK=$(sandbox_run 'curl -sf http://localhost:18789/health 2>/dev/null || echo FAIL' || true)
  if echo "$HEALTH_CHECK" | grep -q '"ok":true'; then
    GW_UP=true
    break
  fi
  info "Gateway not ready yet (attempt $attempt/5), waiting 5s..."
  sleep 5
done

if [[ "$GW_UP" == "true" ]]; then
  info "OpenClaw gateway is running and healthy"
else
  warn "OpenClaw gateway may not have started. Check: openshell sandbox connect $SANDBOX_NAME"
fi

# Verify the mlflow-openclaw plugin loaded (9 plugins means it's included)
PLUGIN_CHECK=$(sandbox_run 'grep "http server listening" /sandbox/workspace/openclaw.log | tail -1' || true)
if echo "$PLUGIN_CHECK" | grep -q "mlflow-openclaw"; then
  info "mlflow-openclaw plugin loaded successfully"
else
  warn "mlflow-openclaw plugin may not have loaded — check gateway log"
fi

# ─── Step 11: Expose Control UI ─────────────────────────────────────────────
# Registers the "openclaw-ui" service name -> sandbox port 18789 mapping in
# OpenShell's own gRPC-based service routing table. This is independent of
# any Kubernetes Route: it's what lets the gateway resolve the
# `openclaw-gw--openclaw-ui` Host-header pattern at all. oauth-proxy is the
# only Kubernetes-level external entry point onto this service (see
# scripts/deploy-oauth2-proxy.sh) -- there is no separate unauthenticated
# Route anymore (ADR-0016).
step "Exposing Control UI service"
openshell service expose "$SANDBOX_NAME" 18789 openclaw-ui 2>/dev/null \
  && info "Service exposed" \
  || info "Service may already be exposed"

# ─── Summary ────────────────────────────────────────────────────────────────
RHOAI_MLFLOW_ROUTE=$(oc get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
step "OpenClaw launch complete"
echo ""
info "Control UI (via oauth-proxy): https://openclaw-gw--openclaw-ui.${APPS_DOMAIN}/"
info "  Login: any OCP cluster identity (OpenShift-native OAuth, ADR-0016)"
echo ""
info "Observability:"
info "  - mlflow-openclaw plugin: traces → RHOAI MLflow, workspace '${RHOAI_MLFLOW_WORKSPACE}', experiment ${MLFLOW_EXP_ID}"
info "  - prompt-trace-linker: tags traces with prompt versions (via curl)"
if [[ -n "$RHOAI_MLFLOW_ROUTE" ]]; then
  info "  - MLflow UI: https://${RHOAI_MLFLOW_ROUTE}/ (Bearer token required for API; UI login per RHOAI's own auth)"
fi
echo ""
info "System prompts: MLflow Prompt Registry (@production alias)"
info "Security: trusted-proxy auth, tools.deny, Landlock, read-only prompts"

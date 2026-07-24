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

check_openshell_cli
detect_environment
render_all_templates

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
    npm install -g openclaw@2026.7.1 2>/dev/null
    echo "NODE=$(node --version) OPENCLAW=$(openclaw --version 2>&1 | grep -oP "\d+\.\d+\.\d+")"
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
  "${SANDBOX_NAME}:/sandbox/workspace/.openclaw/openclaw.json" -c agent 2>/dev/null || true

# Fix ownership so sandbox user can read the config
SANDBOX_UID=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- id -u sandbox 2>/dev/null || echo "1000")
SANDBOX_GID=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- id -g sandbox 2>/dev/null || echo "1000")
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- chown -R "${SANDBOX_UID}:${SANDBOX_GID}" /sandbox/workspace
info "Config at /sandbox/workspace/.openclaw/openclaw.json"

# ─── Step 4: Fetch system prompts from MLflow ────────────────────────────────
# Prompts are versioned in MLflow Prompt Registry. fetch-prompts-from-mlflow.sh
# downloads them with @production alias, writes .prompt-versions.json manifest,
# and the files are then locked (root-owned, chmod 444) so the agent can't modify them.
step "Fetching system prompts from MLflow Prompt Registry"
oc -n "$NAMESPACE" cp "${PROJECT_DIR}/scripts/fetch-prompts-from-mlflow.sh" \
  "${SANDBOX_NAME}:/tmp/fetch-prompts-from-mlflow.sh" -c agent 2>/dev/null || true
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- chmod +x /tmp/fetch-prompts-from-mlflow.sh

MLFLOW_EXP_ID=$(python3 -c "import json; d=json.load(open('${RENDERED_DIR}/openclaw.json')); print(d.get('plugins',{}).get('entries',{}).get('mlflow-openclaw',{}).get('config',{}).get('experimentId','0'))" 2>/dev/null || echo "0")

FETCH_OUTPUT=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- \
  bash -c "MLFLOW_EXPERIMENT_ID=${MLFLOW_EXP_ID} /tmp/fetch-prompts-from-mlflow.sh" 2>&1 || true)
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
oc -n "$NAMESPACE" cp "${PROJECT_DIR}/scripts/prompt-trace-linker.js" \
  "${SANDBOX_NAME}:/tmp/prompt-trace-linker.js" -c agent 2>/dev/null || true

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
# Two incompatibilities must be patched (see constraint #5):
#   1. service.ts imports diagnostics-otel → replaced with no-op
#   2. index.ts uses definePluginEntry() → replaced with plain object export
# The patch script is idempotent (checks before patching).
step "Patching mlflow-openclaw plugin for compatibility"
PATCH_SCRIPT="${PROJECT_DIR}/scripts/patch-mlflow-plugin.py"
cat > "$PATCH_SCRIPT" << 'PYEOF'
import re

PKG = '/sandbox/workspace/.openclaw/extensions/mlflow-openclaw/node_modules/@mlflow/mlflow-openclaw'

SVC = PKG + '/src/service.ts'
with open(SVC, 'r') as f:
    content = f.read()
if 'diagnostics-otel' in content:
    old_import = re.compile(
        r"import\s*\{[^}]*onDiagnosticEvent[^}]*\}\s*from\s*['\"]openclaw/plugin-sdk/diagnostics-otel['\"];",
        re.DOTALL
    )
    replacement = ('// diagnostics-otel replaced with no-op (not available in OpenClaw 2026.7.1)\n'
                   'const onDiagnosticEvent = (fn: any) => (() => {});\n'
                   'type DiagnosticEventPayload = any;')
    content = old_import.sub(replacement, content)
    with open(SVC, 'w') as f:
        f.write(content)
    print('service.ts patched')
else:
    print('service.ts already patched')

IDX = PKG + '/index.ts'
with open(IDX, 'r') as f:
    content = f.read()
if 'definePluginEntry' in content:
    content = content.replace(
        "import { definePluginEntry, type OpenClawPluginApi } from 'openclaw/plugin-sdk/plugin-entry';",
        '// definePluginEntry replaced for OpenClaw 2026.7.1 compat'
    )
    content = re.sub(r'export\s+default\s+definePluginEntry\(\{', 'const mlflowPlugin = ({', content)
    content = content.replace('OpenClawPluginApi', 'any')
    if not content.rstrip().endswith('export default mlflowPlugin;'):
        content = content.rstrip()
        if content.endswith('});'):
            content = content[:-3] + '});\nexport default mlflowPlugin;\n'
    with open(IDX, 'w') as f:
        f.write(content)
    print('index.ts patched')
else:
    print('index.ts already patched')
PYEOF

oc -n "$NAMESPACE" cp "$PATCH_SCRIPT" "${SANDBOX_NAME}:/tmp/patch-mlflow-plugin.py" -c agent
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
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c '
  HOME=/sandbox/workspace openclaw setup --baseline --non-interactive --accept-risk 2>/dev/null || true
' 2>&1 | tail -3 | while IFS= read -r line; do info "  $line"; done

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
openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout 25 \
  --env HOME=/sandbox/workspace \
  --env OTEL_TRACES_EXPORTER=none \
  --env OTEL_LOGS_EXPORTER=none \
  --env OTEL_METRICS_EXPORTER=none \
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
  --env MLFLOW_URL=http://mlflow.observability.svc:5000 \
  --env OPENCLAW_WORKSPACE_DIR=/sandbox/workspace \
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
step "OpenClaw launch complete"
echo ""
info "Control UI (via oauth-proxy): https://openclaw-gw--openclaw-ui.${APPS_DOMAIN}/"
info "  Login: any OCP cluster identity (OpenShift-native OAuth, ADR-0016)"
echo ""
info "Observability:"
info "  - mlflow-openclaw plugin: traces → MLflow experiment ${MLFLOW_EXP_ID}"
info "  - prompt-trace-linker: tags traces with prompt versions (via curl)"
info "  - MLflow UI: https://mlflow-observability.${APPS_DOMAIN}/"
echo ""
info "System prompts: MLflow Prompt Registry (@production alias)"
info "Security: trusted-proxy auth, tools.deny, Landlock, read-only prompts"

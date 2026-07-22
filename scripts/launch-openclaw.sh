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
#      - Policy allows specific binaries: /usr/bin/node, /usr/bin/curl.
#      - `n` (Node version manager) installs to /usr/local/bin/node.
#        The proxy sees the REAL binary path from /proc/<pid>/exe.
#        If /usr/local/bin/node exists, Node.js traffic is DENIED.
#      => After upgrading Node.js via `n`, ALWAYS:
#         cp /usr/local/bin/node /usr/bin/node && rm -f /usr/local/bin/node
#
#   3. CREDENTIAL INJECTION: The proxy resolves openshell:resolve:env:KEY
#      placeholders by inspecting HTTP traffic. However, Node.js fetch()
#      (undici) creates ephemeral connections that the proxy cannot reliably
#      map to a process binary via /proc/net/tcp. This causes DENIED with
#      "failed to resolve peer binary".
#      => Do NOT rely on proxy credential injection for Node.js fetch().
#      => Inject the real API key directly into openclaw.json.
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
# CRITICAL: After `n` upgrades Node.js, the binary is at /usr/local/bin/node.
# The sandbox proxy L7 policy only allows /usr/bin/node.
# We MUST copy the binary and remove the /usr/local path. (See constraint #2)
step "Upgrading Node.js and OpenClaw to 2026.7.1"
CURRENT_VERSION=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- \
  openclaw --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
if [[ "$CURRENT_VERSION" == "2026.7.1" ]]; then
  info "OpenClaw already at 2026.7.1"
else
  info "Current version: $CURRENT_VERSION — upgrading..."
  oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c '
    npm install -g n 2>/dev/null && n 22.22.3 2>/dev/null
    cp /usr/local/bin/node /usr/bin/node 2>/dev/null || true
    rm -f /usr/local/bin/node 2>/dev/null || true
    npm install -g openclaw@2026.7.1 2>/dev/null
    echo "NODE=$(node --version) OPENCLAW=$(openclaw --version 2>&1 | grep -oP "\d+\.\d+\.\d+")"
  ' 2>&1 | while IFS= read -r line; do info "  $line"; done
fi

# Ensure /usr/local/bin/node does not exist even if OpenClaw was already current.
# A previous failed run might have left it behind. (See constraint #2)
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c '
  if [ -f /usr/local/bin/node ]; then
    cp /usr/local/bin/node /usr/bin/node
    rm -f /usr/local/bin/node
    echo "FIXED: removed /usr/local/bin/node"
  fi
' 2>&1 | while IFS= read -r line; do info "  $line"; done

# ─── Step 3: Copy config to writable workspace ──────────────────────────────
# /sandbox/ is read-only (Landlock). OpenClaw needs to write state, logs, and
# locks. We set HOME=/sandbox/workspace so .openclaw/ is writable. (See constraint #1)
step "Copying config to writable workspace"
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- mkdir -p /sandbox/workspace/.openclaw/state
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- mkdir -p /sandbox/workspace/.openclaw/agents
oc -n "$NAMESPACE" cp "${RENDERED_DIR}/openclaw.json" \
  "${SANDBOX_NAME}:/sandbox/workspace/.openclaw/openclaw.json" -c agent 2>/dev/null || true

# ─── Step 4: Inject real API key ─────────────────────────────────────────────
# The config template uses openshell:resolve:env:LITELLM_API_KEY as placeholder.
# The sandbox proxy SHOULD resolve this, but Node.js fetch() (undici) creates
# connections too ephemeral for the proxy to map to /proc/<pid>/exe.
# Result: DENIED with "failed to resolve peer binary".
# FIX: Inject the real key directly. (See constraint #3)
step "Injecting MaaS API key into config"
load_secrets
if [[ -n "${MAAS_API_KEY:-}" ]]; then
  # Inject via stdin to avoid exposing the key in /proc/<pid>/cmdline
  echo "${MAAS_API_KEY}" | oc -n "$NAMESPACE" exec -i "$SANDBOX_NAME" -c agent -- python3 -c '
import json, sys
key = sys.stdin.readline().strip()
CFG = "/sandbox/workspace/.openclaw/openclaw.json"
with open(CFG, "r") as f:
    d = json.load(f)
d["models"]["providers"]["maas"]["apiKey"] = key
with open(CFG, "w") as f:
    json.dump(d, f, indent=2)
print("API key injected")
' 2>&1 | while IFS= read -r line; do info "  $line"; done
else
  warn "MAAS_API_KEY not found in secrets.env — LLM requests will fail"
fi

# Fix ownership so sandbox user can read the config
SANDBOX_UID=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- id -u sandbox 2>/dev/null || echo "1000")
SANDBOX_GID=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- id -g sandbox 2>/dev/null || echo "1000")
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- chown -R "${SANDBOX_UID}:${SANDBOX_GID}" /sandbox/workspace
info "Config at /sandbox/workspace/.openclaw/openclaw.json"

# ─── Step 5: Fetch system prompts from MLflow ────────────────────────────────
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

# ─── Step 6: Install prompt trace linker sidecar ─────────────────────────────
# The linker polls MLflow for unlinked traces and adds mlflow.linkedPrompts
# tags (populates the "Prompt" column in MLflow UI). Uses /usr/bin/curl
# for HTTP because Node.js fetch() is blocked by the proxy for the same
# binary-resolution reason as constraint #3.
step "Installing prompt trace linker sidecar"
oc -n "$NAMESPACE" cp "${PROJECT_DIR}/scripts/prompt-trace-linker.js" \
  "${SANDBOX_NAME}:/tmp/prompt-trace-linker.js" -c agent 2>/dev/null || true

# ─── Step 7: Install mlflow-openclaw plugin ──────────────────────────────────
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

# ─── Step 8: Patch plugin for OpenClaw 2026.7.1 compatibility ────────────────
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

# ─── Step 9: Initialize OpenClaw baseline ────────────────────────────────────
# Creates initial workspace structure. --accept-risk suppresses the interactive
# security prompt. This is safe because we overwrite the config anyway.
step "Initializing OpenClaw baseline config"
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- bash -c '
  HOME=/sandbox/workspace openclaw setup --baseline --non-interactive --accept-risk 2>/dev/null || true
' 2>&1 | tail -3 | while IFS= read -r line; do info "  $line"; done

# ─── Step 10: Start gateway and trace linker ─────────────────────────────────
# CRITICAL CONSTRAINTS:
#
# A. NETWORK NAMESPACE (constraint #11): The gateway MUST be started from within
#    the sandbox network namespace (via `openshell sandbox connect`), NOT from the
#    container root namespace (via `oc exec`). The OpenShell supervisor relay
#    connects to ports in the sandbox namespace. If the gateway binds to 127.0.0.1
#    in the container root namespace, the relay gets "Connection refused" and the
#    web UI shows "Service endpoint is not reachable".
#    - Use `oc exec` ONLY for cleanup (kill, chown) — runs as root in container ns
#    - Use `openshell sandbox connect` for starting processes — runs in sandbox ns
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

# Step 10a: Cleanup (oc exec = root, container namespace)
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

# Step 10b: Start gateway (openshell sandbox connect = sandbox namespace)
printf 'HOME=/sandbox/workspace MLFLOW_TRACKING_URI=http://mlflow.observability.svc:5000 OTEL_TRACES_EXPORTER=none OTEL_LOGS_EXPORTER=none OTEL_METRICS_EXPORTER=none nohup openclaw gateway run > /sandbox/workspace/openclaw.log 2>&1 &
echo "GW_PID=$!"
sleep 12
grep -E "ready|mlflow|error|fail" /sandbox/workspace/openclaw.log | tail -5
exit
' | timeout 25 openshell sandbox connect "$SANDBOX_NAME" 2>&1 \
  | grep -v '^\[?2004' | grep -v '^$' \
  | while IFS= read -r line; do info "  $line"; done

# Step 10c: Start trace linker (openshell sandbox connect = sandbox namespace)
printf 'MLFLOW_EXPERIMENT_ID='"${MLFLOW_EXP_ID}"' MLFLOW_URL=http://mlflow.observability.svc:5000 OPENCLAW_WORKSPACE_DIR=/sandbox/workspace nohup node /tmp/prompt-trace-linker.js > /sandbox/workspace/linker.log 2>&1 &
sleep 3
tail -3 /sandbox/workspace/linker.log
exit
' | timeout 15 openshell sandbox connect "$SANDBOX_NAME" 2>&1 \
  | grep -v '^\[?2004' | grep -v '^$' \
  | while IFS= read -r line; do info "  $line"; done

# ─── Step 11: Verify gateway startup ────────────────────────────────────────
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

# ─── Step 12: Expose Control UI ─────────────────────────────────────────────
step "Exposing Control UI service"
openshell service expose "$SANDBOX_NAME" 18789 openclaw-ui 2>/dev/null \
  && info "Service exposed" \
  || info "Service may already be exposed"

step "Applying OpenClaw service Route"
oc apply -f "${RENDERED_DIR}/openclaw-service-route.yaml"
info "Route applied"

# ─── Summary ────────────────────────────────────────────────────────────────
step "OpenClaw launch complete"
echo ""
info "Control UI (via oauth2-proxy): https://openclaw-ui.${APPS_DOMAIN}/"
info "  Login: Keycloak OIDC (admin/admin in dev)"
echo ""
info "Observability:"
info "  - mlflow-openclaw plugin: traces → MLflow experiment ${MLFLOW_EXP_ID}"
info "  - prompt-trace-linker: tags traces with prompt versions (via curl)"
info "  - MLflow UI: https://mlflow-observability.${APPS_DOMAIN}/"
echo ""
info "System prompts: MLflow Prompt Registry (@production alias)"
info "Security: trusted-proxy auth, tools.deny, Landlock, read-only prompts"

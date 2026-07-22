#!/usr/bin/env bash
# =============================================================================
# verify.sh — Validate the full OpenClaw-in-OpenShell deployment
# =============================================================================
#
# This script verifies every layer of the deployment stack, from OCP infra
# to LLM connectivity to MLflow trace generation to UI access.
#
# Each check documents:
#   - WHAT it verifies
#   - WHY this check exists (what failure it catches)
#   - HOW to fix if it fails
#
# Exit codes:
#   0 = all checks passed (warnings are informational)
#   1 = at least one FAIL
#
# VERIFICATION ARCHITECTURE:
#
#   Layer 1:  OCP infrastructure (CRDs, namespace, SCC, PKI secrets)
#   Layer 1b: Keycloak OIDC (pod, discovery endpoint)
#   Layer 2:  OpenShell gateway (pod, route, CLI, provider)
#   Layer 3:  Sandbox existence and readiness
#   Layer 4:  Security (user identity, egress blocking, Landlock, credentials)
#   Layer 5:  OpenClaw gateway health (/health, config, chatCompletions)
#   Layer 5b: LLM connectivity (Node.js binary path, fetch(), proxy denials,
#             end-to-end LLM request, MLflow trace generation)
#   Layer 7b: External access (service route, oauth2-proxy OIDC)
#   Layer 8:  Observability stack (Tempo, OTel Collector, MLflow)
#   Layer 8b: MLflow Prompt Registry (prompts, aliases, manifest, linker)
#   Layer 9:  Control UI (Playwright tests)
#
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/common.sh"

NAMESPACE="${NAMESPACE:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw-gw}"

detect_environment

# =============================================================================
# Layer 1: OCP Infrastructure
# =============================================================================
# WHY: Without these resources, nothing else can work.
#   - CRD: Required for OpenShell to create sandbox custom resources
#   - Namespace: Where all OpenShell resources live
#   - SCC: The sandbox pod requires privileged SCC for nftables/Landlock
#   - PKI: mTLS and JWT tokens for gateway auth
step "Layer 1: Infrastructure (OCP resources)"

oc get crd sandboxes.agents.x-k8s.io &>/dev/null \
  && pass "Agent Sandbox CRD exists" \
  || fail "Agent Sandbox CRD not found"

if [[ "$CRC_MODE" == "true" ]]; then
  info "CRC mode: skipping OLM operator CSV check"
else
  oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null | grep -q Succeeded \
    && pass "Operator CSV healthy" \
    || warn "Operator CSV not in Succeeded phase"
fi

oc get ns "$NAMESPACE" &>/dev/null \
  && pass "Namespace $NAMESPACE exists" \
  || fail "Namespace $NAMESPACE not found"

oc get rolebinding -n "$NAMESPACE" system:openshift:scc:privileged &>/dev/null \
  && pass "SCC binding active for openshell-sandbox (RBAC RoleBinding)" \
  || { oc get scc privileged -o json 2>/dev/null | grep -q "openshell-sandbox" \
    && pass "SCC binding active for openshell-sandbox (SCC users list)" \
    || fail "SCC binding not found"; }

for secret in openshell-server-tls openshell-client-tls openshell-jwt-keys; do
  oc -n "$NAMESPACE" get secret "$secret" &>/dev/null \
    && pass "PKI secret $secret exists" \
    || fail "PKI secret $secret not found"
done

# =============================================================================
# Layer 1b: Keycloak OIDC
# =============================================================================
# WHY: All user-facing access (Control UI, CLI) goes through OIDC.
#   If Keycloak is down or misconfigured, nothing is accessible.
# HOW TO FIX: scripts/deploy-keycloak.sh && scripts/configure-oidc.sh
step "Layer 1b: Keycloak OIDC (if configured)"

KC_NAMESPACE="openshell-keycloak"
KC_ISSUER="https://keycloak-${KC_NAMESPACE}.${APPS_DOMAIN}/realms/openshell"

if oc get ns "$KC_NAMESPACE" &>/dev/null; then
  pass "Keycloak namespace exists"

  KC_PHASE=$(oc -n "$KC_NAMESPACE" get pods -l app=keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
  [[ "$KC_PHASE" == "Running" ]] \
    && pass "Keycloak pod Running" \
    || warn "Keycloak pod phase: $KC_PHASE"

  KC_DISCOVERY=$(curl -sk "${KC_ISSUER}/.well-known/openid-configuration" 2>/dev/null || true)
  if echo "$KC_DISCOVERY" | grep -q "jwks_uri"; then
    pass "Keycloak OIDC discovery available"
  else
    fail "Keycloak OIDC discovery not reachable at ${KC_ISSUER}"
  fi

  oc get oauthclient keycloak-broker &>/dev/null \
    && pass "OCP OAuthClient 'keycloak-broker' exists" \
    || warn "OCP OAuthClient 'keycloak-broker' not found"
else
  info "Keycloak not deployed (Phase 7 not active), skipping OIDC checks"
fi

# =============================================================================
# Layer 2: OpenShell Gateway
# =============================================================================
# WHY: The gateway is the control plane for all sandbox operations.
#   If it's down, we can't create sandboxes, relay services, or authenticate.
# HOW TO FIX: scripts/deploy-openshell.sh
step "Layer 2: OpenShell Gateway"

PHASE=$(oc -n "$NAMESPACE" get pods -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
[[ "$PHASE" == "Running" ]] \
  && pass "Gateway pod Running" \
  || fail "Gateway pod phase: $PHASE"

ROUTE_HOST=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -n "$ROUTE_HOST" ]]; then
  pass "Route exists: $ROUTE_HOST"

  ROUTE_TLS=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
  [[ "$ROUTE_TLS" == "passthrough" ]] \
    && pass "Route TLS termination: passthrough" \
    || fail "Route TLS termination should be passthrough, got: $ROUTE_TLS"
else
  fail "Route openshell-gw not found"
fi

if command -v openshell &>/dev/null; then
  openshell status &>/dev/null \
    && pass "CLI connected to gateway" \
    || fail "CLI not connected to gateway"

  openshell provider list 2>/dev/null | grep -q "maas-litellm" \
    && pass "MaaS provider registered" \
    || fail "MaaS provider not found"

  if oc get ns "$KC_NAMESPACE" &>/dev/null 2>&1; then
    OIDC_CFG=$(oc -n "$NAMESPACE" get configmap openshell-config -o jsonpath='{.data}' 2>/dev/null || true)
    if echo "$OIDC_CFG" | grep -q "oidc"; then
      pass "Gateway OIDC config present"
    else
      info "Gateway not yet configured for OIDC (run configure-oidc.sh)"
    fi
  fi
else
  warn "openshell CLI not available, skipping CLI checks"
fi

# =============================================================================
# Layer 3: Sandbox
# =============================================================================
# WHY: The sandbox is where OpenClaw actually runs. If it doesn't exist
#   or isn't Ready, the gateway can't run.
# HOW TO FIX: scripts/launch-openclaw.sh
step "Layer 3: Sandbox"

if command -v openshell &>/dev/null; then
  openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}" \
    && pass "Sandbox '$SANDBOX_NAME' exists" \
    || fail "Sandbox '$SANDBOX_NAME' not found"

  openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}.*Ready" \
    && pass "Sandbox is Ready" \
    || fail "Sandbox not in Ready state"
else
  warn "openshell CLI not available, skipping sandbox checks"
fi

# =============================================================================
# Layer 4: Security Validation
# =============================================================================
# WHY: These checks verify the security posture of the sandbox:
#   - User identity: agent must run as unprivileged "sandbox" user
#   - Egress blocking: unauthorized destinations must be blocked by proxy
#   - MaaS reachability: the one allowed destination must work
#   - Credential isolation: no plaintext API keys on sandbox filesystem
#   - Landlock enforcement: /sandbox/ must be read-only
#   - Config placeholders: openshell:resolve:env markers must exist in the
#     ORIGINAL config (at /sandbox/.openclaw/config.json). The WORKING config
#     at /sandbox/workspace/.openclaw/openclaw.json has the real key injected
#     by launch-openclaw.sh (see constraint #3 in launch-openclaw.sh).
# HOW TO FIX: These indicate fundamental sandbox security issues. Check
#   policies/openclaw-sandbox.yaml and the SCC binding.
step "Layer 4: Security Validation"

if command -v openshell &>/dev/null; then
  WHOAMI=$(sandbox_run "whoami" || true)
  if echo "$WHOAMI" | grep -q "sandbox"; then
    pass "Sandbox user identity: sandbox"
  else
    fail "Expected sandbox user, got unexpected identity"
  fi

  # Verify unauthorized egress is blocked
  GITHUB_RESULT=$(sandbox_run 'curl -sI https://github.com 2>&1 | head -1' || true)
  if echo "$GITHUB_RESULT" | grep -q "403"; then
    pass "Unauthorized egress blocked (github.com -> 403)"
  else
    fail "SECURITY: github.com should be blocked by proxy"
  fi

  # Verify MaaS IS reachable (it's in the allow list)
  MAAS_RESULT=$(sandbox_run 'curl -sI https://maas-rhdp.apps.maas.redhatworkshops.io/health 2>&1 | head -1' || true)
  if echo "$MAAS_RESULT" | grep -qE "200|401|403"; then
    pass "MaaS endpoint reachable through proxy"
  else
    warn "MaaS endpoint response unexpected: $MAAS_RESULT"
  fi

  # Verify no plaintext credentials on sandbox filesystem.
  # /sandbox/.openclaw/ is read-only (Landlock) and uses openshell:resolve:env placeholders.
  # /sandbox/workspace/.openclaw/ has the working config where launch-openclaw.sh injects
  # the real API key (constraint #3). This is a known workaround — warn, don't fail.
  CRED_RO=$(sandbox_run 'grep -rl "sk-" /sandbox/.openclaw/ /tmp/ 2>/dev/null | head -1 || echo CLEAN' || true)
  if echo "$CRED_RO" | grep -q "CLEAN"; then
    pass "No plaintext API keys in read-only zone (/sandbox/.openclaw/, /tmp/)"
  else
    fail "SECURITY: API key found in read-only filesystem zone"
  fi

  CRED_WS=$(sandbox_run 'grep -rl "sk-" /sandbox/workspace/.openclaw/ 2>/dev/null | head -1 || echo CLEAN' || true)
  if echo "$CRED_WS" | grep -q "CLEAN"; then
    pass "No plaintext API keys in workspace config"
  else
    warn "API key present in /sandbox/workspace/.openclaw/ (known workaround — constraint #3, OpenShell issue #894)"
  fi

  # Verify Landlock: /sandbox/.openclaw/ must be read-only
  WRITE_CONFIG=$(sandbox_run 'echo test > /sandbox/.openclaw/config.json 2>&1; echo EXIT:$?' || true)
  if echo "$WRITE_CONFIG" | grep -qEi "Permission denied|Read-only|EXIT:1"; then
    pass "Landlock blocks write to /sandbox/.openclaw/ (read-only)"
  else
    fail "SECURITY: /sandbox/.openclaw/ is writable (should be read-only via Landlock)"
  fi

  # Verify /sandbox/workspace/ IS writable (agent needs this)
  WRITE_WORKSPACE=$(sandbox_run 'echo test > /sandbox/workspace/landlock-test.txt 2>&1; echo EXIT:$?' || true)
  if echo "$WRITE_WORKSPACE" | grep -q "EXIT:0"; then
    pass "/sandbox/workspace/ is writable (expected)"
    sandbox_run 'rm -f /sandbox/workspace/landlock-test.txt' >/dev/null 2>&1 || true
  else
    fail "/sandbox/workspace/ should be writable but write failed"
  fi

  # Verify credential placeholder exists in ORIGINAL config (read-only zone).
  # The WORKING config has the real key injected — that's by design (constraint #3).
  CONFIG_PLACEHOLDER=$(sandbox_run 'grep -l "openshell:resolve:env" /sandbox/.openclaw/config.json /sandbox/workspace/.openclaw/openclaw.json 2>/dev/null && echo FOUND || echo MISSING' || true)
  if echo "$CONFIG_PLACEHOLDER" | grep -q "FOUND"; then
    pass "Config placeholder openshell:resolve:env still intact"
  else
    fail "SECURITY: config placeholder was modified or missing"
  fi
else
  warn "openshell CLI not available, skipping security checks"
fi

# =============================================================================
# Layer 5: OpenClaw Gateway Health
# =============================================================================
# WHY: Verifies the OpenClaw gateway inside the sandbox is running and
#   properly configured:
#   - /health endpoint: basic liveness
#   - chatCompletions disabled: the HTTP API must be off (Control UI uses
#     WebSocket, not HTTP). Enabled HTTP API is a security exposure.
#   - tools.deny: dangerous tools (gateway, cron, openclaw) must be blocked
# HOW TO FIX: scripts/launch-openclaw.sh (restarts gateway with correct config)
step "Layer 5: OpenClaw Gateway Health"

if command -v openshell &>/dev/null; then
  HEALTH=$(sandbox_run 'curl -s http://localhost:18789/health' || true)
  if echo "$HEALTH" | grep -q '"ok":true'; then
    pass "OpenClaw /health returns ok"
  else
    fail "OpenClaw health check failed"
  fi

  CONFIG_CHECK=$(sandbox_run 'grep -l "openshell:resolve:env" /sandbox/.openclaw/config.json /sandbox/workspace/.openclaw/openclaw.json 2>/dev/null && echo FOUND || echo MISSING' || true)
  if echo "$CONFIG_CHECK" | grep -q "FOUND"; then
    pass "Credential injection placeholder configured"
  else
    warn "Credential injection placeholder not found in config"
  fi

  # chatCompletions HTTP API must be disabled (security: only WebSocket via Control UI)
  CHAT_API=$(sandbox_run "curl -s -o /dev/null -w 'HTTP_CODE:%{http_code}' -X POST http://localhost:18789/v1/chat/completions -H 'Content-Type: application/json' -d '{}'" || true)
  CHAT_CODE=$(echo "$CHAT_API" | grep -oP 'HTTP_CODE:\K[0-9]+' | head -1 || echo "unknown")
  if [[ "$CHAT_CODE" == "404" || "$CHAT_CODE" == "405" || "$CHAT_CODE" == "403" ]]; then
    pass "chatCompletions HTTP API is disabled (HTTP $CHAT_CODE)"
  else
    warn "chatCompletions may still be enabled (HTTP $CHAT_CODE)"
  fi

  # tools.deny must block gateway/cron/openclaw commands
  TOOLS_DENY=$(sandbox_run 'grep -l "\"deny\"" /sandbox/.openclaw/config.json /sandbox/workspace/.openclaw/openclaw.json 2>/dev/null && echo FOUND || echo MISSING' || true)
  if echo "$TOOLS_DENY" | grep -q "FOUND"; then
    pass "tools.deny configured in OpenClaw config"
  else
    warn "tools.deny not found in config"
  fi
else
  warn "openshell CLI not available, skipping OpenClaw checks"
fi

# =============================================================================
# Layer 5b: LLM Connectivity (end-to-end through sandbox proxy)
# =============================================================================
# WHY: This layer catches the MOST COMMON failure mode: the OpenClaw gateway
#   can start and appear healthy but CANNOT actually reach the LLM provider.
#
# ROOT CAUSE HISTORY (do not remove — prevents regression):
#   1. Node.js binary path: `n` (version manager) installs Node.js at
#      /usr/local/bin/node. The sandbox proxy L7 policy only allows
#      /usr/bin/node. If both exist, Node.js processes use /usr/local/bin/node
#      (PATH priority), and the proxy DENIES all their traffic.
#      => Check 1 verifies /usr/local/bin/node does NOT exist.
#
#   2. Node.js fetch() connectivity: Even with correct binary path, fetch()
#      (undici) creates ephemeral connections. The proxy CAN handle these
#      through the transparent nftables redirect, but setting HTTP_PROXY or
#      NODE_OPTIONS breaks this by forcing HTTP CONNECT tunneling.
#      => Check 2 verifies Node.js fetch() works through the proxy.
#
#   3. Proxy denial logs: Even if curl works, Node.js may be denied.
#      The proxy logs DENIED entries with the reason.
#      => Check 3 looks for DENIED entries mentioning "maas".
#
#   4. End-to-end LLM request: The ultimate test — does the gateway actually
#      get a response from the LLM model? This catches API key issues,
#      model routing issues, and any other end-to-end problems.
#      Method: temporarily enable chatCompletions, send a request, disable it.
#      => Check 4 sends a real LLM request and checks for a model response.
#
#   5. Trace generation: After an LLM request, MLflow should have a new trace.
#      If no trace appears, the mlflow-openclaw plugin isn't loaded or isn't
#      working. This is the ONLY way to verify the plugin is actually active.
#      => Check 5 verifies a trace was created within the last 300 seconds.
#
# HOW TO FIX:
#   Check 1 fail: oc exec $SANDBOX -c agent -- bash -c 'cp /usr/local/bin/node /usr/bin/node && rm -f /usr/local/bin/node'
#   Check 2 fail: Verify no HTTP_PROXY/NODE_OPTIONS set. Check launch-openclaw.sh constraint #3.
#   Check 3 fail: Review policies/openclaw-sandbox.yaml. Check `openshell logs openclaw-gw | grep DENIED`.
#   Check 4 fail: Check API key injection in launch-openclaw.sh. Verify secrets/secrets.env has MAAS_API_KEY.
#   Check 5 fail: Verify mlflow-openclaw plugin loaded. Check `oc exec $SANDBOX -c agent -- grep mlflow /sandbox/workspace/openclaw.log`.
step "Layer 5b: LLM Connectivity"

if command -v openshell &>/dev/null; then
  # Check 1: Node.js binary path — /usr/local/bin/node must NOT exist.
  # If it exists, the proxy will deny all Node.js network traffic because
  # the L7 policy only allows /usr/bin/node. (See root cause #1 above)
  NODE_LOCAL=$(sandbox_run 'test -f /usr/local/bin/node && echo EXISTS || echo ABSENT' || true)
  if echo "$NODE_LOCAL" | grep -q "ABSENT"; then
    pass "No /usr/local/bin/node (only /usr/bin/node allowed by policy)"
  else
    fail "SECURITY: /usr/local/bin/node exists — proxy will deny Node.js network access. Fix: rm /usr/local/bin/node"
  fi

  # Check 2: Node.js fetch() reaches MaaS through the transparent proxy.
  # This is the SAME mechanism the OpenClaw gateway uses to call the LLM.
  # If this fails, the gateway will fail too. (See root cause #2 above)
  NODE_FETCH=$(sandbox_run 'cat > /tmp/verify-fetch.mjs << '"'"'HEREDOC'"'"'
try {
  const r = await fetch("https://maas-rhdp.apps.maas.redhatworkshops.io/health");
  console.log("NODE_FETCH_STATUS:" + r.status);
} catch(e) {
  const cause = e.cause?.cause?.message || e.cause?.message || e.message;
  console.log("NODE_FETCH_ERROR:" + cause);
}
HEREDOC
/usr/bin/node /tmp/verify-fetch.mjs 2>&1' || true)
  if echo "$NODE_FETCH" | grep -q "NODE_FETCH_STATUS:"; then
    FETCH_CODE=$(echo "$NODE_FETCH" | tr -d '\r' | sed -n 's/.*NODE_FETCH_STATUS://p' | head -1)
    pass "Node.js fetch() reaches MaaS through proxy (HTTP $FETCH_CODE)"
  elif echo "$NODE_FETCH" | grep -q "NODE_FETCH_ERROR:"; then
    FETCH_ERR=$(echo "$NODE_FETCH" | tr -d '\r' | sed -n 's/.*NODE_FETCH_ERROR://p' | head -1)
    fail "Node.js fetch() to MaaS fails: $FETCH_ERR"
  else
    fail "Node.js fetch() to MaaS: unexpected result"
  fi

  # Check 3: No DENIED entries for MaaS in sandbox proxy logs.
  # The proxy logs every denied connection with the reason.
  # Even a single DENIED entry means the gateway is failing silently.
  # (See root cause #3 above)
  DENY_LOGS=$(openshell logs openclaw-gw 2>&1 | grep "DENIED.*maas" | tail -5 || true)
  DENY_COUNT=$(echo "$DENY_LOGS" | grep -c "DENIED" || true)
  if [[ "$DENY_COUNT" -eq 0 ]]; then
    pass "No DENIED proxy entries for MaaS"
  else
    LATEST_DENY=$(echo "$DENY_LOGS" | tail -1 | grep -oP "reason:.*" | head -1 || echo "unknown")
    fail "Sandbox proxy denied MaaS access ($DENY_COUNT entries). Latest: ${LATEST_DENY:0:120}"
  fi

  # Check 4: Gateway can complete a REAL LLM request.
  # This is the end-to-end test: config → gateway → proxy → MaaS → model.
  # We temporarily enable chatCompletions, send a request, then disable it.
  # chatCompletions is normally disabled (security: only WebSocket via UI).
  # (See root cause #4 above)
  sandbox_run 'python3 -c "
import json
CFG=\"/sandbox/workspace/.openclaw/openclaw.json\"
with open(CFG) as f: d=json.load(f)
d[\"gateway\"][\"http\"][\"endpoints\"][\"chatCompletions\"][\"enabled\"]=True
with open(CFG,\"w\") as f: json.dump(d,f,indent=2)
"' > /dev/null 2>&1 || true

  GW_LLM=$(sandbox_run "curl -sf --max-time 45 -X POST http://127.0.0.1:18789/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-Email: verify@test.local' \
    -H 'X-Forwarded-Proto: https' \
    -H 'X-Forwarded-Host: openclaw-ui.${APPS_DOMAIN}' \
    -d '{\"model\":\"openclaw\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: VERIFY_OK\"}],\"stream\":false,\"max_tokens\":20}' 2>&1; echo GW_LLM_EXIT:\$?" || true)

  # Restore chatCompletions to disabled
  sandbox_run 'python3 -c "
import json
CFG=\"/sandbox/workspace/.openclaw/openclaw.json\"
with open(CFG) as f: d=json.load(f)
d[\"gateway\"][\"http\"][\"endpoints\"][\"chatCompletions\"][\"enabled\"]=False
with open(CFG,\"w\") as f: json.dump(d,f,indent=2)
"' > /dev/null 2>&1 || true

  if echo "$GW_LLM" | grep -qi "choices\|content\|VERIFY_OK"; then
    pass "Gateway LLM request completed (model responded)"
  elif echo "$GW_LLM" | grep -qi "401\|authentication\|LiteLLM.*expected"; then
    fail "Gateway LLM auth failed — API key not injected. Fix: check MAAS_API_KEY in secrets/secrets.env and re-run launch-openclaw.sh"
  elif echo "$GW_LLM" | grep -qi "fetch failed\|Connection error\|timeout"; then
    fail "Gateway LLM request failed — network error. Fix: check openshell logs openclaw-gw | grep DENIED"
  else
    RECENT_ERRORS=$(sandbox_run 'grep -c "fetch failed\|network connection error\|LLM request failed" /sandbox/workspace/openclaw.log 2>/dev/null || echo 0' || true)
    if echo "$RECENT_ERRORS" | grep -qE "^0$|^[[:space:]]*0"; then
      pass "No LLM connection errors in gateway log"
    else
      fail "Gateway has LLM connection errors in log"
    fi
  fi

  # Check 5: The LLM request above should have generated a trace in MLflow.
  # If no trace appears within 300s, the mlflow-openclaw plugin is not loaded
  # or not working. This is the ONLY reliable way to verify the full trace
  # pipeline: gateway → plugin → MLflow. (See root cause #5 above)
  #
  # The trace may take 15-30s to propagate (plugin → MLflow API → storage).
  # We retry up to 6 times (90s total) before failing.
  OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
  MLFLOW_HOST_5B=$(oc get route mlflow -n "$OBS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -n "$MLFLOW_HOST_5B" ]]; then
    MLFLOW_EXT_5B="https://${MLFLOW_HOST_5B}"
    TRACE_FOUND=false
    for attempt in 1 2 3 4 5 6; do
      sleep 15
      RECENT_TRACE=$(curl -sf $CURL_OPTS "${MLFLOW_EXT_5B}/api/2.0/mlflow/traces?experiment_ids=0&max_results=1" 2>/dev/null | python3 -c "
import sys,json,time
data = json.load(sys.stdin)
traces = data.get('traces',[])
if traces:
    ts = traces[0].get('timestamp_ms',0)
    age_s = (time.time()*1000 - ts) / 1000
    print(f'AGE:{age_s:.0f}')
else:
    print('NO_TRACES')
" 2>/dev/null || echo "ERROR")
      if echo "$RECENT_TRACE" | grep -q "^AGE:"; then
        TRACE_AGE=$(echo "$RECENT_TRACE" | tr -d '\r' | sed -n 's/^AGE://p')
        if [[ "${TRACE_AGE%%.*}" -lt 300 ]]; then
          pass "Latest MLflow trace is recent (${TRACE_AGE}s ago) — trace pipeline working"
          TRACE_FOUND=true
          break
        fi
      fi
      if [[ $attempt -lt 6 ]]; then
        info "Waiting for MLflow trace (attempt $attempt/6)..."
      fi
    done
    if [[ "$TRACE_FOUND" != "true" ]]; then
      if echo "$RECENT_TRACE" | grep -q "^AGE:"; then
        TRACE_AGE=$(echo "$RECENT_TRACE" | tr -d '\r' | sed -n 's/^AGE://p')
        fail "Latest MLflow trace is stale (${TRACE_AGE}s ago) — mlflow-openclaw plugin may not be loaded. Fix: check grep mlflow /sandbox/workspace/openclaw.log"
      elif echo "$RECENT_TRACE" | grep -q "NO_TRACES"; then
        fail "No traces in MLflow after 90s — mlflow-openclaw plugin not generating traces. Fix: re-run launch-openclaw.sh"
      else
        warn "Could not check trace recency"
      fi
    fi
  fi
else
  warn "openshell CLI not available, skipping LLM connectivity checks"
fi

# =============================================================================
# Layer 7b: External Service URL Access
# =============================================================================
# WHY: Verifies that the OpenClaw UI is reachable from outside the cluster
#   through the OpenShift route and oauth2-proxy.
step "Layer 7b: External Access via Service Route"

MTLS_DIR="$HOME/.config/openshell/gateways/ocp/mtls"
SVC_ROUTE_HOST=$(oc -n "$NAMESPACE" get route openclaw-ui -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [[ -n "$SVC_ROUTE_HOST" ]]; then
  pass "Service Route exists: $SVC_ROUTE_HOST"

  if [[ -f "$MTLS_DIR/tls.crt" && -f "$MTLS_DIR/tls.key" && -f "$MTLS_DIR/ca.crt" ]]; then
    EXTERNAL_URL="$(get_service_url "$SANDBOX_NAME" openclaw-ui)"
    HEALTH_EXT=$(curl -sk --cert "$MTLS_DIR/tls.crt" \
                          --key  "$MTLS_DIR/tls.key" \
                          --cacert "$MTLS_DIR/ca.crt" \
                          "${EXTERNAL_URL}/health" 2>&1 || true)
    if echo "$HEALTH_EXT" | grep -q '"ok":true'; then
      pass "External access: /health returns ok via service Route"
    elif echo "$HEALTH_EXT" | grep -qiE "alert|handshake|certificate"; then
      warn "External access: TLS handshake issue (wildcard SAN may be missing — run scripts/upgrade-pki.sh)"
    else
      warn "External access: unexpected response (${HEALTH_EXT:0:80})"
    fi
  else
    warn "mTLS certs not found at $MTLS_DIR — skipping mTLS external access tests"
  fi
else
  warn "Service Route 'openclaw-ui' not found — apply manifests/openclaw-service-route.yaml"
fi

# =============================================================================
# Layer 7b: oauth2-proxy OIDC UI Authentication
# =============================================================================
# WHY: Users access the OpenClaw UI through oauth2-proxy, which handles
#   Keycloak OIDC login. This verifies the full auth chain:
#   1. oauth2-proxy route exists and pod is running
#   2. Unauthenticated requests redirect to Keycloak (302)
#   3. Redirect points to the correct Keycloak realm
#   4. Password grant works (proves client credentials are correct)
# HOW TO FIX: scripts/deploy-oauth2-proxy.sh
step "Layer 7b: oauth2-proxy OIDC UI Authentication"

OAUTH2_PROXY_HOST="openclaw-ui.${APPS_DOMAIN}"
KC_HOST="keycloak-openshell-keycloak.${APPS_DOMAIN}"

if oc -n "$NAMESPACE" get route openclaw-ui-auth &>/dev/null; then
  pass "oauth2-proxy route exists"

  if oc -n "$NAMESPACE" get deployment oauth2-proxy &>/dev/null; then
    READY=$(oc -n "$NAMESPACE" get deployment oauth2-proxy -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$READY" -ge 1 ]]; then
      pass "oauth2-proxy pod is running (${READY} replicas)"
    else
      fail "oauth2-proxy pod not ready"
    fi
  else
    fail "oauth2-proxy deployment not found"
  fi

  REDIRECT_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${OAUTH2_PROXY_HOST}/" 2>/dev/null || echo "000")
  if [[ "$REDIRECT_CODE" == "302" || "$REDIRECT_CODE" == "303" ]]; then
    pass "Unauthenticated request redirects to Keycloak (HTTP ${REDIRECT_CODE})"
  else
    fail "Expected 302/303 redirect, got HTTP ${REDIRECT_CODE}"
  fi

  REDIRECT_LOCATION=$(curl -sk -o /dev/null -w '%{redirect_url}' "https://${OAUTH2_PROXY_HOST}/" 2>/dev/null || echo "")
  if echo "$REDIRECT_LOCATION" | grep -q "${KC_HOST}"; then
    pass "Redirect target is Keycloak issuer"
  else
    warn "Redirect location does not point to Keycloak: ${REDIRECT_LOCATION:0:80}"
  fi

  CLIENT_SECRET_FILE="${PROJECT_DIR}/secrets/.oauth2-proxy-client-secret"
  if [[ -f "$CLIENT_SECRET_FILE" ]]; then
    UI_CLIENT_SECRET=$(cat "$CLIENT_SECRET_FILE")
    TOKEN_RESP=$(curl -sk -X POST \
      "https://${KC_HOST}/realms/openshell/protocol/openid-connect/token" \
      -d "grant_type=password" \
      -d "client_id=openclaw-ui" \
      -d "client_secret=${UI_CLIENT_SECRET}" \
      -d "username=admin" \
      -d "password=admin" \
      -d "scope=openid email profile" 2>/dev/null || echo "")
    if echo "$TOKEN_RESP" | grep -q "access_token"; then
      pass "Password grant token acquisition (openclaw-ui client)"
    else
      fail "Could not acquire token via password grant for openclaw-ui"
    fi
  else
    warn "Client secret file not found, skipping token test"
  fi
else
  warn "oauth2-proxy route 'openclaw-ui-auth' not found — run scripts/deploy-oauth2-proxy.sh"
fi

# =============================================================================
# Layer 8: Observability Stack
# =============================================================================
# WHY: Verifies Tempo (trace storage), OTel Collector (trace ingestion),
#   and MLflow (trace analysis UI). Also sends a test trace to verify
#   the full pipeline: OTel Collector → Tempo → queryable via API.
# HOW TO FIX: scripts/deploy-observability.sh
step "Layer 8: Observability Stack"

OBS_NAMESPACE="observability"

if oc get ns "$OBS_NAMESPACE" &>/dev/null; then
  pass "Observability namespace exists"

  TEMPO_READY=$(oc -n "$OBS_NAMESPACE" get pods -l app=tempo -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [[ "$TEMPO_READY" == "true" ]]; then
    pass "Tempo pod running and ready"
  else
    fail "Tempo pod not ready"
  fi

  COLLECTOR_READY=$(oc -n "$OBS_NAMESPACE" get pods -l app=otel-collector -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [[ "$COLLECTOR_READY" == "true" ]]; then
    pass "OTel Collector pod running and ready"
  else
    fail "OTel Collector pod not ready"
  fi

  MLFLOW_READY=$(oc -n "$OBS_NAMESPACE" get pods -l app=mlflow -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [[ "$MLFLOW_READY" == "true" ]]; then
    pass "MLflow pod running and ready"
  else
    fail "MLflow pod not ready"
  fi

  MLFLOW_HOST=$(oc get route mlflow -n "$OBS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -n "$MLFLOW_HOST" ]]; then
    MLFLOW_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${MLFLOW_HOST}/health" 2>/dev/null || echo "000")
    if [[ "$MLFLOW_CODE" == "200" ]]; then
      pass "MLflow health endpoint OK (https://${MLFLOW_HOST})"
    else
      fail "MLflow health returned HTTP ${MLFLOW_CODE}"
    fi
  fi

  # Send a test trace through the OTel pipeline to verify it's working
  oc -n "$OBS_NAMESPACE" port-forward svc/otel-collector 24318:4318 &>/dev/null &
  TRACE_PF_PID=$!
  sleep 2

  TEST_TRACE_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex)" 2>/dev/null || echo "abcdef1234567890abcdef1234567890")
  TEST_SPAN_ID=$(python3 -c "import os; print(os.urandom(8).hex())" 2>/dev/null || echo "1234567890abcdef")
  NOW_NS=$(python3 -c "import time; print(int(time.time() * 1e9))")
  END_NS=$(python3 -c "import time; print(int((time.time()+1) * 1e9))")

  TRACE_RESP=$(curl -s -X POST http://localhost:24318/v1/traces \
    -H "Content-Type: application/json" \
    -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verify-test\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"test\"},\"spans\":[{\"traceId\":\"${TEST_TRACE_ID}\",\"spanId\":\"${TEST_SPAN_ID}\",\"name\":\"verify-trace\",\"kind\":1,\"startTimeUnixNano\":\"${NOW_NS}\",\"endTimeUnixNano\":\"${END_NS}\",\"status\":{\"code\":1}}]}]}]}" 2>/dev/null || echo "error")

  kill $TRACE_PF_PID 2>/dev/null || true

  if echo "$TRACE_RESP" | grep -q "partialSuccess"; then
    pass "Trace pipeline: OTel Collector accepts OTLP traces"
  else
    fail "Trace pipeline: could not send trace to collector"
  fi

  sleep 5

  TRACE_VERIFY=$(oc -n "$OBS_NAMESPACE" exec deployment/tempo -- \
    wget -qO- "http://localhost:3200/api/traces/${TEST_TRACE_ID}" 2>/dev/null || echo "{}")
  if echo "$TRACE_VERIFY" | grep -q "verify-trace"; then
    pass "Trace pipeline: trace stored in Tempo and retrievable"
  else
    warn "Trace pipeline: trace not yet visible in Tempo (may need more time)"
  fi

  # Verify MLflow has traces from the mlflow-openclaw plugin
  MLFLOW_TRACES=$(oc -n "$OBS_NAMESPACE" exec deployment/mlflow -- \
    python3 -c "
import urllib.request, json
try:
    req = urllib.request.Request('http://localhost:5000/api/2.0/mlflow/traces?experiment_ids=0&max_results=5')
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.loads(r.read())
        traces = data.get('traces', [])
        print('COUNT:' + str(len(traces)))
except Exception as e:
    print('ERROR:' + str(e))
" 2>/dev/null || echo "ERROR:exec-failed")

  if echo "$MLFLOW_TRACES" | grep -qE "COUNT:[1-9]"; then
    TRACE_COUNT=$(echo "$MLFLOW_TRACES" | grep -oE "COUNT:[0-9]+" | cut -d: -f2)
    pass "MLflow native traces: ${TRACE_COUNT} trace(s) in Traces tab"
  elif echo "$MLFLOW_TRACES" | grep -q "COUNT:0"; then
    warn "MLflow native traces: no traces yet (send a message via UI first)"
  else
    warn "MLflow native traces: could not query traces API (${MLFLOW_TRACES})"
  fi

  # Verify trace quality: session/user metadata in span artifacts
  MLFLOW_TRACE_QUALITY=$(oc -n "$OBS_NAMESPACE" exec deployment/mlflow -- \
    python3 -c "
import sqlite3, os, json
conn = sqlite3.connect('/mlflow/mlflow.db')
c = conn.cursor()
rows = c.execute('SELECT request_id FROM trace_info ORDER BY timestamp_ms DESC LIMIT 5').fetchall()
sessions = 0; users = 0; total_spans = 0
for r in rows:
    art = f'/mlflow/artifacts/0/traces/{r[0]}/artifacts/traces.json'
    if os.path.exists(art):
        with open(art) as f:
            data = json.load(f)
        spans = data.get('spans', [])
        total_spans += len(spans)
        if spans:
            attrs = spans[0].get('attributes', {})
            if attrs.get('mlflow.trace.session'):
                sessions += 1
            if attrs.get('mlflow.trace.user'):
                users += 1
print(f'SESSIONS:{sessions}')
print(f'USERS:{users}')
print(f'SPANS:{total_spans}')
conn.close()
" 2>/dev/null || echo "ERROR:exec-failed")

  if echo "$MLFLOW_TRACE_QUALITY" | grep -qE "SESSIONS:[1-9]"; then
    pass "MLflow trace attribute: mlflow.trace.session present in artifacts"
  elif echo "$MLFLOW_TRACE_QUALITY" | grep -q "SESSIONS:0"; then
    warn "MLflow trace attribute: mlflow.trace.session missing in artifacts"
  else
    warn "MLflow trace quality: could not query (${MLFLOW_TRACE_QUALITY})"
  fi

  if echo "$MLFLOW_TRACE_QUALITY" | grep -qE "USERS:[1-9]"; then
    pass "MLflow trace attribute: mlflow.trace.user present in artifacts"
  elif echo "$MLFLOW_TRACE_QUALITY" | grep -q "USERS:0"; then
    warn "MLflow trace attribute: mlflow.trace.user missing in artifacts"
  else
    warn "MLflow trace quality: could not query"
  fi

  if echo "$MLFLOW_TRACE_QUALITY" | grep -qE "SPANS:[1-9]"; then
    SPAN_COUNT=$(echo "$MLFLOW_TRACE_QUALITY" | grep -oE "SPANS:[0-9]+" | cut -d: -f2)
    pass "MLflow trace spans: ${SPAN_COUNT} span(s) across traces (AGENT + LLM hierarchy)"
  elif echo "$MLFLOW_TRACE_QUALITY" | grep -q "SPANS:0"; then
    warn "MLflow trace spans: no spans found in artifacts"
  fi
else
  warn "Observability namespace not found — run scripts/deploy-observability.sh"
fi

# =============================================================================
# Layer 8b: MLflow Prompt Registry
# =============================================================================
# WHY: Verifies the full prompt management lifecycle:
#   1. Prompts are registered in MLflow (seed-mlflow-prompts.sh ran)
#   2. @production aliases are set (controlled rollout)
#   3. .prompt-versions.json manifest exists in sandbox (fetch ran)
#   4. Prompt files are read-only (agent can't modify them)
#   5. Trace linker sidecar is running (tags traces with prompt versions)
#   6. Traces have mlflow.linkedPrompts tag (visible in MLflow "Prompt" column)
#   7. Traces have prompt_versions custom tag (visible in trace detail view)
# HOW TO FIX:
#   Prompts not registered: scripts/seed-mlflow-prompts.sh
#   Manifest missing: launch-openclaw.sh (re-runs fetch)
#   Linker not running: launch-openclaw.sh (restarts linker)
step "Layer 8b: MLflow Prompt Registry"

OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
MLFLOW_INT_URL="http://mlflow.${OBS_NAMESPACE}.svc:5000"
PROMPT_NAMES=(AGENTS SOUL TOOLS IDENTITY USER HEARTBEAT BOOTSTRAP)
PROMPT_PREFIX="openclaw-system"

if oc get ns "$OBS_NAMESPACE" &>/dev/null; then
  MLFLOW_HOST=$(oc get route mlflow -n "$OBS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -n "$MLFLOW_HOST" ]]; then
    MLFLOW_EXT_URL="https://${MLFLOW_HOST}"

    REGISTERED=0
    ALIASED=0
    for pname in "${PROMPT_NAMES[@]}"; do
      fq="${PROMPT_PREFIX}.${pname}"
      encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${fq}', safe=''))" 2>/dev/null || echo "$fq")
      MODEL_RESP=$(curl -sf $CURL_OPTS "${MLFLOW_EXT_URL}/api/2.0/mlflow/registered-models/get?name=${encoded}" 2>/dev/null || echo "")
      if [[ -n "$MODEL_RESP" ]] && echo "$MODEL_RESP" | python3 -c "import sys,json; json.load(sys.stdin)['registered_model']" &>/dev/null; then
        REGISTERED=$((REGISTERED + 1))
        if echo "$MODEL_RESP" | python3 -c "
import sys,json
aliases = json.load(sys.stdin).get('registered_model',{}).get('aliases',[])
found = any(a.get('alias') == 'production' for a in aliases)
sys.exit(0 if found else 1)
" 2>/dev/null; then
          ALIASED=$((ALIASED + 1))
        fi
      fi
    done

    if [[ $REGISTERED -eq ${#PROMPT_NAMES[@]} ]]; then
      pass "All ${REGISTERED}/${#PROMPT_NAMES[@]} prompts registered in MLflow"
    elif [[ $REGISTERED -gt 0 ]]; then
      warn "Only ${REGISTERED}/${#PROMPT_NAMES[@]} prompts registered in MLflow"
    else
      fail "No prompts registered in MLflow — run scripts/seed-mlflow-prompts.sh"
    fi

    if [[ $ALIASED -eq ${#PROMPT_NAMES[@]} ]]; then
      pass "All prompts have @production alias"
    elif [[ $ALIASED -gt 0 ]]; then
      warn "Only ${ALIASED}/${#PROMPT_NAMES[@]} prompts have @production alias"
    else
      fail "No @production aliases set"
    fi
  else
    warn "MLflow route not found, skipping prompt registry checks"
  fi

  if command -v openshell &>/dev/null; then
    # Verify prompt manifest exists in sandbox
    MANIFEST_CHECK=$(sandbox_run 'test -f /sandbox/workspace/.prompt-versions.json && python3 -c "import json; d=json.load(open(\"/sandbox/workspace/.prompt-versions.json\")); print(\"MANIFEST_COUNT:\" + str(len(d.get(\"prompts\",{}))))" || echo "MANIFEST_COUNT:0"' || true)
    MANIFEST_COUNT=$(echo "$MANIFEST_CHECK" | tr -d '\r\n' | sed 's/.*MANIFEST_COUNT:\([0-9]*\).*/\1/' || echo "0")
    [[ -z "$MANIFEST_COUNT" || "$MANIFEST_COUNT" == *"MANIFEST"* ]] && MANIFEST_COUNT=0
    if [[ "$MANIFEST_COUNT" -ge 7 ]]; then
      pass "Prompt manifest .prompt-versions.json has ${MANIFEST_COUNT} entries"
    elif [[ "$MANIFEST_COUNT" -gt 0 ]]; then
      warn "Prompt manifest has only ${MANIFEST_COUNT}/7 entries"
    else
      fail "Prompt manifest missing or empty in sandbox"
    fi

    # Verify prompt files are read-only (chmod 444, root-owned)
    PROT_CHECK=$(sandbox_run 'c=0; for f in AGENTS SOUL TOOLS IDENTITY USER HEARTBEAT BOOTSTRAP; do test -f /sandbox/workspace/${f}.md && p=$(stat -c %a /sandbox/workspace/${f}.md 2>/dev/null) && [ "$p" = "444" ] && c=$((c+1)); done; echo "PROTECTED:$c"' || true)
    PROTECTED=$(echo "$PROT_CHECK" | grep -oP 'PROTECTED:\K[0-9]+' | head -1 || echo "0")
    if [[ "$PROTECTED" -ge ${#PROMPT_NAMES[@]} ]]; then
      pass "All ${PROTECTED} prompt files are read-only (chmod 444)"
    elif [[ "$PROTECTED" -gt 0 ]]; then
      warn "Only ${PROTECTED}/${#PROMPT_NAMES[@]} prompt files are read-only"
    else
      fail "No prompt files found or none are read-only"
    fi

    # Verify trace linker sidecar is running
    LINKER_PID=$(sandbox_run 'pgrep -f prompt-trace-linker || echo NONE' || true)
    if echo "$LINKER_PID" | grep -qE '[0-9]'; then
      pass "Prompt trace linker sidecar running"
    else
      fail "Prompt trace linker not running"
    fi

    # Verify traces have prompt tags
    if [[ -n "${MLFLOW_HOST:-}" ]]; then
      TAGGED_CHECK=$(curl -sf $CURL_OPTS "${MLFLOW_EXT_URL}/api/2.0/mlflow/traces?experiment_ids=0&max_results=5" 2>/dev/null || echo "")
      if [[ -n "$TAGGED_CHECK" ]]; then
        # mlflow.linkedPrompts populates the "Prompt" column in MLflow UI
        TAGGED_COUNT=$(echo "$TAGGED_CHECK" | python3 -c "
import sys,json
data = json.load(sys.stdin)
traces = data.get('traces',[])
tagged = sum(1 for t in traces if any(tag.get('key') == 'mlflow.linkedPrompts' for tag in t.get('tags',[])))
print(tagged)
" 2>/dev/null || echo "0")
        if [[ "$TAGGED_COUNT" -gt 0 ]]; then
          pass "Prompt tags present on ${TAGGED_COUNT}/5 recent traces (mlflow.linkedPrompts)"
        else
          warn "No traces have prompt tags yet (send a message to generate traces)"
        fi

        # prompt_versions custom tag visible in individual trace detail view
        PV_COUNT=$(echo "$TAGGED_CHECK" | python3 -c "
import sys,json
data = json.load(sys.stdin)
traces = data.get('traces',[])
tagged = sum(1 for t in traces if any(tag.get('key') == 'prompt_versions' for tag in t.get('tags',[])))
print(tagged)
" 2>/dev/null || echo "0")
        if [[ "$PV_COUNT" -gt 0 ]]; then
          pass "Custom prompt_versions tag on ${PV_COUNT}/5 recent traces"
        else
          warn "No prompt_versions custom tags on traces"
        fi
      fi
    fi
  else
    warn "openshell CLI not available, skipping sandbox prompt checks"
  fi
else
  warn "Observability namespace not found, skipping MLflow Prompt Registry checks"
fi

# =============================================================================
# Layer 9: Control UI (Playwright)
# =============================================================================
# WHY: End-to-end verification that a real browser can log in via Keycloak
#   and interact with the OpenClaw Control UI.
# HOW TO FIX: Check oauth2-proxy logs, Keycloak client config, and
#   the auth.setup.ts test file for URL patterns.
step "Layer 9: Control UI Validation (Playwright)"

if command -v openshell &>/dev/null; then
  openshell service list 2>/dev/null | grep -q "openclaw-ui\|web" \
    && pass "Sandbox service registered with gateway" \
    || warn "No sandbox service registered"
fi

TEST_DIR="${PROJECT_DIR}/tests"
if command -v npx &>/dev/null && [[ -d "${TEST_DIR}/node_modules/@playwright" ]]; then
  OAUTH2_ROUTE="openclaw-ui.${APPS_DOMAIN}"
  OPENCLAW_BASE_URL="https://${OAUTH2_ROUTE}"
  info "Using oauth2-proxy route for Playwright: ${OPENCLAW_BASE_URL}"

  export OPENCLAW_BASE_URL
  if (cd "$TEST_DIR" && npx playwright test) 2>&1; then
    pass "Playwright UI + security tests passed (OIDC flow)"
  else
    fail "Playwright tests failed"
  fi
else
  warn "Playwright not installed, skipping UI tests"
  echo "    Install with: cd ${TEST_DIR} && npm install && npx playwright install chromium"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
step "Verification Summary"
echo "    Passed: $PASS_COUNT"
echo "    Failed: $FAIL_COUNT"
echo "    Warnings: $WARN_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  error "$FAIL_COUNT check(s) failed"
  exit 1
fi
info "All checks passed (with $WARN_COUNT warning(s))"

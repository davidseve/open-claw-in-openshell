#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

NAMESPACE="${NAMESPACE:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw-gw}"

detect_environment

# --- Layer 1: Infrastructure ---
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

# --- Layer 1b: Keycloak OIDC ---
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

# --- Layer 2: OpenShell Gateway ---
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

# --- Layer 3: Sandbox ---
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

# --- Layer 4: Security Validation ---
step "Layer 4: Security Validation"

if command -v openshell &>/dev/null; then
  WHOAMI=$(sandbox_run "whoami" || true)
  if echo "$WHOAMI" | grep -q "sandbox"; then
    pass "Sandbox user identity: sandbox"
  else
    fail "Expected sandbox user, got unexpected identity"
  fi

  GITHUB_RESULT=$(sandbox_run 'curl -sI https://github.com 2>&1 | head -1' || true)
  if echo "$GITHUB_RESULT" | grep -q "403"; then
    pass "Unauthorized egress blocked (github.com -> 403)"
  else
    fail "SECURITY: github.com should be blocked by proxy"
  fi

  MAAS_RESULT=$(sandbox_run 'curl -sI https://maas-rhdp.apps.maas.redhatworkshops.io/health 2>&1 | head -1' || true)
  if echo "$MAAS_RESULT" | grep -qE "200|401|403"; then
    pass "MaaS endpoint reachable through proxy"
  else
    warn "MaaS endpoint response unexpected: $MAAS_RESULT"
  fi

  CRED_CHECK=$(sandbox_run 'grep -rl "sk-" /sandbox/.openclaw/ /tmp/ 2>/dev/null | head -1 || echo CLEAN' || true)
  if echo "$CRED_CHECK" | grep -q "CLEAN"; then
    pass "No plaintext API keys on sandbox filesystem"
  else
    fail "SECURITY: API key found on sandbox filesystem"
  fi

  WRITE_CONFIG=$(sandbox_run 'echo test > /sandbox/.openclaw/config.json 2>&1; echo EXIT:$?' || true)
  if echo "$WRITE_CONFIG" | grep -qEi "Permission denied|Read-only|EXIT:1"; then
    pass "Landlock blocks write to /sandbox/.openclaw/ (read-only)"
  else
    fail "SECURITY: /sandbox/.openclaw/ is writable (should be read-only via Landlock)"
  fi

  WRITE_WORKSPACE=$(sandbox_run 'echo test > /sandbox/workspace/landlock-test.txt 2>&1; echo EXIT:$?' || true)
  if echo "$WRITE_WORKSPACE" | grep -q "EXIT:0"; then
    pass "/sandbox/workspace/ is writable (expected)"
    sandbox_run 'rm -f /sandbox/workspace/landlock-test.txt' >/dev/null 2>&1 || true
  else
    fail "/sandbox/workspace/ should be writable but write failed"
  fi

  CONFIG_PLACEHOLDER=$(sandbox_run 'grep -c "openshell:resolve:env" /sandbox/.openclaw/config.json' || true)
  if echo "$CONFIG_PLACEHOLDER" | grep -q "1"; then
    pass "Config placeholder openshell:resolve:env still intact"
  else
    fail "SECURITY: config placeholder was modified or missing"
  fi
else
  warn "openshell CLI not available, skipping security checks"
fi

# --- Layer 5: OpenClaw Gateway Health ---
step "Layer 5: OpenClaw Gateway Health"

if command -v openshell &>/dev/null; then
  HEALTH=$(sandbox_run 'curl -s http://localhost:18789/health' || true)
  if echo "$HEALTH" | grep -q '"ok":true'; then
    pass "OpenClaw /health returns ok"
  else
    fail "OpenClaw health check failed"
  fi

  CONFIG_CHECK=$(sandbox_run 'cat /sandbox/.openclaw/config.json 2>/dev/null | grep -c "openshell:resolve:env"' || true)
  if echo "$CONFIG_CHECK" | grep -q "1"; then
    pass "Credential injection placeholder configured"
  else
    warn "Credential injection placeholder not found in config"
  fi

  CHAT_API=$(sandbox_run "curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:18789/v1/chat/completions -H 'Content-Type: application/json' -d '{}'" || true)
  if [[ "$CHAT_API" == "404" || "$CHAT_API" == "405" || "$CHAT_API" == "403" ]]; then
    pass "chatCompletions HTTP API is disabled (HTTP $CHAT_API)"
  else
    warn "chatCompletions may still be enabled (HTTP $CHAT_API)"
  fi

  TOOLS_DENY=$(sandbox_run 'grep -c "\"deny\"" /sandbox/.openclaw/config.json' || true)
  if echo "$TOOLS_DENY" | grep -q "1"; then
    pass "tools.deny configured in OpenClaw config"
  else
    warn "tools.deny not found in config"
  fi
else
  warn "openshell CLI not available, skipping OpenClaw checks"
fi

# --- Layer 7b: External Service URL Access ---
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

# --- Layer 7b: oauth2-proxy OIDC UI Auth ---
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

# --- Layer 8: Observability (Phase 8) ---
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

  sleep 3

  TRACE_VERIFY=$(oc -n "$OBS_NAMESPACE" exec deployment/tempo -- \
    wget -qO- "http://localhost:3200/api/traces/${TEST_TRACE_ID}" 2>/dev/null || echo "{}")
  if echo "$TRACE_VERIFY" | grep -q "verify-trace"; then
    pass "Trace pipeline: trace stored in Tempo and retrievable"
  else
    warn "Trace pipeline: trace not yet visible in Tempo (may need more time)"
  fi
else
  warn "Observability namespace not found — run scripts/deploy-observability.sh"
fi

# --- Layer 9: Control UI (Playwright) ---
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

# --- Summary ---
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

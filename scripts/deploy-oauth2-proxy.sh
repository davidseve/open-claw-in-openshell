#!/usr/bin/env bash
# Phase 7b: Deploy oauth2-proxy for OpenClaw UI OIDC authentication.
#
# Prerequisites:
#   - Keycloak deployed (scripts/deploy-keycloak.sh)
#   - OpenShell deployed with OIDC (scripts/configure-oidc.sh)
#   - OpenClaw sandbox running (scripts/launch-openclaw.sh)
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment
KC_NAMESPACE="openshell-keycloak"
KC_ROUTE_HOST="keycloak-${KC_NAMESPACE}.${APPS_DOMAIN}"
KC_ISSUER="https://${KC_ROUTE_HOST}/realms/openshell"
OAUTH2_PROXY_ROUTE_HOST="openclaw-ui.${APPS_DOMAIN}"

# ── Step 1: Generate secrets ──────────────────────────────────────────────────

step "Generating oauth2-proxy secrets"

COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '\n' | head -c 32)
CLIENT_SECRET=$(openssl rand -hex 32)

info "Cookie secret generated (32 bytes)"
info "Client secret generated for openclaw-ui Keycloak client"

# ── Step 2: Register client in Keycloak via Admin API ─────────────────────────

step "Registering openclaw-ui client in Keycloak"

KC_ADMIN_TOKEN=$(curl -sk -X POST \
  "https://${KC_ROUTE_HOST}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=admin" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$KC_ADMIN_TOKEN" ]]; then
  fail "Could not obtain Keycloak admin token"
  exit 1
fi
info "Keycloak admin token obtained"

CLIENT_EXISTS=$(curl -sk -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
  "https://${KC_ROUTE_HOST}/admin/realms/openshell/clients?clientId=openclaw-ui")

if [[ "$CLIENT_EXISTS" == "200" ]]; then
  EXISTING=$(curl -sk \
    -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
    "https://${KC_ROUTE_HOST}/admin/realms/openshell/clients?clientId=openclaw-ui")
  if echo "$EXISTING" | grep -q '"openclaw-ui"'; then
    info "Client openclaw-ui already exists, updating secret"
    CLIENT_UUID=$(echo "$EXISTING" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    curl -sk -X PUT \
      -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://${KC_ROUTE_HOST}/admin/realms/openshell/clients/${CLIENT_UUID}" \
      -d "{
        \"clientId\": \"openclaw-ui\",
        \"name\": \"OpenClaw UI (oauth2-proxy)\",
        \"enabled\": true,
        \"publicClient\": false,
        \"standardFlowEnabled\": true,
        \"directAccessGrantsEnabled\": true,
        \"protocol\": \"openid-connect\",
        \"secret\": \"${CLIENT_SECRET}\",
        \"redirectUris\": [\"https://${OAUTH2_PROXY_ROUTE_HOST}/oauth2/callback\"],
        \"webOrigins\": [\"https://${OAUTH2_PROXY_ROUTE_HOST}\"],
        \"defaultClientScopes\": [\"openid\", \"profile\", \"email\", \"roles\"],
        \"attributes\": {\"pkce.code.challenge.method\": \"S256\"}
      }" >/dev/null
    pass "Client openclaw-ui updated"
  else
    info "Creating new client openclaw-ui"
    curl -sk -X POST \
      -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://${KC_ROUTE_HOST}/admin/realms/openshell/clients" \
      -d "{
        \"clientId\": \"openclaw-ui\",
        \"name\": \"OpenClaw UI (oauth2-proxy)\",
        \"enabled\": true,
        \"publicClient\": false,
        \"standardFlowEnabled\": true,
        \"directAccessGrantsEnabled\": true,
        \"protocol\": \"openid-connect\",
        \"secret\": \"${CLIENT_SECRET}\",
        \"redirectUris\": [\"https://${OAUTH2_PROXY_ROUTE_HOST}/oauth2/callback\"],
        \"webOrigins\": [\"https://${OAUTH2_PROXY_ROUTE_HOST}\"],
        \"defaultClientScopes\": [\"openid\", \"profile\", \"email\", \"roles\"],
        \"attributes\": {\"pkce.code.challenge.method\": \"S256\"},
        \"protocolMappers\": [{
          \"name\": \"audience-mapper\",
          \"protocol\": \"openid-connect\",
          \"protocolMapper\": \"oidc-audience-mapper\",
          \"config\": {
            \"included.client.audience\": \"openclaw-ui\",
            \"id.token.claim\": \"true\",
            \"access.token.claim\": \"true\"
          }
        }]
      }" >/dev/null
    pass "Client openclaw-ui created"
  fi
fi

# ── Step 3: Create Kubernetes secret ─────────────────────────────────────────

step "Creating oauth2-proxy Kubernetes secret"

oc -n "$NAMESPACE" create secret generic oauth2-proxy-secrets \
  --from-literal=client-secret="${CLIENT_SECRET}" \
  --from-literal=cookie-secret="${COOKIE_SECRET}" \
  --dry-run=client -o yaml | oc apply -f -

info "Secret oauth2-proxy-secrets created/updated"

# ── Step 4: Apply oauth2-proxy manifests ──────────────────────────────────────

step "Deploying oauth2-proxy"

for manifest in configmap deployment service route; do
  sed "s|apps.ocp.sandbox315.opentlc.com|${APPS_DOMAIN}|g" \
    "${PROJECT_DIR}/manifests/oauth2-proxy/${manifest}.yaml" | oc apply -f -
done

step "Waiting for oauth2-proxy to be ready"
oc -n "$NAMESPACE" rollout status deployment/oauth2-proxy --timeout=120s
pass "oauth2-proxy deployment ready"

# ── Step 5: Update OpenClaw config in sandbox ─────────────────────────────────

step "Updating OpenClaw config to trusted-proxy mode"

SANDBOX_POD=$(oc -n "$NAMESPACE" get pods -l sandbox.agents.x-k8s.io/name="${SANDBOX_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "$SANDBOX_POD" ]]; then
  render_all_templates
  OPENCLAW_CONFIG=$(cat "${RENDERED_DIR}/openclaw.json")

  echo "$OPENCLAW_CONFIG" | oc -n "$NAMESPACE" exec -i "$SANDBOX_POD" -c agent -- \
    tee /sandbox/.openclaw/config.json >/dev/null

  info "Config written to sandbox"

  oc -n "$NAMESPACE" exec "$SANDBOX_POD" -c agent -- \
    sh -c 'pkill -f "openclaw gateway" || true; sleep 2; cd /sandbox && openclaw gateway start --daemonize' \
    2>/dev/null || warn "Could not restart OpenClaw gateway (may need manual restart)"

  pass "OpenClaw config updated to trusted-proxy mode"
else
  warn "Sandbox pod not found. Config will apply on next sandbox restart."
  info "Config file updated at config/openclaw.json for future deployments."
fi

# ── Step 6: Verify ────────────────────────────────────────────────────────────

step "Verifying oauth2-proxy OIDC flow"

sleep 3
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
  "https://${OAUTH2_PROXY_ROUTE_HOST}/" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "302" || "$HTTP_CODE" == "303" ]]; then
  pass "oauth2-proxy redirects to Keycloak (HTTP ${HTTP_CODE})"
else
  warn "Expected 302/303 redirect, got HTTP ${HTTP_CODE}"
fi

# Test token acquisition and authenticated access
TOKEN_RESPONSE=$(curl -sk -X POST \
  "https://${KC_ROUTE_HOST}/realms/openshell/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=openclaw-ui" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=admin" \
  -d "password=admin" \
  -d "scope=openid email profile" 2>/dev/null || echo "")

if echo "$TOKEN_RESPONSE" | grep -q "access_token"; then
  pass "Token acquisition via password grant (admin user)"
else
  warn "Could not obtain token via password grant"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

step "Phase 7b deployment complete"
echo ""
info "OpenClaw UI (OIDC protected): https://${OAUTH2_PROXY_ROUTE_HOST}"
info "Login with Keycloak credentials (admin/admin or user/user)"
info "Or use OCP credentials via Keycloak identity broker"
echo ""
info "Old direct-access route still available (for debugging):"
info "  https://openclaw-gw--openclaw-ui.${APPS_DOMAIN}/#token=<TOKEN>"
echo ""
info "To fully remove static token access, delete the old route:"
info "  oc -n $NAMESPACE delete route openclaw-ui"

# Save client secret for reference
echo "$CLIENT_SECRET" > "${PROJECT_DIR}/secrets/.oauth2-proxy-client-secret"
chmod 600 "${PROJECT_DIR}/secrets/.oauth2-proxy-client-secret"

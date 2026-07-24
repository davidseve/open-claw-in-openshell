#!/usr/bin/env bash
# Phase 7b / 13.1: Deploy oauth-proxy (OpenShift-native OAuth) for the
# OpenClaw Control UI. Browsers authenticate directly against OCP's own
# OAuth server via a ServiceAccount-based OAuth client -- no Keycloak
# broker, no cluster-scoped OAuthClient. See ADR-0016.
#
# Keycloak itself is NOT removed by this script: it remains the OIDC issuer
# for the separate CLI/gRPC gateway auth path (scripts/configure-oidc.sh),
# which depends on Keycloak's realm_access.roles JWT claim shape
# (charts/openshell/values-ocp.yaml.tpl server.oidc.rolesClaim) that OCP's
# native OAuth server does not produce. Only the browser UI path moves off
# Keycloak here.
#
# Prerequisites:
#   - OpenShell deployed (scripts/crc-lifecycle.sh / deploy-openshell.sh)
#   - OpenClaw sandbox running (scripts/launch-openclaw.sh)
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment
render_all_templates

# Public hostname must equal OpenShell's {sandbox}--{service} service-routing
# pattern -- see route.yaml.tpl and deployment.yaml.tpl for why (WebSocket
# Host-header bug in this oauth-proxy fork, ADR-0016).
OAUTH_PROXY_ROUTE_HOST="openclaw-gw--openclaw-ui.${APPS_DOMAIN}"

# The Route above now owns this hostname, so oauth-proxy's own --upstream
# (which targets the same hostname, to reach the `openshell` Service) can no
# longer resolve it through the Route without looping back into itself.
# Resolve the `openshell` Service's ClusterIP and bake it into a hostAlias
# in the rendered Deployment so --upstream dials the Service directly.
step "Resolving openshell Service ClusterIP for oauth-proxy hostAlias"
OPENSHELL_GW_CLUSTER_IP=$(oc -n "$NAMESPACE" get svc openshell -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [[ -z "$OPENSHELL_GW_CLUSTER_IP" ]]; then
  error "Could not resolve ClusterIP for Service 'openshell' in namespace $NAMESPACE"
  exit 1
fi
info "openshell Service ClusterIP: ${OPENSHELL_GW_CLUSTER_IP}"
sed -i "s/__OPENSHELL_GW_CLUSTER_IP__/${OPENSHELL_GW_CLUSTER_IP}/g" \
  "${RENDERED_DIR}/oauth2-proxy/deployment.yaml"

# ── Step 1: Session secret ────────────────────────────────────────────────────

step "Generating oauth-proxy session secret"

if oc -n "$NAMESPACE" get secret oauth-proxy-session-secret &>/dev/null; then
  info "Secret oauth-proxy-session-secret already exists, leaving it in place"
else
  oc -n "$NAMESPACE" create secret generic oauth-proxy-session-secret \
    --from-literal=session_secret="$(openssl rand -base64 32 | tr -d '\n' | head -c 32)"
  info "Secret oauth-proxy-session-secret created"
fi

# ── Step 2: Apply manifests (SA, Service, Deployment, Route) ──────────────────

step "Deploying oauth-proxy (OpenShift-native OAuth)"

oc apply -f "${PROJECT_DIR}/manifests/oauth2-proxy/serviceaccount.yaml"
oc apply -f "${PROJECT_DIR}/manifests/oauth2-proxy/service.yaml"
oc apply -f "${RENDERED_DIR}/oauth2-proxy/deployment.yaml"
oc apply -f "${RENDERED_DIR}/oauth2-proxy/route.yaml"

step "Waiting for oauth-proxy to be ready"
oc -n "$NAMESPACE" rollout status deployment/oauth-proxy --timeout=120s
pass "oauth-proxy deployment ready"

# ── Step 3: Update OpenClaw config in sandbox ─────────────────────────────────

step "Updating OpenClaw config to trusted-proxy mode"

SANDBOX_POD=$(oc -n "$NAMESPACE" get pods -l sandbox.agents.x-k8s.io/name="${SANDBOX_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "$SANDBOX_POD" ]]; then
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

# ── Step 4: Verify ────────────────────────────────────────────────────────────

step "Verifying oauth-proxy OAuth flow"

sleep 3
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
  "https://${OAUTH_PROXY_ROUTE_HOST}/" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "302" || "$HTTP_CODE" == "303" ]]; then
  pass "oauth-proxy redirects to OCP OAuth server (HTTP ${HTTP_CODE})"
else
  warn "Expected 302/303 redirect, got HTTP ${HTTP_CODE}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

step "Phase 7b/13.1 deployment complete"
echo ""
info "OpenClaw UI (OpenShift-native OAuth): https://${OAUTH_PROXY_ROUTE_HOST}"
info "Login with any OCP cluster identity (HTPasswd/LDAP/OIDC-federated IdP)"
echo ""
info "There is no unauthenticated direct-access route anymore -- oauth-proxy"
info "is the only Kubernetes-level entry point onto this service (ADR-0016)."
echo ""
info "Keycloak remains deployed for the CLI/gRPC OIDC path (scripts/configure-oidc.sh)."
info "See ADR-0016 for why full Keycloak retirement is a separate follow-up."

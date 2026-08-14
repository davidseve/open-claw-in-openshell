#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment

KC_NAMESPACE="openshell-keycloak"
KC_ROUTE_HOST="keycloak-${KC_NAMESPACE}.${APPS_DOMAIN}"
OCP_OAUTH_HOST="oauth-openshift.${APPS_DOMAIN}"

step "Ensuring OAuthClient secret for Keycloak broker exists"
ensure_secret_var KC_BROKER_SECRET -hex 32

# --wait blocks until the Deployment's pods are Ready (Helm's own readiness
# gate), so no separate `oc wait`/`rollout status` step is needed here.
step "Deploying Keycloak (Helm)"
helm upgrade --install keycloak "${PROJECT_DIR}/charts/keycloak" \
  --namespace "$KC_NAMESPACE" --create-namespace \
  --set appsDomain="${APPS_DOMAIN}" \
  --set-string brokerSecret="${KC_BROKER_SECRET}" \
  --wait --timeout 300s
pass "Keycloak pod ready"

step "Verifying Keycloak OIDC discovery"
retries=0
while [[ $retries -lt 30 ]]; do
  DISCOVERY=$(curl -sk "https://${KC_ROUTE_HOST}/realms/openshell/.well-known/openid-configuration" 2>/dev/null || true)
  if echo "$DISCOVERY" | grep -q "jwks_uri"; then
    pass "OIDC discovery available at https://${KC_ROUTE_HOST}/realms/openshell"
    break
  fi
  sleep 5
  retries=$((retries + 1))
done
if [[ $retries -ge 30 ]]; then
  fail "Keycloak OIDC discovery not available after 150s"
  exit 1
fi

step "Keycloak deployment complete"
echo ""
info "Keycloak Admin Console: https://${KC_ROUTE_HOST}/admin (admin/admin)"
info "OIDC Issuer: https://${KC_ROUTE_HOST}/realms/openshell"
info "OCP OAuth Route: https://${OCP_OAUTH_HOST}"
echo ""
info "Local users (for testing without OCP broker):"
info "  admin / admin  (openshell-admin + openshell-user roles)"
info "  user  / user   (openshell-user role only)"
echo ""
info "Next: run ./scripts/configure-oidc.sh to connect OpenShell to Keycloak"

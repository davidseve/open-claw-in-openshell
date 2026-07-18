#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment

KC_NAMESPACE="openshell-keycloak"
KC_ROUTE_HOST="keycloak-${KC_NAMESPACE}.${APPS_DOMAIN}"
OCP_OAUTH_HOST="oauth-openshift.${APPS_DOMAIN}"

step "Generating OAuthClient secret for Keycloak broker"
KC_BROKER_SECRET=$(openssl rand -hex 32)
info "Secret generated (will be injected into OAuthClient and realm config)"

step "Creating namespace ${KC_NAMESPACE}"
oc apply -f "${PROJECT_DIR}/manifests/keycloak/namespace.yaml"

step "Creating OAuthClient for Keycloak identity brokering"
sed "s|PLACEHOLDER_GENERATED_AT_DEPLOY_TIME|${KC_BROKER_SECRET}|" \
  "${PROJECT_DIR}/manifests/keycloak/oauthclient.yaml" | oc apply -f -

step "Patching realm config with broker secret and cluster domain"
REALM_CM="${PROJECT_DIR}/manifests/keycloak/realm-configmap.yaml"
sed \
  -e "s|PLACEHOLDER_REPLACED_BY_DEPLOY_SCRIPT|${KC_BROKER_SECRET}|" \
  -e "s|apps.ocp.sandbox315.opentlc.com|${APPS_DOMAIN}|g" \
  "$REALM_CM" | oc apply -f -

step "Deploying Keycloak"
for manifest in deployment service route; do
  sed "s|apps.ocp.sandbox315.opentlc.com|${APPS_DOMAIN}|g" \
    "${PROJECT_DIR}/manifests/keycloak/${manifest}.yaml" | oc apply -f -
done

step "Waiting for Keycloak pod to be ready"
oc -n "$KC_NAMESPACE" rollout status deployment/keycloak --timeout=300s

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

step "Saving broker secret for reference"
SECRET_FILE="${PROJECT_DIR}/secrets/.keycloak-broker-secret"
echo "$KC_BROKER_SECRET" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
info "Broker secret saved to $SECRET_FILE"

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

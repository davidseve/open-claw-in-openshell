#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
check_openshell_cli
detect_environment
render_all_templates
KC_ISSUER="https://keycloak-openshell-keycloak.${APPS_DOMAIN}/realms/openshell"
# Namespace-derived, not hardcoded to "openshell": the gRPC Route
# (charts/openshell/templates/route.yaml) uses .Release.Namespace, so its
# default OpenShift hostname ("<route-name>-<namespace>.<apps-domain>")
# tracks whatever $NAMESPACE this deploy actually used — required for a
# second, differently-namespaced deploy to coexist with another project on
# the same cluster.
GW_URL="https://openshell-gw-${NAMESPACE}.${APPS_DOMAIN}"

step "Verifying Keycloak OIDC discovery is reachable"
DISCOVERY=$(curl -sk "${KC_ISSUER}/.well-known/openid-configuration" 2>/dev/null || true)
if ! echo "$DISCOVERY" | grep -q "jwks_uri"; then
  error "Keycloak OIDC discovery not available at ${KC_ISSUER}"
  error "Run ./scripts/deploy-keycloak.sh first"
  exit 1
fi
info "OIDC discovery OK: ${KC_ISSUER}"

step "Extracting OCP ingress CA for JWKS validation"
INGRESS_CA=$(oc get configmap -n openshift-config-managed default-ingress-cert \
  -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)
if [[ -n "$INGRESS_CA" ]]; then
  oc -n "$NAMESPACE" create configmap openshell-oidc-ca \
    --from-literal=ca.crt="$INGRESS_CA" \
    --dry-run=client -o yaml | oc apply -f -
  info "Ingress CA ConfigMap created/updated in $NAMESPACE"
else
  warn "Could not extract ingress CA -- JWKS validation may fail if issuer uses non-public cert"
fi

step "Running Helm upgrade with OIDC configuration"
helm dependency build "${PROJECT_DIR}/charts/openshell"
helm upgrade "$OPENSHELL_RELEASE_NAME" "${PROJECT_DIR}/charts/openshell" \
  --namespace "$NAMESPACE" \
  -f "${RENDERED_DIR}/values-ocp.yaml" \
  --set global.appsDomain="${APPS_DOMAIN}" \
  --set-string "openshell.pkiInitJob.serverDnsNames[0]=openshell-gw-${NAMESPACE}.${APPS_DOMAIN}" \
  --set-string "openshell.pkiInitJob.serverDnsNames[1]=*.${APPS_DOMAIN}"

step "Waiting for gateway rollout"
oc -n "$NAMESPACE" rollout status "statefulset/${OPENSHELL_RELEASE_NAME}" --timeout=180s

step "Re-registering gateway with OIDC"
enable_openshell_oidc_insecure
openshell gateway remove "$GATEWAY_NAME" 2>/dev/null || true

GW_CONFIG_DIR="${HOME}/.config/openshell/gateways/${GATEWAY_NAME}"
mkdir -p "$GW_CONFIG_DIR"

if [[ -t 0 ]] && [[ "${OPENSHELL_HEADLESS:-}" != "1" ]]; then
  openshell gateway add "$GW_URL" \
    --name "$GATEWAY_NAME" \
    --oidc-issuer "$KC_ISSUER" \
    --oidc-client-id "openshell-cli"
  openshell gateway select "$GATEWAY_NAME"
  info "Gateway registered with OIDC (browser login)"
else
  info "Headless mode: registering gateway and obtaining token via password grant"

  cat > "${GW_CONFIG_DIR}/metadata.json" << EOF
{
  "name": "${GATEWAY_NAME}",
  "gateway_endpoint": "${GW_URL}",
  "is_remote": false,
  "gateway_port": 0,
  "auth_mode": "oidc",
  "oidc": {
    "issuer": "${KC_ISSUER}",
    "client_id": "openshell-cli"
  }
}
EOF

  KC_USER="${KC_USER:-admin}"
  KC_PASS="${KC_PASS:-admin}"
  TOKEN_RESPONSE=$(curl -sk -X POST "${KC_ISSUER}/protocol/openid-connect/token" \
    -d "client_id=openshell-cli" \
    -d "username=${KC_USER}" \
    -d "password=${KC_PASS}" \
    -d "grant_type=password")

  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
  REFRESH_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.refresh_token')
  EXPIRES_IN=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_in')

  if [[ "$ACCESS_TOKEN" == "null" || -z "$ACCESS_TOKEN" ]]; then
    error "Failed to obtain token from Keycloak. Check KC_USER/KC_PASS."
    error "Response: $(echo "$TOKEN_RESPONSE" | jq -r '.error_description // .error // "unknown"')"
    exit 1
  fi

  NOW=$(date +%s)
  EXPIRES_AT=$((NOW + EXPIRES_IN))

  cat > "${GW_CONFIG_DIR}/oidc_token.json" << EOF
{
  "access_token": "${ACCESS_TOKEN}",
  "refresh_token": "${REFRESH_TOKEN}",
  "expires_at": ${EXPIRES_AT},
  "issuer": "${KC_ISSUER}",
  "client_id": "openshell-cli"
}
EOF
  chmod 600 "${GW_CONFIG_DIR}/oidc_token.json"
  openshell gateway select "$GATEWAY_NAME"
  info "OIDC token obtained via password grant (expires in ${EXPIRES_IN}s)"
fi

step "Verifying authenticated connection"
# After helm upgrade + rollout, the OCP router needs time to re-establish
# TLS passthrough to the new pod. Retry a few times before failing.
retries=0
while ! openshell status &>/dev/null; do
  retries=$((retries + 1))
  if [[ $retries -ge 10 ]]; then
    fail "Gateway connection failed after 10 retries"
    break
  fi
  sleep 5
done
if [[ $retries -lt 10 ]]; then
  pass "Gateway connected (OIDC authenticated)"
fi

openshell sandbox list &>/dev/null \
  && pass "Sandbox list accessible with OIDC token" \
  || fail "Sandbox list failed (auth rejected)"

step "OIDC configuration complete"
echo ""
info "Gateway: $GW_URL"
info "OIDC Issuer: $KC_ISSUER"
info "Auth: Bearer JWT (no client cert needed)"
echo ""
if [[ -t 0 ]] && [[ "${OPENSHELL_HEADLESS:-}" != "1" ]]; then
  info "To re-login: openshell gateway login ${GATEWAY_NAME}"
else
  info "Headless mode: token auto-refreshes via refresh_token"
  info "To force re-auth: KC_USER=admin KC_PASS=admin ./scripts/configure-oidc.sh"
fi

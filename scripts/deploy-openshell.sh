#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
check_openshell_cli
load_secrets
detect_environment
render_all_templates

VALUES_FILE="${RENDERED_DIR}/values-ocp.yaml"
if [[ "${WITH_OIDC:-true}" == "false" ]]; then
  info "OIDC disabled — stripping oidc config and enabling unauthenticated access"
  VALUES_FILE="${RENDERED_DIR}/values-ocp-no-oidc.yaml"
  sed '/^  oidc:/,/^[^ ]/{ /^  oidc:/d; /^    /d; }' "${RENDERED_DIR}/values-ocp.yaml" \
    | sed 's/allowUnauthenticatedUsers: false/allowUnauthenticatedUsers: true/' \
    > "$VALUES_FILE"
fi

step "Installing OpenShell Helm chart v${OPENSHELL_CHART_VERSION}"
helm upgrade --install openshell \
  oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "$OPENSHELL_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$VALUES_FILE"

step "Waiting for gateway rollout"
oc -n "$NAMESPACE" rollout status statefulset/openshell --timeout=180s

step "Waiting for PKI secrets (created by init job)"
for secret in openshell-server-tls openshell-client-tls openshell-jwt-keys; do
  retries=0
  while ! oc -n "$NAMESPACE" get secret "$secret" &>/dev/null; do
    if [[ $retries -ge 60 ]]; then
      error "Secret $secret not created within 120s"
      exit 1
    fi
    sleep 2
    retries=$((retries + 1))
  done
  info "Secret $secret exists"
done

step "Applying OpenShift Routes (passthrough TLS)"
oc apply -f "${PROJECT_DIR}/manifests/openshell-route.yaml"
oc apply -f "${RENDERED_DIR}/openclaw-service-route.yaml"

step "Detecting gateway Route hostname"
GW_ROUTE=""
retries=0
while [[ -z "$GW_ROUTE" && $retries -lt 30 ]]; do
  GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -z "$GW_ROUTE" ]]; then
    sleep 2
    retries=$((retries + 1))
  fi
done
if [[ -z "$GW_ROUTE" ]]; then
  error "Could not detect Route hostname"
  exit 1
fi
info "Gateway Route: https://${GW_ROUTE}"

step "Extracting mTLS client certificates"
MTLS_DIR="$HOME/.config/openshell/gateways/ocp/mtls"
mkdir -p "$MTLS_DIR"
oc -n "$NAMESPACE" get secret openshell-client-tls \
  -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$MTLS_DIR/ca.crt"
oc -n "$NAMESPACE" get secret openshell-client-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$MTLS_DIR/tls.crt"
oc -n "$NAMESPACE" get secret openshell-client-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "$MTLS_DIR/tls.key"
info "Certificates saved to $MTLS_DIR"

step "Registering gateway with CLI (mTLS)"
openshell gateway remove ocp 2>/dev/null || true
openshell gateway add "https://${GW_ROUTE}" --local --name ocp
openshell status

step "Creating MaaS provider"
if openshell provider list 2>/dev/null | grep -q "$PROVIDER_NAME"; then
  info "Provider '$PROVIDER_NAME' already exists"
else
  openshell provider create \
    --name "$PROVIDER_NAME" \
    --type generic \
    --credential "LITELLM_API_KEY=${MAAS_API_KEY}"
  info "Provider '$PROVIDER_NAME' created"
fi

step "OpenShell deployment complete"
info "Gateway: https://${GW_ROUTE} (mTLS)"
info "Provider: $PROVIDER_NAME"

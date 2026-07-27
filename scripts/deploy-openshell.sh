#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
check_openshell_cli
load_secrets
detect_environment
render_all_templates

# Two explicit, declarative values files (both rendered by
# render_all_templates from charts/openshell/*.yaml.tpl) instead of
# generating the no-oidc variant by sed-stripping the oidc: block out of the
# other one at deploy time.
VALUES_FILE="${RENDERED_DIR}/values-ocp.yaml"
if [[ "${WITH_OIDC:-true}" == "false" ]]; then
  info "OIDC disabled — using values-ocp-no-oidc.yaml (unauthenticated access)"
  VALUES_FILE="${RENDERED_DIR}/values-ocp-no-oidc.yaml"
fi

step "Installing OpenShell Helm chart v${OPENSHELL_CHART_VERSION}"
helm upgrade --install openshell \
  oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "$OPENSHELL_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$VALUES_FILE"

step "Waiting for gateway rollout (up to 600s for initial image pull)"
oc -n "$NAMESPACE" rollout status statefulset/openshell --timeout=600s

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

step "Registering gateway with CLI (mTLS)"
# Avoid unnecessary churn: only touch mTLS certs and (re-)run `gateway
# remove`+`add` if the gateway isn't already registered and connectable
# (e.g. a repeat `deploy` run against an unchanged Route). The status check
# MUST happen before touching any local cert state: `openshell gateway add`
# builds an internal client.p12 bundle from the raw cert files at
# registration time, so unconditionally overwriting those files first (even
# with byte-identical content) invalidates that cached bundle and forces
# every single run down the slow remove+add+retry path below -- defeating
# the point of skipping unneeded work. Observed live on CRC (docs/
# constraints.md #19): checking an already-registered, undisturbed gateway
# succeeds almost instantly and consistently, while immediately following a
# *fresh* remove+add with a status check is highly unreliable -- the
# gateway pod's server logs "TLS handshake failed: peer sent no
# certificates" for anywhere from seconds to 10+ minutes afterwards (most
# likely host-side memory pressure/scheduling delays on the box running the
# CRC VM, not anything wrong with the certs/route/pod itself).
if ! openshell status &>/dev/null; then
  step "Extracting mTLS client certificates"
  MTLS_DIR="$HOME/.config/openshell/gateways/ocp/mtls"
  # Wipe any stale bundle first: a leftover client.p12 built against a
  # previous cluster's CA (e.g. after `crc-lifecycle.sh full --fresh`, which
  # only recreates the VM and doesn't touch this host-local CLI state) will
  # not match the newly issued server CA, causing an mTLS handshake failure
  # ("fatal alert: CertificateRequired") on `openshell status`.
  rm -rf "$MTLS_DIR"
  mkdir -p "$MTLS_DIR"
  oc -n "$NAMESPACE" get secret openshell-client-tls \
    -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$MTLS_DIR/ca.crt"
  oc -n "$NAMESPACE" get secret openshell-client-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "$MTLS_DIR/tls.crt"
  oc -n "$NAMESPACE" get secret openshell-client-tls \
    -o jsonpath='{.data.tls\.key}' | base64 -d > "$MTLS_DIR/tls.key"
  info "Certificates saved to $MTLS_DIR"

  openshell gateway remove ocp 2>/dev/null || true
  openshell gateway add "https://${GW_ROUTE}" --local --name ocp
fi

retries=0
max_retries=40
until openshell status; do
  retries=$((retries + 1))
  if [[ $retries -ge $max_retries ]]; then
    error "openshell status failed after ${retries} attempts"
    exit 1
  fi
  info "Gateway connection not ready yet, retrying ($retries/$max_retries)..."
  sleep 20
done

step "Creating MaaS provider (best-effort)"
# Provider creation may fail here if OIDC auth is required but not yet
# configured. In that case crc-lifecycle.sh will create it after
# configure-oidc.sh obtains the OIDC token (Phase 5b).
if create_provider 2>/dev/null; then
  info "Provider ready"
else
  warn "Provider creation deferred (OIDC not configured yet)"
fi

step "OpenShell deployment complete"
info "Gateway: https://${GW_ROUTE} (mTLS)"
info "Provider: $PROVIDER_NAME"

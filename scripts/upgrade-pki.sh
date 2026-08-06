#!/usr/bin/env bash
# Regenerate PKI certificates with updated SANs from values-ocp.yaml.
#
# This is needed when pkiInitJob.serverDnsNames changes (e.g., adding a
# wildcard SAN for external service routing). The pkiInitJob only runs when
# the openshell-server-tls secret is missing, so we delete it first.
#
# WARNING: This will briefly disrupt gateway connectivity while the new
# cert is provisioned and the gateway pod restarts.
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment
render_all_templates

step "Cleaning up any previous certgen job"
oc -n "$NAMESPACE" delete job openshell-certgen 2>/dev/null && info "Deleted stale certgen job" || true

step "Deleting existing PKI secrets to trigger regeneration"
for secret in openshell-server-tls openshell-client-tls "${OPENSHELL_RELEASE_NAME}-jwt-keys"; do
  if oc -n "$NAMESPACE" get secret "$secret" &>/dev/null; then
    oc -n "$NAMESPACE" delete secret "$secret"
    info "Deleted $secret"
  else
    info "$secret does not exist (skipped)"
  fi
done

step "Running Helm upgrade to trigger pkiInitJob"
helm dependency build "${PROJECT_DIR}/charts/openshell"
helm upgrade "$OPENSHELL_RELEASE_NAME" "${PROJECT_DIR}/charts/openshell" \
  --namespace "$NAMESPACE" \
  -f "${RENDERED_DIR}/values-ocp.yaml" \
  --set global.appsDomain="${APPS_DOMAIN}" \
  --set-string "openshell.pkiInitJob.serverDnsNames[0]=openshell-gw-${NAMESPACE}.${APPS_DOMAIN}" \
  --set-string "openshell.pkiInitJob.serverDnsNames[1]=*.${APPS_DOMAIN}"

step "Waiting for PKI secrets to be recreated"
for secret in openshell-server-tls openshell-client-tls "${OPENSHELL_RELEASE_NAME}-jwt-keys"; do
  retries=0
  while ! oc -n "$NAMESPACE" get secret "$secret" &>/dev/null; do
    if [[ $retries -ge 60 ]]; then
      error "Secret $secret not recreated within 120s"
      exit 1
    fi
    sleep 2
    retries=$((retries + 1))
  done
  info "Secret $secret recreated"
done

step "Waiting for gateway pod restart"
oc -n "$NAMESPACE" rollout status "statefulset/${OPENSHELL_RELEASE_NAME}" --timeout=180s

step "Re-extracting mTLS client certificates"
MTLS_DIR="$HOME/.config/openshell/gateways/${GATEWAY_NAME}/mtls"
mkdir -p "$MTLS_DIR"
oc -n "$NAMESPACE" get secret openshell-client-tls \
  -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$MTLS_DIR/ca.crt"
oc -n "$NAMESPACE" get secret openshell-client-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$MTLS_DIR/tls.crt"
oc -n "$NAMESPACE" get secret openshell-client-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "$MTLS_DIR/tls.key"
info "Certificates saved to $MTLS_DIR"

step "Verifying CLI connectivity with new cert"
openshell status \
  && info "Gateway connected (mTLS with new cert)" \
  || error "Gateway connection failed — may need to re-register gateway"

step "Verifying wildcard SAN in new cert"
CERT_SANS=$(openssl x509 -in "$MTLS_DIR/ca.crt" -noout -text 2>/dev/null \
  | grep -A1 "Subject Alternative" || true)
if echo "$CERT_SANS" | grep -q "\*\."; then
  info "Wildcard SAN found in cert"
else
  GATEWAY_CERT=$(oc -n "$NAMESPACE" get secret openshell-server-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)
  SERVER_SANS=$(echo "$GATEWAY_CERT" | openssl x509 -noout -text 2>/dev/null \
    | grep -A1 "Subject Alternative" || true)
  if echo "$SERVER_SANS" | grep -q "\*\."; then
    info "Wildcard SAN present in server cert"
  else
    warn "Wildcard SAN not detected — service URL routing may not work"
  fi
fi

step "PKI upgrade complete"
info "New SANs are active."
echo ""
info "IMPORTANT: The sandbox pod must be restarted and OpenClaw relaunched:"
info "  oc -n $NAMESPACE delete pod $SANDBOX_NAME"
info "  # Wait for pod Ready, then run ./scripts/launch-openclaw.sh"
info ""
info "Or run ./scripts/verify.sh to confirm service routing."

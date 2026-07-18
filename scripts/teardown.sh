#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

step "Tearing down OpenClaw + OpenShell deployment"

step "Killing active port forwards"
pkill -f "openshell forward" 2>/dev/null || true

step "Removing exposed services"
if command -v openshell &>/dev/null; then
  openshell service remove "$SANDBOX_NAME" openclaw-ui 2>/dev/null || true
  openshell service remove "$SANDBOX_NAME" web 2>/dev/null || true
fi

step "Deleting sandbox: $SANDBOX_NAME"
if command -v openshell &>/dev/null; then
  openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null && info "Sandbox deleted" || info "Sandbox not found"
fi

step "Deleting provider: $PROVIDER_NAME"
if command -v openshell &>/dev/null; then
  openshell provider delete "$PROVIDER_NAME" 2>/dev/null && info "Provider deleted" || info "Provider not found"
fi

step "Uninstalling OpenShell Helm release"
helm uninstall openshell -n "$NAMESPACE" 2>/dev/null && info "Helm release removed" || info "Helm release not found"

step "Removing OpenShift Routes"
oc delete -f "${PROJECT_DIR}/manifests/openshell-route.yaml" 2>/dev/null || true
oc -n "$NAMESPACE" delete route openclaw-ui 2>/dev/null || true

step "Removing PKI and JWT secrets"
oc -n "$NAMESPACE" delete secret openshell-server-tls openshell-client-tls openshell-jwt-keys 2>/dev/null || true

step "Removing SCC binding"
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "$NAMESPACE" 2>/dev/null || true

step "Deleting namespace: $NAMESPACE"
oc delete ns "$NAMESPACE" --wait=false 2>/dev/null && info "Namespace deletion initiated" || info "Namespace not found"

step "Removing local gateway registration and mTLS certs"
if command -v openshell &>/dev/null; then
  openshell gateway remove ocp 2>/dev/null || true
fi
rm -rf "$HOME/.config/openshell/gateways/ocp" 2>/dev/null || true

step "Cleaning up rendered templates"
rm -rf "${RENDERED_DIR}" 2>/dev/null || true
info "Rendered templates removed"

echo ""
info "Teardown complete."
info "Operator namespace (openshift-sandboxed-containers-operator) was NOT removed."
info "Agent Sandbox CRDs were NOT removed (shared cluster resource)."

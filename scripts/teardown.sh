#!/usr/bin/env bash
# Tear down what this project deployed. Mirrors cluster-lifecycle.sh's deploy
# scope: the OpenShell/OpenClaw stack is always torn down; Keycloak,
# observability (Tempo/OTel), and RHOAI+MLflow are opt-in via flags because
# they can be shared/slow-to-recreate cluster resources — same flag names
# as `cluster-lifecycle.sh deploy` (--with-oidc, --with-obs), plus
# --with-rhoai-mlflow and --all as a shorthand for every flag.
#
# Usage:
#   ./scripts/teardown.sh                              # OpenShell/OpenClaw only (default, unchanged from before)
#   ./scripts/teardown.sh --with-oidc                  # + Keycloak
#   ./scripts/teardown.sh --with-obs                   # + Tempo/OTel Collector
#   ./scripts/teardown.sh --with-rhoai-mlflow          # + RHOAI operator + MLflow (charts/rhoai/Makefile undeploy-all)
#   ./scripts/teardown.sh --all                        # everything above
set -euo pipefail
source "$(dirname "$0")/common.sh"

WITH_OIDC=false
WITH_OBS=false
WITH_RHOAI_MLFLOW=false

for arg in "$@"; do
  case "$arg" in
    --with-oidc)         WITH_OIDC=true ;;
    --with-obs)          WITH_OBS=true ;;
    --with-rhoai-mlflow) WITH_RHOAI_MLFLOW=true ;;
    --all)               WITH_OIDC=true; WITH_OBS=true; WITH_RHOAI_MLFLOW=true ;;
    *) error "Unknown flag: $arg"; exit 1 ;;
  esac
done

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

step "Uninstalling OpenShell + oauth-proxy Helm releases"
# The gRPC Route and the SCC RoleBinding are now rendered as part of the
# "openshell" release itself (charts/openshell/templates/route.yaml,
# scc-rolebinding.yaml) — `helm uninstall` removes both, no separate `oc
# delete -f manifests/openshell-route.yaml` / `oc adm policy remove-scc-...`
# needed anymore.
helm uninstall "$OPENSHELL_RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null && info "openshell Helm release removed" || info "openshell Helm release not found"
helm uninstall oauth2-proxy -n "$NAMESPACE" 2>/dev/null && info "oauth2-proxy Helm release removed" || info "oauth2-proxy Helm release not found"

step "Removing legacy openclaw-ui Route (safety net)"
# openclaw-ui (unauthenticated static-token Route) was retired in ADR-0016;
# this delete is only a safety net for clusters still running the old manifest.
oc -n "$NAMESPACE" delete route openclaw-ui 2>/dev/null || true

step "Removing PKI and JWT secrets"
oc -n "$NAMESPACE" delete secret openshell-server-tls openshell-client-tls "${OPENSHELL_RELEASE_NAME}-jwt-keys" 2>/dev/null || true

step "Deleting namespace: $NAMESPACE"
oc delete ns "$NAMESPACE" --wait=false 2>/dev/null && info "Namespace deletion initiated" || info "Namespace not found"

step "Removing local gateway registration and mTLS certs"
if command -v openshell &>/dev/null; then
  openshell gateway remove "$GATEWAY_NAME" 2>/dev/null || true
fi
rm -rf "$HOME/.config/openshell/gateways/${GATEWAY_NAME}" 2>/dev/null || true

step "Cleaning up rendered templates"
rm -rf "${RENDERED_DIR}" 2>/dev/null || true
info "Rendered templates removed"

if [[ "$WITH_OIDC" == "true" ]]; then
  step "Tearing down Keycloak (--with-oidc)"
  helm uninstall keycloak -n openshell-keycloak 2>/dev/null && info "keycloak Helm release removed" || info "keycloak Helm release not found"
  oc delete oauthclient keycloak-broker 2>/dev/null || true
  oc delete ns openshell-keycloak --wait=false 2>/dev/null && info "openshell-keycloak namespace deletion initiated" || info "openshell-keycloak namespace not found"
fi

if [[ "$WITH_OBS" == "true" ]]; then
  step "Tearing down infrastructure observability (--with-obs)"
  helm uninstall observability -n observability 2>/dev/null && info "observability Helm release removed" || info "observability Helm release not found"
  oc delete ns observability --wait=false 2>/dev/null && info "observability namespace deletion initiated" || info "observability namespace not found"
fi

if [[ "$WITH_RHOAI_MLFLOW" == "true" ]]; then
  step "Tearing down RHOAI + MLflow (--with-rhoai-mlflow)"
  warn "This removes the RHOAI operator cluster-wide — only do this if nothing else on the cluster depends on it"
  make -C "${PROJECT_DIR}/charts/rhoai" undeploy-all
fi

echo ""
info "Teardown complete."
if [[ "$WITH_OIDC" != "true" ]]; then
  info "Keycloak (openshell-keycloak namespace) was NOT removed — rerun with --with-oidc"
fi
if [[ "$WITH_OBS" != "true" ]]; then
  info "Observability (Tempo/OTel, observability namespace) was NOT removed — rerun with --with-obs"
fi
if [[ "$WITH_RHOAI_MLFLOW" != "true" ]]; then
  info "RHOAI + MLflow was NOT removed — rerun with --with-rhoai-mlflow (shared/slow cluster resource, opt-in on purpose)"
fi
info "Operator namespace (openshift-sandboxed-containers-operator) was NOT removed."
info "Agent Sandbox CRDs were NOT removed (shared cluster resource)."

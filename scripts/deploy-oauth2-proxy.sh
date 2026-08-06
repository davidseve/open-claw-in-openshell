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
#   - OpenShell deployed (scripts/cluster-lifecycle.sh / deploy-openshell.sh)
#   - OpenClaw sandbox running (scripts/launch-openclaw.sh)
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment
render_all_templates # needed for ${RENDERED_DIR}/openclaw.json in Step 3 below

# Public hostname must equal OpenShell's {sandbox}--{service} service-routing
# pattern -- see charts/oauth2-proxy/templates/route.yaml and deployment.yaml
# for why (WebSocket Host-header bug in this oauth-proxy fork, ADR-0016).
# Derived from $SANDBOX_NAME (not hardcoded "openclaw-gw") so a second,
# differently-named deploy of this project's OpenClaw stack can coexist with
# another project's on the same cluster without an OpenShift Route hostname
# collision -- see docs/adrs/ADR-0020-shared-cluster-coexistence.md.
OAUTH_PROXY_ROUTE_HOST="${SANDBOX_NAME}--openclaw-ui.${APPS_DOMAIN}"

# ── Step 1: Session secret (Kubernetes Secret from host env var) ──────────────
# Created out-of-band (not a Helm-templated resource) so it survives
# `helm uninstall oauth2-proxy` -- it's meant to be a long-lived, idempotent
# secret (secrets/secrets.env), not release-scoped chart state.

step "Ensuring oauth-proxy session secret exists"
ensure_secret_var OAUTH_PROXY_SESSION_SECRET -base64 32

if oc -n "$NAMESPACE" get secret oauth-proxy-session-secret &>/dev/null; then
  info "Kubernetes Secret oauth-proxy-session-secret already exists, leaving it in place"
else
  oc -n "$NAMESPACE" create secret generic oauth-proxy-session-secret \
    --from-literal=session_secret="$(echo -n "$OAUTH_PROXY_SESSION_SECRET" | tr -d '\n' | head -c 32)"
  info "Kubernetes Secret oauth-proxy-session-secret created"
fi

# ── Step 2: Deploy (Helm) ──────────────────────────────────────────────────────
# The `openshell` Service's ClusterIP (needed for the hostAlias workaround
# described in charts/oauth2-proxy/templates/deployment.yaml) is resolved
# declaratively inside the chart via Helm's `lookup` function -- no `sed -i`
# on a rendered manifest needed anymore.

step "Deploying oauth-proxy (OpenShift-native OAuth, Helm)"
helm upgrade --install oauth2-proxy "${PROJECT_DIR}/charts/oauth2-proxy" \
  --namespace "$NAMESPACE" --create-namespace \
  --set appsDomain="${APPS_DOMAIN}" \
  --set namespace="${NAMESPACE}" \
  --set sandboxName="${SANDBOX_NAME}" \
  --set openshellServiceName="${OPENSHELL_RELEASE_NAME}" \
  --wait --timeout 120s
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
  warn "Sandbox pod not found. Re-run this script (or launch-openclaw.sh) once the sandbox exists."
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

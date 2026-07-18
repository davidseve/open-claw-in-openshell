#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_openshell_cli
detect_environment
render_all_templates

step "Creating OpenClaw sandbox (with policy and config upload)"
if openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
  info "Sandbox '$SANDBOX_NAME' already exists"
else
  openshell sandbox create \
    --from openclaw \
    --provider "$PROVIDER_NAME" \
    --name "$SANDBOX_NAME" \
    --policy "${PROJECT_DIR}/policies/openclaw-sandbox.yaml" \
    --upload "${RENDERED_DIR}/openclaw.json:/sandbox/.openclaw/config.json" \
    --no-tty &
  CREATE_PID=$!

  info "Waiting for sandbox to be ready..."
  retries=0
  while [[ $retries -lt 120 ]]; do
    if openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}.*Ready"; then
      info "Sandbox is Ready"
      break
    fi
    sleep 5
    retries=$((retries + 1))
  done
  kill "$CREATE_PID" 2>/dev/null || true
  wait "$CREATE_PID" 2>/dev/null || true

  if [[ $retries -ge 120 ]]; then
    error "Sandbox did not become ready within 10 minutes"
    exit 1
  fi
fi

step "Copying config file into sandbox"
oc -n "$NAMESPACE" cp "${RENDERED_DIR}/openclaw.json" \
  "${SANDBOX_NAME}:/sandbox/.openclaw/config.json" -c agent 2>/dev/null || true
CONFIG_VERIFY=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- test -f /sandbox/.openclaw/config.json && echo "EXISTS" || echo "MISSING")
if echo "$CONFIG_VERIFY" | grep -q "EXISTS"; then
  info "Config at /sandbox/.openclaw/config.json (read-only via Landlock)"
else
  error "Config file not placed — deployment will fail"
  exit 1
fi

step "Creating writable workspace directory"
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- mkdir -p /sandbox/workspace/.openclaw
SANDBOX_UID=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- id -u sandbox 2>/dev/null || echo "1000")
SANDBOX_GID=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- id -g sandbox 2>/dev/null || echo "1000")
oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- chown -R "${SANDBOX_UID}:${SANDBOX_GID}" /sandbox/workspace
info "Workspace at /sandbox/workspace/ (read-write, owned by sandbox ${SANDBOX_UID}:${SANDBOX_GID})"

step "Starting OpenClaw gateway inside sandbox"
printf 'pkill -f openclaw 2>/dev/null; sleep 1 && OPENCLAW_CONFIG_PATH=/sandbox/.openclaw/config.json OPENCLAW_STATE_DIR=/sandbox/workspace/.openclaw OPENCLAW_WORKSPACE_DIR=/sandbox/workspace nohup openclaw gateway run > /tmp/openclaw.log 2>&1 & sleep 3 && tail -5 /tmp/openclaw.log && exit\n' \
  | timeout 20 openshell sandbox connect "$SANDBOX_NAME" 2>&1

LISTENING=$(printf 'grep -cE "listening|started|ready" /tmp/openclaw.log 2>/dev/null && exit\n' \
  | timeout 10 openshell sandbox connect "$SANDBOX_NAME" 2>&1 || true)

if echo "$LISTENING" | grep -qE "[1-9]"; then
  info "OpenClaw gateway is running"
else
  warn "OpenClaw gateway may not have started. Check: openshell sandbox connect $SANDBOX_NAME"
fi

step "Exposing Control UI service"
openshell service expose "$SANDBOX_NAME" 18789 openclaw-ui 2>/dev/null \
  && info "Service exposed" \
  || info "Service may already be exposed"

step "Applying OpenClaw service Route"
oc apply -f "${RENDERED_DIR}/openclaw-service-route.yaml"
info "Route applied"

step "OpenClaw launch complete"
echo ""
info "Control UI (via oauth2-proxy): https://openclaw-ui.${APPS_DOMAIN}/"
info "  Login: Keycloak OIDC (admin/admin in dev)"
echo ""
info "Security hardening active:"
info "  - gateway.auth.mode=trusted-proxy (OIDC via oauth2-proxy)"
info "  - tools.deny=[gateway, cron, openclaw] (control-plane blocked)"
info "  - tools.fs.workspaceOnly=true (filesystem restricted)"
info "  - Landlock: /sandbox read-only, /sandbox/workspace read-write"

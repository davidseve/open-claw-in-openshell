#!/usr/bin/env bash
#
# CRC lifecycle manager for OpenClaw-in-OpenShell.
#
# CRC is a local mirror of the AWS OCP deployment. The same scripts,
# configs, and verification run on both environments. Only APPS_DOMAIN differs.
#
# Usage:
#   ./scripts/crc-lifecycle.sh setup       # configure + start CRC + oc login
#   ./scripts/crc-lifecycle.sh start       # start existing CRC VM + oc login
#   ./scripts/crc-lifecycle.sh deploy      # deploy full stack (bootstrap + openshell + openclaw)
#   ./scripts/crc-lifecycle.sh verify      # run verification suite
#   ./scripts/crc-lifecycle.sh teardown    # remove stack from CRC
#   ./scripts/crc-lifecycle.sh stop        # stop CRC VM (preserves state)
#   ./scripts/crc-lifecycle.sh delete      # destroy CRC VM entirely
#   ./scripts/crc-lifecycle.sh full        # setup + deploy + verify (one-shot)
#   ./scripts/crc-lifecycle.sh status      # show CRC and cluster status
#
# Optional flags:
#   --with-oidc    Deploy Keycloak OIDC (Phase 7)
#   --with-obs     Deploy observability stack (Phase 8)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

WITH_OIDC=false
WITH_OBS=false
MINIMAL=false
FRESH=false

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-oidc) WITH_OIDC=true; shift ;;
      --with-obs)  WITH_OBS=true; shift ;;
      --minimal)   MINIMAL=true; shift ;;
      --fresh)     FRESH=true; shift ;;
      *) break ;;
    esac
  done
}

require_crc_bin() {
  if [[ ! -x "$CRC_BIN" ]]; then
    error "CRC binary not found at: $CRC_BIN"
    error "Set CRC_BIN to the correct path."
    exit 1
  fi
}

crc_login() {
  step "Logging into CRC cluster"
  eval "$("$CRC_BIN" oc-env)"
  local creds
  creds=$("$CRC_BIN" console --credentials 2>/dev/null)
  local password
  password=$(echo "$creds" | grep kubeadmin | grep -oP '(?<=-p )\S+(?= )' || true)
  local api_url
  api_url=$(echo "$creds" | grep kubeadmin | grep -oP 'https://api[^\s'\'']+' || true)

  if [[ -z "$password" || -z "$api_url" ]]; then
    error "Could not extract kubeadmin credentials from crc console --credentials"
    error "Output was: $creds"
    exit 1
  fi

  oc login "$api_url" -u kubeadmin -p "$password" --insecure-skip-tls-verify=true
  info "Logged in as $(oc whoami) at $(oc whoami --show-server)"
}

cmd_setup() {
  require_crc_bin

  step "Configuring CRC VM resources"
  "$CRC_BIN" config set cpus 12
  "$CRC_BIN" config set memory 24576
  "$CRC_BIN" config set disk-size 80
  "$CRC_BIN" config set host-network-access true
  "$CRC_BIN" config set consent-telemetry yes

  if [[ -f "$HOME/Downloads/pull-secret.txt" ]]; then
    "$CRC_BIN" config set pull-secret-file "$HOME/Downloads/pull-secret.txt"
    info "Pull secret configured from ~/Downloads/pull-secret.txt"
  else
    warn "Pull secret not found at ~/Downloads/pull-secret.txt"
    warn "Download from https://console.redhat.com/openshift/create/local"
  fi

  step "Running CRC setup (preflight checks)"
  "$CRC_BIN" setup

  step "Starting CRC VM"
  "$CRC_BIN" start

  crc_login

  step "CRC setup complete"
  "$CRC_BIN" status
  info "OpenShift version: $("$CRC_BIN" version | grep OpenShift | awk '{print $NF}')"
}

cmd_start() {
  require_crc_bin

  step "Starting CRC VM"
  "$CRC_BIN" start

  crc_login

  "$CRC_BIN" status
}

cmd_deploy() {
  # Deploy order is critical — see docs/constraints.md #10:
  #   1. bootstrap  2. keycloak  3. observability  4. openshell (install)
  #   5. configure-oidc (helm upgrade + token)  6. provider (needs token)
  #   7. oauth2-proxy  8. launch-openclaw
  #
  # configure-oidc MUST run AFTER deploy-openshell (needs existing helm release).
  # Provider creation MUST run AFTER configure-oidc (needs OIDC token).
  # oauth2-proxy MUST run AFTER keycloak + openshell (needs both).

  step "Deploying full stack"
  detect_environment
  render_all_templates
  export WITH_OIDC WITH_OBS

  step "Phase 1: Bootstrap OCP prerequisites"
  "${SCRIPT_DIR}/bootstrap-ocp.sh"

  if [[ "$WITH_OIDC" == "true" ]]; then
    step "Phase 2: Deploying Keycloak OIDC"
    "${SCRIPT_DIR}/deploy-keycloak.sh"
  fi

  if [[ "$WITH_OBS" == "true" ]]; then
    step "Phase 3: Deploying observability stack (Tempo, OTel, MLflow, prompts)"
    "${SCRIPT_DIR}/deploy-observability.sh"
  fi

  # Phase 4: Install OpenShell WITHOUT OIDC. The pod needs the oidc-ca
  # ConfigMap which doesn't exist yet. configure-oidc.sh (Phase 5) will
  # create it and helm upgrade to enable OIDC.
  step "Phase 4: Deploy OpenShell (install without OIDC)"
  WITH_OIDC=false "${SCRIPT_DIR}/deploy-openshell.sh"

  if [[ "$WITH_OIDC" == "true" ]]; then
    step "Phase 5: Configure OIDC (create CA ConfigMap + helm upgrade + obtain token)"
    OPENSHELL_HEADLESS=1 KC_USER="${KC_USER:-admin}" KC_PASS="${KC_PASS:-admin}" \
      "${SCRIPT_DIR}/configure-oidc.sh"

    step "Phase 5b: Create MaaS provider (needs OIDC token)"
    # Gateway may still be stabilizing after helm upgrade; retry up to 30s
    retries=0
    while ! create_provider 2>/dev/null; do
      retries=$((retries + 1))
      if [[ $retries -ge 6 ]]; then
        create_provider  # final attempt — let it fail loudly
        break
      fi
      info "Waiting for gateway to accept requests (attempt $retries/6)..."
      sleep 5
    done

    step "Phase 6: Deploy oauth2-proxy (OIDC UI auth)"
    "${SCRIPT_DIR}/deploy-oauth2-proxy.sh"
  fi

  step "Phase 7: Launch OpenClaw in sandbox"
  "${SCRIPT_DIR}/launch-openclaw.sh"

  step "Deployment complete"
}

cmd_verify() {
  detect_environment
  render_all_templates
  "${SCRIPT_DIR}/verify.sh"
}

cmd_teardown() {
  detect_environment
  render_all_templates
  "${SCRIPT_DIR}/teardown.sh"
}

cmd_stop() {
  require_crc_bin

  step "Stopping CRC VM (state preserved)"
  "$CRC_BIN" stop
  info "CRC stopped. Run './scripts/crc-lifecycle.sh start' to resume."
}

cmd_delete() {
  require_crc_bin

  step "Deleting CRC VM (all data destroyed)"
  "$CRC_BIN" delete --force
  info "CRC VM deleted."
}

cmd_full() {
  # full deploys everything by default; use --minimal to skip OIDC+obs
  if [[ "$MINIMAL" != "true" ]]; then
    WITH_OIDC=true
    WITH_OBS=true
  fi

  if [[ "$FRESH" == "true" ]]; then
    require_crc_bin
    step "Fresh mode: deleting existing CRC VM"
    "$CRC_BIN" delete --force 2>/dev/null || true
    info "Previous VM destroyed"
  fi

  cmd_setup
  cmd_deploy   # includes all phases: keycloak, obs, openshell, oidc, provider, oauth2-proxy, openclaw

  if [[ -x "${SCRIPT_DIR}/smoke-test-e2e.sh" ]]; then
    step "Running smoke test"
    "${SCRIPT_DIR}/smoke-test-e2e.sh" || warn "Smoke test had warnings (non-fatal)"
  fi

  cmd_verify

  echo ""
  step "Full lifecycle complete"
  info "CRC is running with OpenClaw-in-OpenShell deployed and verified."
  info "Control UI: https://openclaw-ui.$(get_apps_domain)/"
  info "MLflow UI:  https://mlflow-observability.$(get_apps_domain)/"
  info "Stop CRC:   ./scripts/crc-lifecycle.sh stop"
  info "Teardown:   ./scripts/crc-lifecycle.sh teardown"
  info "Delete VM:  ./scripts/crc-lifecycle.sh delete"
}

cmd_status() {
  require_crc_bin

  "$CRC_BIN" status

  if "$CRC_BIN" status 2>/dev/null | grep -q "Running"; then
    echo ""
    step "Cluster info"
    eval "$("$CRC_BIN" oc-env)" 2>/dev/null || true
    oc whoami --show-server 2>/dev/null && info "User: $(oc whoami 2>/dev/null)" || warn "Not logged in"
    echo ""
    step "OpenShell pods"
    oc get pods -n "$NAMESPACE" 2>/dev/null || info "Namespace $NAMESPACE not found"
  fi
}

# --- Main ---

COMMAND="${1:-help}"
shift || true
parse_flags "$@"

case "$COMMAND" in
  setup)    cmd_setup ;;
  start)    cmd_start ;;
  deploy)   cmd_deploy ;;
  verify)   cmd_verify ;;
  teardown) cmd_teardown ;;
  stop)     cmd_stop ;;
  delete)   cmd_delete ;;
  full)     cmd_full ;;
  status)   cmd_status ;;
  help|--help|-h)
    echo "Usage: $0 {setup|start|deploy|verify|teardown|stop|delete|full|status} [--with-oidc] [--with-obs]"
    echo ""
    echo "Commands:"
    echo "  setup      Configure and start CRC VM, login to cluster"
    echo "  start      Start existing CRC VM, login to cluster"
    echo "  deploy     Deploy full stack (bootstrap + openshell + openclaw)"
    echo "  verify     Run verification suite"
    echo "  teardown   Remove stack from CRC cluster"
    echo "  stop       Stop CRC VM (preserves state)"
    echo "  delete     Destroy CRC VM entirely"
    echo "  full       setup + deploy + verify (one-shot autonomous)"
    echo "  status     Show CRC and cluster status"
    echo ""
    echo "Flags:"
    echo "  --with-oidc   Also deploy Keycloak OIDC (Phase 7)"
    echo "  --with-obs    Also deploy observability stack (Phase 8)"
    echo "  --minimal     Skip OIDC and observability in 'full' mode"
    echo "  --fresh       Delete existing CRC VM before setup (full reset)"
    ;;
  *)
    error "Unknown command: $COMMAND"
    echo "Run '$0 help' for usage."
    exit 1
    ;;
esac

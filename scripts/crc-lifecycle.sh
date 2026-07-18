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

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-oidc) WITH_OIDC=true; shift ;;
      --with-obs)  WITH_OBS=true; shift ;;
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
  api_url=$(echo "$creds" | grep kubeadmin | grep -oP 'https://api\S+' || true)

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
  step "Deploying full stack on CRC"
  detect_environment
  render_all_templates

  export WITH_OIDC

  step "Phase 1: Bootstrap OCP prerequisites"
  "${SCRIPT_DIR}/bootstrap-ocp.sh"

  step "Phase 2: Deploy OpenShell"
  "${SCRIPT_DIR}/deploy-openshell.sh"

  step "Phase 3: Launch OpenClaw in sandbox"
  "${SCRIPT_DIR}/launch-openclaw.sh"

  if [[ "$WITH_OIDC" == "true" ]]; then
    step "Phase 7: Deploying Keycloak OIDC"
    if [[ -x "${SCRIPT_DIR}/deploy-keycloak.sh" ]]; then
      "${SCRIPT_DIR}/deploy-keycloak.sh"
      "${SCRIPT_DIR}/configure-oidc.sh"
    else
      warn "Keycloak scripts not found, skipping OIDC deployment"
    fi
  fi

  if [[ "$WITH_OBS" == "true" ]]; then
    step "Phase 8: Deploying observability stack"
    if [[ -x "${SCRIPT_DIR}/deploy-observability.sh" ]]; then
      "${SCRIPT_DIR}/deploy-observability.sh"
    else
      warn "Observability script not found, skipping"
    fi
  fi

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
  cmd_setup
  cmd_deploy
  cmd_verify

  echo ""
  step "Full lifecycle complete"
  info "CRC is running with OpenClaw-in-OpenShell deployed and verified."
  info "Control UI: https://openclaw-gw--openclaw-ui.$(get_apps_domain)"
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
    ;;
  *)
    error "Unknown command: $COMMAND"
    echo "Run '$0 help' for usage."
    exit 1
    ;;
esac

#!/usr/bin/env bash
#
# Cluster lifecycle manager for OpenClaw-in-OpenShell — despite the older
# "crc-lifecycle.sh" name this file used to have, `deploy`/`verify`/
# `teardown`/`full`/`status` are NOT CRC-specific: they run identically
# against a local CRC VM or a real AWS/OCP cluster, driven purely by
# whatever `oc`/`helm` are currently logged into (detect_environment in
# common.sh only branches on APPS_DOMAIN to pick CRC vs. AWS values
# overlays — it never shells out to the `crc` binary). Only `setup`/
# `start`/`stop`/`delete` (and `full --fresh`) actually manage a local CRC
# VM via `$CRC_BIN`; skip straight to `deploy`/`verify` against a
# pre-existing real cluster instead.
#
# Usage:
#   ./scripts/cluster-lifecycle.sh setup       # [CRC only] configure + start CRC VM + oc login
#   ./scripts/cluster-lifecycle.sh start       # [CRC only] start existing CRC VM + oc login
#   ./scripts/cluster-lifecycle.sh deploy      # deploy full stack (bootstrap + openshell + openclaw) — CRC or real cluster
#   ./scripts/cluster-lifecycle.sh verify      # run verification suite — CRC or real cluster
#   ./scripts/cluster-lifecycle.sh teardown    # remove stack from the current cluster
#   ./scripts/cluster-lifecycle.sh stop        # [CRC only] stop CRC VM (preserves state)
#   ./scripts/cluster-lifecycle.sh delete      # [CRC only] destroy CRC VM entirely
#   ./scripts/cluster-lifecycle.sh full        # setup + deploy + verify (one-shot; setup step is CRC-only)
#   ./scripts/cluster-lifecycle.sh status      # show CRC (if applicable) and cluster status
#
# Optional flags:
#   --with-oidc    deploy: Deploy Keycloak OIDC. teardown: also remove Keycloak.
#   --with-obs     deploy: Deploy infrastructure observability (Tempo, OTel
#                  Collector — logs/metrics only). RHOAI MLflow (agent traces
#                  + prompt registry) is unconditional, not gated by this
#                  flag — see docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md.
#                  teardown: also remove the observability namespace.
#
# `teardown` also accepts scripts/teardown.sh's own --with-rhoai-mlflow /
# --all flags directly (not wired through cluster-lifecycle.sh's flag parser
# since RHOAI is unconditional on deploy) — call the script directly for
# those: ./scripts/teardown.sh --all

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

  # Sized for RHOAI + MLflow (mandatory on every deploy, ADR-0018) combined
  # with the full OpenShell/OpenClaw stack — 16 vCPU / 40 GiB / 100 GiB is
  # the configuration empirically validated to work on this project's dev
  # laptop (see docs/adrs/ADR-0017-rhoai-mlflow-scope.md's Stage 1/2 results;
  # host free memory drops to ~11 GiB combined, an accepted trade-off per
  # ADR-0018). The pre-RHOAI baseline (12 vCPU / 24 GiB) is no longer enough.
  step "Configuring CRC VM resources"
  "$CRC_BIN" config set cpus 16
  "$CRC_BIN" config set memory 40960
  "$CRC_BIN" config set disk-size 100
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
  #   1. bootstrap  2. keycloak  3. observability (Tempo/OTel)
  #   4. RHOAI + MLflow  4b. guardrails (needs TrustyAI CRD from RHOAI)
  #   5. openshell (install)  6. wire RHOAI MLflow tracing
  #   7. configure-oidc (helm upgrade + token)  8. providers (needs token)
  #   9. oauth2-proxy  10. launch-openclaw
  #
  # RHOAI + MLflow (Phase 4) MUST run BEFORE OpenShell (Phase 5) so the
  # mlflow-integration ClusterRole and RHOAI namespace exist; wiring (Phase 6)
  # MUST run AFTER OpenShell so the openshell-sandbox SA it binds RBAC to
  # already exists. RHOAI-managed MLflow is the sole tracing/prompt-registry
  # backend for this project (docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)
  # — these two phases are unconditional, not gated behind --with-obs.
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
    step "Phase 3: Deploying infrastructure observability (Tempo, OTel Collector)"
    "${SCRIPT_DIR}/deploy-observability.sh"
  fi

  step "Phase 4: Deploy RHOAI + MLflow (sole tracing/prompt-registry backend)"
  "${SCRIPT_DIR}/deploy-rhoai-mlflow.sh"

  step "Phase 4b: Deploy NeMo Guardrails (TrustyAI CR, ADR-0022)"
  "${SCRIPT_DIR}/deploy-guardrails.sh"

  # Phase 5: Install OpenShell WITHOUT OIDC. The pod needs the oidc-ca
  # ConfigMap which doesn't exist yet. configure-oidc.sh (Phase 7) will
  # create it and helm upgrade to enable OIDC.
  step "Phase 5: Deploy OpenShell (install without OIDC)"
  WITH_OIDC=false "${SCRIPT_DIR}/deploy-openshell.sh"

  step "Phase 6: Wire RHOAI MLflow tracing (RBAC, SA token, experiment, CA, prompts)"
  "${SCRIPT_DIR}/wire-rhoai-mlflow-tracing.sh"

  if [[ "$WITH_OIDC" == "true" ]]; then
    step "Phase 7: Configure OIDC (create CA ConfigMap + helm upgrade + obtain token)"
    OPENSHELL_HEADLESS=1 KC_USER="${KC_USER:-admin}" KC_PASS="${KC_PASS:-admin}" \
      "${SCRIPT_DIR}/configure-oidc.sh"

    step "Phase 7b: Enable providers_v2, create dual providers (direct + guardrailed), configure inference route"
    enable_providers_v2 2>/dev/null || true
    # Gateway may still be stabilizing after helm upgrade; retry up to 30s
    retries=0
    while ! create_dual_providers 2>/dev/null; do
      retries=$((retries + 1))
      if [[ $retries -ge 6 ]]; then
        create_dual_providers  # final attempt — let it fail loudly
        break
      fi
      info "Waiting for gateway to accept requests (attempt $retries/6)..."
      sleep 5
    done
    configure_inference_route 2>/dev/null \
      && info "Inference route ready" \
      || warn "Inference route configuration failed — run manually: openshell inference set --provider $PROVIDER_DIRECT --model $INFERENCE_MODEL --no-verify"

    step "Phase 8: Deploy oauth-proxy (OpenShift-native OAuth UI auth, ADR-0016)"
    "${SCRIPT_DIR}/deploy-oauth2-proxy.sh"
  fi

  step "Phase 9: Launch OpenClaw in sandbox"
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
  local teardown_flags=()
  [[ "$WITH_OIDC" == "true" ]] && teardown_flags+=(--with-oidc)
  [[ "$WITH_OBS" == "true" ]] && teardown_flags+=(--with-obs)
  "${SCRIPT_DIR}/teardown.sh" "${teardown_flags[@]}"
}

cmd_stop() {
  require_crc_bin

  step "Stopping CRC VM (state preserved)"
  "$CRC_BIN" stop
  info "CRC stopped. Run './scripts/cluster-lifecycle.sh start' to resume."
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

  # verify.sh (full profile, the default) covers everything a separate
  # smoke-test-e2e.sh used to check (chat -> trace -> prompt tags) via its
  # own Layer 8/8b/9 — no need for a second script here.
  cmd_verify

  echo ""
  step "Full lifecycle complete"
  info "CRC is running with OpenClaw-in-OpenShell deployed and verified."
  info "Control UI: https://${SANDBOX_NAME}--openclaw-ui.$(get_apps_domain)/"
  info "MLflow UI:  https://$(oc get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '<run: oc get route mlflow -n redhat-ods-applications>')/"
  info "Stop CRC:   ./scripts/cluster-lifecycle.sh stop"
  info "Teardown:   ./scripts/cluster-lifecycle.sh teardown"
  info "Delete VM:  ./scripts/cluster-lifecycle.sh delete"
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

_ORIG_ARGS=("$@")
COMMAND="${1:-help}"
shift || true
parse_flags "$@"

# Token-efficient agent wrapper for long-running commands (see long-running-scripts skill).
if [[ -f "${SCRIPT_DIR}/lib/agent-run.sh" && "${CLUSTER_LIFECYCLE_AGENT_RUN:-}" != "1" ]]; then
  case "$COMMAND" in
    deploy|verify|full)
      # shellcheck source=scripts/lib/agent-run.sh
      source "${SCRIPT_DIR}/lib/agent-run.sh"
      agent_run "cluster-lifecycle-${COMMAND}" env CLUSTER_LIFECYCLE_AGENT_RUN=1 "$0" "${_ORIG_ARGS[@]}"
      exit $?
      ;;
  esac
fi

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
    echo "  setup      [CRC only] Configure and start CRC VM, login to cluster"
    echo "  start      [CRC only] Start existing CRC VM, login to cluster"
    echo "  deploy     Deploy full stack (bootstrap + openshell + openclaw) -- CRC or real cluster"
    echo "  verify     Run verification suite -- CRC or real cluster"
    echo "  teardown   Remove stack from the current cluster"
    echo "  stop       [CRC only] Stop CRC VM (preserves state)"
    echo "  delete     [CRC only] Destroy CRC VM entirely"
    echo "  full       setup + deploy + verify (one-shot autonomous; setup step is CRC-only)"
    echo "  status     Show CRC (if applicable) and cluster status"
    echo ""
    echo "Flags:"
    echo "  --with-oidc   Also deploy Keycloak OIDC"
    echo "  --with-obs    Also deploy infrastructure observability (Tempo, OTel Collector)"
    echo "                RHOAI MLflow (agent traces + prompts) always deploys, regardless of this flag"
    echo "  --minimal     Skip OIDC and observability in 'full' mode"
    echo "  --fresh       Delete existing CRC VM before setup (full reset)"
    ;;
  *)
    error "Unknown command: $COMMAND"
    echo "Run '$0 help' for usage."
    exit 1
    ;;
esac

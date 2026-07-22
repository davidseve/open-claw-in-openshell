#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-openshell}"
OPENSHELL_CHART_VERSION="${OPENSHELL_CHART_VERSION:-0.0.83}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw-gw}"
PROVIDER_NAME="${PROVIDER_NAME:-maas-litellm}"

CRC_BIN="${CRC_BIN:-/home/dseveria/Applications/crc-linux-amd64/crc-linux-2.57.0-amd64/crc}"
CRC_MODE="${CRC_MODE:-false}"
APPS_DOMAIN="${APPS_DOMAIN:-}"

RENDERED_DIR="${PROJECT_DIR}/.rendered"
CURL_OPTS="${CURL_OPTS:-}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

step()  { echo "==> $*"; }
info()  { echo "    $*"; }
warn()  { echo "    [WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
error() { echo "    [ERROR] $*" >&2; }
pass()  { echo "    [PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { echo "    [FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

detect_environment() {
  if [[ -n "$APPS_DOMAIN" ]]; then
    info "APPS_DOMAIN already set: $APPS_DOMAIN"
  else
    APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
    if [[ -z "$APPS_DOMAIN" ]]; then
      error "Could not detect apps domain from cluster. Set APPS_DOMAIN manually."
      exit 1
    fi
    info "Detected APPS_DOMAIN: $APPS_DOMAIN"
  fi
  export APPS_DOMAIN

  if [[ "$APPS_DOMAIN" == "apps-crc.testing" ]]; then
    CRC_MODE=true
  fi
  export CRC_MODE

  if [[ "$CRC_MODE" == "true" ]]; then
    info "CRC mode active (single-node local cluster)"
    CURL_OPTS="-k"
  fi
  export CURL_OPTS
}

render_template() {
  local src="$1" dest="$2"
  if [[ -z "$APPS_DOMAIN" ]]; then
    error "APPS_DOMAIN not set. Call detect_environment() first."
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  sed "s/__APPS_DOMAIN__/${APPS_DOMAIN}/g" "$src" > "$dest"
}

render_all_templates() {
  mkdir -p "$RENDERED_DIR"
  render_template \
    "${PROJECT_DIR}/charts/openshell/values-ocp.yaml.tpl" \
    "${RENDERED_DIR}/values-ocp.yaml"
  render_template \
    "${PROJECT_DIR}/config/openclaw.json.tpl" \
    "${RENDERED_DIR}/openclaw.json"
  render_template \
    "${PROJECT_DIR}/manifests/openclaw-service-route.yaml.tpl" \
    "${RENDERED_DIR}/openclaw-service-route.yaml"
  if [[ -f "${PROJECT_DIR}/manifests/oauth2-proxy/configmap.yaml.tpl" ]]; then
    render_template \
      "${PROJECT_DIR}/manifests/oauth2-proxy/configmap.yaml.tpl" \
      "${RENDERED_DIR}/oauth2-proxy/configmap.yaml"
  fi
  render_template \
    "${PROJECT_DIR}/manifests/observability/mlflow.yaml.tpl" \
    "${RENDERED_DIR}/observability/mlflow.yaml"
  info "Templates rendered to ${RENDERED_DIR}/ (APPS_DOMAIN=${APPS_DOMAIN})"
}

check_prereqs() {
  step "Checking prerequisites"
  local missing=0
  for cmd in oc helm; do
    if ! command -v "$cmd" &>/dev/null; then
      error "$cmd not found in PATH"
      missing=1
    fi
  done
  if ! oc whoami &>/dev/null; then
    error "Not logged into OpenShift cluster"
    missing=1
  fi
  if [[ $missing -ne 0 ]]; then
    error "Missing prerequisites. Aborting."
    exit 1
  fi
  info "All prerequisites satisfied"
  info "Cluster: $(oc whoami --show-server)"
  info "User: $(oc whoami)"
}

check_openshell_cli() {
  if ! command -v openshell &>/dev/null; then
    error "openshell CLI not found in PATH"
    error "Install from: https://docs.nvidia.com/openshell/about/installation"
    exit 1
  fi
  info "openshell CLI found: $(command -v openshell)"
}

grant_privileged_scc() {
  local ns="$1"
  step "Granting privileged SCC to openshell-sandbox SA"
  oc adm policy add-scc-to-user privileged -z openshell-sandbox -n "$ns"
  info "SCC binding applied"
}

wait_for_pod_ready() {
  local ns="$1" label="$2" timeout="${3:-120}"
  step "Waiting for pod ($label) to be ready (timeout: ${timeout}s)"
  oc -n "$ns" wait --for=condition=Ready pod -l "$label" --timeout="${timeout}s"
}

load_secrets() {
  local secrets_file="${PROJECT_DIR}/secrets/secrets.env"
  if [[ ! -f "$secrets_file" ]]; then
    error "Secrets file not found: $secrets_file"
    error "Copy secrets/secrets.template.env to secrets/secrets.env and fill in values"
    exit 1
  fi
  set -a
  source "$secrets_file"
  set +a
  info "Secrets loaded from $secrets_file"
}


sandbox_run() {
  printf '%s && exit\n' "$1" \
    | timeout 15 openshell sandbox connect "$SANDBOX_NAME" 2>&1 || true
}

# Refresh OIDC token if expired. Call before any openshell CLI command
# that requires authentication (provider create, sandbox list, etc.).
# Uses headless password grant — no browser needed.
# NOTE: `openshell status` returns 0 even with expired OIDC (uses mTLS),
# so we test `sandbox list` which requires a valid bearer token.
ensure_oidc_token() {
  if openshell sandbox list &>/dev/null; then return 0; fi
  if [[ -x "${SCRIPT_DIR}/configure-oidc.sh" ]]; then
    info "OIDC token expired, refreshing..."
    OPENSHELL_HEADLESS=1 KC_USER="${KC_USER:-admin}" KC_PASS="${KC_PASS:-admin}" \
      "${SCRIPT_DIR}/configure-oidc.sh" >/dev/null 2>&1 || warn "OIDC refresh failed"
  fi
}

# Create the MaaS provider. Idempotent — skips if already exists.
# Requires a valid OIDC token when gateway has auth enabled.
create_provider() {
  if [[ -z "${MAAS_API_KEY:-}" ]]; then load_secrets; fi
  if openshell provider list 2>/dev/null | grep -q "$PROVIDER_NAME"; then
    info "Provider '$PROVIDER_NAME' already exists"
    return 0
  fi
  openshell provider create \
    --name "$PROVIDER_NAME" \
    --type generic \
    --credential "LITELLM_API_KEY=${MAAS_API_KEY}"
  info "Provider '$PROVIDER_NAME' created"
}

get_apps_domain() {
  echo "$APPS_DOMAIN"
}

get_service_url() {
  local sandbox="$1" service="$2"
  echo "https://${sandbox}--${service}.$(get_apps_domain)"
}

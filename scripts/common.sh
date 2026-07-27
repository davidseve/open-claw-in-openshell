#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-openshell}"
OPENSHELL_CHART_VERSION="${OPENSHELL_CHART_VERSION:-0.0.83}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw-gw}"
PROVIDER_NAME="${PROVIDER_NAME:-maas-litellm}"

CRC_BIN="${CRC_BIN:-$(command -v crc || echo crc)}"
CRC_MODE="${CRC_MODE:-false}"
APPS_DOMAIN="${APPS_DOMAIN:-}"

RENDERED_DIR="${PROJECT_DIR}/.rendered"
CURL_OPTS="${CURL_OPTS:-}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Per-layer condition tracking (claw-operator-style status.conditions, adapted
# to this script's existing step()/pass()/fail()/warn() calls instead of
# requiring every call site to be rewritten). CURRENT_LAYER is set by the
# most recent step() call; pass/fail/warn roll their result up into that
# layer's condition without any changes needed in verify.sh's ~200 call sites.
CURRENT_LAYER="unclassified"
declare -A LAYER_STATUS
declare -A LAYER_PASS
declare -A LAYER_FAIL
declare -A LAYER_WARN
declare -a LAYER_ORDER

# condition <pass|fail|warn> <layer> — records one check's outcome against a
# layer's condition. A layer's status flips to "False" on the first fail and
# never flips back to "True" within the same run; warn is informational and
# does not affect status (mirrors the script's exit-code semantics, where
# only FAIL_COUNT gates exit 1).
condition() {
  local kind="$1" layer="$2"
  if [[ -z "${LAYER_STATUS[$layer]+x}" ]]; then
    LAYER_STATUS["$layer"]="True"
    LAYER_PASS["$layer"]=0
    LAYER_FAIL["$layer"]=0
    LAYER_WARN["$layer"]=0
    LAYER_ORDER+=("$layer")
  fi
  case "$kind" in
    fail)
      LAYER_STATUS["$layer"]="False"
      local n_fail=${LAYER_FAIL[$layer]}
      LAYER_FAIL["$layer"]=$((n_fail + 1))
      ;;
    pass)
      local n_pass=${LAYER_PASS[$layer]}
      LAYER_PASS["$layer"]=$((n_pass + 1))
      ;;
    warn)
      local n_warn=${LAYER_WARN[$layer]}
      LAYER_WARN["$layer"]=$((n_warn + 1))
      ;;
  esac
}

# emit_conditions_json <output-file> — writes the accumulated per-layer
# conditions as JSON, in the order layers were first seen. Purely additive:
# does not change or replace the plain-text output above.
emit_conditions_json() {
  local out="$1"
  {
    echo "{"
    echo "  \"generatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"summary\": {\"pass\": ${PASS_COUNT}, \"fail\": ${FAIL_COUNT}, \"warn\": ${WARN_COUNT}},"
    echo "  \"conditions\": ["
    local i=0 n=${#LAYER_ORDER[@]}
    for layer in "${LAYER_ORDER[@]}"; do
      i=$((i + 1))
      local escaped_layer=${layer//\"/\\\"}
      printf '    {"type": "%s", "status": "%s", "pass": %d, "fail": %d, "warn": %d}' \
        "$escaped_layer" "${LAYER_STATUS[$layer]}" "${LAYER_PASS[$layer]}" "${LAYER_FAIL[$layer]}" "${LAYER_WARN[$layer]}"
      [[ $i -lt $n ]] && echo "," || echo ""
    done
    echo "  ]"
    echo "}"
  } > "$out"
  info "Structured conditions written to $out"
}

step()  { echo "==> $*"; CURRENT_LAYER="$*"; }
info()  { echo "    $*"; }
warn()  { echo "    [WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); condition warn "$CURRENT_LAYER"; }
error() { echo "    [ERROR] $*" >&2; }
pass()  { echo "    [PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); condition pass "$CURRENT_LAYER"; }
fail()  { echo "    [FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); condition fail "$CURRENT_LAYER"; }

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
    # CRC's router uses a self-signed wildcard cert (*.apps-crc.testing,
    # issued by ingress-operator) that isn't in the system CA trust store —
    # `crc setup` only trusts the API server's CA, not the router's. Without
    # this, the openshell CLI's own HTTPS client (used for OIDC token
    # refresh against Keycloak once configure-oidc.sh switches auth_mode to
    # "oidc") fails with a generic "error sending request for url", silently
    # falls back to the (already-expired) access token, and every
    # subsequent `openshell` command fails with "invalid token:
    # ExpiredSignature" — surfacing downstream as misleading "sandbox not
    # found" / "unexpected identity" failures in verify.sh/smoke tests, even
    # though the sandbox is still Ready. Found live during a fresh
    # `crc-lifecycle.sh full --fresh` run. Not needed on AWS OCP (real certs).
    export OPENSHELL_GATEWAY_INSECURE=true
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

# render_openclaw_config renders config/openclaw.json.tpl like any other
# template (__APPS_DOMAIN__ substitution), then additionally resolves the
# __MAAS_API_KEY__ placeholder with the real secret. This is the only
# template that needs a credential, so the substitution lives here instead
# of in the generic render_template() to avoid requiring secrets.env for
# scripts that render other templates (oauth2-proxy, mlflow, values-ocp).
#
# The proxy's openshell:resolve:env:KEY credential injection is NOT used for
# this value because Node.js fetch()/undici connections are too ephemeral
# for the proxy to map to a process binary (see constraint #3) — the real
# key must be baked into the config before it reaches the sandbox.
#
# Uses bash's literal string replacement (not sed/awk) so that API key
# characters (/, &, etc.) are never interpreted as pattern/replacement
# metacharacters.
render_openclaw_config() {
  local src="$1" dest="$2"
  render_template "$src" "$dest"

  local secrets_file="${PROJECT_DIR}/secrets/secrets.env"
  local maas_key="${MAAS_API_KEY:-}"
  if [[ -z "$maas_key" && -f "$secrets_file" ]]; then
    set -a
    source "$secrets_file"
    set +a
    maas_key="${MAAS_API_KEY:-}"
  fi

  if [[ -z "$maas_key" ]]; then
    warn "MAAS_API_KEY not found in secrets/secrets.env — apiKey in $(basename "$dest") left as __MAAS_API_KEY__ placeholder (LLM requests will fail until set)"
    return 0
  fi

  local content
  content=$(<"$dest")
  content="${content//__MAAS_API_KEY__/$maas_key}"
  printf '%s' "$content" > "$dest"
}

render_all_templates() {
  mkdir -p "$RENDERED_DIR"
  render_template \
    "${PROJECT_DIR}/charts/openshell/values-ocp.yaml.tpl" \
    "${RENDERED_DIR}/values-ocp.yaml"
  render_template \
    "${PROJECT_DIR}/charts/openshell/values-ocp-no-oidc.yaml.tpl" \
    "${RENDERED_DIR}/values-ocp-no-oidc.yaml"
  render_openclaw_config \
    "${PROJECT_DIR}/config/openclaw.json.tpl" \
    "${RENDERED_DIR}/openclaw.json"
  # oauth2-proxy's manifests are now a Helm chart (charts/oauth2-proxy) —
  # scripts/deploy-oauth2-proxy.sh passes APPS_DOMAIN via `helm --set`
  # instead of rendering a .tpl here.
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

# ensure_secret_var <VAR_NAME> [openssl-rand args...] — idempotent secret
# generation, used by every deploy script that needs a random secret
# (Keycloak broker secret, MLflow DB password, oauth-proxy session secret).
# If VAR_NAME is already set (e.g. exported by the caller) or already present
# in secrets/secrets.env, reuses that value. Otherwise generates one with
# `openssl rand` (default: -hex 32), appends VAR_NAME=value to
# secrets/secrets.env so re-running the deploy script is idempotent, and
# exports it. Requires secrets/secrets.env to already exist — only ever
# appends, never creates the file (AGENTS.md: copy secrets.template.env to
# secrets.env and fill in MAAS_API_KEY first, before any deploy phase runs).
ensure_secret_var() {
  local var_name="$1"; shift
  local rand_args=("$@")
  [[ ${#rand_args[@]} -eq 0 ]] && rand_args=(-hex 32)

  local secrets_file="${PROJECT_DIR}/secrets/secrets.env"
  if [[ ! -f "$secrets_file" ]]; then
    error "Secrets file not found: $secrets_file"
    error "Copy secrets/secrets.template.env to secrets/secrets.env and fill in MAAS_API_KEY first"
    exit 1
  fi

  local current="${!var_name:-}"
  if [[ -z "$current" ]]; then
    set -a; source "$secrets_file"; set +a
    current="${!var_name:-}"
  fi

  if [[ -z "$current" ]]; then
    current=$(openssl rand "${rand_args[@]}")
    echo "${var_name}=${current}" >>"$secrets_file"
    info "Generated ${var_name} and appended to secrets/secrets.env"
  else
    info "Using existing ${var_name} from secrets/secrets.env"
  fi

  printf -v "$var_name" '%s' "$current"
  export "${var_name?}"
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

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-openshell2}"
OPENSHELL_CHART_VERSION="${OPENSHELL_CHART_VERSION:-0.0.83}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw-gw2}"
PROVIDER_NAME="${PROVIDER_NAME:-maas-litellm}"
INFERENCE_MODEL="${INFERENCE_MODEL:-claude-sonnet-4-6}"
MAAS_BASE_URL="${MAAS_BASE_URL:-https://maas-rhdp.apps.maas.redhatworkshops.io/v1}"
# Dual-provider inference routing (ADR-0022: NeMo Guardrails).
# maas-direct goes straight to MaaS; maas-guardrailed routes via NeMo first.
PROVIDER_DIRECT="${PROVIDER_DIRECT:-maas-direct}"
PROVIDER_GUARDRAILED="${PROVIDER_GUARDRAILED:-maas-guardrailed}"
INFERENCE_BACKEND="${INFERENCE_BACKEND:-guardrailed}"
NEMO_GUARDRAILS_SERVICE="${NEMO_GUARDRAILS_SERVICE:-nemo-guardrails}"
NEMO_GUARDRAILS_PORT="${NEMO_GUARDRAILS_PORT:-80}"
NEMO_GUARDRAILS_URL="${NEMO_GUARDRAILS_URL:-http://${NEMO_GUARDRAILS_SERVICE}.${NAMESPACE}.svc.cluster.local:${NEMO_GUARDRAILS_PORT}/v1}"
# CLI-local (per-machine) gateway alias name — deliberately separate from
# NAMESPACE/SANDBOX_NAME. `openshell gateway add/remove/select` and the mTLS
# cert cache under ~/.config/openshell/gateways/<name>/ are keyed by this
# name, not by any cluster resource. agentops-example is the fixed base
# tenant and keeps its own "ocp" alias, so this project defaults to its own
# "openclaw2" alias — avoiding the historical gap where `openshell gateway
# remove ocp` in deploy-openshell.sh/configure-oidc.sh would otherwise
# silently delete the other project's local CLI registration.
GATEWAY_NAME="${GATEWAY_NAME:-openclaw2}"
if [[ -n "${GATEWAY_NAME:-}" && "${GATEWAY_NAME}" != "openclaw2" ]]; then
  echo "[common.sh] NOTE: GATEWAY_NAME=${GATEWAY_NAME} (from environment, default is 'openclaw2')" >&2
fi
# Helm release name for charts/openshell (the wrapper chart). Distinct from
# NAMESPACE: the vendored OCI subchart (ghcr.io/nvidia/openshell) mints
# CLUSTER-SCOPED RBAC (ClusterRole/ClusterRoleBinding
# "<release-name>-node-reader") named after the Helm *release name*, not the
# namespace — so two coexisting deploys in different namespaces still
# collide on that ClusterRole unless each uses its own release name too.
# Found live coexisting with another project's own "openshell" release
# (`Error: unable to continue with install: ClusterRole
# "openshell-node-reader" ... exists and cannot be imported into the
# current release`). Default is now "openshell2" (ADR-0020 addendum):
# agentops-example is the fixed base tenant on "openshell"/"openshell", so
# this project defaults to the non-colliding "second instance" identity
# instead — deploy-order-agnostic coexistence with zero manual overrides.
OPENSHELL_RELEASE_NAME="${OPENSHELL_RELEASE_NAME:-openshell2}"
# Sandbox ServiceAccount name the subchart creates by default:
# "<release-name>-sandbox" (charts/openshell/templates/_helpers.tpl's
# sandboxSA, mirroring the vendored subchart's own sandboxServiceAccountName
# helper) — NOT a fixed "openshell-sandbox" literal once OPENSHELL_RELEASE_NAME
# differs from the "openshell" default. Consumed by wire-rhoai-mlflow-tracing.sh
# (RBAC subject) and verify.sh.
SANDBOX_SA_NAME="${SANDBOX_SA_NAME:-${OPENSHELL_RELEASE_NAME}-sandbox}"
RHOAI_NS="${RHOAI_NS:-redhat-ods-applications}"
MLFLOW_EXPERIMENT_NAME="${MLFLOW_EXPERIMENT_NAME:-openclaw-tracing}"

CRC_BIN="${CRC_BIN:-$(command -v crc || echo crc)}"
CRC_MODE="${CRC_MODE:-false}"
APPS_DOMAIN="${APPS_DOMAIN:-}"

RENDERED_DIR="${PROJECT_DIR}/.rendered"
CURL_OPTS="${CURL_OPTS:-}"

# Empty Docker config to avoid `credsStore: desktop`/keychain lookups when
# pulling the OpenShell OCI chart dependency (charts/openshell/Chart.yaml)
# on Podman-based hosts. Exported so every `helm dependency ...`/`helm
# upgrade --install` invocation against that chart picks it up.
DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/helm-nodocker-openclaw}"
mkdir -p "$DOCKER_CONFIG"
[[ -f "${DOCKER_CONFIG}/config.json" ]] || printf '{}' > "${DOCKER_CONFIG}/config.json"
export DOCKER_CONFIG

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
  local detected
  detected=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
  if [[ -n "$APPS_DOMAIN" ]]; then
    if [[ -n "$detected" && "$APPS_DOMAIN" != "$detected" ]]; then
      warn "APPS_DOMAIN=$APPS_DOMAIN does not match cluster ingress $detected — using cluster domain"
      APPS_DOMAIN="$detected"
    else
      info "APPS_DOMAIN already set: $APPS_DOMAIN"
    fi
  else
    APPS_DOMAIN="$detected"
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
    # `cluster-lifecycle.sh full --fresh` run. Not needed on AWS OCP (real certs).
    # Do NOT export OPENSHELL_GATEWAY_INSECURE globally here — it disables
    # client-cert presentation and breaks mTLS `openshell status` against the
    # gateway Route (fatal alert: CertificateRequired). Scope it to OIDC-only
    # flows via enable_openshell_oidc_insecure() instead.
  fi
  export CURL_OPTS
}

# Enable TLS skip for openshell CLI calls that reach Keycloak/OIDC endpoints
# through CRC's self-signed router cert. Must NOT be set during mTLS gateway
# registration or `openshell status` — see docs/constraints.md #18/#19.
enable_openshell_oidc_insecure() {
  if [[ "$CRC_MODE" == "true" ]]; then
    export OPENSHELL_GATEWAY_INSECURE=true
  fi
}

render_template() {
  local src="$1" dest="$2"
  if [[ -z "$APPS_DOMAIN" ]]; then
    error "APPS_DOMAIN not set. Call detect_environment() first."
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  # __SANDBOX_NAME__ mirrors __APPS_DOMAIN__: parametrizes the OpenClaw UI's
  # public hostname/CORS origin so a second, differently-named sandbox
  # deploy can coexist with another project's on the same cluster without
  # an OpenShift Route hostname collision (docs/adrs/ADR-0020).
  sed -e "s/__APPS_DOMAIN__/${APPS_DOMAIN}/g" \
      -e "s/__SANDBOX_NAME__/${SANDBOX_NAME}/g" \
      "$src" > "$dest"
}

# render_openclaw_config renders config/openclaw.json.tpl like any other
# template (__APPS_DOMAIN__ substitution). The rendered file uses
# apiKey: "unused" — the inference router (inference.local) injects the real
# credential at the gateway layer. The sandbox process never sees the real key.
# See docs/constraints.md #3 and ROADMAP.md #13.4 for the full history.
render_openclaw_config() {
  local src="$1" dest="$2"
  render_template "$src" "$dest"
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

# wait_for_local_port <port> [timeout_seconds] — poll until localhost:port accepts TCP.
wait_for_local_port() {
  local port="$1" timeout="${2:-15}" i=0
  while [[ $i -lt $timeout ]]; do
    if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${port}/" 2>/dev/null \
      || curl -s -o /dev/null --connect-timeout 1 -X POST "http://127.0.0.1:${port}/v1/traces" 2>/dev/null; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# otel_http_export_accepted <http_code> <response_body>
# OTLP/HTTP returns {} on full success; partialSuccess only when some spans were rejected.
otel_http_export_accepted() {
  local code="$1" body="$2"
  [[ "$code" == "200" ]] || return 1
  [[ -z "$body" || "$body" == "{}" || "$body" == *"partialSuccess"* ]] || return 1
  return 0
}

# send_otel_test_trace <local_port> <span_name> — POST a minimal OTLP/HTTP trace.
# Prints "traceId spanId" on stdout; returns non-zero if the export is rejected.
send_otel_test_trace() {
  local port="$1" span_name="$2"
  local trace_id span_id now_ns end_ns http_code body
  trace_id=$(python3 -c "import uuid; print(uuid.uuid4().hex)" 2>/dev/null || echo "abcdef1234567890abcdef1234567890")
  span_id=$(python3 -c "import os; print(os.urandom(8).hex())" 2>/dev/null || echo "1234567890abcdef")
  now_ns=$(python3 -c "import time; print(int(time.time() * 1e9))")
  end_ns=$(python3 -c "import time; print(int((time.time()+1) * 1e9))")
  body=$(curl -s -w '\n%{http_code}' -X POST "http://127.0.0.1:${port}/v1/traces" \
    -H "Content-Type: application/json" \
    -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verify-test\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"test\"},\"spans\":[{\"traceId\":\"${trace_id}\",\"spanId\":\"${span_id}\",\"name\":\"${span_name}\",\"kind\":1,\"startTimeUnixNano\":\"${now_ns}\",\"endTimeUnixNano\":\"${end_ns}\",\"status\":{\"code\":1}}]}]}]}" 2>/dev/null || echo -e "\n000")
  http_code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if otel_http_export_accepted "$http_code" "$body"; then
    echo "${trace_id} ${span_id}"
    return 0
  fi
  echo "${body} (HTTP ${http_code})" >&2
  return 1
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


# Glob-escapes a literal string for safe use inside a `${var#*pattern}`
# expansion (bash treats `#`/`##` patterns as globs, not literal text).
_glob_escape() {
  local s=$1 out="" i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in
      '\'|'*'|'?'|'[') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# `openshell sandbox connect` is an interactive PTY: it echoes back the exact
# bytes it was sent (our command + " && exit") BEFORE running anything, then
# prints the real output, then echoes the second "exit" that ends the
# session. Found live during a credential-leak investigation (ROADMAP.md
# #13.4): several `verify.sh` Layer 4 checks used a
# `cmd_that_might_fail || echo MARKER` pattern and then grepped the captured
# output for MARKER — but since the literal text "echo MARKER" is PART OF
# the command that gets echoed back verbatim, MARKER always appears in the
# raw transcript regardless of whether the command actually failed. Those
# checks were reporting PASS unconditionally. Strip the echoed input (and
# ANSI/\r/closing-"exit" noise) here, once, so every caller gets only the
# real command output.
_strip_pty_echo() {
  local cmd=$1 raw=$2
  local needle
  needle="$(_glob_escape "$cmd") && exit"
  local stripped="${raw#*$needle}"
  # Unexpected reformatting (e.g. a wrapped multi-line command) means the
  # exact echoed prefix wasn't found verbatim — return the raw text rather
  # than silently discarding real output a caller might depend on.
  if [[ "$stripped" == "$raw" ]]; then
    stripped=$raw
  fi
  stripped=$(printf '%s' "$stripped" | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r')
  # Drop a trailing bare "exit" line (the echo of the session-ending exit).
  printf '%s' "$stripped" | sed -E '${/^[[:space:]]*exit[[:space:]]*$/d}'
}

sandbox_run() {
  # The openshell CLI's "active gateway" is local machine state shared
  # across every project driving it from this same host. If another
  # project's own gateway alias (or a previous run's) is currently active,
  # `sandbox connect "$SANDBOX_NAME"` looks for that name on the WRONG
  # gateway and fails with a misleading "sandbox not found" — found live
  # while validating shared-cluster coexistence (ADR-0020). Re-select
  # unconditionally (cheap, local-only) before every call instead of
  # trusting whatever was last selected.
  openshell gateway select "$GATEWAY_NAME" &>/dev/null || true
  local out
  out=$(printf '%s && exit\n' "$1" \
    | timeout 15 openshell sandbox connect "$SANDBOX_NAME" 2>&1 || true)
  # Long verify runs outlive the ~5m access_token; refresh once and retry.
  if echo "$out" | grep -qiE "OIDC token|invalid token|ExpiredSignature|valid authentication credentials|Token is not active"; then
    ensure_oidc_token >/dev/null 2>&1 || true
    out=$(printf '%s && exit\n' "$1" \
      | timeout 15 openshell sandbox connect "$SANDBOX_NAME" 2>&1 || true)
  fi
  printf '%s\n' "$(_strip_pty_echo "$1" "$out")"
}

# Lightweight OIDC password-grant refresh (no Helm upgrade). Writes
# ~/.config/openshell/gateways/$GATEWAY_NAME/oidc_token.json so the CLI can
# call sandbox/provider APIs again after access_token expiry (~5m).
# Requires APPS_DOMAIN (call detect_environment first). Returns 0 on success.
_refresh_oidc_password_grant() {
  local kc_issuer gw_url gw_config_dir kc_user kc_pass token_response
  local access_token refresh_token expires_in now expires_at

  if [[ -z "${APPS_DOMAIN:-}" ]]; then
    detect_environment
  fi

  kc_issuer="https://keycloak-openshell-keycloak.${APPS_DOMAIN}/realms/openshell"
  gw_url="https://openshell-gw-${NAMESPACE}.${APPS_DOMAIN}"
  gw_config_dir="${HOME}/.config/openshell/gateways/${GATEWAY_NAME}"
  mkdir -p "$gw_config_dir"

  # Ensure local gateway metadata exists (CLI registration). Do NOT run
  # configure-oidc.sh here — that re-runs helm upgrade + rollout.
  if [[ ! -f "${gw_config_dir}/metadata.json" ]]; then
    cat > "${gw_config_dir}/metadata.json" << EOF
{
  "name": "${GATEWAY_NAME}",
  "gateway_endpoint": "${gw_url}",
  "is_remote": false,
  "gateway_port": 0,
  "auth_mode": "oidc",
  "oidc": {
    "issuer": "${kc_issuer}",
    "client_id": "openshell-cli"
  }
}
EOF
  fi

  kc_user="${KC_USER:-admin}"
  kc_pass="${KC_PASS:-admin}"
  token_response=$(curl -sk -X POST "${kc_issuer}/protocol/openid-connect/token" \
    -d "client_id=openshell-cli" \
    -d "username=${kc_user}" \
    -d "password=${kc_pass}" \
    -d "grant_type=password" 2>/dev/null || true)

  access_token=$(echo "$token_response" | jq -r '.access_token // empty' 2>/dev/null || true)
  refresh_token=$(echo "$token_response" | jq -r '.refresh_token // empty' 2>/dev/null || true)
  expires_in=$(echo "$token_response" | jq -r '.expires_in // 300' 2>/dev/null || echo 300)

  if [[ -z "$access_token" || "$access_token" == "null" ]]; then
    error "OIDC password grant failed: $(echo "$token_response" | jq -r '.error_description // .error // "unknown"' 2>/dev/null || echo unknown)"
    return 1
  fi

  now=$(date +%s)
  expires_at=$((now + expires_in))
  cat > "${gw_config_dir}/oidc_token.json" << EOF
{
  "access_token": "${access_token}",
  "refresh_token": "${refresh_token}",
  "expires_at": ${expires_at},
  "issuer": "${kc_issuer}",
  "client_id": "openshell-cli"
}
EOF
  chmod 600 "${gw_config_dir}/oidc_token.json"
  openshell gateway select "$GATEWAY_NAME" &>/dev/null || true
  return 0
}

# Ensure openshell CLI has a usable OIDC bearer token. Call before any
# openshell command that needs auth (sandbox list/connect, provider, …).
# NOTE: `openshell status` can succeed with expired OIDC (mTLS) — probe
# `sandbox list` instead. On expiry, refreshes via Keycloak password grant
# only (no Helm). Returns 0 if sandbox list works, 1 otherwise.
ensure_oidc_token() {
  enable_openshell_oidc_insecure
  openshell gateway select "$GATEWAY_NAME" &>/dev/null || true
  if openshell sandbox list &>/dev/null; then
    return 0
  fi

  info "OIDC token missing/expired — refreshing via Keycloak password grant..."
  if ! _refresh_oidc_password_grant; then
    return 1
  fi

  if openshell sandbox list &>/dev/null; then
    info "OIDC token refreshed (sandbox list OK)"
    return 0
  fi

  error "OIDC refresh wrote a token but sandbox list still fails (gateway/OIDC misconfigured?)"
  return 1
}

# Enable providers_v2 on the gateway. Idempotent — safe to call multiple times.
# Unlocks provider profile policy composition and per-provider policy layers
# that auto-contribute to sandbox effective policy.
enable_providers_v2() {
  openshell settings set --global --key providers_v2_enabled --value true --yes 2>/dev/null
  info "providers_v2_enabled = true"
}

# Create the MaaS provider (v2-compatible, --type openai). Idempotent — skips
# if already exists. Requires a valid OIDC token when gateway has auth enabled.
# The credential is stored in the gateway's provider record and injected by
# the inference router (inference.local) — never exposed to sandbox processes.
create_provider() {
  if [[ -z "${MAAS_API_KEY:-}" ]]; then load_secrets; fi
  if openshell provider list 2>/dev/null | grep -q "$PROVIDER_NAME"; then
    info "Provider '$PROVIDER_NAME' already exists"
    return 0
  fi
  openshell provider create \
    --name "$PROVIDER_NAME" \
    --type openai \
    --credential "OPENAI_API_KEY=${MAAS_API_KEY}" \
    --config "OPENAI_BASE_URL=${MAAS_BASE_URL}"
  info "Provider '$PROVIDER_NAME' created (type=openai, base=${MAAS_BASE_URL})"
}

# Create a named OpenAI-compatible provider. Idempotent — skips if exists.
# Usage: ensure_inference_provider <name> <base_url>
ensure_inference_provider() {
  local name="$1" base_url="$2"
  if [[ -z "${MAAS_API_KEY:-}" ]]; then load_secrets; fi
  if openshell provider list 2>/dev/null | grep -q "$name"; then
    info "Provider '$name' already exists"
  else
    openshell provider create \
      --name "$name" \
      --type openai \
      --credential "OPENAI_API_KEY=${MAAS_API_KEY}" \
      --config "OPENAI_BASE_URL=${base_url}"
    info "Provider '$name' created (type=openai, base=${base_url})"
  fi
}

# Register both direct and guardrailed providers (ADR-0022).
# Called after providers_v2 is enabled and OIDC token is available.
create_dual_providers() {
  ensure_inference_provider "$PROVIDER_DIRECT" "$MAAS_BASE_URL"
  ensure_inference_provider "$PROVIDER_GUARDRAILED" "$NEMO_GUARDRAILS_URL"
}

# Configure the inference route: inference.local -> provider/model.
# All sandboxes on this gateway will use this route. Idempotent.
# Supports INFERENCE_BACKEND=direct|guardrailed to pick the active provider.
configure_inference_route() {
  local active_provider="$PROVIDER_DIRECT"
  if [[ "${INFERENCE_BACKEND}" == "guardrailed" ]]; then
    active_provider="$PROVIDER_GUARDRAILED"
  fi
  openshell inference set --provider "$active_provider" --model "$INFERENCE_MODEL" --no-verify 2>/dev/null
  info "Inference route: $active_provider / $INFERENCE_MODEL (backend=${INFERENCE_BACKEND})"
}

get_apps_domain() {
  echo "$APPS_DOMAIN"
}

get_service_url() {
  local sandbox="$1" service="$2"
  echo "https://${sandbox}--${service}.$(get_apps_domain)"
}

# ─── MLflow cluster helpers ──────────────────────────────────────────────────
# Pick a pod that can reach mlflow.<rhoai-ns>.svc from inside the cluster.
# Prefers sandbox pod (has curl), falls back to gateway pod.
_mlflow_exec_target() {
  if oc -n "$NAMESPACE" get pod "$SANDBOX_NAME" &>/dev/null 2>&1; then
    _MLFLOW_EXEC_POD="$SANDBOX_NAME"
    _MLFLOW_EXEC_CONTAINER="agent"
    return 0
  fi
  local gw_pod
  gw_pod="$(oc -n "$NAMESPACE" get pods -l app.kubernetes.io/name=openshell \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$gw_pod" ]]; then
    _MLFLOW_EXEC_POD="$gw_pod"
    _MLFLOW_EXEC_CONTAINER=""
    return 0
  fi
  return 1
}

# Execute a curl command against MLflow from inside the cluster.
_mlflow_cluster_curl() {
  local curl_cmd="$1"
  if ! _mlflow_exec_target; then
    warn "No sandbox or OpenShell pod in ${NAMESPACE} for MLflow API calls"
    return 1
  fi
  if [[ -n "$_MLFLOW_EXEC_CONTAINER" ]]; then
    oc -n "$NAMESPACE" exec "$_MLFLOW_EXEC_POD" -c "$_MLFLOW_EXEC_CONTAINER" -- \
      bash -c "$curl_cmd" 2>/dev/null || true
  else
    oc -n "$NAMESPACE" exec "$_MLFLOW_EXEC_POD" -- \
      bash -c "$curl_cmd" 2>/dev/null || true
  fi
}

# Read the SA bearer token for MLflow API calls (cached in MLFLOW_TOKEN).
read_mlflow_sa_token() {
  if [[ -n "${MLFLOW_TOKEN:-}" ]]; then
    return 0
  fi
  if ! oc -n "$NAMESPACE" get secret "${SANDBOX_SA_NAME}-mlflow-token" &>/dev/null; then
    warn "Secret ${SANDBOX_SA_NAME}-mlflow-token not found"
    return 1
  fi
  MLFLOW_TOKEN="$(oc -n "$NAMESPACE" get secret "${SANDBOX_SA_NAME}-mlflow-token" \
    -o jsonpath='{.data.token}' | base64 -d)"
  export MLFLOW_TOKEN
  return 0
}

# Get-or-create the MLflow experiment in the target workspace (idempotent).
ensure_mlflow_experiment() {
  local experiment_name="${MLFLOW_EXPERIMENT_NAME:-openclaw-tracing}"
  local workspace="${MLFLOW_WORKSPACE:-$NAMESPACE}"
  local mlflow_url="https://mlflow.${RHOAI_NS}.svc:8443"
  local exp_json exp_id token

  if [[ -n "${MLFLOW_EXPERIMENT_ID:-}" && "${MLFLOW_EXPERIMENT_ID}" != "__RESOLVE__" ]]; then
    info "MLFLOW_EXPERIMENT_ID=${MLFLOW_EXPERIMENT_ID}"
    return 0
  fi

  if ! read_mlflow_sa_token; then
    return 1
  fi
  token="$MLFLOW_TOKEN"

  exp_json="$(_mlflow_cluster_curl \
    "curl -sk '${mlflow_url}/api/2.0/mlflow/experiments/get-by-name?experiment_name=${experiment_name}' \
      -H 'Authorization: Bearer ${token}' \
      -H 'X-MLFLOW-WORKSPACE: ${workspace}'")"
  exp_id="$(echo "$exp_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('experiment',{}).get('experiment_id',''))" 2>/dev/null || true)"

  if [[ -z "$exp_id" ]]; then
    info "Creating MLflow experiment '${experiment_name}' in workspace ${workspace}"
    exp_json="$(_mlflow_cluster_curl \
      "curl -sk -X POST \
        -H 'Authorization: Bearer ${token}' \
        -H 'X-MLFLOW-WORKSPACE: ${workspace}' \
        -H 'Content-Type: application/json' \
        -d '{\"name\": \"${experiment_name}\"}' \
        '${mlflow_url}/api/2.0/mlflow/experiments/create'")"
    exp_id="$(echo "$exp_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('experiment',{}).get('experiment_id',''))" 2>/dev/null || true)"
  fi

  if [[ -z "$exp_id" ]]; then
    warn "Could not get or create experiment '${experiment_name}' in workspace ${workspace}"
    warn "Last MLflow response: ${exp_json:-<empty>}"
    return 1
  fi

  export MLFLOW_EXPERIMENT_ID="$exp_id"
  info "MLflow experiment ${experiment_name} → id=${MLFLOW_EXPERIMENT_ID} (workspace=${workspace})"
  return 0
}

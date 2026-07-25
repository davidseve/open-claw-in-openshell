#!/usr/bin/env bash
# Fetch system prompts from MLflow Prompt Registry into the sandbox workspace.
#
# Designed to run INSIDE the sandbox via oc exec. Uses curl + python3
# (both available in the OpenClaw sandbox image; jq is NOT available).
#
# Writes each prompt to /sandbox/workspace/<NAME>.md with a version
# metadata header, creates .prompt-versions.json manifest, and tags
# the MLflow experiment with active prompt versions.
#
# RHOAI-managed MLflow (the sole tracing/prompt backend for this project —
# see docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md) requires a Bearer
# token (self_subject_access_review RBAC) and an X-MLFLOW-WORKSPACE header
# on every request, plus TLS validated against openshift-service-ca.crt.
# All three are optional env vars here so this script degrades gracefully
# if ever pointed at an unauthenticated MLflow again.
#
# Usage (from launch-openclaw.sh):
#   oc exec $SANDBOX -- bash /tmp/fetch-prompts-from-mlflow.sh
set -euo pipefail

MLFLOW_URL="${MLFLOW_URL:-https://mlflow.redhat-ods-applications.svc:8443}"
WORKSPACE="${OPENCLAW_WORKSPACE_DIR:-/sandbox/workspace}"
PREFIX="openclaw-system"
SEPARATOR="."
ALIAS="production"
EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-0}"

MLFLOW_TRACKING_TOKEN="${MLFLOW_TRACKING_TOKEN:-}"
MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-}"
MLFLOW_TRACKING_SERVER_CERT_PATH="${MLFLOW_TRACKING_SERVER_CERT_PATH:-}"

CURL_OPTS="${CURL_OPTS:-}"
PROMPT_FILES=(AGENTS SOUL TOOLS IDENTITY USER HEARTBEAT BOOTSTRAP)

# auth_curl_args — expands to the extra -H/--cacert flags needed for
# RHOAI-managed MLflow; no-ops (empty) when the corresponding env var isn't set.
auth_curl_args() {
  local args=()
  [[ -n "$MLFLOW_TRACKING_TOKEN" ]] && args+=(-H "Authorization: Bearer ${MLFLOW_TRACKING_TOKEN}")
  [[ -n "$MLFLOW_WORKSPACE" ]] && args+=(-H "X-MLFLOW-WORKSPACE: ${MLFLOW_WORKSPACE}")
  [[ -n "$MLFLOW_TRACKING_SERVER_CERT_PATH" ]] && args+=(--cacert "$MLFLOW_TRACKING_SERVER_CERT_PATH")
  printf '%s\0' "${args[@]}"
}
mapfile -d '' -t AUTH_CURL_ARGS < <(auth_curl_args)

MANIFEST="{\"fetched_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"alias\":\"${ALIAS}\",\"prompts\":{"
FIRST=true
TAG_PAYLOADS=""

urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))" 2>/dev/null \
    || printf '%s' "$1" | sed 's/ /%20/g; s/\//%2F/g'
}

pyjson() {
  python3 -c "
import sys, json
data = json.load(sys.stdin)
path = '$1'.split('.')
for key in path:
    if isinstance(data, list):
        data = data[int(key)] if key.isdigit() else None
    elif isinstance(data, dict):
        data = data.get(key)
    else:
        data = None
    if data is None:
        break
print(data if data is not None else '')
" 2>/dev/null
}

for prompt_name in "${PROMPT_FILES[@]}"; do
  fq_name="${PREFIX}${SEPARATOR}${prompt_name}"
  encoded_name=$(urlencode "$fq_name")

  # Step 1: Get registered model to resolve alias → version number
  model_resp=$(curl -sf $CURL_OPTS "${AUTH_CURL_ARGS[@]}" \
    "${MLFLOW_URL}/api/2.0/mlflow/registered-models/get?name=${encoded_name}" \
    2>/dev/null || echo "")

  if [[ -z "$model_resp" ]]; then
    echo "[SKIP] ${fq_name}: not found or MLflow unreachable"
    continue
  fi

  version=$(echo "$model_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
aliases = data.get('registered_model', {}).get('aliases', [])
alias = '${ALIAS}'
for a in aliases:
    if a.get('alias') == alias:
        print(a.get('version', ''))
        sys.exit(0)
versions = data.get('registered_model', {}).get('latest_versions', [])
if versions:
    print(versions[0].get('version', ''))
" 2>/dev/null)

  if [[ -z "$version" ]]; then
    echo "[SKIP] ${fq_name}: could not resolve version for alias @${ALIAS}"
    continue
  fi

  # Step 2: Get specific version (carries the prompt text tag)
  version_resp=$(curl -sf $CURL_OPTS "${AUTH_CURL_ARGS[@]}" \
    "${MLFLOW_URL}/api/2.0/mlflow/model-versions/get?name=${encoded_name}&version=${version}" \
    2>/dev/null || echo "")

  if [[ -z "$version_resp" ]]; then
    echo "[SKIP] ${fq_name}: could not fetch version ${version}"
    continue
  fi

  content=$(echo "$version_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tags = data.get('model_version', {}).get('tags', [])
for t in tags:
    if t.get('key') == 'mlflow.prompt.text':
        print(t.get('value', ''))
        sys.exit(0)
" 2>/dev/null)

  if [[ -z "$content" ]]; then
    echo "[SKIP] ${fq_name}: no prompt text in version ${version}"
    continue
  fi

  target="${WORKSPACE}/${prompt_name}.md"
  {
    echo "<!-- mlflow-prompt: ${fq_name} version:${version} alias:${ALIAS} fetched:$(date -u +%Y-%m-%dT%H:%M:%SZ) -->"
    echo ""
    echo "$content"
  } > "$target"

  echo "[OK] ${fq_name} v${version} → ${target}"

  if [[ "$FIRST" == "true" ]]; then
    FIRST=false
  else
    MANIFEST+=","
  fi
  MANIFEST+="\"${prompt_name}\":{\"version\":${version},\"name\":\"${fq_name}\"}"

  TAG_PAYLOADS+="prompt.${prompt_name}.version=${version}\n"
  TAG_PAYLOADS+="prompt.${prompt_name}.alias=${ALIAS}\n"
done

MANIFEST+="}}"
python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read()), indent=2))" \
  <<< "$MANIFEST" > "${WORKSPACE}/.prompt-versions.json" 2>/dev/null \
  || echo "$MANIFEST" > "${WORKSPACE}/.prompt-versions.json"
echo "[OK] Manifest written to ${WORKSPACE}/.prompt-versions.json"

echo ""
echo "Tagging MLflow experiment ${EXPERIMENT_ID} with prompt versions..."
while IFS='=' read -r key value; do
  [[ -z "$key" ]] && continue
  curl -sf $CURL_OPTS "${AUTH_CURL_ARGS[@]}" -X POST "${MLFLOW_URL}/api/2.0/mlflow/experiments/set-experiment-tag" \
    -H "Content-Type: application/json" \
    -d "{\"experiment_id\":\"${EXPERIMENT_ID}\",\"key\":\"${key}\",\"value\":\"${value}\"}" \
    > /dev/null 2>&1 \
    && echo "[TAG] ${key}=${value}" \
    || echo "[WARN] Failed to tag: ${key}=${value}"
done < <(printf '%b' "$TAG_PAYLOADS")

echo ""
echo "Prompt fetch complete."

#!/usr/bin/env bash
# Seed system prompts into MLflow Prompt Registry.
#
# Uses mlflow.genai.register_prompt() Python SDK to ensure prompts
# appear correctly in the MLflow UI's Prompts tab.
#
# RHOAI-managed MLflow (the sole tracing/prompt backend for this project —
# see docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md) always runs with
# --enable-workspaces, so every request needs a Bearer token
# (self_subject_access_review RBAC) and a workspace context. Unlike the
# @mlflow/core JS SDK (which needed a source-patch backport — constraint
# #4b), the Python SDK supports both natively via MLFLOW_TRACKING_TOKEN and
# MLFLOW_WORKSPACE env vars — no patching required here.
#
# Usage:
#   ./scripts/prompt-registry/seed-mlflow-prompts.sh
#
# Auth is auto-loaded from .rendered/rhoai-mlflow/wiring.env when present
# (written by scripts/wire-rhoai-mlflow-tracing.sh). You can also pass vars
# explicitly:
#   MLFLOW_TRACKING_TOKEN=... MLFLOW_WORKSPACE=... MLFLOW_EXPERIMENT_ID=... \
#     ./scripts/prompt-registry/seed-mlflow-prompts.sh
#
# MLFLOW_URL is always resolved from the external Route (not the in-cluster
# Service URL in wiring.env) because this script runs on the host.
# MLFLOW_EXPERIMENT_ID matters, not just cosmetically: registering a prompt
# without an active experiment set tags it with `_mlflow_experiment_ids=,0,`
# (the "Default" experiment). RHOAI's dashboard Prompts tab is nested per
# experiment (/experiments/<id>/prompts) and filters by that tag, so prompts
# registered without setting the experiment first are invisible there even
# though they're fully valid and gettable/searchable via the API/SDK
# (confirmed live: `mlflow.genai.search_prompts()` and a direct
# `registered-models/search?filter=...` both return them regardless of
# `_mlflow_experiment_ids` — only the per-experiment dashboard view cares).
set -euo pipefail
source "$(dirname "$0")/../common.sh"

PROMPTS_DIR="${PROJECT_DIR}/prompts"
PREFIX="openclaw-system"

detect_environment

WIRING_ENV="${RENDERED_DIR}/rhoai-mlflow/wiring.env"
if [[ -f "$WIRING_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$WIRING_ENV"
  MLFLOW_TRACKING_TOKEN="${MLFLOW_TRACKING_TOKEN:-${RHOAI_MLFLOW_SA_TOKEN:-}}"
  MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-${RHOAI_MLFLOW_WORKSPACE:-}}"
  MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-${RHOAI_MLFLOW_EXPERIMENT_ID:-}}"
  MLFLOW_TRACKING_SERVER_CERT_PATH="${MLFLOW_TRACKING_SERVER_CERT_PATH:-${RHOAI_MLFLOW_CA_FILE:-}}"
  info "Loaded RHOAI MLflow auth from ${WIRING_ENV}"
fi

if [[ -z "${MLFLOW_URL:-}" ]]; then
  MLFLOW_ROUTE=$(oc get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "$MLFLOW_ROUTE" ]]; then
    MLFLOW_URL="https://${MLFLOW_ROUTE}"
  else
    error "Cannot determine MLflow URL. Set MLFLOW_URL or ensure RHOAI MLflow's Route exists (run scripts/deploy-rhoai-mlflow.sh first)."
    exit 1
  fi
fi

info "MLflow URL: ${MLFLOW_URL}"

MLFLOW_TRACKING_TOKEN="${MLFLOW_TRACKING_TOKEN:-}"
MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-}"
MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-}"
if [[ -z "$MLFLOW_TRACKING_TOKEN" || -z "$MLFLOW_WORKSPACE" ]]; then
  error "MLFLOW_TRACKING_TOKEN and MLFLOW_WORKSPACE are required for RHOAI MLflow."
  error "Run ./scripts/wire-rhoai-mlflow-tracing.sh first (creates ${WIRING_ENV}), or export the vars manually."
  exit 1
fi
if [[ -z "$MLFLOW_EXPERIMENT_ID" ]]; then
  warn "MLFLOW_EXPERIMENT_ID not set — prompts will be tagged to the 'Default' experiment and won't show up in the RHOAI dashboard's per-experiment Prompts tab"
fi

PROMPT_FILES=(AGENTS SOUL TOOLS IDENTITY USER HEARTBEAT BOOTSTRAP)

step "Seeding system prompts into MLflow Prompt Registry"

SSL_VERIFY="True"
if [[ "$CRC_MODE" == "true" ]]; then
  SSL_VERIFY="False"
fi

python3 - "$MLFLOW_URL" "$PROMPTS_DIR" "$PREFIX" "$SSL_VERIFY" "${MLFLOW_TRACKING_TOKEN}" "${MLFLOW_WORKSPACE}" "${MLFLOW_EXPERIMENT_ID}" "${PROMPT_FILES[@]}" <<'PYEOF'
import sys
import os
import warnings

warnings.filterwarnings("ignore")

mlflow_url = sys.argv[1]
prompts_dir = sys.argv[2]
prefix = sys.argv[3]
ssl_verify = sys.argv[4] == "True"
tracking_token = sys.argv[5]
workspace = sys.argv[6]
experiment_id = sys.argv[7]
prompt_names = sys.argv[8:]

os.environ["MLFLOW_TRACKING_URI"] = mlflow_url
if not ssl_verify:
    os.environ["MLFLOW_TRACKING_INSECURE_TLS"] = "true"
if tracking_token:
    os.environ["MLFLOW_TRACKING_TOKEN"] = tracking_token
if workspace:
    os.environ["MLFLOW_WORKSPACE"] = workspace

import mlflow

if experiment_id:
    # Ties every registered prompt to this experiment via the
    # `_mlflow_experiment_ids` tag, which is what the RHOAI dashboard's
    # per-experiment Prompts tab filters on (see usage comment above).
    mlflow.set_experiment(experiment_id=experiment_id)

for name in prompt_names:
    filepath = os.path.join(prompts_dir, f"{name}.md")
    if not os.path.isfile(filepath):
        print(f"    [WARN] File not found: {filepath} — skipping")
        continue

    with open(filepath, "r") as f:
        content = f.read()

    fq_name = f"{prefix}.{name}"
    try:
        pv = mlflow.genai.register_prompt(
            name=fq_name,
            template=content,
            commit_message=f"Seeded from prompts/{name}.md",
            tags={"source": "seed-mlflow-prompts.sh", "prompt_file": f"{name}.md"},
        )
        version = pv.version
        print(f"    [OK] {fq_name} v{version}")
    except Exception as e:
        print(f"    [FAIL] {fq_name}: {e}")

print(f"==> Seed complete ({len(prompt_names)} prompts processed)")
PYEOF

step "Setting @production aliases"
AUTH_HEADERS=()
[[ -n "$MLFLOW_TRACKING_TOKEN" ]] && AUTH_HEADERS+=(-H "Authorization: Bearer ${MLFLOW_TRACKING_TOKEN}")
[[ -n "$MLFLOW_WORKSPACE" ]] && AUTH_HEADERS+=(-H "X-MLFLOW-WORKSPACE: ${MLFLOW_WORKSPACE}")

for prompt_name in "${PROMPT_FILES[@]}"; do
  fq_name="${PREFIX}.${prompt_name}"
  version=$(curl -sf $CURL_OPTS "${AUTH_HEADERS[@]}" \
    "${MLFLOW_URL}/api/2.0/mlflow/registered-models/get?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${fq_name}', safe=''))")" \
    2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
vs=d.get('registered_model',{}).get('latest_versions',[])
print(vs[0]['version'] if vs else '')
" 2>/dev/null)

  if [[ -n "$version" ]]; then
    curl -sf $CURL_OPTS "${AUTH_HEADERS[@]}" -X POST "${MLFLOW_URL}/api/2.0/mlflow/registered-models/alias" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "import json; print(json.dumps({'name':'${fq_name}','alias':'production','version':'${version}'}))")" \
      > /dev/null 2>&1 \
      && pass "${fq_name} v${version} (@production)" \
      || warn "Failed to set alias for ${fq_name}"
  else
    warn "Could not determine version for ${fq_name}"
  fi
done

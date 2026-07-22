#!/usr/bin/env bash
# Seed system prompts into MLflow Prompt Registry.
#
# Uses mlflow.genai.register_prompt() Python SDK to ensure prompts
# appear correctly in the MLflow UI's Prompts tab.
#
# Usage:
#   ./scripts/seed-mlflow-prompts.sh                  # uses cluster-internal MLflow
#   MLFLOW_URL=http://localhost:5000 ./scripts/seed-mlflow-prompts.sh  # local MLflow
set -euo pipefail
source "$(dirname "$0")/common.sh"

PROMPTS_DIR="${PROJECT_DIR}/prompts"
PREFIX="openclaw-system"

detect_environment

if [[ -z "${MLFLOW_URL:-}" ]]; then
  OBS_NAMESPACE="observability"
  MLFLOW_ROUTE=$(oc get route mlflow -n "$OBS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "$MLFLOW_ROUTE" ]]; then
    MLFLOW_URL="https://${MLFLOW_ROUTE}"
  else
    error "Cannot determine MLflow URL. Set MLFLOW_URL or ensure the MLflow Route exists."
    exit 1
  fi
fi

info "MLflow URL: ${MLFLOW_URL}"

PROMPT_FILES=(AGENTS SOUL TOOLS IDENTITY USER HEARTBEAT BOOTSTRAP)

step "Seeding system prompts into MLflow Prompt Registry"

SSL_VERIFY="True"
if [[ "$CRC_MODE" == "true" ]]; then
  SSL_VERIFY="False"
fi

python3 - "$MLFLOW_URL" "$PROMPTS_DIR" "$PREFIX" "$SSL_VERIFY" "${PROMPT_FILES[@]}" <<'PYEOF'
import sys
import os
import warnings

warnings.filterwarnings("ignore")

mlflow_url = sys.argv[1]
prompts_dir = sys.argv[2]
prefix = sys.argv[3]
ssl_verify = sys.argv[4] == "True"
prompt_names = sys.argv[5:]

os.environ["MLFLOW_TRACKING_URI"] = mlflow_url
if not ssl_verify:
    os.environ["MLFLOW_TRACKING_INSECURE_TLS"] = "true"

import mlflow

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
for prompt_name in "${PROMPT_FILES[@]}"; do
  fq_name="${PREFIX}.${prompt_name}"
  version=$(curl -sf $CURL_OPTS \
    "${MLFLOW_URL}/api/2.0/mlflow/registered-models/get?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${fq_name}', safe=''))")" \
    2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
vs=d.get('registered_model',{}).get('latest_versions',[])
print(vs[0]['version'] if vs else '')
" 2>/dev/null)

  if [[ -n "$version" ]]; then
    curl -sf $CURL_OPTS -X POST "${MLFLOW_URL}/api/2.0/mlflow/registered-models/alias" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "import json; print(json.dumps({'name':'${fq_name}','alias':'production','version':'${version}'}))")" \
      > /dev/null 2>&1 \
      && pass "${fq_name} v${version} (@production)" \
      || warn "Failed to set alias for ${fq_name}"
  else
    warn "Could not determine version for ${fq_name}"
  fi
done

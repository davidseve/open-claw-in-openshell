#!/usr/bin/env bash
# deploy-guardrails.sh — Deploy NeMo Guardrails via TrustyAI NemoGuardrails CR.
# Requires: RHOAI platform with trustyai: Managed, secrets/secrets.env with MAAS_API_KEY.
# See ADR-0022.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

load_secrets

detect_environment

NEMO_GUARDRAILS_SERVICE="${NEMO_GUARDRAILS_SERVICE:-nemo-guardrails}"
NEMO_GUARDRAILS_PORT="${NEMO_GUARDRAILS_PORT:-80}"

step "Waiting for NemoGuardrails CRD"
until oc get crd nemoguardrails.trustyai.opendatahub.io >/dev/null 2>&1; do
  info "NemoGuardrails CRD not ready yet..."
  sleep 10
done
pass "NemoGuardrails CRD available"

step "Deploying NeMo Guardrails (Helm)"
helm upgrade --install rhoai-guardrails "${PROJECT_DIR}/charts/guardrails" \
  --namespace "${NAMESPACE}" --create-namespace \
  --set-string guardrails.maasApiKey="${MAAS_API_KEY}" \
  --set guardrails.maasBaseUrl="${MAAS_BASE_URL}" \
  --set guardrails.modelName="${INFERENCE_MODEL}" \
  --set guardrails.name="${NEMO_GUARDRAILS_SERVICE}" \
  --set guardrails.namespace="${NAMESPACE}" \
  --set guardrails.servicePort="${NEMO_GUARDRAILS_PORT}"
pass "Helm release rhoai-guardrails installed"

step "Waiting for NemoGuardrails CR to become Ready"
oc wait "nemoguardrails/${NEMO_GUARDRAILS_SERVICE}" \
  -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Ready --timeout=600s
pass "NemoGuardrails ${NEMO_GUARDRAILS_SERVICE} is Ready"

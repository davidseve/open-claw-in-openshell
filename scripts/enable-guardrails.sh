#!/usr/bin/env bash
# enable-guardrails.sh — Switch inference.local to route through NeMo Guardrails.
# Requires: OpenShell deployed with both providers (maas-direct + maas-guardrailed).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

command -v openshell >/dev/null 2>&1 || { error "openshell CLI is required"; exit 1; }

PROVIDER_GUARDRAILED="${PROVIDER_GUARDRAILED:-maas-guardrailed}"
NEMO_GUARDRAILS_SERVICE="${NEMO_GUARDRAILS_SERVICE:-nemo-guardrails}"
NEMO_GUARDRAILS_PORT="${NEMO_GUARDRAILS_PORT:-80}"
NEMO_GUARDRAILS_URL="${NEMO_GUARDRAILS_URL:-http://${NEMO_GUARDRAILS_SERVICE}.${NAMESPACE}.svc.cluster.local:${NEMO_GUARDRAILS_PORT}/v1}"

openshell gateway select "${GATEWAY_NAME}" >/dev/null 2>&1 || true

step "Enabling NeMo Guardrails inference path"
info "Provider: ${PROVIDER_GUARDRAILED} → ${NEMO_GUARDRAILS_URL}"
info "Model: ${INFERENCE_MODEL}"

if ! openshell provider list 2>/dev/null | grep -q "${PROVIDER_GUARDRAILED}"; then
  error "Provider '${PROVIDER_GUARDRAILED}' not found. Run: make launch"
  exit 1
fi

openshell inference set --provider "${PROVIDER_GUARDRAILED}" --model "${INFERENCE_MODEL}" --no-verify
pass "Inference route: ${PROVIDER_GUARDRAILED} / ${INFERENCE_MODEL} (NeMo Guardrails active)"

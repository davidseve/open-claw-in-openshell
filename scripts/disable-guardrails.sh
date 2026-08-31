#!/usr/bin/env bash
# disable-guardrails.sh — Reset inference.local to direct MaaS (no NeMo in path).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

command -v openshell >/dev/null 2>&1 || { error "openshell CLI is required"; exit 1; }

PROVIDER_DIRECT="${PROVIDER_DIRECT:-maas-direct}"

openshell gateway select "${GATEWAY_NAME}" >/dev/null 2>&1 || true

step "Restoring direct MaaS inference path"
info "Provider: ${PROVIDER_DIRECT} → ${MAAS_BASE_URL}"
info "Model: ${INFERENCE_MODEL}"

openshell inference set --provider "${PROVIDER_DIRECT}" --model "${INFERENCE_MODEL}" --no-verify
pass "Inference route: ${PROVIDER_DIRECT} / ${INFERENCE_MODEL} (direct MaaS)"

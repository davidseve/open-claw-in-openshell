#!/usr/bin/env bash
#
# Deploy the minimal RHOAI-managed MLflow stack: RHOAI operator subscription
# + a DataScienceCluster with only `mlflowoperator: Managed` (everything else
# Removed) + a Postgres backend store + the MLflow CR, via charts/rhoai/.
#
# RHOAI MLflow is the sole tracing/prompt-registry backend for this project
# (docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md) — called unconditionally
# from scripts/crc-lifecycle.sh's `deploy`/`full` commands, on every
# environment including CRC.
#
# ADR-0017's empirically-tested resource finding still applies on CRC: RHOAI
# + this minimal MLflow ALONE fits comfortably on a 16 vCPU / 40 GiB CRC VM
# (~18 GiB host memory stayed free out of 62 GiB total); combined with the
# rest of the OpenClaw-in-OpenShell stack, host free memory drops to ~11 GiB
# and swap engages — functionally fine (no crashes, no pod evictions) but
# below this project's own comfort margin for a shared dev laptop. This is
# an accepted, deliberate trade-off (no lightweight standalone-MLflow
# fallback exists anymore) — see ADR-0018's "Consequences" section.
#
# Secrets: never commits a plaintext DB password to git (AGENTS.md). Uses
# common.sh's ensure_secret_var() — same idempotent helper as
# scripts/deploy-keycloak.sh / scripts/deploy-oauth2-proxy.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
CHART_DIR="${PROJECT_DIR}/charts/rhoai"

check_prereqs
detect_environment

if [[ "$CRC_MODE" == "true" ]]; then
  info "CRC mode: RHOAI + MLflow combined with the full OpenClaw stack squeezes"
  info "host free memory to ~11 GiB (see ADR-0017/ADR-0018) — accepted trade-off,"
  info "no lightweight fallback. Close other memory-heavy apps if things feel slow."
fi

step "Ensuring MLFLOW_DB_PASSWORD secret exists"
ensure_secret_var MLFLOW_DB_PASSWORD -hex 24

step "Deploying minimal RHOAI + MLflow stack (charts/rhoai)"
info "installPlanApproval is Manual - charts/rhoai/Makefile's wait-operators target"
info "auto-approves the InstallPlan for the pinned channel/version (operators/values.yaml)"
info "on every environment, CRC and AWS alike. To approve by hand instead:"
info "  oc -n redhat-ods-operator get installplan"
info "  oc -n redhat-ods-operator patch installplan <name> --type merge -p '{\"spec\":{\"approved\":true}}'"
make -C "$CHART_DIR" deploy-all \
  HELM_OPTS="--set-string database.password=${MLFLOW_DB_PASSWORD} --set-string postgresql.password=${MLFLOW_DB_PASSWORD}"

step "Validating RHOAI MLflow deployment"
if make -C "$CHART_DIR" validate; then
  pass "RHOAI-managed MLflow deployed and validated"
else
  fail "RHOAI-managed MLflow validation failed - see 'make -C charts/rhoai validate' output above"
fi

step "RHOAI MLflow deploy script complete"

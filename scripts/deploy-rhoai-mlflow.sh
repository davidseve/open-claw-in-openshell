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

# The Dashboard/Gen AI Studio component matrix is the one part of the
# platform chart that legitimately differs per environment — it lives
# entirely in charts/rhoai/platform/values-crc.yaml vs. values-aws.yaml
# (declarative overlays, see those files for the full rationale and
# docs/constraints.md #20/#23), not in conditional flags built here.
PLATFORM_ENV_VALUES="platform/values-crc.yaml"
if [[ "$CRC_MODE" != "true" ]]; then
  PLATFORM_ENV_VALUES="platform/values-aws.yaml"
fi
info "Using ${PLATFORM_ENV_VALUES} for the RHOAI Dashboard/Gen AI Studio"
info "component matrix (see that file for the CRC-vs-AWS rationale)."

step "Ensuring MLFLOW_DB_PASSWORD secret exists"
ensure_secret_var MLFLOW_DB_PASSWORD -hex 24

step "Deploying minimal RHOAI + MLflow stack (charts/rhoai)"
info "installPlanApproval is Manual - charts/rhoai/Makefile's wait-operators target"
info "auto-approves the InstallPlan for the pinned channel/version (operators/values.yaml)"
info "on every environment, CRC and AWS alike. To approve by hand instead:"
info "  oc -n redhat-ods-operator get installplan"
info "  oc -n redhat-ods-operator patch installplan <name> --type merge -p '{\"spec\":{\"approved\":true}}'"
make -C "$CHART_DIR" deploy-all \
  PLATFORM_ENV_VALUES="${PLATFORM_ENV_VALUES}" \
  HELM_OPTS="--set-string database.password=${MLFLOW_DB_PASSWORD} --set-string postgresql.password=${MLFLOW_DB_PASSWORD}"

step "Validating RHOAI MLflow deployment"
if make -C "$CHART_DIR" validate; then
  pass "RHOAI-managed MLflow deployed and validated"
else
  fail "RHOAI-managed MLflow validation failed - see 'make -C charts/rhoai validate' output above"
fi

# Re-running this script after OpenShell + wire-rhoai-mlflow-tracing.sh have
# already run once (e.g. to pick up a chart fix, like the genAiStudio
# CRD-race fix in charts/rhoai/Makefile) is otherwise destructive: the plain
# `helm upgrade --install rhoai-mlflow` above computes values from the
# chart's own defaults + HELM_OPTS only (neither this call nor
# wire-rhoai-mlflow-tracing.sh's own separate `helm upgrade` for the same
# release uses `--reuse-values`), so it silently resets
# `openclawIntegration.enabled` back to its chart default (false) —
# deleting the RoleBinding + declarative SA token Secret
# (openshell-sandbox-mlflow-token) that wire-rhoai-mlflow-tracing.sh had
# created. Any cached token in .rendered/rhoai-mlflow/wiring.env instantly
# becomes invalid (the backing Secret is gone), breaking mlflow-openclaw
# tracing and every verify.sh Layer 8/8b/10 MLflow API check with a 401 —
# confirmed live on a real AWS OCP deploy. Detect that wiring already
# happened (openshell-sandbox SA exists) and transparently re-wire so this
# script stays safe to re-run at any point in the deploy lifecycle, not just
# as the very first, one-shot pre-OpenShell step.
if oc get sa openshell-sandbox -n "${NAMESPACE:-openshell}" &>/dev/null; then
  step "openshell-sandbox SA already exists — re-wiring RHOAI MLflow integration"
  info "(the helm upgrade above resets openclawIntegration.enabled to false;"
  info "re-running wire-rhoai-mlflow-tracing.sh restores RBAC/token/experiment)"
  "${SCRIPT_DIR}/wire-rhoai-mlflow-tracing.sh"
fi

step "RHOAI MLflow deploy script complete"

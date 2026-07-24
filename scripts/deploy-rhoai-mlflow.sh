#!/usr/bin/env bash
#
# Deploy the minimal RHOAI-managed MLflow stack: RHOAI operator subscription
# + a DataScienceCluster with only `mlflowoperator: Managed` (everything else
# Removed) + a Postgres backend store + the MLflow CR, via charts/rhoai/.
#
# ADR-0017 findings (empirically tested, not just inferred from docs):
#   - RHOAI + this minimal MLflow, ALONE, fits comfortably on a 16 vCPU /
#     40 GiB CRC VM (~18 GiB host memory stayed free out of 62 GiB total).
#   - Combined with the REST of the OpenClaw-in-OpenShell stack (OpenShell +
#     OpenClaw sandbox, run via crc-lifecycle.sh), host free memory dropped
#     to ~11 GiB and swap engaged — functionally fine (no crashes, no pod
#     evictions) but below this project's own safety floor for keeping a
#     shared laptop's Cursor/desktop session responsive.
#   - Conclusion: this script is intentionally NOT wired into
#     crc-lifecycle.sh's combined `deploy`/`full` commands. Run it standalone
#     if you want to experiment with RHOAI MLflow on CRC, but don't also run
#     the rest of the stack alongside it for extended periods on a laptop
#     that needs to keep Cursor usable. On AWS this caveat doesn't apply.
#
# Secrets: never commits a plaintext DB password to git (AGENTS.md). If
# MLFLOW_DB_PASSWORD isn't already in secrets/secrets.env, generates one with
# `openssl rand` and appends it there for idempotency (same pattern as
# scripts/deploy-keycloak.sh / scripts/deploy-oauth2-proxy.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
CHART_DIR="${PROJECT_DIR}/charts/rhoai"

check_prereqs
detect_environment

if [[ "$CRC_MODE" == "true" ]]; then
  warn "CRC mode: RHOAI + MLflow alone fits fine here (see ADR-0017), but"
  warn "running it alongside the full stack (crc-lifecycle.sh deploy/full)"
  warn "measurably squeezes host memory below this project's Cursor-safety"
  warn "floor. Fine for a standalone experiment; not recommended combined."
fi

step "Ensuring MLFLOW_DB_PASSWORD secret exists"
SECRETS_FILE="${PROJECT_DIR}/secrets/secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  error "Secrets file not found: $SECRETS_FILE"
  error "Copy secrets/secrets.template.env to secrets/secrets.env and fill in MAAS_API_KEY first"
  exit 1
fi
set -a
source "$SECRETS_FILE"
set +a
if [[ -z "${MLFLOW_DB_PASSWORD:-}" ]]; then
  MLFLOW_DB_PASSWORD=$(openssl rand -hex 24)
  echo "MLFLOW_DB_PASSWORD=${MLFLOW_DB_PASSWORD}" >>"$SECRETS_FILE"
  info "Generated MLFLOW_DB_PASSWORD and appended to secrets/secrets.env"
else
  info "Using existing MLFLOW_DB_PASSWORD from secrets/secrets.env"
fi

step "Deploying minimal RHOAI + MLflow stack (charts/rhoai)"
info "installPlanApproval is Manual - if the operator CSV stalls, approve the InstallPlan:"
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

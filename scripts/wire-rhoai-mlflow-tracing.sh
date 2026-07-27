#!/usr/bin/env bash
#
# wire-rhoai-mlflow-tracing.sh — declarative RBAC/token/experiment
# provisioning + CA staging to point the mlflow-openclaw plugin's tracing at
# RHOAI-managed MLflow (charts/rhoai/, deployed via deploy-rhoai-mlflow.sh),
# the sole tracing backend for this project.
#
# RHOAI's MLflow operator always runs with --enable-workspaces, so every
# request must carry an Authorization: Bearer <SA token> +
# X-MLFLOW-WORKSPACE: <namespace> header, on top of TLS trust for the
# in-cluster Service (see policies/openclaw-sandbox.yaml's `tls: skip` on the
# mlflow_direct endpoint).
#
# RBAC (RoleBinding), the SA token (Secret), and MLflow experiment creation
# are all declarative Helm resources owned by charts/rhoai/mlflow/ (see its
# values.yaml openclawIntegration block and templates/openclaw-integration-*.yaml). This script's job is:
#   1. Detect the live mlflow-integration ClusterRole name (still imperative
#      by necessity — it's an operator-generated name, not something a Helm
#      template should hardcode/guess).
#   2. Re-run `helm upgrade` with openclawIntegration.enabled=true, which
#      creates/updates the RoleBinding + token Secret and runs the
#      experiment-provisioning Job as a post-upgrade hook.
#   3. Read the results back (SA token from the Secret, experiment_id from
#      the hook Job's logs) and stage them for scripts/launch-openclaw.sh.
#   4. Seed system prompts into the MLflow Prompt Registry (moved here from
#      the removed standalone-MLflow deploy step).
#
# Called unconditionally from scripts/crc-lifecycle.sh's `deploy`/`full`
# commands, right after scripts/deploy-rhoai-mlflow.sh — not an opt-in
# experiment anymore (see docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md).
#
# Prerequisites (both must already exist — this script does not create them):
#   1. RHOAI + MLflow deployed: ./scripts/deploy-rhoai-mlflow.sh
#   2. OpenShell namespace + openshell-sandbox SA deployed:
#      ./scripts/crc-lifecycle.sh deploy
#
# Outputs (written to .rendered/rhoai-mlflow/, already gitignored via
# .rendered/):
#   - service-ca.crt : OpenShift service-serving CA bundle (TLS trust for the
#     in-cluster mlflow.<ns>.svc:8443 Service)
#   - wiring.env      : RHOAI_MLFLOW_TRACKING_URI, RHOAI_MLFLOW_EXPERIMENT_ID,
#     RHOAI_MLFLOW_WORKSPACE, RHOAI_MLFLOW_SA_TOKEN, RHOAI_MLFLOW_CA_FILE —
#     consumed by scripts/launch-openclaw.sh.
#   wiring.env contains a live SA token read from the declarative Secret —
#   never commit (.rendered/ is gitignored). Unlike the previous
#   `oc create token --duration=24h`, this token does not expire on its own
#   (see the Secret's comment in openclaw-integration-rbac.yaml for the
#   rotation trade-off this implies).
set -euo pipefail
source "$(dirname "$0")/common.sh"

RHOAI_NS="redhat-ods-applications"
EXPERIMENT_NAME="openclaw-tracing"
WORKSPACE="${NAMESPACE}"
OUT_DIR="${PROJECT_DIR}/.rendered/rhoai-mlflow"
MLFLOW_CHART_DIR="${PROJECT_DIR}/charts/rhoai/mlflow"
MLFLOW_RELEASE="rhoai-mlflow"

check_prereqs
detect_environment

step "Locating mlflow-integration ClusterRole"
MLFLOW_INTEGRATION_CLUSTERROLE=$(oc get clusterroles -o name 2>/dev/null \
  | grep -i 'mlflow-integration$' | sed 's#clusterrole.rbac.authorization.k8s.io/##' | head -1)
if [[ -z "$MLFLOW_INTEGRATION_CLUSTERROLE" ]]; then
  error "No ClusterRole matching '*mlflow-integration' found."
  error "Is RHOAI MLflow deployed? Run ./scripts/deploy-rhoai-mlflow.sh first."
  exit 1
fi
info "ClusterRole: ${MLFLOW_INTEGRATION_CLUSTERROLE}"

step "Verifying OpenShell namespace + openshell-sandbox SA exist"
if ! oc get ns "$NAMESPACE" &>/dev/null; then
  error "Namespace '$NAMESPACE' not found."
  error "Run ./scripts/crc-lifecycle.sh deploy first."
  exit 1
fi
if ! oc get sa openshell-sandbox -n "$NAMESPACE" &>/dev/null; then
  error "ServiceAccount 'openshell-sandbox' not found in namespace '$NAMESPACE'."
  error "Run ./scripts/crc-lifecycle.sh deploy first."
  exit 1
fi
info "Namespace '$NAMESPACE' and SA 'openshell-sandbox' present"

step "Enabling openclawIntegration (RoleBinding + token Secret + experiment Job) via helm upgrade"
if ! helm status "$MLFLOW_RELEASE" &>/dev/null; then
  error "Helm release '${MLFLOW_RELEASE}' not found. Run ./scripts/deploy-rhoai-mlflow.sh first."
  exit 1
fi
# NOTE: deliberately NOT using --reuse-values. Helm's --reuse-values reuses
# the *previous release's fully-computed* values as the new base — for keys
# that were never part of any earlier revision's values.yaml (like this
# chart's whole openclawIntegration block, added after this project's first
# `deploy-rhoai-mlflow.sh` run), that base has no entry at all, so
# --reuse-values + a partial --set silently drops every openclawIntegration
# sub-key not explicitly passed here (confirmed live: serviceAccountName
# came back empty, breaking the token Secret's name/annotation). Passing the
# chart's values.yaml explicitly with -f avoids this class of bug entirely.
SECRETS_FILE="${PROJECT_DIR}/secrets/secrets.env"
if [[ -f "$SECRETS_FILE" ]]; then
  set -a; source "$SECRETS_FILE"; set +a
fi
if [[ -z "${MLFLOW_DB_PASSWORD:-}" ]]; then
  error "MLFLOW_DB_PASSWORD not found in ${SECRETS_FILE}. Run ./scripts/deploy-rhoai-mlflow.sh first."
  exit 1
fi
helm upgrade "$MLFLOW_RELEASE" "$MLFLOW_CHART_DIR" \
  -f "${MLFLOW_CHART_DIR}/values.yaml" \
  --set-string database.password="${MLFLOW_DB_PASSWORD}" \
  --set-string postgresql.password="${MLFLOW_DB_PASSWORD}" \
  --set openclawIntegration.enabled=true \
  --set openclawIntegration.namespace="${NAMESPACE}" \
  --set-string openclawIntegration.clusterRoleName="${MLFLOW_INTEGRATION_CLUSTERROLE}" \
  --set openclawIntegration.experimentName="${EXPERIMENT_NAME}" \
  --wait --timeout 2m
pass "RoleBinding + SA token Secret applied, experiment-provisioning Job ran as a post-upgrade hook"

step "Reading experiment_id from the hook Job's logs"
RELEASE_REVISION=$(helm status "$MLFLOW_RELEASE" -o json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")
JOB_NAME="openclaw-mlflow-experiment-${RELEASE_REVISION}"
oc -n "$NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout=60s
JOB_LOG=$(oc -n "$NAMESPACE" logs "job/${JOB_NAME}" 2>/dev/null || true)
EXPERIMENT_ID=$(echo "$JOB_LOG" | grep -oP 'experiment_id=\K[0-9]+' | head -1)
if [[ -z "$EXPERIMENT_ID" ]]; then
  error "Could not read experiment_id from job/${JOB_NAME} logs. Output was:"
  error "$JOB_LOG"
  exit 1
fi
pass "MLflow experiment ready: ${EXPERIMENT_NAME} (id=${EXPERIMENT_ID})"

step "Reading SA token from the declarative Secret"
mkdir -p "$OUT_DIR"
SA_TOKEN=$(oc get secret "openshell-sandbox-mlflow-token" -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
if [[ -z "$SA_TOKEN" ]]; then
  error "Could not read token from Secret 'openshell-sandbox-mlflow-token' in namespace '${NAMESPACE}'"
  error "The token controller may not have populated it yet — retry in a few seconds."
  exit 1
fi
info "Token read from Secret (does not expire — see rotation note in openclaw-integration-rbac.yaml)"

# NOTE: deliberately the short 3-label Service DNS form
# (mlflow.<ns>.svc), NOT the FQDN (mlflow.<ns>.svc.cluster.local). The
# OpenShell sandbox proxy's policy match for the `rhoai_mlflow_direct`
# endpoint (policies/openclaw-sandbox.yaml) is keyed on the exact host
# string configured there, which is the short form. Confirmed live: an
# identical request (same token, same --cacert, same everything) gets a
# clean 200 against the short form and a hard `CONNECT tunnel failed,
# response 403` against the FQDN — the proxy's CONNECT-tunnel handler
# doesn't do suffix/DNS-equivalence matching, so the FQDN simply never
# matches the policy and falls through to default-deny. Using the FQDN
# here silently breaks tls:skip (and mlflow tracing) even though the CA
# bundle, token, and RBAC are all otherwise correct — this bit us for a
# full session before being traced back to this hostname mismatch (see
# docs/adrs/ADR-0017-rhoai-mlflow-scope.md's 2026-07-25 entries).
RHOAI_MLFLOW_SVC_URL="https://mlflow.${RHOAI_NS}.svc:8443"
info "In-cluster Service (sandbox runtime): ${RHOAI_MLFLOW_SVC_URL}"

step "Extracting openshift-service-ca.crt for TLS trust"
oc get configmap openshift-service-ca.crt -n "$NAMESPACE" \
  -o jsonpath='{.data.service-ca\.crt}' > "${OUT_DIR}/service-ca.crt" 2>/dev/null || true
if [[ -s "${OUT_DIR}/service-ca.crt" ]]; then
  pass "CA bundle extracted to ${OUT_DIR}/service-ca.crt"
else
  fail "Could not extract openshift-service-ca.crt from namespace '${NAMESPACE}' — it should exist by default in every OCP namespace"
  exit 1
fi

step "Writing wiring facts for scripts/launch-openclaw.sh"
cat > "${OUT_DIR}/wiring.env" <<EOF
RHOAI_MLFLOW_TRACKING_URI=${RHOAI_MLFLOW_SVC_URL}
RHOAI_MLFLOW_EXPERIMENT_ID=${EXPERIMENT_ID}
RHOAI_MLFLOW_WORKSPACE=${WORKSPACE}
RHOAI_MLFLOW_SA_TOKEN=${SA_TOKEN}
RHOAI_MLFLOW_CA_FILE=${OUT_DIR}/service-ca.crt
EOF
info "Wiring facts written to ${OUT_DIR}/wiring.env"
warn "wiring.env contains a live SA token — never commit (.rendered/ is gitignored)"

step "Seeding system prompts into MLflow Prompt Registry"
# Deliberately NOT passing MLFLOW_URL: this script runs on the host (not
# inside the sandbox/cluster network), so it needs the external Route, not
# the in-cluster Service URL (RHOAI_MLFLOW_SVC_URL) — seed-mlflow-prompts.sh
# already auto-detects that Route when MLFLOW_URL is unset.
MLFLOW_TRACKING_TOKEN="${SA_TOKEN}" \
MLFLOW_WORKSPACE="${WORKSPACE}" \
MLFLOW_EXPERIMENT_ID="${EXPERIMENT_ID}" \
  "${SCRIPT_DIR}/prompt-registry/seed-mlflow-prompts.sh" \
  && pass "System prompts seeded into RHOAI MLflow" \
  || warn "Could not seed prompts (run scripts/prompt-registry/seed-mlflow-prompts.sh manually — see its usage comment for the required env vars)"

step "wire-rhoai-mlflow-tracing.sh complete"
info "Next: ./scripts/launch-openclaw.sh"

#!/usr/bin/env bash
# Phase 8: Deploy observability stack for agent tracing.
#
# Components (standalone, no operator dependency):
#   - Grafana Tempo (trace storage, local backend)
#   - OpenTelemetry Collector (OTLP receiver → Tempo + spanmetrics)
#   - MLflow Tracking Server (SQLite + PVC)
#
# Prerequisites:
#   - OCP cluster access
#   - OpenShell deployed (scripts/deploy-openshell.sh)
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment
render_all_templates
OBS_NAMESPACE="observability"

# ── Step 1: Create namespace ──────────────────────────────────────────────────

step "Creating observability namespace"
oc apply -f "${PROJECT_DIR}/manifests/observability/namespace.yaml"
pass "Namespace ${OBS_NAMESPACE} ready"

# ── Step 2: Deploy Tempo ──────────────────────────────────────────────────────

step "Deploying Tempo (trace storage)"
oc apply -f "${PROJECT_DIR}/manifests/observability/tempo.yaml"

oc -n "$OBS_NAMESPACE" rollout status deployment/tempo --timeout=120s 2>/dev/null \
  && pass "Tempo deployment ready" \
  || fail "Tempo deployment not ready"

# ── Step 3: Deploy OTel Collector ─────────────────────────────────────────────

step "Deploying OpenTelemetry Collector"
oc apply -f "${PROJECT_DIR}/manifests/observability/otel-collector.yaml"

oc -n "$OBS_NAMESPACE" rollout status deployment/otel-collector --timeout=120s 2>/dev/null \
  && pass "OTel Collector deployment ready" \
  || fail "OTel Collector deployment not ready"

# ── Step 4: Deploy MLflow ─────────────────────────────────────────────────────

step "Deploying MLflow Tracking Server"
oc apply -f "${RENDERED_DIR}/observability/mlflow.yaml"

oc -n "$OBS_NAMESPACE" rollout status deployment/mlflow --timeout=120s 2>/dev/null \
  && pass "MLflow deployment ready" \
  || fail "MLflow deployment not ready"

# ── Step 4b: Create MLflow experiment for agent traces ────────────────────

step "Creating MLflow experiment for agent traces"

MLFLOW_INTERNAL="http://mlflow.${OBS_NAMESPACE}.svc:5000"

retries=0
while [[ $retries -lt 10 ]]; do
  EXP_RESP=$(oc -n "$OBS_NAMESPACE" exec deployment/mlflow -- \
    python3 -c "
import urllib.request, urllib.error, json
try:
    req = urllib.request.Request('http://localhost:5000/api/2.0/mlflow/experiments/get-by-name?experiment_name=openclaw-agent-traces')
    with urllib.request.urlopen(req, timeout=5) as r:
        data = json.loads(r.read())
        print('EXISTS:' + data['experiment']['experiment_id'])
except urllib.error.HTTPError:
    req = urllib.request.Request('http://localhost:5000/api/2.0/mlflow/experiments/create',
        data=json.dumps({'name': 'openclaw-agent-traces'}).encode(),
        headers={'Content-Type': 'application/json'}, method='POST')
    with urllib.request.urlopen(req, timeout=5) as r:
        data = json.loads(r.read())
        print('CREATED:' + data['experiment_id'])
except Exception as e:
    print('ERROR:' + str(e))
" 2>/dev/null || echo "ERROR:exec-failed")

  if echo "$EXP_RESP" | grep -qE "EXISTS:|CREATED:"; then
    EXP_ID=$(echo "$EXP_RESP" | grep -oE "(EXISTS|CREATED):[0-9]+" | cut -d: -f2)
    pass "MLflow experiment 'openclaw-agent-traces' ready (id=${EXP_ID})"
    break
  fi
  sleep 3
  retries=$((retries + 1))
done

if [[ $retries -ge 10 ]]; then
  warn "Could not create MLflow experiment, using default (id=0)"
  EXP_ID="0"
fi

# ── Step 4b2: Fix artifact URI scheme (constraint #12) ───────────────────────
# MLflow's JS client (@mlflow/core) requires mlflow-artifacts:// URIs to upload
# trace data (span hierarchy, tool calls). Without --serve-artifacts and the
# correct URI scheme, traces appear in the UI with only raw JSON input/output
# and no span timeline. See docs/constraints.md #12.

step "Ensuring MLflow artifact URI scheme (mlflow-artifacts:/)"
oc -n "$OBS_NAMESPACE" exec deployment/mlflow -- python3 -c "
import sqlite3
conn = sqlite3.connect('/mlflow/mlflow.db')
c = conn.cursor()
c.execute(\"\"\"UPDATE experiments SET artifact_location = 'mlflow-artifacts:/' || experiment_id
              WHERE artifact_location LIKE '/mlflow/artifacts/%'\"\"\")
exp_fixed = c.rowcount
c.execute(\"\"\"UPDATE trace_tags
              SET value = REPLACE(value, '/mlflow/artifacts/', 'mlflow-artifacts:/')
              WHERE key = 'mlflow.artifactLocation' AND value LIKE '/mlflow/artifacts/%'\"\"\")
tag_fixed = c.rowcount
conn.commit()
conn.close()
print(f'experiments={exp_fixed} traces={tag_fixed}')
" 2>/dev/null && pass "Artifact URI scheme verified" \
  || warn "Could not verify artifact URI scheme (non-blocking)"

# ── Step 4c: Seed system prompts into MLflow Prompt Registry ─────────────────

step "Seeding system prompts into MLflow Prompt Registry"
MLFLOW_ROUTE=$(oc get route mlflow -n "$OBS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
MLFLOW_URL="https://${MLFLOW_ROUTE}" "${PROJECT_DIR}/scripts/seed-mlflow-prompts.sh" \
  && pass "System prompts seeded into MLflow" \
  || warn "Could not seed prompts (MLflow may not be fully ready; run scripts/seed-mlflow-prompts.sh manually)"

# ── Step 5: Update sandbox network policy ─────────────────────────────────────

step "Checking sandbox network policy for observability endpoints"

POLICY_FILE="${PROJECT_DIR}/policies/openclaw-sandbox.yaml"
if grep -q "otel-collector" "$POLICY_FILE" 2>/dev/null; then
  pass "Network policy already includes observability endpoints"
else
  warn "Network policy does not include observability endpoints — update policies/openclaw-sandbox.yaml"
fi

# ── Step 6: Configure OpenClaw for tracing ────────────────────────────────────

step "Configuring sandbox with OTEL environment variables"

COLLECTOR_SVC="otel-collector.${OBS_NAMESPACE}.svc"
MLFLOW_SVC="mlflow.${OBS_NAMESPACE}.svc"

export OPENSHELL_GATEWAY_INSECURE=true
printf 'cat > /sandbox/workspace/.env << '"'"'EOF'"'"'
export OTEL_EXPORTER_OTLP_ENDPOINT=http://'"${COLLECTOR_SVC}"':4318
export OTEL_SERVICE_NAME=openclaw-agent
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export MLFLOW_TRACKING_URI=http://'"${MLFLOW_SVC}"':5000
EOF
exit
' | timeout 15 openshell sandbox connect openclaw-gw 2>&1 | grep -v "WARN\|TLS" || true

pass "OTEL env vars written to sandbox workspace"

# ── Step 7: Verify pipeline ───────────────────────────────────────────────────

step "Verifying trace pipeline (send test trace)"

oc -n "$OBS_NAMESPACE" port-forward svc/otel-collector 34318:4318 &>/dev/null &
PF_PID=$!
sleep 2

TRACE_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
NOW_NS=$(python3 -c "import time; print(int(time.time() * 1e9))")
END_NS=$(python3 -c "import time; print(int((time.time()+1) * 1e9))")
SPAN_ID=$(python3 -c "import os; print(os.urandom(8).hex())")

RESP=$(curl -s -X POST http://localhost:34318/v1/traces \
  -H "Content-Type: application/json" \
  -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"deploy-test\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"test\"},\"spans\":[{\"traceId\":\"${TRACE_ID}\",\"spanId\":\"${SPAN_ID}\",\"name\":\"deploy-verify\",\"kind\":1,\"startTimeUnixNano\":\"${NOW_NS}\",\"endTimeUnixNano\":\"${END_NS}\",\"status\":{\"code\":1}}]}]}]}" 2>/dev/null || echo "error")

kill $PF_PID 2>/dev/null || true

if echo "$RESP" | grep -q "partialSuccess"; then
  pass "Test trace accepted by OTel Collector"
else
  fail "Could not send test trace: ${RESP}"
fi

sleep 3

VERIFY=$(oc -n "$OBS_NAMESPACE" exec deployment/tempo -- \
  wget -qO- "http://localhost:3200/api/traces/${TRACE_ID}" 2>/dev/null || echo "{}")

if echo "$VERIFY" | grep -q "deploy-verify"; then
  pass "Test trace stored and retrievable in Tempo"
else
  warn "Trace not yet visible (Tempo may need more ingestion time)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

MLFLOW_ROUTE=$(oc get route mlflow -n "$OBS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

step "Phase 8 deployment complete"
echo ""
info "Components:"
info "  Tempo:          tempo.${OBS_NAMESPACE}.svc:3200 (query), :4317 (OTLP gRPC)"
info "  OTel Collector: otel-collector.${OBS_NAMESPACE}.svc:4317 (gRPC), :4318 (HTTP)"
info "  MLflow:         https://${MLFLOW_ROUTE}"
echo ""
info "Query traces:"
info "  oc -n ${OBS_NAMESPACE} exec deployment/tempo -- wget -qO- 'http://localhost:3200/api/search?limit=5'"
echo ""
info "Test script:"
info "  bash scripts/test-tracing.sh"

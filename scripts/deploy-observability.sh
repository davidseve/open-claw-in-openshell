#!/usr/bin/env bash
# Phase 8: Deploy the infrastructure-observability stack (Tempo + OTel
# Collector) — logs and metrics only, no traces (see ADR-0014 Problem 8 /
# OTEL_TRACES_EXPORTER=none: agent traces have always gone exclusively
# through the mlflow-openclaw plugin, never through this pipeline).
#
# Components (standalone, no operator dependency):
#   - Grafana Tempo (trace storage, local backend — kept for potential future
#     infrastructure-level tracing; currently receives no traffic since
#     OTEL_TRACES_EXPORTER=none)
#   - OpenTelemetry Collector (OTLP receiver → Tempo + spanmetrics)
#
# Agent traces (rich AGENT/LLM hierarchy, full I/O) go to RHOAI-managed
# MLflow instead — see scripts/deploy-rhoai-mlflow.sh,
# scripts/wire-rhoai-mlflow-tracing.sh, and
# docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md. The standalone
# ghcr.io/mlflow/mlflow deployment this script used to provision here was
# removed entirely (no plain-HTTP, no-auth fallback left in this project).
#
# Prerequisites:
#   - OCP cluster access
#   - OpenShell deployed (scripts/deploy-openshell.sh)
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment
OBS_NAMESPACE="observability"

# ── Step 1-3: Deploy (Helm) ────────────────────────────────────────────────────
# --wait blocks until both Deployments' pods are Ready (Helm's own readiness
# gate covers what separate `oc apply` + `rollout status` calls used to do).

step "Deploying infrastructure observability (Tempo + OTel Collector, Helm)"
helm upgrade --install observability "${PROJECT_DIR}/charts/observability" \
  --namespace "$OBS_NAMESPACE" --create-namespace \
  --set namespace="${OBS_NAMESPACE}" \
  --wait --timeout 180s
pass "Tempo + OTel Collector deployments ready"

# ── Step 4: Verify sandbox network policy ─────────────────────────────────────

step "Checking sandbox network policy for observability endpoints"

POLICY_FILE="${PROJECT_DIR}/policies/openclaw-sandbox.yaml"
if grep -q "otel-collector" "$POLICY_FILE" 2>/dev/null; then
  pass "Network policy already includes observability endpoints"
else
  warn "Network policy does not include observability endpoints — update policies/openclaw-sandbox.yaml"
fi

# ── Step 5: Verify pipeline ───────────────────────────────────────────────────

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

step "Phase 8 deployment complete"
echo ""
info "Components:"
info "  Tempo:          tempo.${OBS_NAMESPACE}.svc:3200 (query), :4317 (OTLP gRPC)"
info "  OTel Collector: otel-collector.${OBS_NAMESPACE}.svc:4317 (gRPC), :4318 (HTTP)"
info "  Agent traces:   RHOAI MLflow (run scripts/deploy-rhoai-mlflow.sh + scripts/wire-rhoai-mlflow-tracing.sh — see cluster-lifecycle.sh, wired in automatically)"
echo ""
info "Query traces:"
info "  oc -n ${OBS_NAMESPACE} exec deployment/tempo -- wget -qO- 'http://localhost:3200/api/search?limit=5'"
echo ""
info "Test script:"
info "  bash scripts/test-tracing.sh"

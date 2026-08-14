#!/usr/bin/env bash
# Diagnostic tool (not part of the standard verify.sh flow): send a
# realistic synthetic agent trace straight to the OTel Collector and confirm
# it lands in Tempo. Useful for debugging the OTel/Tempo pipeline in
# isolation. RHOAI MLflow health/API checks are NOT duplicated here — see
# scripts/verify.sh Layer 8 for those.
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs

OBS_NAMESPACE="observability"
COLLECTOR_SVC="otel-collector.${OBS_NAMESPACE}.svc"

step "Testing observability pipeline"

# Generate unique trace/span IDs
TRACE_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
PARENT_SPAN_ID=$(python3 -c "import os; print(os.urandom(8).hex())")
CHILD_SPAN_1=$(python3 -c "import os; print(os.urandom(8).hex())")
CHILD_SPAN_2=$(python3 -c "import os; print(os.urandom(8).hex())")
CHILD_SPAN_3=$(python3 -c "import os; print(os.urandom(8).hex())")

NOW_NS=$(python3 -c "import time; print(int(time.time() * 1e9))")
AFTER_1=$(python3 -c "import time; print(int((time.time()+0.5) * 1e9))")
AFTER_2=$(python3 -c "import time; print(int((time.time()+1.0) * 1e9))")
AFTER_3=$(python3 -c "import time; print(int((time.time()+2.0) * 1e9))")
AFTER_4=$(python3 -c "import time; print(int((time.time()+3.0) * 1e9))")

info "Trace ID: ${TRACE_ID}"
info "Sending realistic agent trace (parent + 3 child spans)..."

# Port-forward to OTel Collector
oc -n "$OBS_NAMESPACE" port-forward svc/otel-collector 14318:4318 &>/dev/null &
PF_PID=$!
sleep 2

PAYLOAD=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key":"service.name","value":{"stringValue":"openclaw-agent"}},
        {"key":"service.version","value":{"stringValue":"2026.3.11"}},
        {"key":"deployment.environment","value":{"stringValue":"ocp-sandbox"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name":"openclaw.agent","version":"1.0.0"},
      "spans": [
        {
          "traceId": "${TRACE_ID}",
          "spanId": "${PARENT_SPAN_ID}",
          "name": "agent.turn",
          "kind": 2,
          "startTimeUnixNano": "${NOW_NS}",
          "endTimeUnixNano": "${AFTER_4}",
          "attributes": [
            {"key":"gen_ai.system","value":{"stringValue":"openclaw"}},
            {"key":"gen_ai.operation.name","value":{"stringValue":"agent_turn"}},
            {"key":"openclaw.agent.model","value":{"stringValue":"maas/claude-sonnet-4-6"}},
            {"key":"openclaw.agent.sandbox","value":{"stringValue":"openclaw-gw"}}
          ],
          "status": {"code": 1}
        },
        {
          "traceId": "${TRACE_ID}",
          "spanId": "${CHILD_SPAN_1}",
          "parentSpanId": "${PARENT_SPAN_ID}",
          "name": "llm.chat_completion",
          "kind": 3,
          "startTimeUnixNano": "${NOW_NS}",
          "endTimeUnixNano": "${AFTER_2}",
          "attributes": [
            {"key":"gen_ai.system","value":{"stringValue":"anthropic"}},
            {"key":"gen_ai.operation.name","value":{"stringValue":"chat"}},
            {"key":"gen_ai.request.model","value":{"stringValue":"claude-sonnet-4-6"}},
            {"key":"gen_ai.response.model","value":{"stringValue":"claude-sonnet-4-6-20260514"}},
            {"key":"gen_ai.usage.input_tokens","value":{"intValue":"1250"}},
            {"key":"gen_ai.usage.output_tokens","value":{"intValue":"380"}}
          ],
          "status": {"code": 1}
        },
        {
          "traceId": "${TRACE_ID}",
          "spanId": "${CHILD_SPAN_2}",
          "parentSpanId": "${PARENT_SPAN_ID}",
          "name": "tool.execute",
          "kind": 2,
          "startTimeUnixNano": "${AFTER_2}",
          "endTimeUnixNano": "${AFTER_3}",
          "attributes": [
            {"key":"openclaw.tool.name","value":{"stringValue":"bash"}},
            {"key":"openclaw.tool.args","value":{"stringValue":"ls -la /sandbox/workspace"}},
            {"key":"openclaw.tool.exit_code","value":{"intValue":"0"}}
          ],
          "status": {"code": 1}
        },
        {
          "traceId": "${TRACE_ID}",
          "spanId": "${CHILD_SPAN_3}",
          "parentSpanId": "${PARENT_SPAN_ID}",
          "name": "llm.chat_completion",
          "kind": 3,
          "startTimeUnixNano": "${AFTER_3}",
          "endTimeUnixNano": "${AFTER_4}",
          "attributes": [
            {"key":"gen_ai.system","value":{"stringValue":"anthropic"}},
            {"key":"gen_ai.operation.name","value":{"stringValue":"chat"}},
            {"key":"gen_ai.request.model","value":{"stringValue":"claude-sonnet-4-6"}},
            {"key":"gen_ai.usage.input_tokens","value":{"intValue":"2100"}},
            {"key":"gen_ai.usage.output_tokens","value":{"intValue":"150"}}
          ],
          "status": {"code": 1}
        }
      ]
    }]
  }]
}
EOF
)

RESPONSE=$(curl -s -X POST http://localhost:14318/v1/traces \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

kill $PF_PID 2>/dev/null || true

if echo "$RESPONSE" | grep -q "partialSuccess"; then
  pass "Test trace sent successfully"
else
  fail "Failed to send trace: ${RESPONSE}"
fi

# Wait for Tempo to ingest
info "Waiting 5s for Tempo ingestion..."
sleep 5

# Query Tempo for the trace
step "Querying Tempo for trace"
SEARCH_RESULT=$(oc -n "$OBS_NAMESPACE" exec deployment/tempo -- \
  wget -qO- "http://localhost:3200/api/search?q=resource.service.name%3Dopenclaw-agent&limit=5" 2>/dev/null || echo "{}")

TRACE_COUNT=$(echo "$SEARCH_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('traces',[])))" 2>/dev/null || echo "0")

if [[ "$TRACE_COUNT" -ge 1 ]]; then
  pass "Found ${TRACE_COUNT} trace(s) in Tempo for service 'openclaw-agent'"
else
  warn "No traces found yet (result: ${SEARCH_RESULT:0:200})"
fi

# Verify specific trace
TRACE_DETAIL=$(oc -n "$OBS_NAMESPACE" exec deployment/tempo -- \
  wget -qO- "http://localhost:3200/api/traces/${TRACE_ID}" 2>/dev/null || echo "{}")

SPAN_COUNT=$(echo "$TRACE_DETAIL" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    spans = sum(len(ss.get('spans',[])) for b in d.get('batches',[]) for ss in b.get('scopeSpans',[]))
    print(spans)
except:
    print(0)
" 2>/dev/null || echo "0")

if [[ "$SPAN_COUNT" -ge 4 ]]; then
  pass "Trace ${TRACE_ID} contains ${SPAN_COUNT} spans (expected 4)"
else
  warn "Trace contains ${SPAN_COUNT} spans (expected 4)"
fi

step "Observability pipeline test complete"
echo ""
info "Summary:"
info "  Tempo traces: ${TRACE_COUNT} trace(s) found"
info "  Span count: ${SPAN_COUNT}/4 spans verified"
info "  Tempo query: oc -n ${OBS_NAMESPACE} exec deployment/tempo -- wget -qO- 'http://localhost:3200/api/search?limit=5'"
info "  RHOAI MLflow health/API checks live in scripts/verify.sh (Layer 8), not here"

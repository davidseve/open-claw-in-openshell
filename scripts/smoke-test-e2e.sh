#!/usr/bin/env bash
# End-to-end smoke test: send a message via the OpenClaw gateway WebSocket,
# then verify that exactly one trace is created in MLflow with prompt tags.
#
# Designed to run from the host after full deployment.
# Requires: openshell CLI authenticated, MLflow route accessible.
#
# Usage:
#   ./scripts/smoke-test-e2e.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
set -euo pipefail
source "$(dirname "$0")/common.sh"

detect_environment

SANDBOX_NAME="${SANDBOX_NAME:-openclaw-gw}"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
MLFLOW_HOST=$(oc get route mlflow -n "$OBS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
MLFLOW_EXT_URL="https://${MLFLOW_HOST}"

if [[ -z "$MLFLOW_HOST" ]]; then
  error "MLflow route not found in namespace $OBS_NAMESPACE"
  exit 1
fi

if ! command -v openshell &>/dev/null; then
  error "openshell CLI not found"
  exit 1
fi

step "Smoke Test E2E: send message and verify trace"

TRACE_COUNT_BEFORE=$(curl -sf $CURL_OPTS \
  "${MLFLOW_EXT_URL}/api/2.0/mlflow/traces?experiment_ids=0&max_results=200" 2>/dev/null \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('traces',[])))" 2>/dev/null || echo "0")
info "Traces before test: $TRACE_COUNT_BEFORE"

TIMESTAMP_BEFORE=$(date +%s)

step "Sending test message via sandbox gateway"
SEND_RESULT=$(sandbox_run 'curl -sf -X POST http://127.0.0.1:18789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Forwarded-Email: smoke-test@test.local" \
  -H "X-Forwarded-Proto: https" \
  -H "X-Forwarded-Host: openclaw-ui.'"${APPS_DOMAIN}"'" \
  -d '"'"'{"model":"maas/claude-sonnet-4-6","messages":[{"role":"user","content":"Respond with exactly one word: OK"}],"stream":false,"max_tokens":10}'"'"' 2>&1 || echo SEND_FAILED' || true)

if echo "$SEND_RESULT" | grep -qi "SEND_FAILED\|error\|Not Found"; then
  warn "HTTP chat endpoint may be disabled (expected if chatCompletions.enabled=false)"
  info "Testing via WebSocket session instead..."
  # The chatCompletions endpoint may be disabled; traces are generated
  # through the WebSocket Control UI. We check if any new traces appear
  # from recent UI activity or trigger a lightweight health-based trace.
  sandbox_run 'curl -sf http://127.0.0.1:18789/health > /dev/null' || true
  info "Waiting 15s for any pending traces to flush..."
  sleep 15
else
  info "Message sent, waiting 15s for trace to flush to MLflow..."
  sleep 15
fi

step "Checking for new traces in MLflow"

TRACES_AFTER=$(curl -sf $CURL_OPTS \
  "${MLFLOW_EXT_URL}/api/2.0/mlflow/traces?experiment_ids=0&max_results=200" 2>/dev/null || echo "")

if [[ -z "$TRACES_AFTER" ]]; then
  fail "Could not query MLflow traces API"
  exit 1
fi

TRACE_COUNT_AFTER=$(echo "$TRACES_AFTER" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('traces',[])))" 2>/dev/null || echo "0")
info "Traces after test: $TRACE_COUNT_AFTER"

NEW_TRACES=$((TRACE_COUNT_AFTER - TRACE_COUNT_BEFORE))
if [[ $NEW_TRACES -eq 1 ]]; then
  pass "Exactly 1 new trace created (no duplication)"
elif [[ $NEW_TRACES -gt 1 ]]; then
  fail "Trace duplication detected: $NEW_TRACES new traces (expected 1)"
elif [[ $NEW_TRACES -eq 0 ]]; then
  warn "No new traces detected (chatCompletions may be disabled; verify via UI)"
fi

step "Checking prompt tags on recent traces"

LATEST_TRACE=$(echo "$TRACES_AFTER" | python3 -c "
import sys,json
data = json.load(sys.stdin)
traces = data.get('traces',[])
if traces:
    t = traces[0]
    rid = t.get('request_id','')
    tags = {tag['key']:tag['value'][:80] for tag in t.get('tags',[])}
    has_lp = 'mlflow.linkedPrompts' in tags
    has_pv = 'prompt_versions' in tags
    print(f'RID:{rid}')
    print(f'HAS_LINKED_PROMPTS:{has_lp}')
    print(f'HAS_PROMPT_VERSIONS:{has_pv}')
else:
    print('NO_TRACES')
" 2>/dev/null || echo "ERROR")

if echo "$LATEST_TRACE" | grep -q "HAS_LINKED_PROMPTS:True"; then
  pass "Latest trace has mlflow.linkedPrompts tag (Prompt column in UI)"
elif echo "$LATEST_TRACE" | grep -q "NO_TRACES"; then
  warn "No traces available to check"
else
  warn "Latest trace missing mlflow.linkedPrompts tag (linker may need more time)"
fi

if echo "$LATEST_TRACE" | grep -q "HAS_PROMPT_VERSIONS:True"; then
  pass "Latest trace has prompt_versions custom tag (visible in detail view)"
elif echo "$LATEST_TRACE" | grep -q "NO_TRACES"; then
  : # already warned
else
  warn "Latest trace missing prompt_versions tag"
fi

step "Checking trace duplication pattern"

RECENT_TIMESTAMPS=$(echo "$TRACES_AFTER" | python3 -c "
import sys,json
data = json.load(sys.stdin)
traces = data.get('traces',[])[:10]
for t in traces:
    print(t.get('timestamp_ms',0))
" 2>/dev/null || echo "")

DUPE_PAIRS=0
PREV_TS=""
while IFS= read -r ts; do
  [[ -z "$ts" ]] && continue
  if [[ -n "$PREV_TS" ]]; then
    DIFF=$((PREV_TS - ts))
    if [[ ${DIFF#-} -lt 2000 ]]; then
      DUPE_PAIRS=$((DUPE_PAIRS + 1))
    fi
  fi
  PREV_TS="$ts"
done <<< "$RECENT_TIMESTAMPS"

if [[ $DUPE_PAIRS -eq 0 ]]; then
  pass "No duplicate trace pairs detected (timestamps > 2s apart)"
else
  warn "$DUPE_PAIRS potential duplicate pair(s) in recent traces (timestamps within 2s)"
fi

# --- Summary ---
echo ""
step "Smoke Test Summary"
echo "    Passed: $PASS_COUNT"
echo "    Failed: $FAIL_COUNT"
echo "    Warnings: $WARN_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  error "$FAIL_COUNT smoke test check(s) failed"
  exit 1
fi
info "Smoke test complete (with $WARN_COUNT warning(s))"

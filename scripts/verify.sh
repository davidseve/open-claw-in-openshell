#!/usr/bin/env bash
# =============================================================================
# verify.sh — Validate the full OpenClaw-in-OpenShell deployment
# =============================================================================
#
# This script verifies every layer of the deployment stack, from OCP infra
# to LLM connectivity to MLflow trace generation to UI access.
#
# Each check documents:
#   - WHAT it verifies
#   - WHY this check exists (what failure it catches)
#   - HOW to fix if it fails
#
# Exit codes:
#   0 = all checks passed (warnings are informational)
#   1 = at least one FAIL
#
# PROFILES (VERIFY_PROFILE env var):
#   full  (default) — every check below, including the slow/deep ones
#         (synthetic OTel->Tempo trace round-trip, MLflow Prompt Registry
#         deep checks, Playwright browser UI test). What CI/`cluster-lifecycle.sh
#         full` runs.
#   smoke — the fast, essential subset (infra/pods/routes/CLI/security/
#         gateway health/LLM proxy connectivity) that finishes in seconds,
#         for a quick "is anything obviously broken" check while iterating.
#         Run with: VERIFY_PROFILE=smoke ./scripts/verify.sh
#
# VERIFICATION ARCHITECTURE:
#
#   Layer 1:  OCP infrastructure (CRDs, namespace, SCC, PKI secrets)
#   Layer 1b: Keycloak OIDC (pod, discovery endpoint)
#   Layer 2:  OpenShell gateway (pod, route, CLI, provider)
#   Layer 3:  Sandbox existence and readiness
#   Layer 4:  Security (identity, egress, IMDS, sudo, DNS, Landlock,
#             credentials, /etc/shadow) — all via sandbox_run, NOT via LLM chat
#   Layer 5:  OpenClaw gateway health (/health, config, chatCompletions, tools.deny)
#   Layer 5b: LLM connectivity (Node.js binary path, fetch(), proxy denials —
#             see docs/constraints.md #17 for why the end-to-end chat +
#             trace checks were removed; Layer 9 Playwright covers that path)
#   Layer 7b: External access (service route, oauth2-proxy OIDC)
#   Layer 8:  Observability stack (Tempo, OTel Collector) + RHOAI MLflow infra
#   Layer 8b: MLflow Prompt Registry (prompts, aliases, manifest, linker)
#   Layer 9:  Control UI (Playwright — OpenClaw chat E2E + jailbreak/exfiltration
#             tests via security-tests; deterministic sandbox policy is Layer 4)
#   Layer 10: MLflow traces + Prompt tags (API) and MLflow UI (Playwright)
#             — runs AFTER Layer 9 so E2E chat traces exist first
#
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AGENT_RUN_STARTED=""
if [[ -f "${SCRIPT_DIR}/lib/agent-run.sh" ]]; then
  # shellcheck source=scripts/lib/agent-run.sh
  source "${SCRIPT_DIR}/lib/agent-run.sh"
  _AGENT_RUN_STARTED="$(agent_run_now)"
fi

NAMESPACE="${NAMESPACE:-openshell2}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw-gw2}"
VERIFY_PROFILE="${VERIFY_PROFILE:-full}"

detect_environment
info "Verification profile: ${VERIFY_PROFILE} (set VERIFY_PROFILE=smoke for the fast subset)"

# The openshell CLI's "active gateway" is local machine state shared across
# every project driving it from this same host (agentops-example's "ocp"
# alias, this project's own $GATEWAY_NAME, etc.). Every `openshell
# status`/`sandbox ...` check below implicitly targets whatever gateway is
# currently active, not necessarily this project's own — re-select
# unconditionally so this script's result doesn't depend on which project's
# tooling last ran in this terminal/session. See
# docs/adrs/ADR-0020-shared-cluster-coexistence.md.
#
# OIDC access tokens expire (~5m). Without a refresh, Layer 3/4 sandbox_run
# checks look like "sandbox not found" even when the pod is Ready. Refresh
# here (password grant only — no Helm) before any openshell auth probes.
if command -v openshell &>/dev/null; then
  openshell gateway select "$GATEWAY_NAME" &>/dev/null || true
  if ! ensure_oidc_token; then
    fail "OIDC auth for openshell CLI failed — Layer 3/4 sandbox checks will be unreliable"
    warn "Fix: KC_USER=admin KC_PASS=admin OPENSHELL_HEADLESS=1 ./scripts/configure-oidc.sh (full) or check Keycloak"
  fi
fi

# =============================================================================
# Layer 1: OCP Infrastructure
# =============================================================================
# WHY: Without these resources, nothing else can work.
#   - CRD: Required for OpenShell to create sandbox custom resources
#   - Namespace: Where all OpenShell resources live
#   - SCC: The sandbox pod requires privileged SCC for nftables/Landlock
#   - PKI: mTLS and JWT tokens for gateway auth
step "Layer 1: Infrastructure (OCP resources)"

oc get crd sandboxes.agents.x-k8s.io &>/dev/null \
  && pass "Agent Sandbox CRD exists" \
  || fail "Agent Sandbox CRD not found"

if [[ "$CRC_MODE" == "true" ]]; then
  info "CRC mode: skipping OLM operator CSV check (raw upstream manifest fallback)"
else
  oc get csv -n agent-sandbox-system 2>/dev/null | grep -q Succeeded \
    && pass "Agent Sandbox Operator CSV healthy (agent-sandbox-system)" \
    || warn "Agent Sandbox Operator CSV not in Succeeded phase (oc -n agent-sandbox-system get csv)"
fi

oc get ns "$NAMESPACE" &>/dev/null \
  && pass "Namespace $NAMESPACE exists" \
  || fail "Namespace $NAMESPACE not found"

# The declarative RoleBinding (charts/openshell/templates/scc-rolebinding.yaml,
# ADR-0006 addendum) is named "<wrapper-fullname>-sandbox-privileged-scc", not
# a fixed literal — match on its roleRef instead of guessing its metadata.name.
# Falls back to the pre-ADR-0019 imperative `oc adm policy add-scc-to-user`
# SCC-users-list check for clusters that still used that mechanism.
if oc get rolebinding -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -e '.items[] | select(.roleRef.name=="system:openshift:scc:privileged")' >/dev/null 2>&1; then
  pass "SCC binding active for openshell-sandbox (RBAC RoleBinding)"
elif oc get scc privileged -o json 2>/dev/null | grep -q "openshell-sandbox"; then
  pass "SCC binding active for openshell-sandbox (SCC users list)"
else
  fail "SCC binding not found"
fi

for secret in openshell-server-tls openshell-client-tls "${OPENSHELL_RELEASE_NAME}-jwt-keys"; do
  oc -n "$NAMESPACE" get secret "$secret" &>/dev/null \
    && pass "PKI secret $secret exists" \
    || fail "PKI secret $secret not found"
done

# =============================================================================
# Layer 1b: Keycloak OIDC
# =============================================================================
# WHY: All user-facing access (Control UI, CLI) goes through OIDC.
#   If Keycloak is down or misconfigured, nothing is accessible.
# HOW TO FIX: scripts/deploy-keycloak.sh && scripts/configure-oidc.sh
step "Layer 1b: Keycloak OIDC (if configured)"

KC_NAMESPACE="openshell-keycloak"
KC_ISSUER="https://keycloak-${KC_NAMESPACE}.${APPS_DOMAIN}/realms/openshell"

if oc get ns "$KC_NAMESPACE" &>/dev/null; then
  pass "Keycloak namespace exists"

  if oc -n "$KC_NAMESPACE" wait --for=condition=Ready pod -l app=keycloak --timeout=20s &>/dev/null; then
    pass "Keycloak pod Running"
  else
    KC_PHASE=$(oc -n "$KC_NAMESPACE" get pods -l app=keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    warn "Keycloak pod phase: $KC_PHASE"
  fi

  KC_DISCOVERY=$(curl -sk "${KC_ISSUER}/.well-known/openid-configuration" 2>/dev/null || true)
  if echo "$KC_DISCOVERY" | grep -q "jwks_uri"; then
    pass "Keycloak OIDC discovery available"
  else
    fail "Keycloak OIDC discovery not reachable at ${KC_ISSUER}"
  fi

  oc get oauthclient keycloak-broker &>/dev/null \
    && pass "OCP OAuthClient 'keycloak-broker' exists" \
    || warn "OCP OAuthClient 'keycloak-broker' not found"
else
  info "Keycloak not deployed (Phase 7 not active), skipping OIDC checks"
fi

# =============================================================================
# Layer 2: OpenShell Gateway
# =============================================================================
# WHY: The gateway is the control plane for all sandbox operations.
#   If it's down, we can't create sandboxes, relay services, or authenticate.
# HOW TO FIX: scripts/deploy-openshell.sh
step "Layer 2: OpenShell Gateway"

if oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=20s &>/dev/null; then
  pass "Gateway pod Running"
else
  PHASE=$(oc -n "$NAMESPACE" get pods -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
  fail "Gateway pod phase: $PHASE"
fi

ROUTE_HOST=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -n "$ROUTE_HOST" ]]; then
  pass "Route exists: $ROUTE_HOST"

  ROUTE_TLS=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
  [[ "$ROUTE_TLS" == "passthrough" ]] \
    && pass "Route TLS termination: passthrough" \
    || fail "Route TLS termination should be passthrough, got: $ROUTE_TLS"
else
  fail "Route openshell-gw not found"
fi

if command -v openshell &>/dev/null; then
  openshell status &>/dev/null \
    && pass "CLI connected to gateway" \
    || fail "CLI not connected to gateway"

  openshell provider list 2>/dev/null | grep -q "maas-litellm" \
    && pass "MaaS provider registered" \
    || fail "MaaS provider not found"

  if oc get ns "$KC_NAMESPACE" &>/dev/null 2>&1; then
    OIDC_CFG=$(oc -n "$NAMESPACE" get configmap openshell-config -o jsonpath='{.data}' 2>/dev/null || true)
    if echo "$OIDC_CFG" | grep -q "oidc"; then
      pass "Gateway OIDC config present"
    else
      info "Gateway not yet configured for OIDC (run configure-oidc.sh)"
    fi
  fi
else
  warn "openshell CLI not available, skipping CLI checks"
fi

# =============================================================================
# Layer 3: Sandbox
# =============================================================================
# WHY: The sandbox is where OpenClaw actually runs. If it doesn't exist
#   or isn't Ready, the gateway can't run.
# HOW TO FIX: scripts/launch-openclaw.sh
step "Layer 3: Sandbox"

if command -v openshell &>/dev/null; then
  openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}" \
    && pass "Sandbox '$SANDBOX_NAME' exists" \
    || fail "Sandbox '$SANDBOX_NAME' not found"

  openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}.*Ready" \
    && pass "Sandbox is Ready" \
    || fail "Sandbox not in Ready state"
else
  warn "openshell CLI not available, skipping sandbox checks"
fi

# =============================================================================
# Layer 4: Security Validation
# =============================================================================
# WHY: These checks verify the security posture of the sandbox via direct
#   `sandbox_run` (openshell exec), NOT via LLM chat. Playwright formerly
#   asked the model to run curl/sudo/nslookup and pattern-matched natural-
#   language refusals — that was flaky under gpt-oss and measured model
#   cooperativeness, not sandbox enforcement.
#   - User identity: agent must run as unprivileged "sandbox" user
#   - Egress blocking: unauthorized destinations must be blocked by proxy
#   - IMDS: link-local AWS metadata must be unreachable
#   - sudo / privilege escalation blocked
#   - DNS/connect to arbitrary hosts fails or is proxy-denied
#   - /etc/shadow not readable as password hashes
#   - MaaS reachability: the one allowed destination must work
#   - Credential isolation: no plaintext API keys on sandbox filesystem —
#     apiKey is OpenClaw's native "${LITELLM_API_KEY}" env SecretRef,
#     resolved in-process at gateway startup, never baked into the file
#     (see constraint #3 in launch-openclaw.sh / ROADMAP.md #13.4)
#   - Landlock enforcement: /sandbox/.openclaw must be read-only
#   - Config placeholder: the ${LITELLM_API_KEY} marker must still be intact
#     in the working config at /sandbox/workspace/.openclaw/openclaw.json
# HOW TO FIX: These indicate fundamental sandbox security issues. Check
#   policies/openclaw-sandbox.yaml and the SCC binding.
step "Layer 4: Security Validation"

# Helper: sandbox_run failed (OIDC/auth/sandbox gone) — never treat as a security PASS.
_sandbox_run_ok() {
  local out="$1"
  ! echo "$out" | grep -qiE "OIDC token|invalid token|ExpiredSignature|sandbox not found|valid authentication credentials|Error:"
}

if command -v openshell &>/dev/null; then
  if ! ensure_oidc_token; then
    fail "OIDC auth failed — cannot run Layer 4 sandbox security checks"
    warn "Skipping remaining Layer 4 checks"
  else

  WHOAMI=$(sandbox_run "whoami" || true)
  if echo "$WHOAMI" | tr -d '\r' | grep -qx "sandbox" || echo "$WHOAMI" | grep -qE '(^|[[:space:]])sandbox([[:space:]]|$)'; then
    pass "Sandbox user identity: sandbox"
  else
    fail "Expected sandbox user, got unexpected identity (OIDC/sandbox exec failed? ${WHOAMI:0:100})"
    warn "Skipping remaining Layer 4 checks — sandbox_run is not usable"
  fi

  if echo "$WHOAMI" | grep -q "sandbox" && _sandbox_run_ok "$WHOAMI"; then
  # Verify unauthorized egress is blocked (proxy L7 default-deny)
  GITHUB_RESULT=$(sandbox_run 'curl -sI --max-time 5 https://github.com 2>&1 | head -1' || true)
  if ! _sandbox_run_ok "$GITHUB_RESULT"; then
    fail "SECURITY: cannot verify github.com egress (sandbox_run failed)"
  elif echo "$GITHUB_RESULT" | grep -qE "HTTP/[0-9.]+ 200"; then
    fail "SECURITY: github.com returned HTTP 200 (should be blocked by proxy)"
  elif echo "$GITHUB_RESULT" | grep -qiE "403|forbidden|blocked|denied|refused|reset|timed out|timeout|HTTP/[0-9.]+ 40[0-9]"; then
    pass "Unauthorized egress blocked (github.com)"
  else
    # Non-200 connection failure without openshell errors = blocked/unreachable
    pass "Unauthorized egress blocked (github.com unreachable)"
  fi

  # AWS IMDS must not be reachable from the sandbox
  IMDS_RESULT=$(sandbox_run 'curl -s --max-time 5 -o /tmp/imds.out -w "HTTP:%{http_code}" http://169.254.169.254/latest/meta-data/ 2>&1; echo; head -c 200 /tmp/imds.out 2>/dev/null; echo; echo EXIT:$?' || true)
  if ! _sandbox_run_ok "$IMDS_RESULT"; then
    fail "SECURITY: cannot verify IMDS block (sandbox_run failed)"
  elif echo "$IMDS_RESULT" | grep -qiE "ami-|i-[a-z0-9]{8,}|instance-type"; then
    fail "SECURITY: AWS IMDS metadata leaked from sandbox"
  elif echo "$IMDS_RESULT" | grep -qE "HTTP:200"; then
    fail "SECURITY: AWS IMDS returned HTTP 200"
  else
    pass "AWS IMDS metadata endpoint not reachable"
  fi

  # Privilege escalation via sudo must fail (non-interactive)
  SUDO_RESULT=$(sandbox_run 'sudo -n whoami 2>&1; echo EXIT:$?' || true)
  if ! _sandbox_run_ok "$SUDO_RESULT"; then
    fail "SECURITY: cannot verify sudo block (sandbox_run failed)"
  else
    SUDO_CLEAN=$(echo "$SUDO_RESULT" | tr -d '\r')
    if echo "$SUDO_CLEAN" | grep -E '^root$' >/dev/null; then
      fail "SECURITY: sudo whoami returned root"
    else
      pass "Privilege escalation via sudo is blocked"
    fi
  fi

  # Arbitrary host: must not succeed with HTTP 200 (DNS fail or proxy 403 OK)
  ARB_RESULT=$(sandbox_run 'curl -sI --max-time 5 https://evil-exfil.example.com 2>&1 | head -3' || true)
  if ! _sandbox_run_ok "$ARB_RESULT"; then
    fail "SECURITY: cannot verify arbitrary-host block (sandbox_run failed)"
  elif echo "$ARB_RESULT" | grep -qE "HTTP/[0-9.]+ 200"; then
    fail "SECURITY: arbitrary host evil-exfil.example.com returned HTTP 200"
  else
    pass "Arbitrary host connect denied or failed (evil-exfil.example.com)"
  fi

  # /etc/shadow must not expose password hashes
  SHADOW_RESULT=$(sandbox_run 'cat /etc/shadow 2>&1 | head -3; echo EXIT:$?' || true)
  if ! _sandbox_run_ok "$SHADOW_RESULT"; then
    fail "SECURITY: cannot verify /etc/shadow (sandbox_run failed)"
  elif echo "$SHADOW_RESULT" | grep -qE 'root:\$[0-9a-zA-Z]'; then
    fail "SECURITY: /etc/shadow password hashes readable"
  elif echo "$SHADOW_RESULT" | grep -qiE "permission denied|cannot open|EXIT:[1-9]|No such file"; then
    pass "/etc/shadow not readable"
  else
    pass "/etc/shadow content not exposed as hashes"
  fi

  # Verify MaaS IS reachable (it's in the allow list)
  MAAS_RESULT=$(sandbox_run 'curl -sI --max-time 5 https://maas-rhdp.apps.maas.redhatworkshops.io/health 2>&1 | head -1' || true)
  if ! _sandbox_run_ok "$MAAS_RESULT"; then
    warn "MaaS reachability check skipped (sandbox_run failed)"
  elif echo "$MAAS_RESULT" | grep -qE "200|401|403"; then
    pass "MaaS endpoint reachable through proxy"
  else
    warn "MaaS endpoint response unexpected: $MAAS_RESULT"
  fi

  # Verify no plaintext credentials on sandbox filesystem.
  # /sandbox/.openclaw/ is read-only (Landlock). /sandbox/workspace/.openclaw/
  # is the working config — since config/openclaw.json.tpl's apiKey is now
  # OpenClaw's native "${LITELLM_API_KEY}" env SecretRef (resolved in-process
  # at gateway startup, never baked into the file — see constraint #3 /
  # ROADMAP.md #13.4), neither location should ever contain a raw "sk-" key.
  # This is a hard fail now, not the former known-workaround warn.
  # Match a plausible key SHAPE (sk-<16+ alnum>), not a bare "sk-" substring
  # — the latter false-positives constantly on unrelated build artifacts
  # under node_modules (minified bundles, source maps, etc.), which used to
  # bury the real match under `head -1` noise. Also: `grep ... | head -N
  # || echo MARKER` looks like it distinguishes "found" vs "clean" by exit
  # status, but the exit status of a pipeline is the LAST command's (head),
  # which succeeds whether or not grep matched anything — so `|| echo
  # MARKER` never actually fires on "no match" either. Use an explicit
  # if/else inside the sandboxed command instead of relying on pipe exit
  # status or embedded fallback text (see `_strip_pty_echo` in common.sh for
  # why embedded fallback text was doubly unreliable until that fix).
  CRED_RO=$(sandbox_run 'M=$(grep -rlE "sk-[A-Za-z0-9]{16,}" /sandbox/.openclaw/ /tmp/ --exclude-dir=node_modules 2>/dev/null); if [ -n "$M" ]; then echo "$M"; else echo CLEAN; fi' || true)
  if ! _sandbox_run_ok "$CRED_RO"; then
    fail "SECURITY: cannot verify read-only credential zone (sandbox_run failed)"
  elif echo "$CRED_RO" | grep -qx "CLEAN"; then
    pass "No plaintext API keys in read-only zone (/sandbox/.openclaw/, /tmp/)"
  else
    fail "SECURITY: API key found in read-only filesystem zone: $(echo "$CRED_RO" | head -3 | tr '\n' ' ')"
  fi

  CRED_WS=$(sandbox_run 'M=$(grep -rlE "sk-[A-Za-z0-9]{16,}" /sandbox/workspace/.openclaw/ --exclude-dir=node_modules 2>/dev/null); if [ -n "$M" ]; then echo "$M"; else echo CLEAN; fi' || true)
  if ! _sandbox_run_ok "$CRED_WS"; then
    warn "Workspace credential check skipped (sandbox_run failed)"
  elif echo "$CRED_WS" | grep -qx "CLEAN"; then
    pass "No plaintext API keys in workspace config"
  else
    fail "SECURITY: API key present in /sandbox/workspace/.openclaw/: $(echo "$CRED_WS" | head -3 | tr '\n' ' ') (apiKey should be the \${LITELLM_API_KEY} SecretRef literal, never a real key)"
  fi

  # Verify Landlock: /sandbox/.openclaw/ must be read-only
  WRITE_CONFIG=$(sandbox_run 'echo test > /sandbox/.openclaw/config.json 2>&1; echo EXIT:$?' || true)
  if ! _sandbox_run_ok "$WRITE_CONFIG"; then
    fail "SECURITY: cannot verify Landlock (sandbox_run failed)"
  elif echo "$WRITE_CONFIG" | grep -qEi "Permission denied|Read-only|EXIT:1"; then
    pass "Landlock blocks write to /sandbox/.openclaw/ (read-only)"
  else
    fail "SECURITY: /sandbox/.openclaw/ is writable (should be read-only via Landlock)"
  fi

  # Verify /sandbox/workspace/ IS writable (agent needs this)
  WRITE_WORKSPACE=$(sandbox_run 'echo test > /sandbox/workspace/landlock-test.txt 2>&1; echo EXIT:$?' || true)
  if ! _sandbox_run_ok "$WRITE_WORKSPACE"; then
    fail "SECURITY: cannot verify workspace writability (sandbox_run failed)"
  elif echo "$WRITE_WORKSPACE" | grep -q "EXIT:0"; then
    pass "/sandbox/workspace/ is writable (expected)"
    sandbox_run 'rm -f /sandbox/workspace/landlock-test.txt' >/dev/null 2>&1 || true
  else
    fail "/sandbox/workspace/ should be writable but write failed"
  fi

  # Verify the working config still holds OpenClaw's native env SecretRef
  # literal, not a real key. Since config/openclaw.json.tpl's apiKey field
  # is never bash-substituted with the real secret anymore (constraint #3 /
  # ROADMAP.md #13.4), this placeholder should be present at rest and only
  # resolved in-process by OpenClaw at gateway startup.
  CONFIG_PLACEHOLDER=$(sandbox_run 'grep -l "LITELLM_API_KEY" /sandbox/workspace/.openclaw/openclaw.json 2>/dev/null && echo FOUND || echo MISSING' || true)
  if ! _sandbox_run_ok "$CONFIG_PLACEHOLDER"; then
    fail "SECURITY: cannot verify config placeholder (sandbox_run failed)"
  elif echo "$CONFIG_PLACEHOLDER" | grep -q "FOUND"; then
    pass "Config placeholder \${LITELLM_API_KEY} still intact"
  else
    fail "SECURITY: config placeholder was modified or missing"
  fi
  fi  # end: sandbox_run usable
  fi  # end: ensure_oidc_token succeeded
else
  warn "openshell CLI not available, skipping security checks"
fi

# =============================================================================
# Layer 5: OpenClaw Gateway Health
# =============================================================================
# WHY: Verifies the OpenClaw gateway inside the sandbox is running and
#   properly configured:
#   - /health endpoint: basic liveness
#   - chatCompletions disabled: the HTTP API must be off (Control UI uses
#     WebSocket, not HTTP). Enabled HTTP API is a security exposure.
#   - tools.deny: dangerous tools (gateway, cron, openclaw) must be blocked
# HOW TO FIX: scripts/launch-openclaw.sh (restarts gateway with correct config)
step "Layer 5: OpenClaw Gateway Health"

if command -v openshell &>/dev/null; then
  HEALTH=$(sandbox_run 'curl -s http://localhost:18789/health' || true)
  if echo "$HEALTH" | grep -q '"ok":true'; then
    pass "OpenClaw /health returns ok"
  else
    fail "OpenClaw health check failed"
  fi

  CONFIG_CHECK=$(sandbox_run 'grep -l "LITELLM_API_KEY" /sandbox/workspace/.openclaw/openclaw.json 2>/dev/null && echo FOUND || echo MISSING' || true)
  if echo "$CONFIG_CHECK" | grep -q "FOUND"; then
    pass "Credential injection placeholder configured"
  else
    warn "Credential injection placeholder not found in config"
  fi

  # chatCompletions HTTP API must be disabled (security: only WebSocket via Control UI)
  CHAT_API=$(sandbox_run "curl -s -o /dev/null -w 'HTTP_CODE:%{http_code}' -X POST http://localhost:18789/v1/chat/completions -H 'Content-Type: application/json' -d '{}'" || true)
  CHAT_CODE=$(echo "$CHAT_API" | grep -oP 'HTTP_CODE:\K[0-9]+' | head -1 || echo "unknown")
  if [[ "$CHAT_CODE" == "404" || "$CHAT_CODE" == "405" || "$CHAT_CODE" == "403" ]]; then
    pass "chatCompletions HTTP API is disabled (HTTP $CHAT_CODE)"
  else
    warn "chatCompletions may still be enabled (HTTP $CHAT_CODE)"
  fi

  # tools.deny must block gateway/cron/openclaw (and related) commands
  TOOLS_DENY=$(sandbox_run 'python3 -c "import json;d=json.load(open(\"/sandbox/workspace/.openclaw/openclaw.json\"));print(\"DENY:\"+\",\".join((d.get(\"tools\") or {}).get(\"deny\") or []))"' || true)
  if echo "$TOOLS_DENY" | grep -qiE "OIDC token|invalid token|ExpiredSignature|sandbox not found|valid authentication credentials"; then
    fail "SECURITY: cannot verify tools.deny (sandbox_run failed)"
  elif echo "$TOOLS_DENY" | grep -q "DENY:gateway" || { echo "$TOOLS_DENY" | grep -q "gateway" && echo "$TOOLS_DENY" | grep -q "cron"; }; then
    DENY_LIST=$(echo "$TOOLS_DENY" | tr -d '\r' | sed -n 's/.*DENY://p' | head -1)
    pass "tools.deny includes gateway+cron (${DENY_LIST:-ok})"
  elif echo "$TOOLS_DENY" | grep -q "DENY:$"; then
    fail "SECURITY: tools.deny is empty in working config"
  else
    fail "SECURITY: tools.deny missing gateway/cron — got ${TOOLS_DENY:0:120}"
  fi
else
  warn "openshell CLI not available, skipping OpenClaw checks"
fi

# =============================================================================
# Layer 5b: LLM Connectivity (end-to-end through sandbox proxy)
# =============================================================================
# WHY: This layer catches the MOST COMMON failure mode: the OpenClaw gateway
#   can start and appear healthy but CANNOT actually reach the LLM provider.
#
# ROOT CAUSE HISTORY (do not remove — prevents regression):
#   1. Node.js binary path: `n` (version manager) installs Node.js at
#      /usr/local/bin/node. The sandbox proxy L7 policy only allows
#      /usr/bin/node. If both exist, Node.js processes use /usr/local/bin/node
#      (PATH priority), and the proxy DENIES all their traffic.
#      => Check 1 verifies /usr/local/bin/node does NOT exist.
#
#   2. Node.js fetch() connectivity: Even with correct binary path, fetch()
#      (undici) creates ephemeral connections. The proxy CAN handle these
#      through the transparent nftables redirect, but setting HTTP_PROXY or
#      NODE_OPTIONS breaks this by forcing HTTP CONNECT tunneling.
#      => Check 2 verifies Node.js fetch() works through the proxy.
#
#   3. Proxy denial logs: Even if curl works, Node.js may be denied.
#      The proxy logs DENIED entries with the reason.
#      => Check 3 looks for DENIED entries mentioning "maas".
#
# A real end-to-end chat request + MLflow trace check used to live here as
# Checks 4-5, but were removed (docs/constraints.md #17): Check 4 toggled
# `gateway.http.endpoints.chatCompletions.enabled` at runtime, which is a
# no-op on the running gateway (`gateway.reload.mode=off`) — its "PASS" came
# from a PTY echoing the curl command's own text, not a real model response,
# while Check 5 (trace recency) then correctly but confusingly FAILed against
# a request that never actually happened. Layer 9's Playwright test already
# exercises a real chat turn over the WebSocket path (unaffected by this
# bug) end-to-end, so that removal costs no real coverage.
#
# HOW TO FIX:
#   Check 1 fail: oc exec $SANDBOX -c agent -- bash -c 'cp /usr/local/bin/node /usr/bin/node && rm -f /usr/local/bin/node'
#   Check 2 fail: Verify no HTTP_PROXY/NODE_OPTIONS set. Check launch-openclaw.sh constraint #3.
#   Check 3 fail: Review policies/openclaw-sandbox.yaml. Check `openshell logs openclaw-gw | grep DENIED`.
step "Layer 5b: LLM Connectivity"

if command -v openshell &>/dev/null; then
  # Check 1: Node.js binary path — /usr/local/bin/node must NOT exist.
  # If it exists, the proxy will deny all Node.js network traffic because
  # the L7 policy only allows /usr/bin/node. (See root cause #1 above)
  NODE_LOCAL=$(sandbox_run 'test -f /usr/local/bin/node && echo EXISTS || echo ABSENT' || true)
  if echo "$NODE_LOCAL" | grep -q "ABSENT"; then
    pass "No /usr/local/bin/node (only /usr/bin/node allowed by policy)"
  else
    fail "SECURITY: /usr/local/bin/node exists — proxy will deny Node.js network access. Fix: rm /usr/local/bin/node"
  fi

  # Check 2: Node.js fetch() reaches MaaS through the transparent proxy.
  # This is the SAME mechanism the OpenClaw gateway uses to call the LLM.
  # If this fails, the gateway will fail too. (See root cause #2 above)
  NODE_FETCH=$(sandbox_run 'cat > /tmp/verify-fetch.mjs << '"'"'HEREDOC'"'"'
try {
  const r = await fetch("https://maas-rhdp.apps.maas.redhatworkshops.io/health");
  console.log("NODE_FETCH_STATUS:" + r.status);
} catch(e) {
  const cause = e.cause?.cause?.message || e.cause?.message || e.message;
  console.log("NODE_FETCH_ERROR:" + cause);
}
HEREDOC
/usr/bin/node /tmp/verify-fetch.mjs 2>&1' || true)
  if echo "$NODE_FETCH" | grep -q "NODE_FETCH_STATUS:"; then
    FETCH_CODE=$(echo "$NODE_FETCH" | tr -d '\r' | sed -n 's/.*NODE_FETCH_STATUS://p' | head -1)
    pass "Node.js fetch() reaches MaaS through proxy (HTTP $FETCH_CODE)"
  elif echo "$NODE_FETCH" | grep -q "NODE_FETCH_ERROR:"; then
    FETCH_ERR=$(echo "$NODE_FETCH" | tr -d '\r' | sed -n 's/.*NODE_FETCH_ERROR://p' | head -1)
    fail "Node.js fetch() to MaaS fails: $FETCH_ERR"
  else
    fail "Node.js fetch() to MaaS: unexpected result"
  fi

  # Check 3: No DENIED entries for MaaS in sandbox proxy logs.
  # The proxy logs every denied connection with the reason.
  # Even a single DENIED entry means the gateway is failing silently.
  # (See root cause #3 above)
  DENY_LOGS=$(openshell logs "$SANDBOX_NAME" 2>&1 | grep "DENIED.*maas" | tail -5 || true)
  DENY_COUNT=$(echo "$DENY_LOGS" | grep -c "DENIED" || true)
  if [[ "$DENY_COUNT" -eq 0 ]]; then
    pass "No DENIED proxy entries for MaaS"
  else
    LATEST_DENY=$(echo "$DENY_LOGS" | tail -1 | grep -oP "reason:.*" | head -1 || echo "unknown")
    fail "Sandbox proxy denied MaaS access ($DENY_COUNT entries). Latest: ${LATEST_DENY:0:120}"
  fi

else
  warn "openshell CLI not available, skipping LLM connectivity checks"
fi

# =============================================================================
# Layer 7a: Unauthenticated Direct-Access Route Is Retired
# =============================================================================
# WHY: ADR-0016 retired the unauthenticated static-token Route `openclaw-ui`
#   (it pointed straight at the `openshell` Service, bypassing oauth-proxy
#   entirely) once oauth-proxy became the sole browser auth path. This check
#   is intentionally inverted from what it used to verify: it now confirms
#   the insecure Route stays gone, instead of proving it works.
step "Layer 7a: Unauthenticated direct-access Route is retired"

if oc -n "$NAMESPACE" get route openclaw-ui &>/dev/null; then
  fail "Route 'openclaw-ui' still exists — unauthenticated direct access to the sandbox service is possible, bypassing oauth-proxy (see ADR-0016)"
else
  pass "Route 'openclaw-ui' does not exist — no unauthenticated direct access path"
fi

# =============================================================================
# Layer 7b: oauth-proxy OpenShift-native OAuth UI Authentication
# =============================================================================
# WHY: Users access the OpenClaw UI through oauth-proxy (OpenShift fork,
#   `-provider=openshift`), which authenticates browsers directly against
#   OCP's own OAuth server via a ServiceAccount-based OAuth client -- no
#   Keycloak broker in this path (see ADR-0016). This verifies the chain:
#   1. oauth-proxy route exists and pod is running
#   2. Unauthenticated requests redirect to the OCP OAuth server (302)
#   3. Redirect points to the cluster's real OAuth route (oauth-openshift)
#   Keycloak remains deployed only for the separate CLI/gRPC OIDC path
#   (scripts/configure-oidc.sh) -- see Layer 7c below.
# HOW TO FIX: scripts/deploy-oauth2-proxy.sh
step "Layer 7b: oauth-proxy OpenShift-native OAuth UI Authentication"

# Hostname must equal OpenShell's {sandbox}--{service} pattern -- see
# charts/oauth2-proxy/templates/route.yaml for why (WebSocket Host-header bug
# in this oauth-proxy fork, ADR-0016).
OAUTH_PROXY_HOST="${SANDBOX_NAME}--openclaw-ui.${APPS_DOMAIN}"

if oc -n "$NAMESPACE" get route openclaw-ui-auth &>/dev/null; then
  pass "oauth-proxy route exists"

  if oc -n "$NAMESPACE" get deployment oauth-proxy &>/dev/null; then
    READY=$(oc -n "$NAMESPACE" get deployment oauth-proxy -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$READY" -ge 1 ]]; then
      pass "oauth-proxy pod is running (${READY} replicas)"
    else
      fail "oauth-proxy pod not ready"
    fi
  else
    fail "oauth-proxy deployment not found"
  fi

  REDIRECT_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${OAUTH_PROXY_HOST}/" 2>/dev/null || echo "000")
  if [[ "$REDIRECT_CODE" == "302" || "$REDIRECT_CODE" == "303" ]]; then
    pass "Unauthenticated request redirects to OCP OAuth server (HTTP ${REDIRECT_CODE})"
  else
    fail "Expected 302/303 redirect, got HTTP ${REDIRECT_CODE}"
  fi

  REDIRECT_LOCATION=$(curl -sk -o /dev/null -w '%{redirect_url}' "https://${OAUTH_PROXY_HOST}/" 2>/dev/null || echo "")
  if echo "$REDIRECT_LOCATION" | grep -q "oauth-openshift"; then
    pass "Redirect target is OCP's native OAuth server (zero Keycloak involvement)"
  else
    warn "Redirect location does not point to oauth-openshift: ${REDIRECT_LOCATION:0:80}"
  fi

  # Full authorization-code flow against an HTPasswd test user, proving
  # end-to-end login without any Keycloak hop (ADR-0016 evidence). CRC's
  # default HTPasswd identity is `developer`/`developer`; real AWS OCP
  # clusters (e.g. OpenTLC sandboxes) typically provision a single, differently
  # named HTPasswd user instead (no `developer` user at all) -- override via
  # OCP_TEST_USERNAME/OCP_TEST_PASSWORD env vars, same names tests/auth.setup.ts
  # already uses, so both the shell verify path and the Playwright path share
  # one override mechanism per environment.
  OCP_TEST_USERNAME="${OCP_TEST_USERNAME:-developer}"
  OCP_TEST_PASSWORD="${OCP_TEST_PASSWORD:-developer}"
  CJ=$(mktemp)
  LOGIN_HTML=$(mktemp)
  curl -sk -c "$CJ" -L "https://${OAUTH_PROXY_HOST}/" -o "$LOGIN_HTML" 2>/dev/null || true
  CSRF=$(grep -oP 'name="csrf" value="\K[^"]+' "$LOGIN_HTML" 2>/dev/null || true)
  THEN_RAW=$(grep -oP 'name="then" value="\K[^"]+' "$LOGIN_HTML" 2>/dev/null || true)
  if [[ -n "$CSRF" && -n "$THEN_RAW" ]]; then
    THEN=$(python3 -c "import sys,html; print(html.unescape(sys.argv[1]))" "$THEN_RAW" 2>/dev/null || echo "$THEN_RAW")
    FINAL_URL=$(curl -sk -b "$CJ" -c "$CJ" -L \
      --data-urlencode "csrf=${CSRF}" \
      --data-urlencode "then=${THEN}" \
      --data-urlencode "username=${OCP_TEST_USERNAME}" \
      --data-urlencode "password=${OCP_TEST_PASSWORD}" \
      "https://oauth-openshift.${APPS_DOMAIN}/login" \
      -o /dev/null -w '%{url_effective}' 2>/dev/null || echo "")
    if [[ "$FINAL_URL" == "https://${OAUTH_PROXY_HOST}/" ]]; then
      pass "Full OAuth login flow (HTPasswd ${OCP_TEST_USERNAME} user) reaches the Control UI"

      # Regression check for the WebSocket Host-header bug this hostname
      # unification fix addresses (ADR-0016 "WebSocket login failure"): a
      # real browser opens wss://<OAUTH_PROXY_HOST>/ for the OpenClaw chat
      # gateway once logged in. If oauth-proxy's WebSocket proxy ever
      # forwards an unrewritten Host again, OpenShell's service routing
      # returns 404 here instead of 101.
      #
      # IMPORTANT: a *successful* 101 upgrade leaves the connection open
      # indefinitely (that's the point of WebSocket) -- curl's `-w
      # '%{http_code}'` only populates once the transfer completes, which
      # never happens here, so it always reports empty/000 on success and
      # is indistinguishable from a real failure. Use `-D` instead: curl
      # writes response headers to that file as soon as they're received,
      # before the body/frames start streaming, so the status line is
      # captured correctly even though the subsequent `-m` timeout on the
      # now-open connection is expected and ignored.
      WS_HEADERS=$(mktemp)
      timeout 6 curl -sk -b "$CJ" -m 3 -D "$WS_HEADERS" -o /dev/null \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        "https://${OAUTH_PROXY_HOST}/" 2>/dev/null || true
      WS_CODE=$(grep -oP 'HTTP/[\d.]+ \K\d+' "$WS_HEADERS" 2>/dev/null | head -1 || echo "000")
      rm -f "$WS_HEADERS"
      if [[ "$WS_CODE" == "101" ]]; then
        pass "WebSocket upgrade through oauth-proxy succeeds (HTTP 101) -- chat gateway reachable"
      else
        fail "WebSocket upgrade through oauth-proxy returned HTTP ${WS_CODE} (expected 101) -- chat will show 'Could not connect'"
      fi
    else
      warn "OAuth login flow did not land on the Control UI (got: ${FINAL_URL:0:80})"
    fi
  else
    warn "Could not parse OCP login form (csrf/then fields) -- skipping full login flow test"
  fi
  rm -f "$CJ" "$LOGIN_HTML"
else
  warn "oauth-proxy route 'openclaw-ui-auth' not found — run scripts/deploy-oauth2-proxy.sh"
fi

# =============================================================================
# Layer 7c: Keycloak (CLI/gRPC OIDC issuer only -- not used by the browser UI)
# =============================================================================
# WHY: Keycloak is intentionally still deployed. It is the OIDC issuer for
#   the openshell CLI/gRPC gateway auth path only (scripts/configure-oidc.sh),
#   because that path needs a real JWKS-serving OIDC provider with a
#   realm_access.roles claim (charts/openshell/values-ocp.yaml.tpl
#   server.oidc.rolesClaim) -- OCP's native OAuth server does not produce
#   that claim shape. See ADR-0016 "Follow-up: retiring Keycloak".
step "Layer 7c: Keycloak (CLI/gRPC OIDC issuer)"

KC_HOST="keycloak-openshell-keycloak.${APPS_DOMAIN}"
if oc get ns openshell-keycloak &>/dev/null; then
  DISCOVERY=$(curl -sk "https://${KC_HOST}/realms/openshell/.well-known/openid-configuration" 2>/dev/null || true)
  if echo "$DISCOVERY" | grep -q "jwks_uri"; then
    pass "Keycloak OIDC discovery reachable (CLI/gRPC issuer)"
  else
    fail "Keycloak OIDC discovery not reachable at ${KC_HOST}"
  fi
else
  warn "openshell-keycloak namespace not found -- CLI/gRPC OIDC auth (scripts/configure-oidc.sh) will fail"
fi

# =============================================================================
# Layer 8: Observability Stack
# =============================================================================
# WHY: Verifies Tempo (trace storage) and OTel Collector (log/metric
#   ingestion) — infrastructure observability only (traces disabled here,
#   OTEL_TRACES_EXPORTER=none, see ADR-0014 Problem 8). Also verifies
#   RHOAI MLflow (agent traces + prompt registry — the sole tracing backend,
#   docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md), in a separate
#   namespace/operator lifecycle from Tempo/OTel. Sends a test trace to
#   verify the Tempo pipeline: OTel Collector → Tempo → queryable via API.
# HOW TO FIX: scripts/deploy-observability.sh (Tempo/OTel),
#   scripts/deploy-rhoai-mlflow.sh + scripts/wire-rhoai-mlflow-tracing.sh (MLflow)
step "Layer 8: Observability Stack"

OBS_NAMESPACE="observability"
RHOAI_NS="redhat-ods-applications"

if oc get ns "$OBS_NAMESPACE" &>/dev/null; then
  pass "Observability namespace exists"

  if oc -n "$OBS_NAMESPACE" wait --for=condition=Ready pod -l app=tempo --timeout=20s &>/dev/null; then
    pass "Tempo pod running and ready"
  else
    fail "Tempo pod not ready"
  fi

  if oc -n "$OBS_NAMESPACE" wait --for=condition=Ready pod -l app=otel-collector --timeout=20s &>/dev/null; then
    pass "OTel Collector pod running and ready"
  else
    fail "OTel Collector pod not ready"
  fi
else
  warn "Observability namespace not found, skipping Tempo/OTel checks"
fi

# RHOAI MLflow checks live outside the `if oc get ns observability` guard —
# separate namespace (redhat-ods-applications), separate operator lifecycle.
RHOAI_WIRING_8="${PROJECT_DIR}/.rendered/rhoai-mlflow/wiring.env"
if oc get ns "$RHOAI_NS" &>/dev/null; then
  pass "RHOAI namespace exists"

  if oc -n "$RHOAI_NS" wait --for=condition=Ready pod -l app=mlflow --timeout=20s &>/dev/null; then
    pass "MLflow pod running and ready"
  else
    fail "MLflow pod not ready"
  fi

  MLFLOW_HOST=$(oc get route mlflow -n "$RHOAI_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  AUTH_HEADERS_8=()
  if [[ -f "$RHOAI_WIRING_8" ]]; then
    set -a; source "$RHOAI_WIRING_8"; set +a
    AUTH_HEADERS_8=(-H "Authorization: Bearer ${RHOAI_MLFLOW_SA_TOKEN}" -H "X-MLFLOW-WORKSPACE: ${RHOAI_MLFLOW_WORKSPACE}")
  else
    warn "RHOAI wiring facts not found (${RHOAI_WIRING_8}) — API checks below will likely fail auth"
  fi
  if [[ -n "$MLFLOW_HOST" ]]; then
    # RHOAI-managed MLflow doesn't expose the bare, unauthenticated `/health`
    # path the old standalone deployment had — confirmed live (404, with or
    # without auth headers). Use a real, authenticated MLflow REST API call
    # instead as the health signal (same endpoint scripts/wire-rhoai-mlflow-
    # tracing.sh uses to check for the experiment).
    MLFLOW_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "${AUTH_HEADERS_8[@]}" \
      "https://${MLFLOW_HOST}/api/2.0/mlflow/experiments/get-by-name?experiment_name=openclaw-tracing" 2>/dev/null || echo "000")
    if [[ "$MLFLOW_CODE" == "200" ]]; then
      pass "MLflow health endpoint OK (https://${MLFLOW_HOST})"
    else
      fail "MLflow health returned HTTP ${MLFLOW_CODE}"
    fi
  fi
fi

if [[ "$VERIFY_PROFILE" != "full" ]]; then
  info "Skipping synthetic OTel->Tempo trace round-trip (smoke profile) — diagnostic-only, see scripts/test-tracing.sh"
elif oc get ns "$OBS_NAMESPACE" &>/dev/null; then
  # Send a test trace through the OTel pipeline to verify it's working
  oc -n "$OBS_NAMESPACE" port-forward svc/otel-collector 24318:4318 &>/dev/null &
  TRACE_PF_PID=$!
  if wait_for_local_port 24318 20; then
    if TRACE_IDS=$(send_otel_test_trace 24318 verify-trace); then
      TEST_TRACE_ID="${TRACE_IDS%% *}"
      pass "Trace pipeline: OTel Collector accepts OTLP traces"
    else
      fail "Trace pipeline: could not send trace to collector"
      TEST_TRACE_ID=""
    fi
  else
    fail "Trace pipeline: port-forward to otel-collector:4318 not ready"
    TEST_TRACE_ID=""
  fi

  kill $TRACE_PF_PID 2>/dev/null || true

  if [[ -z "$TEST_TRACE_ID" ]]; then
    : # already failed above
  fi

  if [[ -n "$TEST_TRACE_ID" ]]; then
    sleep 5

    TRACE_VERIFY=$(oc -n "$OBS_NAMESPACE" exec deployment/tempo -- \
      wget -qO- "http://localhost:3200/api/traces/${TEST_TRACE_ID}" 2>/dev/null || echo "{}")
    if echo "$TRACE_VERIFY" | grep -q "verify-trace"; then
      pass "Trace pipeline: trace stored in Tempo and retrievable"
    else
      warn "Trace pipeline: trace not yet visible in Tempo (may need more time)"
    fi
  fi

else
  warn "Observability namespace not found — run scripts/deploy-observability.sh"
fi

# Trace content + prompt-tag checks moved to Layer 10 (after Playwright E2E chat).

# =============================================================================
# Layer 8b: MLflow Prompt Registry
# =============================================================================
# WHY: Verifies the full prompt management lifecycle. See
#   scripts/prompt-registry/README.md for what this subsystem is, how it
#   works, and how to remove it if it's no longer worth the operational cost:
#   1. Prompts are registered in MLflow (seed-mlflow-prompts.sh ran)
#   2. @production aliases are set (controlled rollout)
#   3. .prompt-versions.json manifest exists in sandbox (fetch ran)
#   4. Prompt files are read-only (agent can't modify them)
#   5. Trace linker sidecar is running (tags traces with prompt versions)
#   6-7. Trace prompt tags: see Layer 10 (after E2E chat generates traces)
# HOW TO FIX:
#   Prompts not registered: scripts/prompt-registry/seed-mlflow-prompts.sh
#   Manifest missing: launch-openclaw.sh (re-runs fetch)
#   Linker not running: launch-openclaw.sh (restarts linker)
step "Layer 8b: MLflow Prompt Registry"

RHOAI_NS="${RHOAI_NS:-redhat-ods-applications}"
PROMPT_NAMES=(AGENTS SOUL TOOLS IDENTITY USER HEARTBEAT BOOTSTRAP)
PROMPT_PREFIX="openclaw-system"

RHOAI_WIRING_8B="${PROJECT_DIR}/.rendered/rhoai-mlflow/wiring.env"
AUTH_HEADERS_8B=()
if [[ -f "$RHOAI_WIRING_8B" ]]; then
  set -a; source "$RHOAI_WIRING_8B"; set +a
  AUTH_HEADERS_8B=(-H "Authorization: Bearer ${RHOAI_MLFLOW_SA_TOKEN}" -H "X-MLFLOW-WORKSPACE: ${RHOAI_MLFLOW_WORKSPACE}")
fi

if [[ "$VERIFY_PROFILE" != "full" ]]; then
  info "Skipping MLflow Prompt Registry deep checks (smoke profile)"
elif oc get ns "$RHOAI_NS" &>/dev/null; then
  MLFLOW_HOST=$(oc get route mlflow -n "$RHOAI_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -n "$MLFLOW_HOST" ]]; then
    MLFLOW_EXT_URL="https://${MLFLOW_HOST}"

    REGISTERED=0
    ALIASED=0
    for pname in "${PROMPT_NAMES[@]}"; do
      fq="${PROMPT_PREFIX}.${pname}"
      encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${fq}', safe=''))" 2>/dev/null || echo "$fq")
      MODEL_RESP=$(curl -sf $CURL_OPTS "${AUTH_HEADERS_8B[@]}" "${MLFLOW_EXT_URL}/api/2.0/mlflow/registered-models/get?name=${encoded}" 2>/dev/null || echo "")
      if [[ -n "$MODEL_RESP" ]] && echo "$MODEL_RESP" | python3 -c "import sys,json; json.load(sys.stdin)['registered_model']" &>/dev/null; then
        REGISTERED=$((REGISTERED + 1))
        if echo "$MODEL_RESP" | python3 -c "
import sys,json
aliases = json.load(sys.stdin).get('registered_model',{}).get('aliases',[])
found = any(a.get('alias') == 'production' for a in aliases)
sys.exit(0 if found else 1)
" 2>/dev/null; then
          ALIASED=$((ALIASED + 1))
        fi
      fi
    done

    if [[ $REGISTERED -eq ${#PROMPT_NAMES[@]} ]]; then
      pass "All ${REGISTERED}/${#PROMPT_NAMES[@]} prompts registered in MLflow"
    elif [[ $REGISTERED -gt 0 ]]; then
      warn "Only ${REGISTERED}/${#PROMPT_NAMES[@]} prompts registered in MLflow"
    else
      fail "No prompts registered in MLflow — run scripts/prompt-registry/seed-mlflow-prompts.sh"
    fi

    if [[ $ALIASED -eq ${#PROMPT_NAMES[@]} ]]; then
      pass "All prompts have @production alias"
    elif [[ $ALIASED -gt 0 ]]; then
      warn "Only ${ALIASED}/${#PROMPT_NAMES[@]} prompts have @production alias"
    else
      fail "No @production aliases set"
    fi
  else
    warn "MLflow route not found, skipping prompt registry checks"
  fi

  if command -v openshell &>/dev/null; then
    # Verify prompt manifest exists in sandbox
    MANIFEST_CHECK=$(sandbox_run 'test -f /sandbox/workspace/.prompt-versions.json && python3 -c "import json; d=json.load(open(\"/sandbox/workspace/.prompt-versions.json\")); print(\"MANIFEST_COUNT:\" + str(len(d.get(\"prompts\",{}))))" || echo "MANIFEST_COUNT:0"' || true)
    MANIFEST_COUNT=$(echo "$MANIFEST_CHECK" | tr -d '\r\n' | sed 's/.*MANIFEST_COUNT:\([0-9]*\).*/\1/' || echo "0")
    [[ -z "$MANIFEST_COUNT" || "$MANIFEST_COUNT" == *"MANIFEST"* ]] && MANIFEST_COUNT=0
    if [[ "$MANIFEST_COUNT" -ge 7 ]]; then
      pass "Prompt manifest .prompt-versions.json has ${MANIFEST_COUNT} entries"
    elif [[ "$MANIFEST_COUNT" -gt 0 ]]; then
      warn "Prompt manifest has only ${MANIFEST_COUNT}/7 entries"
    else
      fail "Prompt manifest missing or empty in sandbox"
    fi

    # Verify prompt files are read-only (chmod 444, root-owned).
    # BOOTSTRAP.md is intentionally excluded from the "must be present"
    # count: OpenClaw's workspace setup (src/agents/workspace.ts,
    # fs.rm(bootstrapPath) once workspaceHasBootstrapCompletionEvidence() is
    # true) deletes it after the sandbox's first conversation completes —
    # see prompts/BOOTSTRAP.md's own text ("This file is only shown during
    # your first conversation. After setup completes, it will not appear
    # again."). A missing BOOTSTRAP.md is expected/healthy once the sandbox
    # has done real onboarding; only "present but not 444" would be a defect.
    PERSISTENT_PROMPT_COUNT=$((${#PROMPT_NAMES[@]} - 1)) # excludes BOOTSTRAP
    PROT_CHECK=$(sandbox_run 'c=0; for f in AGENTS SOUL TOOLS IDENTITY USER HEARTBEAT; do test -f /sandbox/workspace/${f}.md && p=$(stat -c %a /sandbox/workspace/${f}.md 2>/dev/null) && [ "$p" = "444" ] && c=$((c+1)); done; echo "PROTECTED:$c"' || true)
    PROTECTED=$(echo "$PROT_CHECK" | grep -oP 'PROTECTED:\K[0-9]+' | head -1 || echo "0")
    # sandbox_run's PTY echoes the command text before running it, so the
    # literal string "BOOTSTRAP_PERM:%a" (unexpanded) always appears once
    # from the echo. Only `stat`'s real numeric output can satisfy the
    # \d+ capture below, so take the LAST match (the real result, printed
    # after the echoed input line) rather than checking substring presence.
    BOOTSTRAP_CHECK=$(sandbox_run 'if [ ! -f /sandbox/workspace/BOOTSTRAP.md ]; then echo "BOOTSTRAP_PERM:none"; else stat -c "BOOTSTRAP_PERM:%a" /sandbox/workspace/BOOTSTRAP.md 2>/dev/null || echo "BOOTSTRAP_PERM:err"; fi' || true)
    BOOTSTRAP_PERM=$(echo "$BOOTSTRAP_CHECK" | grep -oE 'BOOTSTRAP_PERM:(none|err|[0-9]+)' | tail -1 | cut -d: -f2)
    if [[ "$PROTECTED" -ge $PERSISTENT_PROMPT_COUNT ]]; then
      if [[ "$BOOTSTRAP_PERM" != "none" && "$BOOTSTRAP_PERM" != "444" ]]; then
        fail "BOOTSTRAP.md exists with insecure permissions: ${BOOTSTRAP_PERM}"
      elif [[ "$BOOTSTRAP_PERM" == "444" ]]; then
        pass "All ${PROTECTED} persistent prompt files are read-only (chmod 444); BOOTSTRAP.md present and protected"
      else
        pass "All ${PROTECTED} persistent prompt files are read-only (chmod 444); BOOTSTRAP.md absent (setup already completed)"
      fi
    elif [[ "$PROTECTED" -gt 0 ]]; then
      warn "Only ${PROTECTED}/${PERSISTENT_PROMPT_COUNT} persistent prompt files are read-only"
    else
      fail "No prompt files found or none are read-only"
    fi

    # Verify trace linker sidecar is running
    LINKER_PID=$(sandbox_run 'pgrep -f prompt-trace-linker || echo NONE' || true)
    if echo "$LINKER_PID" | grep -qE '[0-9]'; then
      pass "Prompt trace linker sidecar running"
    else
      fail "Prompt trace linker not running"
    fi
  else
    warn "openshell CLI not available, skipping sandbox prompt checks"
  fi
else
  warn "RHOAI namespace not found, skipping MLflow Prompt Registry checks"
fi

# =============================================================================
# Layer 9: Control UI (Playwright)
# =============================================================================
# WHY: End-to-end verification that a real browser can log in via OCP's
#   native OAuth server (no Keycloak) and interact with the OpenClaw
#   Control UI.
# HOW TO FIX: Check oauth-proxy logs, the SA's oauth-redirectreference
#   annotation, and the auth.setup.ts test file for URL/selector patterns.
step "Layer 9: Control UI Validation (Playwright)"

if [[ "$VERIFY_PROFILE" != "full" ]]; then
  info "Skipping Playwright browser UI test (smoke profile)"
else
  if command -v openshell &>/dev/null; then
    openshell service list 2>/dev/null | grep -q "openclaw-ui\|web" \
      && pass "Sandbox service registered with gateway" \
      || warn "No sandbox service registered"
  fi

  TEST_DIR="${PROJECT_DIR}/tests"
  if command -v npx &>/dev/null && [[ -d "${TEST_DIR}/node_modules/@playwright" ]]; then
    OAUTH_ROUTE="${SANDBOX_NAME}--openclaw-ui.${APPS_DOMAIN}"
    OPENCLAW_BASE_URL="https://${OAUTH_ROUTE}"
    info "Using oauth-proxy route for Playwright: ${OPENCLAW_BASE_URL}"

    # `npm install` only fetches the @playwright/test package, not the actual
    # browser binaries (a separate, larger download) — a fresh clone/environment
    # (or a fresh Cursor sandbox cache) can have the former without the latter,
    # which fails Playwright with "Executable doesn't exist" rather than
    # skipping gracefully like the `[[ -d node_modules/@playwright ]]` check
    # above intends. `playwright install` is idempotent and fast (a version
    # check only, no re-download) when the browser is already present, so it's
    # safe/cheap to always run before `playwright test` instead of trying to
    # detect browser presence ourselves.
    (cd "$TEST_DIR" && npx playwright install chromium) 2>&1 | tail -5

    export OPENCLAW_BASE_URL
    load_secrets
    export MAAS_API_KEY
    if (cd "$TEST_DIR" && npx playwright test --project=ui-tests) 2>&1; then
      pass "Playwright Control UI tests passed (OIDC flow)"
    else
      fail "Playwright Control UI tests failed"
    fi

    # PROBE_START_MS marks "now" so the model-drift guard below only looks at
    # sessions the run about to happen actually creates (session keys embed
    # Date.now(), see tests/helpers.ts uniqueSessionKey()).
    PROBE_START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
    SECURITY_TESTS_STATUS=0
    (cd "$TEST_DIR" && npx playwright test --project=security-tests) 2>&1 || SECURITY_TESTS_STATUS=$?

    # Guard against stale-model drift: gateway.reload.mode is "off" (openclaw.json),
    # so a gateway process that was already running when agents.defaults.model.primary
    # changed on disk keeps handing NEW sessions the model that was loaded into memory
    # at its OWN last startup — silently testing a different model than configured,
    # with no error anywhere. Found live 2026-08-13: 121/141 security-test sessions ran
    # on llama-scout-17b while primary said claude-sonnet-4-6 (gateway hadn't been
    # restarted since before the primary was fixed). See ROADMAP.md #13.4. Verify here
    # against the REAL sessions this run just created — sessions.json is ground truth,
    # not the config file or the UI.
    PRIMARY_MODEL_FULL=$(python3 -c "import json; print(json.load(open('${RENDERED_DIR}/openclaw.json'))['agents']['defaults']['model']['primary'])" 2>/dev/null || echo "")
    PRIMARY_MODEL="${PRIMARY_MODEL_FULL#*/}"
    if [[ -n "$PRIMARY_MODEL" ]]; then
      MODEL_CHECK=$(oc -n "$NAMESPACE" exec "$SANDBOX_NAME" -c agent -- python3 -c "
import json
data = json.load(open('/sandbox/workspace/.openclaw/agents/main/sessions/sessions.json'))
start = ${PROBE_START_MS}
primary = '${PRIMARY_MODEL}'
bad = []
seen = 0
for k, v in data.items():
    if ':security-' not in k or not isinstance(v, dict):
        continue
    tail = k.split(':security-', 1)[1]
    epoch_str = tail.split('-', 1)[0]
    if not epoch_str.isdigit() or int(epoch_str) < start:
        continue
    seen += 1
    # The top-level 'model' key is always null in practice — the model a
    # session actually ran against is recorded under systemPromptReport.model
    # (confirmed live 2026-08-13 while forensically tracing a leaked-key chat
    # transcript back to a specific stale-gateway session; the original
    # version of this guard checked the always-null field and therefore never
    # actually caught anything, silently). See ROADMAP.md #13.4.
    model = (v.get('systemPromptReport') or {}).get('model')
    if model and model != primary:
        bad.append((k, model))
if seen == 0:
    print('NO_SESSIONS_FOUND')
elif bad:
    print('MISMATCH:' + repr(bad[:5]))
else:
    print('OK:' + str(seen))
" 2>&1) || true
      if echo "$MODEL_CHECK" | grep -q "^OK:"; then
        pass "Security tests ran against the configured primary model (${PRIMARY_MODEL})"
      elif echo "$MODEL_CHECK" | grep -q "^MISMATCH"; then
        fail "SECURITY TESTS RAN AGAINST THE WRONG MODEL (expected ${PRIMARY_MODEL}): ${MODEL_CHECK#MISMATCH:}. The gateway process didn't pick up the current primary (gateway.reload.mode=off never hot-reloads it). Fix: ./scripts/launch-openclaw.sh (restarts the gateway), then re-run this layer."
      else
        warn "Could not verify which model the security tests ran against (${MODEL_CHECK:-no output}); results above may be invalid"
      fi
    else
      warn "Could not read agents.defaults.model.primary from ${RENDERED_DIR}/openclaw.json — skipping model-drift guard"
    fi

    if [[ "$SECURITY_TESTS_STATUS" -eq 0 ]]; then
      pass "Playwright security exfiltration tests passed"
    else
      fail "Playwright security exfiltration tests failed"
    fi
  else
    warn "Playwright not installed, skipping UI tests"
    echo "    Install with: cd ${TEST_DIR} && npm install && npx playwright install chromium"
  fi
fi

# =============================================================================
# Layer 10: MLflow Traces + UI (post-E2E)
# =============================================================================
# WHY: Layer 9's Playwright chat generates real traces in RHOAI MLflow. These
#   checks confirm the data is present via REST API and visible in the MLflow
#   web UI (Prompts tab, Traces tab). Must run after Layer 9.
# HOW TO FIX:
#   No traces: re-run scripts/launch-openclaw.sh, then Layer 9 chat test
#   UI fails: check MLflow route, wiring.env token, workspace header
step "Layer 10: MLflow Traces + UI (post-E2E)"

if [[ "$VERIFY_PROFILE" != "full" ]]; then
  info "Skipping MLflow trace/UI checks (smoke profile)"
else
  RHOAI_WIRING_10="${PROJECT_DIR}/.rendered/rhoai-mlflow/wiring.env"
  MLFLOW_HOST_L10=$(oc get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  AUTH_HEADERS_10=()
  if [[ -f "$RHOAI_WIRING_10" ]]; then
    set -a; source "$RHOAI_WIRING_10"; set +a
    AUTH_HEADERS_10=(-H "Authorization: Bearer ${RHOAI_MLFLOW_SA_TOKEN}" -H "X-MLFLOW-WORKSPACE: ${RHOAI_MLFLOW_WORKSPACE}")
  else
    warn "RHOAI wiring facts not found (${RHOAI_WIRING_10}) — MLflow API/UI checks will likely fail"
  fi

  if [[ -n "$MLFLOW_HOST_L10" && ${#AUTH_HEADERS_10[@]} -gt 0 ]]; then
    # Brief poll: traces may take a few seconds to land after Layer 9 chat.
    MLFLOW_TRACES=""
    TRACE_COUNT=""
    for _poll in 1 2 3 4 5 6; do
      MLFLOW_TRACES=$(curl -sk "${AUTH_HEADERS_10[@]}" \
        "https://${MLFLOW_HOST_L10}/api/2.0/mlflow/traces?experiment_ids=${RHOAI_MLFLOW_EXPERIMENT_ID:-0}&max_results=5" 2>/dev/null || echo "")
      TRACE_COUNT=$(echo "$MLFLOW_TRACES" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('traces',[])))" 2>/dev/null || echo "")
      if [[ "$TRACE_COUNT" =~ ^[1-9] ]]; then
        break
      fi
      sleep 5
    done

    if [[ "$TRACE_COUNT" =~ ^[1-9] ]]; then
      pass "MLflow native traces: ${TRACE_COUNT} trace(s) in Traces tab"
    elif [[ "$TRACE_COUNT" == "0" ]]; then
      fail "MLflow native traces: no traces after E2E chat (Layer 9 should have generated them)"
    else
      fail "MLflow native traces: could not query traces API"
    fi

    RICH_CONTENT=$(echo "$MLFLOW_TRACES" | python3 -c "
import sys,json
data = json.load(sys.stdin)
traces = data.get('traces', [])
rich = sum(1 for t in traces if any(m.get('key') == 'mlflow.traceInputs' for m in t.get('request_metadata', [])))
print(rich)
" 2>/dev/null || echo "")
    if [[ "$RICH_CONTENT" =~ ^[1-9] ]]; then
      pass "MLflow trace content: ${RICH_CONTENT} trace(s) with full input/output (mlflow.traceInputs)"
    elif [[ -n "$RICH_CONTENT" ]]; then
      warn "MLflow trace content: no traces with mlflow.traceInputs found yet"
    fi

    TAGGED_CHECK="$MLFLOW_TRACES"
    if [[ -n "$TAGGED_CHECK" ]]; then
      TAGGED_COUNT=$(echo "$TAGGED_CHECK" | python3 -c "
import sys,json
data = json.load(sys.stdin)
traces = data.get('traces',[])
tagged = sum(1 for t in traces if any(tag.get('key') == 'mlflow.linkedPrompts' for tag in t.get('tags',[])))
print(tagged)
" 2>/dev/null || echo "0")
      if [[ "$TAGGED_COUNT" -gt 0 ]]; then
        pass "Prompt tags present on ${TAGGED_COUNT}/5 recent traces (mlflow.linkedPrompts)"
      else
        warn "No traces have prompt tags yet (linker may need more time)"
      fi

      PV_COUNT=$(echo "$TAGGED_CHECK" | python3 -c "
import sys,json
data = json.load(sys.stdin)
traces = data.get('traces',[])
tagged = sum(1 for t in traces if any(tag.get('key') == 'prompt_versions' for tag in t.get('tags',[])))
print(tagged)
" 2>/dev/null || echo "0")
      if [[ "$PV_COUNT" -gt 0 ]]; then
        pass "Custom prompt_versions tag on ${PV_COUNT}/5 recent traces"
      else
        warn "No prompt_versions custom tags on traces"
      fi
    fi
  else
    fail "MLflow route or auth wiring missing — cannot verify traces"
  fi

  if command -v npx &>/dev/null && [[ -d "${PROJECT_DIR}/tests/node_modules/@playwright" ]]; then
    TEST_DIR="${PROJECT_DIR}/tests"
    MLFLOW_BASE_URL="https://${MLFLOW_HOST_L10}/mlflow/"
    export MLFLOW_BASE_URL MLFLOW_AUTH_TOKEN="${RHOAI_MLFLOW_SA_TOKEN:-}" \
      MLFLOW_WORKSPACE="${RHOAI_MLFLOW_WORKSPACE:-openshell}" \
      MLFLOW_EXPERIMENT_ID="${RHOAI_MLFLOW_EXPERIMENT_ID:-1}"
    info "MLflow UI Playwright: ${MLFLOW_BASE_URL}"

    if (cd "$TEST_DIR" && npx playwright test --project=mlflow-ui-tests) 2>&1; then
      pass "Playwright MLflow UI tests passed (prompts + traces visible)"
    else
      fail "Playwright MLflow UI tests failed"
    fi
  else
    warn "Playwright not installed, skipping MLflow UI tests"
  fi
fi

# =============================================================================
# Structured output (conditions JSON)
# =============================================================================
# Emitted before the "Verification Summary" step() call so that step doesn't
# add an empty trailing layer to the JSON. Enables CI gates / dashboards to
# consume per-layer status without parsing the plain-text output above.
VERIFY_STATUS_FILE="${VERIFY_STATUS_FILE:-${PROJECT_DIR}/.verify-status.json}"
emit_conditions_json "$VERIFY_STATUS_FILE"

# =============================================================================
# Summary
# =============================================================================
echo ""
step "Verification Summary"
echo "    Passed: $PASS_COUNT"
echo "    Failed: $FAIL_COUNT"
echo "    Warnings: $WARN_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  error "$FAIL_COUNT check(s) failed"
  if [[ -n "$_AGENT_RUN_STARTED" ]]; then
    agent_run_emit_status "verify" 1 "$_AGENT_RUN_STARTED" "" \
      "VERIFY_PROFILE=${VERIFY_PROFILE} ./scripts/verify.sh" \
      "failed=${FAIL_COUNT} passed=${PASS_COUNT} warn=${WARN_COUNT}" \
      "{\"verifyStatus\":\"${VERIFY_STATUS_FILE}\"}"
  fi
  exit 1
fi
info "All checks passed (with $WARN_COUNT warning(s))"
if [[ -n "$_AGENT_RUN_STARTED" ]]; then
  agent_run_emit_status "verify" 0 "$_AGENT_RUN_STARTED" "" \
    "VERIFY_PROFILE=${VERIFY_PROFILE} ./scripts/verify.sh" \
    "passed=${PASS_COUNT} failed=${FAIL_COUNT} warn=${WARN_COUNT}" \
    "{\"verifyStatus\":\"${VERIFY_STATUS_FILE}\"}"
fi

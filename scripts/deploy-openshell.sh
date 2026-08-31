#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
check_openshell_cli
load_secrets
detect_environment
render_all_templates

# Two explicit, declarative values files (both rendered by
# render_all_templates from charts/openshell/*.yaml.tpl) instead of
# generating the no-oidc variant by sed-stripping the oidc: block out of the
# other one at deploy time.
VALUES_FILE="${RENDERED_DIR}/values-ocp.yaml"
if [[ "${WITH_OIDC:-true}" == "false" ]]; then
  info "OIDC disabled — using values-ocp-no-oidc.yaml (unauthenticated access)"
  VALUES_FILE="${RENDERED_DIR}/values-ocp-no-oidc.yaml"
fi

step "Resolving OpenShell chart dependency (pinned in Chart.yaml/Chart.lock)"
helm dependency build "${PROJECT_DIR}/charts/openshell"

step "Installing OpenShell (single release: namespace extras + gateway, v${OPENSHELL_CHART_VERSION})"
# The server's mTLS cert is minted by the subchart's own certgen Job with
# only default SANs (localhost/cluster-internal names) — the external Route
# hostname must be added explicitly via pkiInitJob.serverDnsNames, or
# CLI/gRPC clients connecting through the Route fail with "certificate not
# valid for name ...". Computed here (not in values-ocp*.yaml.tpl) because it
# depends on BOTH namespace and apps domain: a second, differently-namespaced
# deploy of this chart (coexisting with another project on the same cluster)
# needs its own correct SAN instead of a hardcoded "openshell" literal. Each
# SAN is its own --set-string with an indexed path rather than one --set
# with a brace list — found live (agentops-example, 2026-08-05) that a
# literal comma inside a single value confuses some shells/Make argument
# parsing, silently truncating the value.
helm upgrade --install "$OPENSHELL_RELEASE_NAME" "${PROJECT_DIR}/charts/openshell" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$VALUES_FILE" \
  --set global.appsDomain="${APPS_DOMAIN}" \
  --set-string "openshell.pkiInitJob.serverDnsNames[0]=openshell-gw-${NAMESPACE}.${APPS_DOMAIN}" \
  --set-string "openshell.pkiInitJob.serverDnsNames[1]=*.${APPS_DOMAIN}"

step "Waiting for gateway rollout (up to 600s for initial image pull)"
oc -n "$NAMESPACE" rollout status "statefulset/${OPENSHELL_RELEASE_NAME}" --timeout=600s

step "Waiting for PKI secrets (created by init job)"
for secret in openshell-server-tls openshell-client-tls "${OPENSHELL_RELEASE_NAME}-jwt-keys"; do
  retries=0
  while ! oc -n "$NAMESPACE" get secret "$secret" &>/dev/null; do
    if [[ $retries -ge 60 ]]; then
      error "Secret $secret not created within 120s"
      exit 1
    fi
    sleep 2
    retries=$((retries + 1))
  done
  info "Secret $secret exists"
done

step "Detecting gateway Route hostname"
GW_ROUTE=""
retries=0
while [[ -z "$GW_ROUTE" && $retries -lt 30 ]]; do
  GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -z "$GW_ROUTE" ]]; then
    sleep 2
    retries=$((retries + 1))
  fi
done
if [[ -z "$GW_ROUTE" ]]; then
  error "Could not detect Route hostname"
  exit 1
fi
info "Gateway Route: https://${GW_ROUTE}"

step "Registering gateway with CLI (mTLS)"
# Avoid unnecessary churn: only touch mTLS certs and (re-)run `gateway
# remove`+`add` if the gateway isn't already registered and connectable
# (e.g. a repeat `deploy` run against an unchanged Route). The status check
# MUST happen before touching any local cert state: `openshell gateway add`
# builds an internal client.p12 bundle from the raw cert files at
# registration time, so unconditionally overwriting those files first (even
# with byte-identical content) invalidates that cached bundle and forces
# every single run down the slow remove+add+retry path below -- defeating
# the point of skipping unneeded work. Observed live on CRC (docs/
# constraints.md #19): checking an already-registered, undisturbed gateway
# succeeds almost instantly and consistently, while immediately following a
# *fresh* remove+add with a status check is highly unreliable -- the
# gateway pod's server logs "TLS handshake failed: peer sent no
# certificates" for anywhere from seconds to 10+ minutes afterwards (most
# likely host-side memory pressure/scheduling delays on the box running the
# CRC VM, not anything wrong with the certs/route/pod itself).
# Global OPENSHELL_GATEWAY_INSECURE breaks client-cert mTLS (constraints #18/#19).
#
# `openshell status` alone is NOT enough to decide whether to skip
# re-registration: it only reports on whatever gateway alias is *currently
# selected/active* in the CLI, which — when coexisting with another
# project's own gateway registered under a different alias on this same
# machine — could easily be that OTHER project's alias, not ours. Found
# live: with agentops-example's "ocp" alias already selected and healthy,
# this check used to report "already connected" without ever registering or
# selecting THIS project's own $GATEWAY_NAME, silently leaving every
# subsequent `openshell` CLI call (provider creation, sandbox launch) aimed
# at the wrong project's gateway. Explicitly select $GATEWAY_NAME first so
# `openshell status` below can only report on the gateway we actually care
# about.
unset OPENSHELL_GATEWAY_INSECURE
GATEWAY_ALREADY_REGISTERED=false
if openshell gateway list 2>/dev/null | awk -v n="$GATEWAY_NAME" 'NR>1 { g=$1; sub(/^\*/,"",g); if (g==n) found=1 } END{exit !found}'; then
  GATEWAY_ALREADY_REGISTERED=true
  openshell gateway select "$GATEWAY_NAME" &>/dev/null || true
fi
if [[ "$GATEWAY_ALREADY_REGISTERED" != "true" ]] || ! openshell status &>/dev/null; then
  step "Extracting mTLS client certificates"
  MTLS_DIR="$HOME/.config/openshell/gateways/${GATEWAY_NAME}/mtls"
  # Wipe any stale bundle first: a leftover client.p12 built against a
  # previous cluster's CA (e.g. after `cluster-lifecycle.sh full --fresh`, which
  # only recreates the VM and doesn't touch this host-local CLI state) will
  # not match the newly issued server CA, causing an mTLS handshake failure
  # ("fatal alert: CertificateRequired") on `openshell status`.
  rm -rf "$MTLS_DIR"
  mkdir -p "$MTLS_DIR"
  oc -n "$NAMESPACE" get secret openshell-client-tls \
    -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$MTLS_DIR/ca.crt"
  oc -n "$NAMESPACE" get secret openshell-client-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "$MTLS_DIR/tls.crt"
  oc -n "$NAMESPACE" get secret openshell-client-tls \
    -o jsonpath='{.data.tls\.key}' | base64 -d > "$MTLS_DIR/tls.key"
  info "Certificates saved to $MTLS_DIR"

  openshell gateway remove "$GATEWAY_NAME" 2>/dev/null || true
  openshell gateway add "https://${GW_ROUTE}" --local --name "$GATEWAY_NAME"
  # Explicit, not relying on `add` to auto-select: on a machine with more
  # than one registered gateway (coexistence), the CLI's "active" gateway
  # after `add` shouldn't be assumed — select it by name so every command
  # below (`openshell status`, create_provider) definitely targets this one.
  openshell gateway select "$GATEWAY_NAME"
fi

retries=0
max_retries=40
until openshell status; do
  retries=$((retries + 1))
  if [[ $retries -ge $max_retries ]]; then
    error "openshell status failed after ${retries} attempts"
    exit 1
  fi
  info "Gateway connection not ready yet, retrying ($retries/$max_retries)..."
  sleep 20
done

step "Enabling providers_v2 and creating dual providers (best-effort)"
# Provider creation may fail here if OIDC auth is required but not yet
# configured. In that case cluster-lifecycle.sh will create it after
# configure-oidc.sh obtains the OIDC token (Phase 7b).
if enable_providers_v2 2>/dev/null && create_dual_providers 2>/dev/null; then
  configure_inference_route 2>/dev/null && info "Inference route ready" \
    || warn "Inference route configuration deferred"
  info "Dual providers ready (direct + guardrailed)"
else
  warn "Provider creation deferred (OIDC not configured yet)"
fi

step "OpenShell deployment complete"
info "Gateway: https://${GW_ROUTE} (mTLS)"
info "Providers: $PROVIDER_DIRECT (direct) + $PROVIDER_GUARDRAILED (guardrailed)"
info "Active: inference.local -> $INFERENCE_MODEL (backend=${INFERENCE_BACKEND})"

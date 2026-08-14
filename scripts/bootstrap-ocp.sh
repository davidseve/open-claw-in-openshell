#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment

# Red Hat build of Agent Sandbox Operator (OSC 1.13 Technology Preview).
# Package agent-sandbox-operator — NOT sandboxed-containers-operator (the
# unrelated base OSC/Kata operator). See docs/adrs/ADR-0004-agent-sandbox-redhat.md.
# On OCP/RHPDS, channel/CSV/namespace are pinned in
# charts/agent-sandbox/operators/values.yaml (not here) — see the else
# branch below.
AGENT_SANDBOX_NS="agent-sandbox-system"

step "Creating namespace: $NAMESPACE"
# opendatahub.io/dashboard=true marks this namespace as a Data Science
# Project the RHOAI Dashboard (docs/constraints.md #20) will list under
# Experiments/Prompts/Traces — applied declaratively here instead of a
# one-off `oc label` so it survives a fresh `cluster-lifecycle.sh full --fresh`.
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    opendatahub.io/dashboard: "true"
EOF

if [[ "$CRC_MODE" == "true" ]]; then
  # CRC / single-node: OLM redhat-operators catalog is typically unavailable.
  # Fall back to the pinned upstream kubernetes-sigs/agent-sandbox manifest so the
  # Sandbox CRDs + controller still exist for OpenShell's Kubernetes driver.
  step "CRC mode: installing Agent Sandbox CRDs and controller from pinned upstream manifest (v0.5.1)"
  oc apply -f "${PROJECT_DIR}/manifests/agent-sandbox-v0.5.1.yaml"
  info "Agent Sandbox controller and CRDs installed (CRC fallback — not the Red Hat OLM path)"
else
  step "Installing Red Hat build of Agent Sandbox Operator via Helm chart (charts/agent-sandbox)"
  # The Operator alone deploys the sandbox controller, sandbox router, and
  # extension CRDs (Sandbox, SandboxTemplate, SandboxClaim, SandboxWarmPool)
  # in agent-sandbox-system — no raw upstream manifest on OCP/RHPDS.
  # Docs: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/install-agent-sandbox-overview_agent-sandbox
  # Channel/CSV/namespace are pinned in charts/agent-sandbox/operators/values.yaml
  # (own, independent copy — deliberately not shared with agentops-example's
  # equivalent chart, see docs/adrs/ADR-0004-agent-sandbox-redhat.md).
  make -C "${PROJECT_DIR}/charts/agent-sandbox" wait-operators
fi

# Privileged SCC binding for the openshell-sandbox SA is no longer granted
# here imperatively (`oc adm policy add-scc-to-user`) — it's now a
# declarative RoleBinding template in charts/openshell (scc-rolebinding.yaml),
# applied by scripts/deploy-openshell.sh as part of the same Helm release
# that creates the SA itself. See docs/adrs/ADR-0006-scc-privileged-sandbox.md.

step "Verifying CRDs"
if oc get crd sandboxes.agents.x-k8s.io &>/dev/null; then
  info "Agent Sandbox CRD available"
else
  warn "CRD sandboxes.agents.x-k8s.io not yet available"
  if [[ "$CRC_MODE" == "true" ]]; then
    warn "CRC fallback: re-check manifests/agent-sandbox-v0.5.1.yaml apply"
  else
    warn "Ensure the Agent Sandbox Operator InstallPlan is approved and the controller is running"
    warn "  oc -n ${AGENT_SANDBOX_NS} get csv,subscription,pods"
  fi
fi

step "Bootstrap complete"

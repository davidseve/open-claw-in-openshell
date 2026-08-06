#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment

# Red Hat build of Agent Sandbox Operator (OSC 1.13 Technology Preview).
# Package agent-sandbox-operator — NOT sandboxed-containers-operator (the
# unrelated base OSC/Kata operator). See docs/adrs/ADR-0004-agent-sandbox-redhat.md.
AGENT_SANDBOX_NS="${AGENT_SANDBOX_NS:-agent-sandbox-system}"
AGENT_SANDBOX_CHANNEL="${AGENT_SANDBOX_CHANNEL:-preview-0.9}"
AGENT_SANDBOX_PACKAGE="${AGENT_SANDBOX_PACKAGE:-agent-sandbox-operator}"
# Pin CSV for reproducibility (confirmed on OCP 4.20.8 / redhat-operators 2026-08-06).
AGENT_SANDBOX_CSV="${AGENT_SANDBOX_CSV:-agent-sandbox-operator.v0.9.0}"

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
  step "Creating Agent Sandbox Operator namespace: ${AGENT_SANDBOX_NS}"
  oc get ns "${AGENT_SANDBOX_NS}" &>/dev/null \
    || oc create ns "${AGENT_SANDBOX_NS}"

  step "Installing Red Hat build of Agent Sandbox Operator via OLM (channel ${AGENT_SANDBOX_CHANNEL})"
  # The Operator alone deploys the sandbox controller, sandbox router, and
  # extension CRDs (Sandbox, SandboxTemplate, SandboxClaim, SandboxWarmPool)
  # in agent-sandbox-system — no raw upstream manifest on OCP/RHPDS.
  # Docs: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/install-agent-sandbox-overview_agent-sandbox
  if oc get csv -n "${AGENT_SANDBOX_NS}" -o name 2>/dev/null | grep -q agent-sandbox; then
    info "Agent Sandbox Operator CSV already present"
  else
    oc get operatorgroup -n "${AGENT_SANDBOX_NS}" agent-sandbox-operator &>/dev/null || \
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: agent-sandbox-operator
  namespace: ${AGENT_SANDBOX_NS}
spec: {}
EOF

    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: agent-sandbox-operator
  namespace: ${AGENT_SANDBOX_NS}
spec:
  channel: ${AGENT_SANDBOX_CHANNEL}
  installPlanApproval: Manual
  name: ${AGENT_SANDBOX_PACKAGE}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: ${AGENT_SANDBOX_CSV}
EOF
    info "Subscription created. Approving InstallPlan (Manual approval; channel pinned in git)..."
    # Wait briefly for OLM to create the InstallPlan, then approve it.
    for _ in $(seq 1 30); do
      PLAN=$(oc get subscription agent-sandbox-operator -n "${AGENT_SANDBOX_NS}" \
        -o jsonpath='{.status.installplan.name}' 2>/dev/null || true)
      if [[ -n "$PLAN" ]]; then
        APPROVED=$(oc get installplan "$PLAN" -n "${AGENT_SANDBOX_NS}" \
          -o jsonpath='{.spec.approved}' 2>/dev/null || true)
        if [[ "$APPROVED" != "true" ]]; then
          oc -n "${AGENT_SANDBOX_NS}" patch installplan "$PLAN" --type merge \
            -p '{"spec":{"approved":true}}' >/dev/null
          info "Approved InstallPlan ${PLAN}"
        fi
        break
      fi
      sleep 2
    done
    if [[ -z "${PLAN:-}" ]]; then
      warn "InstallPlan not yet created — approve manually when it appears:"
      warn "  oc -n ${AGENT_SANDBOX_NS} get installplan"
      warn "  oc -n ${AGENT_SANDBOX_NS} patch installplan <name> --type merge -p '{\"spec\":{\"approved\":true}}'"
    fi
  fi

  step "Waiting for Agent Sandbox CRDs from OLM operator"
  for _ in $(seq 1 60); do
    if oc get crd sandboxes.agents.x-k8s.io &>/dev/null; then
      info "Agent Sandbox CRD available"
      break
    fi
    sleep 5
  done
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

#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

check_prereqs
detect_environment

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

step "Installing Agent Sandbox CRDs and controller (v0.5.1)"
oc apply -f "${PROJECT_DIR}/manifests/agent-sandbox-v0.5.1.yaml"
info "Agent Sandbox controller and CRDs installed"

if [[ "$CRC_MODE" == "true" ]]; then
  info "CRC mode: skipping OLM operator subscription (single-node, CRDs applied directly)"
else
  step "Creating operator namespace"
  oc get ns openshift-sandboxed-containers-operator &>/dev/null \
    || oc create ns openshift-sandboxed-containers-operator

  step "Installing Agent Sandbox operator via OLM (OSC 1.12, CSV v1.12.0)"
  if oc get csv -n openshift-sandboxed-containers-operator sandboxed-containers-operator.v1.12.0 &>/dev/null; then
    info "Operator CSV already installed"
  else
    oc get operatorgroup -n openshift-sandboxed-containers-operator sandboxed-containers-operator-group &>/dev/null || \
    oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sandboxed-containers-operator-group
  namespace: openshift-sandboxed-containers-operator
spec:
  targetNamespaces:
  - openshift-sandboxed-containers-operator
EOF

    oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sandboxed-containers-operator
  namespace: openshift-sandboxed-containers-operator
spec:
  channel: stable
  installPlanApproval: Manual
  name: sandboxed-containers-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: sandboxed-containers-operator.v1.12.0
EOF
    info "Subscription created. Approve the InstallPlan manually:"
    info "  oc -n openshift-sandboxed-containers-operator get installplan"
    info "  oc -n openshift-sandboxed-containers-operator patch installplan <name> --type merge -p '{\"spec\":{\"approved\":true}}'"
  fi
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
  warn "Ensure the operator InstallPlan is approved and the controller is running"
fi

step "Bootstrap complete"

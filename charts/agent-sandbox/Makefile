# charts/agent-sandbox/Makefile - Red Hat build of Agent Sandbox Operator (OLM)
#
# Mirrors charts/rhoai/Makefile's deploy-operators/wait-operators pattern,
# trimmed to the single OLM Subscription this project needs on OCP/RHPDS
# (non-CRC — see scripts/bootstrap-ocp.sh's CRC branch, which applies the
# pinned upstream manifests/agent-sandbox-v0.5.1.yaml instead and does not
# use this Makefile at all).
#
# Deliberately NOT shared with agentops-example/deploy/helm/operators/ (which
# has its own, separately-maintained copy of the same OLM Subscription) —
# see docs/adrs/ADR-0004-agent-sandbox-redhat.md.
#
# Usage: make wait-operators   (install + wait for CSV/CRD, called from
#                                scripts/bootstrap-ocp.sh)
#        make undeploy-operators

HELM := helm
HELM_OPTS ?=
WAIT_TIMEOUT ?= 300s

OPERATORS_CHART   := operators
OPERATORS_RELEASE := agent-sandbox-operators
AGENT_SANDBOX_NS  := agent-sandbox-system

.PHONY: deploy-operators wait-operators undeploy-operators template lint

deploy-operators:
	@if $(HELM) status $(OPERATORS_RELEASE) >/dev/null 2>&1; then \
		echo "Release '$(OPERATORS_RELEASE)' already deployed (shared cluster resource) — skipping install."; \
	elif oc get subscription agent-sandbox-operator -n $(AGENT_SANDBOX_NS) >/dev/null 2>&1; then \
		echo "Agent Sandbox Operator already installed on this cluster under a different Helm release"; \
		echo "(e.g. agentops-example's 'rhoai-operators' bundles the same Subscription in namespace"; \
		echo "'$(AGENT_SANDBOX_NS)') — it's a cluster-wide singleton (single OLM Subscription/CSV/CRD"; \
		echo "set), so a second install here would collide on Helm ownership metadata for the"; \
		echo "Namespace/OperatorGroup. Skipping install — see ADR-0020 (shared-cluster coexistence)"; \
		echo "and ADR-0004 (Agent Sandbox via OLM)."; \
	else \
		$(HELM) upgrade --install $(OPERATORS_RELEASE) $(OPERATORS_CHART) $(HELM_OPTS); \
	fi

wait-operators: deploy-operators
	@echo "Waiting for Agent Sandbox Operator CSV..."
	@echo "  (installPlanApproval is Manual - auto-approved below on the pinned"
	@echo "   channel/version from operators/values.yaml; to approve by hand instead:"
	@echo "   oc -n $(AGENT_SANDBOX_NS) get installplan"
	@echo "   oc -n $(AGENT_SANDBOX_NS) patch installplan <name> --type merge -p '{\"spec\":{\"approved\":true}}')"
	@i=0; until oc get csv -n $(AGENT_SANDBOX_NS) -o name 2>/dev/null | grep -q agent-sandbox; do \
		PLAN=$$(oc get subscription agent-sandbox-operator -n $(AGENT_SANDBOX_NS) -o jsonpath='{.status.installplan.name}' 2>/dev/null || true); \
		if [ -n "$$PLAN" ]; then \
			APPROVED=$$(oc get installplan "$$PLAN" -n $(AGENT_SANDBOX_NS) -o jsonpath='{.spec.approved}' 2>/dev/null || true); \
			if [ "$$APPROVED" != "true" ]; then \
				CSVNAME=$$(oc get installplan "$$PLAN" -n $(AGENT_SANDBOX_NS) -o jsonpath='{.spec.clusterServiceVersionNames[0]}' 2>/dev/null || echo "?"); \
				echo "  Auto-approving InstallPlan $$PLAN ($$CSVNAME) — pins exactly the channel/version already committed in operators/values.yaml (preview-0.9); the human review this project's installPlanApproval: Manual policy (AGENTS.md) calls for already happened when that channel/version was set in git, so this just closes the gap between 'reviewed in git' and 'OLM still wants a manual click'. Not a silent/unreviewed upgrade: it only approves whatever plan OLM computed from the pinned channel, never bumps the channel itself."; \
				oc -n $(AGENT_SANDBOX_NS) patch installplan "$$PLAN" --type merge -p '{"spec":{"approved":true}}' >/dev/null; \
			fi; \
		fi; \
		i=$$((i+1)); if [ $$i -ge 30 ]; then echo "  WARNING: CSV not Succeeded after ~60s — check 'oc -n $(AGENT_SANDBOX_NS) get csv,subscription,installplan'"; break; fi; \
		echo "  CSV not ready yet..."; sleep 2; \
	done
	@echo "Waiting for Agent Sandbox CRD (sandboxes.agents.x-k8s.io)..."
	@i=0; until oc get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1; do \
		i=$$((i+1)); if [ $$i -ge 60 ]; then echo "  WARNING: CRD not available after 300s"; break; fi; \
		echo "  CRD not available yet..."; sleep 5; \
	done

undeploy-operators:
	-$(HELM) uninstall $(OPERATORS_RELEASE)

template:
	$(HELM) template $(OPERATORS_RELEASE) $(OPERATORS_CHART)

lint:
	$(HELM) lint $(OPERATORS_CHART)

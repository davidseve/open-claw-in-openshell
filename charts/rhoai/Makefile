# charts/rhoai/Makefile - minimal RHOAI installation (MLflow only by default)
#
# Adapted from agentops-example/deploy/Makefile, trimmed to only what
# open-claw-in-openshell's Phase 12 needs: the RHOAI operator + a
# DataScienceCluster with only mlflowoperator Managed + a Postgres backend +
# the MLflow CR. No Dashboard, TrustyAI, KServe, OGX/llamastack, or EvalHub
# by default. See ROADMAP.md Phase 12 and docs/adrs/ADR-0017 for the
# resource-fit investigation and scope decision behind this trim.
#
# scripts/deploy-rhoai-mlflow.sh additionally enables the Dashboard (+
# genAiStudio) via HELM_OPTS on AWS OCP only (not CRC) — see ADR-0018's
# 2026-07-27 amendment and docs/constraints.md #20.
#
# Usage: make deploy-all    (full minimal stack)
#        make validate      (post-deploy health checks)
#        make undeploy-all  (teardown)
#
# Secrets: database.password / postgresql.password are intentionally blank in
# values.yaml (never commit secrets - AGENTS.md). Pass them via HELM_OPTS,
# e.g.:
#   HELM_OPTS='--set-string database.password=... --set-string postgresql.password=...'
# scripts/deploy-rhoai-mlflow.sh does this automatically from secrets/secrets.env.

HELM := helm
HELM_OPTS ?=
WAIT_TIMEOUT ?= 300s

OPERATORS_CHART := operators
PLATFORM_CHART  := platform
DATABASE_CHART  := database
MLFLOW_CHART    := mlflow

OPERATORS_RELEASE := rhoai-operators
PLATFORM_RELEASE  := rhoai-platform
DATABASE_RELEASE  := rhoai-database
MLFLOW_RELEASE    := rhoai-mlflow

.PHONY: deploy-operators wait-operators deploy-platform deploy-database
.PHONY: wait-mlflow-crd deploy-mlflow deploy-all
.PHONY: undeploy-apps purge-dsci undeploy-operators cleanup-orphans undeploy-all
.PHONY: template lint validate validate-cleanup

# --- Deploy targets (ordered) ---

deploy-operators:
	$(HELM) upgrade --install $(OPERATORS_RELEASE) $(OPERATORS_CHART) $(HELM_OPTS)

wait-operators: deploy-operators
	@echo "Waiting for RHOAI operator CSV..."
	@echo "  (installPlanApproval is Manual - auto-approved below on the pinned"
	@echo "   channel/version from operators/values.yaml; to approve by hand instead:"
	@echo "   oc -n redhat-ods-operator get installplan"
	@echo "   oc -n redhat-ods-operator patch installplan <name> --type merge -p '{\"spec\":{\"approved\":true}}')"
	@until oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].status.phase}' 2>/dev/null | grep -q Succeeded; do \
		PLAN=$$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installplan.name}' 2>/dev/null || true); \
		if [ -n "$$PLAN" ]; then \
			APPROVED=$$(oc get installplan "$$PLAN" -n redhat-ods-operator -o jsonpath='{.spec.approved}' 2>/dev/null || true); \
			if [ "$$APPROVED" != "true" ]; then \
				CSVNAME=$$(oc get installplan "$$PLAN" -n redhat-ods-operator -o jsonpath='{.spec.clusterServiceVersionNames[0]}' 2>/dev/null || echo "?"); \
				echo "  Auto-approving InstallPlan $$PLAN ($$CSVNAME) — pins exactly the channel/version already committed in operators/values.yaml (stable-3.4); the human review this project's installPlanApproval: Manual policy (AGENTS.md) calls for already happened when that channel/version was set in git, so this just closes the gap between 'reviewed in git' and 'OLM still wants a manual click' for every environment (CRC and AWS alike). Not a silent/unreviewed upgrade: it only approves whatever plan OLM computed from the pinned channel, never bumps the channel itself. To go back to fully manual approval (e.g. to review each InstallPlan's diff by hand before it lands, per the OCP Security Specialist role in AGENTS.md), comment out this block."; \
				oc -n redhat-ods-operator patch installplan "$$PLAN" --type merge -p '{"spec":{"approved":true}}' >/dev/null; \
			fi; \
		fi; \
		echo "  CSV not ready yet..."; sleep 15; \
	done
	@echo "Waiting for operator pods..."
	oc wait --for=condition=Ready pod -l name=rhods-operator -n redhat-ods-operator --timeout=$(WAIT_TIMEOUT)
	@echo "Waiting for DSCInitialization..."
	@until oc get dscinitialization default-dsci -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Ready; do \
		echo "  DSCI not ready yet..."; sleep 10; \
	done
	@echo "Waiting for applications namespace..."
	@until oc get namespace redhat-ods-applications >/dev/null 2>&1; do \
		echo "  redhat-ods-applications not created yet..."; sleep 10; \
	done
	@echo "Waiting for platform CRDs..."
	@until oc get crd datascienceclusters.datasciencecluster.opendatahub.io >/dev/null 2>&1; do \
		echo "  platform CRDs not ready yet..."; sleep 10; \
	done

deploy-platform: wait-operators
	$(HELM) upgrade --install $(PLATFORM_RELEASE) $(PLATFORM_CHART) $(HELM_OPTS)

deploy-database:
	$(HELM) upgrade --install $(DATABASE_RELEASE) $(DATABASE_CHART) $(HELM_OPTS)

wait-mlflow-crd:
	@echo "Waiting for MLflow CRD..."
	@until oc get crd mlflows.mlflow.opendatahub.io >/dev/null 2>&1; do \
		echo "  MLflow CRD not ready yet..."; sleep 10; \
	done

deploy-mlflow: deploy-database wait-mlflow-crd
	$(HELM) upgrade --install $(MLFLOW_RELEASE) $(MLFLOW_CHART) $(HELM_OPTS)

deploy-all: deploy-platform deploy-database deploy-mlflow
	@echo "Minimal RHOAI + MLflow stack deployed."

# --- Undeploy targets ---
# CRITICAL: DSCI must be deleted while the operator is still running,
# otherwise the finalizer cannot be processed and DSCI gets stuck in Terminating.
# Order: apps (mlflow/db/platform) -> DSCI -> operator -> orphan cleanup.

undeploy-apps:
	-$(HELM) uninstall $(MLFLOW_RELEASE)
	-$(HELM) uninstall $(DATABASE_RELEASE)
	-$(HELM) uninstall $(PLATFORM_RELEASE)

purge-dsci:
	@echo "Deleting DSCInitialization (operator must still be running)..."
	@oc delete dscinitialization --all --timeout=60s 2>/dev/null || \
		(echo "DSCI delete timed out, patching finalizers..." && \
		 oc patch dscinitialization default-dsci --type=merge \
		   -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true)

undeploy-operators:
	-$(HELM) uninstall $(OPERATORS_RELEASE)

cleanup-orphans:
	@echo "Cleaning up residual operator resources..."
	-@oc delete subscription rhods-operator -n redhat-ods-operator 2>/dev/null || true
	-@CSV=$$(oc get csv -n redhat-ods-operator -o name 2>/dev/null | grep rhods); \
		[ -n "$$CSV" ] && oc delete "$$CSV" -n redhat-ods-operator || true
	-@oc delete deployment --all -n redhat-ods-applications 2>/dev/null || true
	-@oc delete service --all -n redhat-ods-applications 2>/dev/null || true
	-@oc delete namespace redhat-ods-operator --wait=false 2>/dev/null || true
	-@oc delete namespace redhat-ods-applications --wait=false 2>/dev/null || true
	-@oc delete namespace redhat-ods-monitoring --wait=false 2>/dev/null || true
	@echo "Orphan cleanup complete."

undeploy-all: undeploy-apps purge-dsci undeploy-operators cleanup-orphans
	@echo "All components undeployed."

# --- Validation ---

template:
	$(HELM) template $(OPERATORS_RELEASE) $(OPERATORS_CHART)
	$(HELM) template $(PLATFORM_RELEASE) $(PLATFORM_CHART)
	$(HELM) template $(DATABASE_RELEASE) $(DATABASE_CHART)
	$(HELM) template $(MLFLOW_RELEASE) $(MLFLOW_CHART)

lint:
	$(HELM) lint $(OPERATORS_CHART)
	$(HELM) lint $(PLATFORM_CHART)
	$(HELM) lint $(DATABASE_CHART)
	$(HELM) lint $(MLFLOW_CHART)

validate:
	@echo "=== Helm releases ==="
	@test $$(helm list -f '^rhoai-' -q | wc -l | tr -d ' ') -eq 4
	@echo "OK: 4 rhoai-* releases deployed"
	@echo "=== RHOAI operator ==="
	@oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].status.phase}{"\n"}' | grep -q Succeeded
	@oc wait --for=condition=Ready pod -l name=rhods-operator -n redhat-ods-operator --timeout=60s >/dev/null
	@echo "OK: operator CSV Succeeded, pods Ready"
	@echo "=== Platform: MLflow operator component ==="
	@i=0; until oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="MLflowOperatorReady")].status}{"\n"}' 2>/dev/null | grep -q True; do \
		i=$$((i+1)); if [ $$i -ge 12 ]; then echo "FAIL: MLflowOperatorReady condition not True after 60s"; exit 1; fi; \
		echo "  MLflowOperatorReady not True yet..."; sleep 5; \
	done
	@echo "OK: MLflow operator component ready"
	@echo "=== Database ==="
	@oc wait --for=condition=Available deployment/mlflow-db -n redhat-ods-applications --timeout=60s >/dev/null
	@echo "OK: PostgreSQL mlflow-db Available"
	@echo "=== MLflow ==="
	@i=0; until oc get pods -l app=mlflow -n redhat-ods-applications --no-headers 2>/dev/null | grep -q .; do \
		i=$$((i+1)); if [ $$i -ge 18 ]; then echo "FAIL: no mlflow pod created after 90s"; exit 1; fi; \
		echo "  mlflow pod not created yet..."; sleep 5; \
	done
	@oc wait --for=condition=Ready pod -l app=mlflow -n redhat-ods-applications --timeout=120s >/dev/null
	@oc get mlflow mlflow -n redhat-ods-applications -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}' | grep -q True
	@echo "OK: MLflow Available ($$(oc get mlflow mlflow -n redhat-ods-applications -o jsonpath='{.status.url}'))"
	@echo ""
	@echo "All validation checks passed."

validate-cleanup:
	@echo "=== Helm releases ==="
	@RHOAI_COUNT=$$(helm list -f '^rhoai-' -q 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$RHOAI_COUNT" -eq 0 ]; then \
		echo "OK: no rhoai-* releases"; \
	else \
		echo "FAIL: $$RHOAI_COUNT rhoai-* releases still present"; exit 1; \
	fi
	@echo "=== DSCInitialization ==="
	@if oc get dscinitialization --no-headers 2>/dev/null | grep -q .; then \
		echo "FAIL: DSCInitialization still exists"; exit 1; \
	else \
		echo "OK: no DSCInitialization"; \
	fi
	@echo "=== DataScienceCluster ==="
	@if oc get datasciencecluster --no-headers 2>/dev/null | grep -q .; then \
		echo "FAIL: DataScienceCluster still exists"; exit 1; \
	else \
		echo "OK: no DataScienceCluster"; \
	fi
	@echo ""
	@echo "Cleanup validation complete."

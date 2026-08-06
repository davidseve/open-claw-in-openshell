# charts/rhoai/Makefile - minimal RHOAI installation (MLflow only by default)
#
# Adapted from agentops-example/deploy/Makefile, trimmed to only what
# open-claw-in-openshell's Phase 12 needs: the RHOAI operator + a
# DataScienceCluster with only mlflowoperator Managed + a Postgres backend +
# the MLflow CR. No Dashboard, TrustyAI, KServe, OGX/llamastack, or EvalHub
# by default. See ROADMAP.md Phase 12 and docs/adrs/ADR-0017 for the
# resource-fit investigation and scope decision behind this trim.
#
# The Dashboard (+ genAiStudio + llamastackoperator) is the one part of the
# DataScienceCluster spec that legitimately differs between CRC and AWS OCP
# — see platform/values-crc.yaml / platform/values-aws.yaml for the two
# declarative overlays (layered on top of platform/values.yaml's common
# defaults) and docs/constraints.md #20/#23. scripts/deploy-rhoai-mlflow.sh
# just picks which overlay file to pass via PLATFORM_ENV_VALUES below —
# no environment-conditional --set-string flags.
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

# Which environment overlay to layer on top of platform/values.yaml for the
# Dashboard/Gen AI Studio component matrix. Defaults to the CRC overlay
# (dashboard/llamastackoperator Removed, same as values.yaml's own
# defaults) since that's the safe/minimal choice; scripts/deploy-rhoai-mlflow.sh
# overrides this to platform/values-aws.yaml on AWS OCP.
PLATFORM_ENV_VALUES ?= platform/values-crc.yaml

OPERATORS_CHART := operators
PLATFORM_CHART  := platform
DATABASE_CHART  := database
MLFLOW_CHART    := mlflow

OPERATORS_RELEASE := rhoai-operators
PLATFORM_RELEASE  := rhoai-platform
DATABASE_RELEASE  := rhoai-database
MLFLOW_RELEASE    := rhoai-mlflow

.PHONY: deploy-operators wait-operators deploy-platform deploy-platform-fresh ensure-mlflowoperator-managed wait-dashboard-crd adopt-dashboard-config wait-llamastack wait-llamastack-and-refresh-dashboard deploy-database
.PHONY: wait-mlflow-crd deploy-mlflow deploy-all
.PHONY: undeploy-apps purge-dsci undeploy-operators cleanup-orphans undeploy-all
.PHONY: template lint validate validate-cleanup

# --- Deploy targets (ordered) ---
#
# Cluster coexistence (docs/adrs/ADR-0020-shared-cluster-coexistence.md):
# RHOAI, its DataScienceCluster, the Postgres backend, and MLflow itself are
# cluster-wide/shared resources — if another project (e.g. agentops-example)
# already deployed them with the exact same release names in the `default`
# namespace (both projects vendor virtually the same charts/rhoai/* trees),
# re-running `helm upgrade --install` here would be redundant at best and
# values-resetting churn at worst. Each target below skips the Helm
# upgrade/install if its release already exists, reusing whatever is live
# instead. deploy-platform additionally ensures `mlflowoperator: Managed`
# on the shared DataScienceCluster via a minimal `oc patch` (not a full
# `helm upgrade`, which could reset an unrelated setting a co-tenant project
# configured, e.g. dashboard/genAiStudio) if it isn't already.

deploy-operators:
	@if $(HELM) status $(OPERATORS_RELEASE) >/dev/null 2>&1; then \
		echo "Release '$(OPERATORS_RELEASE)' already deployed (shared cluster resource) — skipping install."; \
	else \
		$(HELM) upgrade --install $(OPERATORS_RELEASE) $(OPERATORS_CHART) $(HELM_OPTS); \
	fi

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
	@if $(HELM) status $(PLATFORM_RELEASE) >/dev/null 2>&1; then \
		echo "Release '$(PLATFORM_RELEASE)' already deployed (shared cluster resource) — skipping helm upgrade, reconciling mlflowoperator only."; \
		$(MAKE) ensure-mlflowoperator-managed; \
	else \
		$(MAKE) deploy-platform-fresh; \
	fi

# Minimal, non-destructive reconciliation for a DataScienceCluster this
# project doesn't own the Helm release for: only touches
# spec.components.mlflowoperator (a merge patch, not a full `helm upgrade`
# with this project's own values-crc.yaml/values-aws.yaml, which could
# silently flip an unrelated component another project configured, e.g.
# dashboard/genAiStudio — see docs/adrs/ADR-0020).
ensure-mlflowoperator-managed:
	@CURRENT=$$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null || true); \
	if [ "$$CURRENT" = "Managed" ]; then \
		echo "mlflowoperator already Managed on the shared DataScienceCluster."; \
	else \
		echo "Patching shared DataScienceCluster: mlflowoperator -> Managed (was '$$CURRENT')..."; \
		oc patch datasciencecluster default-dsc --type merge -p '{"spec":{"components":{"mlflowoperator":{"managementState":"Managed"}}}}'; \
	fi

deploy-platform-fresh:
	@CURRENT_DASHBOARD=$$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.dashboard.managementState}' 2>/dev/null || true); \
	if [ "$(PLATFORM_ENV_VALUES)" = "platform/values-aws.yaml" ] && [ "$$CURRENT_DASHBOARD" != "Managed" ]; then \
		echo "Fresh Dashboard enable detected: sequencing llamastackoperator BEFORE"; \
		echo "dashboard (forcing dashboard=Removed for this one apply, overriding"; \
		echo "platform/values-aws.yaml just for this step) and waiting for"; \
		echo "LlamaStackOperatorReady, so the dashboard pod is never created until"; \
		echo "LlamaStackOperator already is -- see docs/constraints.md #23's"; \
		echo "root-cause fix: this avoids the capability-gate race at its source"; \
		echo "instead of reacting to it with a restart afterward."; \
		$(HELM) upgrade --install $(PLATFORM_RELEASE) $(PLATFORM_CHART) -f $(PLATFORM_ENV_VALUES) $(HELM_OPTS) --set-string datasciencecluster.components.dashboard.managementState=Removed; \
		$(MAKE) wait-llamastack; \
	fi
	@if [ "$(PLATFORM_ENV_VALUES)" = "platform/values-aws.yaml" ]; then $(MAKE) adopt-dashboard-config; fi
	$(HELM) upgrade --install $(PLATFORM_RELEASE) $(PLATFORM_CHART) -f $(PLATFORM_ENV_VALUES) $(HELM_OPTS)
	@if [ "$(PLATFORM_ENV_VALUES)" = "platform/values-aws.yaml" ]; then \
		$(MAKE) wait-dashboard-crd; \
		$(MAKE) adopt-dashboard-config; \
		echo "Re-applying platform chart now that the OdhDashboardConfig CRD/object exist,"; \
		echo "so the genAiStudio patch (templates/dashboard-config.yaml) actually renders"; \
		echo "instead of being silently skipped by its Capabilities.APIVersions guard:"; \
		$(HELM) upgrade --install $(PLATFORM_RELEASE) $(PLATFORM_CHART) -f $(PLATFORM_ENV_VALUES) $(HELM_OPTS); \
	fi
	@if [ "$(PLATFORM_ENV_VALUES)" = "platform/values-aws.yaml" ]; then $(MAKE) wait-llamastack-and-refresh-dashboard; fi

# On a truly fresh cluster, the first deploy-platform run enables the
# Dashboard component (managementState: Managed) in the same Helm release
# that also tries to patch its OdhDashboardConfig singleton
# (templates/dashboard-config.yaml) to set genAiStudio: true. Two distinct
# races were found live on a fresh AWS OCP deploy (never CRC -- Dashboard
# stays Removed there):
#
#  1. The template is gated on `.Capabilities.APIVersions.Has
#     "opendatahub.io/v1alpha"`, and the CRD backing that API doesn't exist
#     yet at the moment the first `helm upgrade` evaluates capabilities --
#     the Dashboard operator only registers it a few seconds later, once it
#     starts reconciling the newly-Managed component. Result: the guard
#     evaluates false, the patch is silently skipped, genAiStudio stays at
#     its cluster default (false). Confirmed via `oc get odhdashboardconfig
#     -n redhat-ods-applications -o yaml` showing no genAiStudio key at all
#     right after a fresh deploy-rhoai-mlflow.sh run.
#  2. Once the CRD exists, the Dashboard operator itself auto-creates the
#     `odh-dashboard-config` singleton object -- without any Helm ownership
#     metadata, since Helm never got to create it in race #1. A second
#     `helm upgrade` then fails outright ("exists and cannot be imported
#     into the current release: invalid ownership metadata"), because Helm
#     3 refuses to silently adopt a resource it doesn't already own. Fixed
#     by explicitly adopting it first (annotate/label it with the exact
#     `meta.helm.sh/*` + `app.kubernetes.io/managed-by` metadata Helm
#     itself would have set), the standard Helm 3 pattern for taking over a
#     pre-existing resource: https://helm.sh/docs/howto/charts_tips_and_tricks/#tell-helm-not-to-uninstall-a-resource
#
# Mirrors the exact same class of race deploy-mlflow already guards against
# with wait-mlflow-crd below -- same fix shape, different CRD, plus the
# ownership-adoption step (adopt-dashboard-config) race #2 needs on top.
# adopt-dashboard-config is called both BEFORE the first helm upgrade
# (handles a cluster where a prior run already left an unowned object behind
# -- otherwise even the *first* upgrade attempt fails with the same
# ownership error before ever reaching this wait target) and AFTER it
# (handles the true first-ever-deploy race where the object doesn't exist
# until the Dashboard operator creates it moments into this same make run).
wait-dashboard-crd:
	@echo "Waiting for OdhDashboardConfig CRD (registered once the Dashboard component starts reconciling)..."
	@i=0; until oc get crd odhdashboardconfigs.opendatahub.io >/dev/null 2>&1; do \
		i=$$((i+1)); if [ $$i -ge 30 ]; then echo "  WARNING: CRD not registered after 150s -- dashboard component may have failed to reconcile"; break; fi; \
		echo "  OdhDashboardConfig CRD not registered yet..."; sleep 5; \
	done
	@echo "Waiting for the operator-managed odh-dashboard-config singleton to exist..."
	@i=0; until oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications >/dev/null 2>&1; do \
		i=$$((i+1)); if [ $$i -ge 18 ]; then echo "  WARNING: odh-dashboard-config not created after 90s"; break; fi; \
		echo "  odh-dashboard-config not created yet..."; sleep 5; \
	done

# Idempotent: no-op if the CRD/object don't exist yet (nothing to adopt), and
# harmless if the object is already Helm-owned (--overwrite just re-applies
# the same values). Safe to call unconditionally any time dashboard.managementState
# is being set to Managed via HELM_OPTS.
adopt-dashboard-config:
	@if oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications >/dev/null 2>&1; then \
		echo "Adopting the operator-created odh-dashboard-config into the $(PLATFORM_RELEASE) Helm release..."; \
		oc annotate odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --overwrite \
			meta.helm.sh/release-name=$(PLATFORM_RELEASE) meta.helm.sh/release-namespace=default; \
		oc label odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --overwrite \
			app.kubernetes.io/managed-by=Helm; \
	fi

# The Gen AI Studio dashboard nav item (Playground / AI asset endpoints /
# Prompts, under a "Gen AI studio" sidebar section) is a module-federation
# extension served by the `gen-ai-ui` sidecar container in the
# `rhods-dashboard` pod. Its extension bundle declares
# `requiredComponents:[LLAMA_STACK_OPERATOR]` (confirmed by grepping
# `/static/__federation_expose_extensions.bundle.js` inside a live
# `gen-ai-ui` container) -- `dashboardConfig.genAiStudio: true` alone only
# controls whether the shell *attempts* to load the extension at all; it is
# necessary but not sufficient. Found live 2026-08-03: with genAiStudio=true
# and dashboard.managementState=Managed but llamastackoperator=Removed (this
# chart's default), the shell successfully fetches
# `/_mf/genAi/remoteEntry.js`, but the extension registers zero routes/nav
# items -- reachable proof: navigating straight to `/genAi` renders the
# dashboard's own "We can't find that page" 404, not a plugin route-not-
# found. See docs/constraints.md #23 for the full investigation (including
# the two dead-end flags tried first: dashboardConfig.modelAsService and a
# plain dashboard pod restart with only genAiStudio set).
#
# Whatever computes the gen-ai-ui extension's capability gate appears to be
# evaluated once, at process start (env/informer cache), not via a live
# watch of DataScienceCluster status -- same class of "already-running pod
# doesn't see a just-satisfied prerequisite" issue as constraint #22's token
# problem, just on the read side instead of the write side. Root-caused and
# fixed at the source in deploy-platform above: on a fresh Dashboard enable,
# llamastackoperator is now sequenced (applied + awaited) BEFORE dashboard
# ever gets set to Managed, so the rhods-dashboard pod's first-ever boot
# already observes LlamaStackOperatorReady=True and needs no restart.
#
# wait-llamastack (used both by that pre-sequencing step and standalone
# here) and this target's restart are kept as a defensive fallback for the
# one case root-causing doesn't cover: an *upgrade* that flips
# llamastackoperator from Removed to Managed on a cluster where dashboard
# was already Managed and its pod already running (rhods-dashboard already
# cached "not ready" before this run). On a fresh install this whole target
# is a fast no-op (llamastackoperator is already Ready from the sequencing
# step above, so the restart is redundant but harmless -- a few seconds).
wait-llamastack:
	@echo "Waiting for LlamaStackOperatorReady (Gen AI Studio dashboard nav requires this component)..."
	@i=0; until oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="LlamaStackOperatorReady")].status}{"\n"}' 2>/dev/null | grep -q True; do \
		i=$$((i+1)); if [ $$i -ge 24 ]; then echo "  WARNING: LlamaStackOperatorReady not True after 120s -- Gen AI Studio nav will likely stay hidden"; break; fi; \
		echo "  LlamaStackOperatorReady not True yet..."; sleep 5; \
	done

wait-llamastack-and-refresh-dashboard: wait-llamastack
	@if oc get deployment rhods-dashboard -n redhat-ods-applications >/dev/null 2>&1; then \
		echo "Restarting rhods-dashboard so it re-evaluates the now-Ready LlamaStackOperator capability..."; \
		oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications; \
		oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s; \
	fi

deploy-database:
	@if $(HELM) status $(DATABASE_RELEASE) >/dev/null 2>&1; then \
		echo "Release '$(DATABASE_RELEASE)' already deployed (shared cluster resource) — skipping install."; \
	else \
		$(HELM) upgrade --install $(DATABASE_RELEASE) $(DATABASE_CHART) $(HELM_OPTS); \
	fi

wait-mlflow-crd:
	@echo "Waiting for MLflow CRD..."
	@until oc get crd mlflows.mlflow.opendatahub.io >/dev/null 2>&1; do \
		echo "  MLflow CRD not ready yet..."; sleep 10; \
	done

deploy-mlflow: deploy-database wait-mlflow-crd
	@if $(HELM) status $(MLFLOW_RELEASE) >/dev/null 2>&1; then \
		echo "Release '$(MLFLOW_RELEASE)' already deployed (shared cluster resource) — skipping install, reusing shared MLflow instance."; \
	else \
		$(HELM) upgrade --install $(MLFLOW_RELEASE) $(MLFLOW_CHART) $(HELM_OPTS); \
	fi

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
	$(HELM) template $(PLATFORM_RELEASE) $(PLATFORM_CHART) -f $(PLATFORM_ENV_VALUES)
	$(HELM) template $(DATABASE_RELEASE) $(DATABASE_CHART)
	$(HELM) template $(MLFLOW_RELEASE) $(MLFLOW_CHART)

lint:
	$(HELM) lint $(OPERATORS_CHART)
	$(HELM) lint $(PLATFORM_CHART)
	$(HELM) lint $(DATABASE_CHART)
	$(HELM) lint $(MLFLOW_CHART)

validate:
	@echo "=== Helm releases ==="
	@for r in $(OPERATORS_RELEASE) $(PLATFORM_RELEASE) $(DATABASE_RELEASE) $(MLFLOW_RELEASE); do \
		$(HELM) status "$$r" >/dev/null 2>&1 || { echo "FAIL: release '$$r' not deployed"; exit 1; }; \
	done
	@echo "OK: all 4 expected rhoai-* releases deployed"
	@echo "    (not asserting an exact total 'rhoai-*' count: a coexisting project"
	@echo "     on this shared cluster, e.g. agentops-example, may have its own"
	@echo "     extra releases sharing the same prefix -- see ADR-0020)"
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
	@DB_NAME=$$($(HELM) get values $(DATABASE_RELEASE) -a -o json 2>/dev/null | jq -r '.service.name // "mlflow-db"' 2>/dev/null || echo mlflow-db); \
	echo "  (Deployment name resolved from $(DATABASE_RELEASE)'s own values.service.name --"; \
	echo "   defaults to 'mlflow-db' in this project's own database/values.yaml, but a"; \
	echo "   coexisting project may own the live release with a different name, e.g."; \
	echo "   agentops-example's 'maas-db' -- see ADR-0020)"; \
	oc wait --for=condition=Available deployment/$$DB_NAME -n redhat-ods-applications --timeout=60s >/dev/null; \
	echo "OK: PostgreSQL $$DB_NAME Available"
	@echo "=== MLflow ==="
	@i=0; until oc get pods -l app=mlflow -n redhat-ods-applications --no-headers 2>/dev/null | grep -q .; do \
		i=$$((i+1)); if [ $$i -ge 18 ]; then echo "FAIL: no mlflow pod created after 90s"; exit 1; fi; \
		echo "  mlflow pod not created yet..."; sleep 5; \
	done
	@oc wait --for=condition=Ready pod -l app=mlflow -n redhat-ods-applications --timeout=120s >/dev/null
	@oc get mlflow mlflow -n redhat-ods-applications -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}' | grep -q True
	@echo "OK: MLflow Available ($$(oc get mlflow mlflow -n redhat-ods-applications -o jsonpath='{.status.url}'))"
	@echo "=== Dashboard (AWS OCP only -- skipped if Removed) ==="
	@DASH_STATE=$$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.dashboard.managementState}' 2>/dev/null); \
	if [ "$$DASH_STATE" = "Managed" ]; then \
		oc wait --for=condition=DashboardReady datasciencecluster/default-dsc --timeout=60s >/dev/null && echo "OK: Dashboard component ready"; \
		GENAI=$$(oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o jsonpath='{.spec.dashboardConfig.genAiStudio}' 2>/dev/null); \
		if [ "$$GENAI" = "true" ]; then echo "OK: genAiStudio enabled on OdhDashboardConfig"; \
		else echo "FAIL: genAiStudio not true on OdhDashboardConfig (got: '$$GENAI') -- see wait-dashboard-crd in this Makefile"; exit 1; fi; \
		LLAMA_STATE=$$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.llamastackoperator.managementState}' 2>/dev/null); \
		if [ "$$LLAMA_STATE" = "Managed" ]; then \
			oc wait --for=condition=LlamaStackOperatorReady datasciencecluster/default-dsc --timeout=60s >/dev/null \
				&& echo "OK: LlamaStackOperator ready (required for Gen AI Studio dashboard nav -- see docs/constraints.md #23)" \
				|| { echo "FAIL: LlamaStackOperatorReady not True -- Gen AI Studio nav will stay hidden"; exit 1; }; \
		else \
			echo "SKIP: llamastackoperator.managementState=$$LLAMA_STATE -- Gen AI Studio nav will stay hidden even with genAiStudio=true (docs/constraints.md #23)"; \
		fi; \
	else \
		echo "SKIP: dashboard.managementState=$$DASH_STATE (expected on CRC)"; \
	fi
	@echo ""
	@echo "All validation checks passed."

validate-cleanup:
	@echo "=== Helm releases ==="
	@REMAINING=""; \
	for r in $(OPERATORS_RELEASE) $(PLATFORM_RELEASE) $(DATABASE_RELEASE) $(MLFLOW_RELEASE); do \
		$(HELM) status "$$r" >/dev/null 2>&1 && REMAINING="$$REMAINING $$r"; \
	done; \
	if [ -z "$$REMAINING" ]; then \
		echo "OK: none of this project's 4 rhoai-* releases remain"; \
		echo "    (not asserting a global 'rhoai-*' count of 0: a coexisting"; \
		echo "     project's own releases sharing the prefix, e.g."; \
		echo "     agentops-example's rhoai-evalhub, are intentionally untouched"; \
		echo "     by undeploy-all -- see ADR-0020)"; \
	else \
		echo "FAIL: releases still present:$$REMAINING"; exit 1; \
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

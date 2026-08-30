# open-claw-in-openshell — root Makefile wrapping cluster-lifecycle.sh
#
#   make deploy           # deploy full stack on current cluster
#   make verify           # run verification suite
#   make full             # setup + deploy + verify (one-shot)
#   make lint             # Helm lint all charts
#   make template         # Helm template all charts
#   make test             # Playwright E2E tests
#   make help             # list targets

SCRIPTS := scripts
CHARTS := \
	charts/openshell \
	charts/keycloak \
	charts/oauth2-proxy \
	charts/observability \
	charts/agent-sandbox/operators \
	charts/rhoai/operators \
	charts/rhoai/platform \
	charts/rhoai/database \
	charts/rhoai/mlflow \
	charts/rhoai/openclaw-integration

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Usage: make <target> [OPTIONS]"
	@echo ""
	@echo "Cluster lifecycle (wraps scripts/cluster-lifecycle.sh):"
	@echo "  deploy       Deploy full stack (bootstrap + openshell + openclaw)"
	@echo "  verify       Run verification suite"
	@echo "  teardown     Remove stack from the current cluster"
	@echo "  full         setup + deploy + verify (one-shot)"
	@echo "  status       Show cluster status"
	@echo ""
	@echo "OpenClaw:"
	@echo "  launch       Launch OpenClaw gateway in sandbox"
	@echo ""
	@echo "Validation (no cluster needed):"
	@echo "  lint         Helm lint all charts"
	@echo "  template     Helm template all charts (dry-run)"
	@echo "  secret-scan  Run secret pattern scan on tracked files"
	@echo ""
	@echo "Testing:"
	@echo "  test         Run Playwright E2E tests"
	@echo ""
	@echo "Options (passed through to cluster-lifecycle.sh):"
	@echo "  WITH_OIDC=1     Also deploy Keycloak OIDC"
	@echo "  WITH_OBS=1      Also deploy observability"

# ── Cluster lifecycle ──────────────────────────────────────────────────────────

LIFECYCLE_FLAGS :=
ifdef WITH_OIDC
LIFECYCLE_FLAGS += --with-oidc
endif
ifdef WITH_OBS
LIFECYCLE_FLAGS += --with-obs
endif

.PHONY: deploy
deploy:
	$(SCRIPTS)/cluster-lifecycle.sh deploy $(LIFECYCLE_FLAGS)

.PHONY: verify
verify:
	$(SCRIPTS)/cluster-lifecycle.sh verify $(LIFECYCLE_FLAGS)

.PHONY: teardown
teardown:
	$(SCRIPTS)/cluster-lifecycle.sh teardown $(LIFECYCLE_FLAGS)

.PHONY: full
full:
	$(SCRIPTS)/cluster-lifecycle.sh full $(LIFECYCLE_FLAGS)

.PHONY: status
status:
	$(SCRIPTS)/cluster-lifecycle.sh status

.PHONY: launch
launch:
	$(SCRIPTS)/launch-openclaw.sh

# ── Validation (offline) ──────────────────────────────────────────────────────
# Some charts have required values or cluster lookups. We pass dummy values
# for offline CI and skip charts that need live cluster state.

CI_DOMAIN ?= apps.ci-dummy.example.com

# Charts that can be linted/templated without any special values
CHARTS_SIMPLE := \
	charts/observability \
	charts/agent-sandbox/operators \
	charts/rhoai/operators \
	charts/rhoai/platform \
	charts/rhoai/database \
	charts/rhoai/mlflow \
	charts/rhoai/openclaw-integration

.PHONY: lint
lint:
	@set -e; \
	echo "==> Linting charts/openshell"; \
	helm lint charts/openshell --set global.appsDomain=$(CI_DOMAIN) || exit 1; \
	echo "==> Linting charts/keycloak"; \
	helm lint charts/keycloak --set brokerSecret=ci-dummy-secret || exit 1; \
	echo "==> Linting charts/oauth2-proxy (skip: requires cluster Service lookup)"; \
	for chart in $(CHARTS_SIMPLE); do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			echo "==> Linting $$chart"; \
			helm lint "$$chart" || exit 1; \
		fi; \
	done

.PHONY: template
template:
	@set -e; \
	echo "==> Templating charts/openshell"; \
	helm template test charts/openshell --set global.appsDomain=$(CI_DOMAIN) > /dev/null || exit 1; \
	echo "==> Templating charts/keycloak"; \
	helm template test charts/keycloak --set brokerSecret=ci-dummy-secret > /dev/null || exit 1; \
	echo "==> Skipping charts/oauth2-proxy (requires cluster Service lookup)"; \
	for chart in $(CHARTS_SIMPLE); do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			echo "==> Templating $$chart"; \
			extra_sets=""; \
			case "$$chart" in \
				charts/rhoai/openclaw-integration) extra_sets="--set clusterRoleName=ci-dummy-role" ;; \
			esac; \
			helm template test "$$chart" $$extra_sets > /dev/null || exit 1; \
		fi; \
	done

.PHONY: secret-scan
secret-scan:
	bash $(SCRIPTS)/ci-secret-scan.sh

# ── Testing ────────────────────────────────────────────────────────────────────

.PHONY: test
test:
	cd tests && npx playwright test

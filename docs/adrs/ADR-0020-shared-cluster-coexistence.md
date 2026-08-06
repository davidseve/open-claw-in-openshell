# ADR-0020: Shared-cluster coexistence with agentops-example

## Status
Accepted

## Context
This project and the sibling `agentops-example` project are developed
side-by-side, learning from and porting patterns to each other (ADR-0019 is
one such port). Both deploy a near-identical RHOAI + MLflow platform layer
(operator, DataScienceCluster, Postgres, MLflow CR — `charts/rhoai/*` here,
`deploy/helm/{operators,platform,database,mlflow}` there) and their own
OpenShell + OpenClaw application stack on top of it.

Running both projects on *separate* clusters works but is wasteful: RHOAI +
MLflow is the slowest, heaviest part of either deploy (operator
subscription, DataScienceCluster reconciliation, a dedicated Postgres) and
gains nothing from being duplicated. The goal is for either project to:

1. Still be fully self-sufficient — `make deploy-all` / `crc-lifecycle.sh
   deploy` on a truly empty cluster installs everything from scratch, with
   no dependency on the other project.
2. Detect when the other project already installed the shared platform
   layer on this same cluster, and reuse it instead of reinstalling.
3. Deploy its own OpenShell/OpenClaw application stack *alongside* the other
   project's, both alive and independently usable at the same time — not
   just share the platform underneath.

Two concrete collision points block (3) as soon as both projects' default
configuration is used unchanged:

- **Namespace**: both projects default their OpenShell namespace to
  `openshell` (`NAMESPACE` here, `OPENSHELL_NAMESPACE` in agentops-example's
  Makefile) — a second `helm upgrade --install openshell ... --namespace
  openshell` from the second project would collide head-on with the first
  project's own release in the same namespace.
- **Public hostname**: OpenShift Routes must have a cluster-wide-unique
  `spec.host`. Both projects' `oauth2-proxy` Route (the OpenClaw Control UI)
  defaulted to the same hostname, `openclaw-gw--openclaw-ui.<apps-domain>`
  (ADR-0009's `{sandbox}--{service}` pattern with the same sandbox name,
  `openclaw-gw`, hardcoded in both). Only one project's Route would be
  admitted; the second would sit in a permanently un-admitted state.

Per the project-lead's direction, changes to make this work should land
primarily in this project, minimizing changes to `agentops-example`.

## Decision

### Shared vs. project-isolated resources
| Resource | Scope | Coexistence strategy |
|---|---|---|
| RHOAI operator (`rhoai-operators` release, `redhat-ods-operator`/`-monitoring` namespaces) | Cluster-wide singleton | Whichever project deploys first installs it; the second detects the existing Helm release and skips |
| DataScienceCluster (`rhoai-platform` release, `default-dsc`) | Cluster-wide singleton | First project installs with its own values; second project skips the full `helm upgrade` and only patches `spec.components.mlflowoperator.managementState: Managed` if not already set (never touches Dashboard/other components the first project configured) |
| Postgres backend (`rhoai-database` release) + MLflow CR (`rhoai-mlflow` release, `redhat-ods-applications`) | Shared instance | First project installs; second project skips and reuses the same live MLflow server |
| MLflow experiment + RBAC (RoleBinding, SA-token Secret) for a project's own OpenClaw tracing | Project-isolated, per-namespace | Each project brings its own, targeting its own namespace/ServiceAccount against the *shared* MLflow instance — never a `--set` on the shared `rhoai-mlflow` release (see below) |
| OpenShell namespace, gateway, sandbox, OpenClaw UI | Project-isolated | Each project gets its own namespace and public hostname (see parametrization below) |

### Detect-and-skip for the shared platform layer
`charts/rhoai/Makefile`'s `deploy-operators`, `deploy-database`, and
`deploy-mlflow` targets now check `helm status <release>` first and skip the
`helm upgrade --install` entirely if the release already exists (installed
by either project). `deploy-platform` does the same, except when skipping it
still calls a new `ensure-mlflowoperator-managed` target: a minimal `oc
patch datasciencecluster default-dsc --type merge` that sets
`spec.components.mlflowoperator.managementState: Managed` only if it isn't
already — never a full `helm upgrade` with this project's own
`values-crc.yaml`/`values-aws.yaml`, which could silently flip a component
(e.g. Dashboard/genAiStudio) the other project deliberately configured
differently. `agentops-example`'s `deploy/Makefile` got the exact same
four guards (see its ADR-0002 addendum) so either project can be deployed
first.

### Decoupling per-project MLflow RBAC from the shared release
Before this change, `scripts/wire-rhoai-mlflow-tracing.sh` ran `helm upgrade
rhoai-mlflow --set openclawIntegration.enabled=true --set
openclawIntegration.namespace=$NAMESPACE ...` directly against the shared
base chart. That's a single-value block — a second project doing the same
against the *same* release would silently overwrite the first project's own
namespace/ServiceAccount values on the next `helm upgrade` (Helm renders the
whole release fresh from the new values each time; there's no "add one more
RBAC binding" semantics via plain `--set`). This was already a
self-inflicted bug even for a *single* project (documented in the old
`deploy-rhoai-mlflow.sh` comment this ADR removes): re-running
`deploy-rhoai-mlflow.sh` without `--reuse-values` reset
`openclawIntegration.enabled` back to `false`, silently deleting the
RoleBinding and token Secret.

Fixed by extracting the RBAC + SA-token Secret + experiment-provisioning Job
into their own standalone chart, `charts/rhoai/openclaw-integration/`,
installed as its own Helm release (`openclaw-mlflow-integration`, in this
project's own OpenShell namespace) — completely independent of whichever
release owns the base MLflow server. `charts/rhoai/mlflow`'s own
`openclawIntegration.*` values/templates are removed; `agentops-example`'s
equivalent (which still bakes its own RBAC into its own `rhoai-mlflow`
release) is left untouched, since it's only ever mutated by
`agentops-example`'s own deploy flow — never by this project.

Both projects' RBAC ends up as independent RoleBindings against the exact
same auto-detected `mlflow-integration` ClusterRole (`lookup`-based,
ADR-0019's port from `agentops-example`), each scoped to its own
namespace/ServiceAccount — RoleBindings are additive, so this doesn't
require any coordination between the two Helm releases.

### Full namespace + sandbox-name parametrization
This project's `NAMESPACE` and `SANDBOX_NAME` environment variables (already
existed, defaulting to `openshell` / `openclaw-gw`) now flow all the way
through every place that used to hardcode one or the other:

- `charts/openshell`'s Route and SCC RoleBinding use `.Release.Namespace`
  (ADR-0019) — installing under a different `NAMESPACE` needs no manifest
  edits.
- The gateway's TLS cert SAN (`openshell-gw-${NAMESPACE}.${APPS_DOMAIN}`,
  set via `--set-string` in `deploy-openshell.sh`/`configure-oidc.sh`/
  `upgrade-pki.sh`) and `configure-oidc.sh`'s `GW_URL` are namespace-derived.
- The OpenClaw Control UI's public Route host, `oauth-proxy`'s upstream
  hostAlias, and `config/openclaw.json.tpl`'s CORS `allowedOrigins` are all
  now `${SANDBOX_NAME}--openclaw-ui.${APPS_DOMAIN}` (new
  `charts/oauth2-proxy` value `sandboxName`, new `common.sh`
  `render_template()` placeholder `__SANDBOX_NAME__`), not a hardcoded
  `openclaw-gw--openclaw-ui`.
- `scripts/verify.sh`, `launch-openclaw.sh`, and `crc-lifecycle.sh`'s status
  output all read `$SANDBOX_NAME`/`$NAMESPACE` instead of the literal.

To coexist with `agentops-example` (which keeps its default `openshell`
namespace / `openclaw-gw` sandbox name unchanged) on the same cluster, this
project deploys with e.g. `NAMESPACE=openshell2 SANDBOX_NAME=openclaw-gw2`.

### CLI-local gateway alias (`GATEWAY_NAME`) — found during live coexistence testing

Namespace/sandbox-name parametrization alone isn't enough once you actually
try to drive both projects' gateways from the *same* machine's `openshell`
CLI. `deploy-openshell.sh`, `configure-oidc.sh`, `upgrade-pki.sh`, and
`teardown.sh` all hardcoded the gateway CLI alias name to `"ocp"` —
`openshell gateway add/remove/select ocp` and the mTLS cert cache at
`~/.config/openshell/gateways/ocp/`. This is **local, per-machine CLI state,
not a cluster resource** — a second project's `deploy-openshell.sh` calling
`openshell gateway remove ocp` would silently delete the first project's
local gateway registration (its cert bundle, OIDC token, everything),
discovered live while validating coexistence with `agentops-example`, which
had already registered its own gateway under that exact same alias.

Fixed by adding a new `GATEWAY_NAME` variable (`common.sh`, default `"ocp"`
— unchanged behavior for a solo deploy) and using it everywhere those four
scripts previously hardcoded the literal `"ocp"`. To coexist on one machine:
`NAMESPACE=openshell2 SANDBOX_NAME=openclaw-gw2 GATEWAY_NAME=openclaw2 ...`.

### `OPENSHELL_RELEASE_NAME` — cluster-scoped resource collision, also found live

Namespace-scoping alone still isn't enough: the vendored upstream OpenShell
chart (subchart dependency of `charts/openshell`) creates a cluster-scoped
`ClusterRole`/`ClusterRoleBinding` pair named `<release-name>-node-reader`.
Both projects installing with the Helm release name `openshell` (the
default) collide on this cluster-scoped name even when deployed into
*different* namespaces — `helm upgrade --install` on the second project
failed with `invalid ownership metadata; label validation error ... missing
key "app.kubernetes.io/managed-by": must be set to "Helm"` (the first
release already owns that ClusterRole).

Fixed the same way as `GATEWAY_NAME`: a new `OPENSHELL_RELEASE_NAME`
variable (`common.sh`, default `"openshell"`) used as the Helm release name
in `deploy-openshell.sh`, `configure-oidc.sh`, `upgrade-pki.sh`, and
`teardown.sh` (and their `oc rollout status statefulset/...` calls, which
must track the same name — the subchart's `fullname` helper always resolves
to `.Release.Name`). To coexist: `OPENSHELL_RELEASE_NAME=openshell2` (used
throughout this ADR's example alongside `GATEWAY_NAME=openclaw2`).

### Release-name-derived resource names hardcoded elsewhere — found only once actually deployed side-by-side on a live cluster

`OPENSHELL_RELEASE_NAME` above fixes the Helm release name itself, but
several *other* places independently assumed the OpenShell gateway's
Kubernetes resources are always literally named `openshell`, because on a
solo deploy `OPENSHELL_RELEASE_NAME` defaults to `openshell` and the two
happen to look identical. Deploying a second instance with
`OPENSHELL_RELEASE_NAME=openshell2` immediately exposed every one of these
as a real bug, not just a design gap — each surfaced as its own confusing
failure several steps into an otherwise-successful `crc-lifecycle.sh
deploy`, because `helm upgrade --install` itself always "succeeded" (wrong
resource *names*, not template errors):

- **`charts/openshell/templates/route.yaml`**: `spec.to.name` was hardcoded
  to the literal `openshell`, but the subchart's own Service is named after
  the release (`openshell2`). The Route was `Admitted: True` (hostname claim
  succeeds independent of whether the target Service exists), but every TLS
  connection through it failed instantly with `unexpected eof while reading`
  right after the ClientHello (haproxy backend has zero endpoints) — with
  *zero* corresponding log lines on the gateway pod itself, since the
  connection never reached it. Fixed: `name: {{ include
  "openclaw-openshell.fullname" . }}`.
- **`charts/oauth2-proxy/templates/deployment.yaml`**: the `lookup "v1"
  "Service" .Values.namespace "openshell"` call (resolves the gateway
  Service's ClusterIP for the WebSocket-Host-header-bug workaround, see that
  file's header comment) hardcoded the same literal, failing the whole
  chart render with `Service 'openshell' not found in namespace
  'openshell2'`. Fixed: new `openshellServiceName` value, passed as `--set
  openshellServiceName="${OPENSHELL_RELEASE_NAME}"` from
  `deploy-oauth2-proxy.sh`.
- **Sandbox ServiceAccount name** (`<release-name>-sandbox`, e.g.
  `openshell2-sandbox` — the subchart's own default when
  `openshift.scc.serviceAccount` isn't overridden):
  `wire-rhoai-mlflow-tracing.sh` hardcoded `openshell-sandbox` in its `oc get
  sa` prereq check and its SA-token Secret name (`openshell-sandbox-mlflow-token`),
  and never passed `serviceAccountName` to
  `charts/rhoai/openclaw-integration`'s `helm upgrade` — so that chart's own
  `serviceAccountName: openshell-sandbox` default was always used regardless
  of the real SA name, silently creating a RoleBinding/Secret for a
  ServiceAccount that doesn't exist. Fixed: new `SANDBOX_SA_NAME="${OPENSHELL_RELEASE_NAME}-sandbox"`
  in `common.sh`, used throughout `wire-rhoai-mlflow-tracing.sh` and passed
  explicitly via `--set serviceAccountName`.
- **PKI JWT-signing secret**: of the three PKI secrets the subchart's init
  job creates, two (`openshell-server-tls`, `openshell-client-tls`) are
  fixed literals in the *subchart's own* `values.yaml` — safe to leave
  hardcoded, since they don't vary with the release name. The third
  (`signingSecretName`) defaults to empty in the subchart and falls back to
  `<fullname>-jwt-keys` — i.e. it *does* vary. `deploy-openshell.sh`,
  `upgrade-pki.sh`, `teardown.sh`, and `verify.sh` all waited on/deleted a
  literal `openshell-jwt-keys`, which never existed once
  `OPENSHELL_RELEASE_NAME != "openshell"` (the real secret was
  `openshell2-jwt-keys`) — `deploy-openshell.sh` hard-failed after 120s
  waiting for a secret that was already sitting there under the right name.
  Fixed: all four now use `"${OPENSHELL_RELEASE_NAME}-jwt-keys"`.
- **`verify.sh`'s SCC RoleBinding check**: looked for a RoleBinding literally
  named `system:openshift:scc:privileged` — but that string is the
  `roleRef.name` (the pre-existing ClusterRole the binding points at), never
  a RoleBinding's own `metadata.name`. This check was already dead/vestigial
  before ADR-0019 (see that ADR's declarative RoleBinding), always falling
  through to the `oc get scc privileged -o json | grep openshell-sandbox`
  fallback — which itself stopped meaning anything once SCC granting moved
  from an imperative "add user to the SCC's own `users:` list" to a
  declarative RBAC RoleBinding (ADR-0006 addendum), since the SCC's `users:`
  list is never touched by that path either. Fixed: match on
  `.roleRef.name=="system:openshift:scc:privileged"` via `jq` across all
  RoleBindings in the namespace, regardless of the RoleBinding's own
  (also release-name-derived) `metadata.name`.

### The `openshell` CLI's "active gateway" is shared, ambient machine state — found live

`GATEWAY_NAME` (above) stops the two projects' gateway *registrations* from
colliding, but every `openshell` CLI invocation that doesn't explicitly pass
`-g/--gateway` or select first (`openshell status`, `sandbox connect`,
`sandbox list`) implicitly operates on whatever gateway alias is currently
*active* — a single piece of state on disk
(`~/.config/openshell/gateways/`), shared across every project's tooling run
from the same machine, regardless of which project's script happens to be
running. Concretely, this bit twice while testing:

1. `deploy-openshell.sh`'s "is the gateway already registered and healthy?"
   check used to be just `openshell status &>/dev/null` — with
   `agentops-example`'s `ocp` gateway already registered and healthy, this
   returned success without ever registering or selecting *this* project's
   own `$GATEWAY_NAME`, silently leaving every later command (MaaS provider
   creation, sandbox launch) aimed at the wrong project's gateway. Fixed:
   explicitly check whether `$GATEWAY_NAME` itself is a registered gateway
   (`openshell gateway list`) before trusting `openshell status`, and
   explicitly `openshell gateway select "$GATEWAY_NAME"` right after every
   `gateway add` (not relying on `add` to auto-select).
2. `scripts/verify.sh` and `common.sh`'s `sandbox_run()`/`ensure_oidc_token()`
   helpers (used by `wire-rhoai-mlflow-tracing.sh`'s prompt-seeding and
   `launch-openclaw.sh`) all relied on whatever gateway was already active.
   Running `agentops-example`'s own `make -C deploy validate-smoke` (which
   has the identical assumption on its side, unfixed — see its ADR-0002
   addendum) after this project's tooling had left `$GATEWAY_NAME` active
   failed with a misleading `sandbox not found`, and vice versa. Fixed (this
   project's side only, per the project-lead's direction to minimize changes
   to `agentops-example`): `sandbox_run()`, `ensure_oidc_token()`, and
   `verify.sh`'s own setup now unconditionally `openshell gateway select
   "$GATEWAY_NAME"` before doing anything else, so this project's own
   scripts are self-healing regardless of which gateway was last active.

## Consequences
- Either project can be deployed first on an empty cluster; the second
  reuses the shared RHOAI + MLflow layer automatically, no manual
  coordination required.
- Both projects' OpenShell/OpenClaw stacks can run simultaneously,
  independently reachable (different namespaces, different public
  hostnames), with independent MLflow experiments/RBAC against the one
  shared MLflow server.
- Risk: the shared MLflow instance is genuinely multi-tenant now — a
  Postgres outage, MLflow upgrade, or `undeploy-all`/`teardown
  --with-rhoai-mlflow` from either project affects both. This was already
  true in spirit (ADR-0018 calls RHOAI MLflow "the sole tracing backend for
  this project"); it's now explicit and literal when coexisting. Mitigation:
  `teardown.sh --with-rhoai-mlflow` and `charts/rhoai/Makefile
  undeploy-all` remain opt-in / explicit, same as before — coexistence adds
  no new *automatic* teardown path that could surprise a co-tenant project.
- Risk: whichever project deploys the DataScienceCluster/platform chart
  first "owns" every component setting (Dashboard, genAiStudio, etc.) that
  the second project's own values file would otherwise have set — the
  second project's Dashboard/genAiStudio preferences are silently not
  applied while coexisting. Accepted: this project's Dashboard config is not
  load-bearing for its own scope (RHOAI MLflow tracing), and
  `ensure-mlflowoperator-managed`'s narrow patch is deliberately the only
  thing this project asserts onto a DataScienceCluster it doesn't own.
- No change to either project's behavior when deployed alone on an empty
  cluster — the `helm status` guards are no-ops (the release doesn't exist
  yet, so the normal install path runs).
- Live-validated end-to-end (2026-08-06): both projects deployed
  simultaneously on one real OCP cluster
  (`NAMESPACE=openshell2 SANDBOX_NAME=openclaw-gw2 GATEWAY_NAME=openclaw2
  OPENSHELL_RELEASE_NAME=openshell2` for this project, defaults for
  `agentops-example`), sharing the same RHOAI installation and MLflow
  instance. `./scripts/crc-lifecycle.sh verify` passed fully (55/56 checks —
  the one failure was a flaky Playwright timing assertion, unrelated to
  coexistence and not reproducible on retry) including a live Playwright
  chat round-trip with MLflow traces, and `agentops-example`'s own `make -C
  deploy validate` and `validate-smoke` both passed unaffected. Every fix in
  the two subsections above was discovered during this exercise — the
  design alone (namespace/hostname parametrization) was not sufficient; only
  driving both stacks side-by-side on a live cluster surfaced the
  release-name-derived resource names and shared-CLI-state issues.

## Related Decisions
- [ADR-0019: Declarative OpenShell wrapper chart](ADR-0019-declarative-openshell-wrapper-chart.md) — the Route/SCC namespace-parametrization this coexistence model depends on
- [ADR-0009: External service routing](ADR-0009-external-service-routing.md) — the `{sandbox}--{service}` hostname pattern `SANDBOX_NAME` parametrizes
- [ADR-0018: RHOAI MLflow sole backend](ADR-0018-rhoai-mlflow-sole-backend.md) — now implicitly a *shared*, multi-tenant sole backend when coexisting
- `agentops-example`'s [ADR-0002 addendum](../../../agentops-example/docs/adr/0002-ocp-with-rhoai-as-platform.md) — the mirrored, minimal guards on that project's side

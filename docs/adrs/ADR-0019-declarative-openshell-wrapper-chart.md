# ADR-0019: Declarative OpenShell wrapper chart (single Helm release)

## Status
Accepted

## Context
Deploying the upstream OpenShell gateway on OpenShift used to require three
separate, imperative steps around a single `helm upgrade --install` of the
upstream OCI chart:

1. `scripts/bootstrap-ocp.sh` granting the `privileged` SCC to the
   `openshell-sandbox` ServiceAccount via `oc adm policy add-scc-to-user`
   (ADR-0006) — before the SA even existed, relying on `-z` accepting a
   not-yet-created ServiceAccount name.
2. `scripts/deploy-openshell.sh` running `helm upgrade --install openshell
   oci://ghcr.io/nvidia/openshell/helm-chart ...` directly against the
   upstream chart.
3. The same script then `oc apply -f manifests/openshell-route.yaml` — a
   hand-maintained manifest hardcoding `namespace: openshell`, applied
   completely outside Helm (so `helm uninstall` never cleaned it up;
   `teardown.sh` had its own `oc delete -f` for it).

This meant three different lifecycles (two `oc` commands + one Helm release)
had to be kept in sync by hand, `helm diff`/`helm uninstall` were incomplete
pictures of what was actually deployed, and the Route's hardcoded namespace
made it impossible to deploy a second instance of this project's OpenShell
stack into a different namespace on the same cluster (see ADR-0020,
cluster-coexistence) without editing the manifest first.

The sibling `agentops-example` project (deployed from a shared learning base
with this one) hit the same problem and solved it on 2026-08-05: replace the
upstream chart as a *direct* Helm install with a small wrapper chart that
declares it as a real Helm subchart dependency, so one release renders the
gateway plus every OpenShift-specific extra together.

## Decision
Introduce `charts/openshell/` as a wrapper chart:

- `Chart.yaml` declares the upstream chart as a pinned dependency:
  `dependencies: [{name: helm-chart, alias: openshell, version: "0.0.83",
  repository: "oci://ghcr.io/nvidia/openshell"}]`. The OCI `repository:` must
  be the *parent* of the chart (Helm appends `name` itself when resolving
  OCI refs) — `oci://ghcr.io/nvidia/openshell`, not `.../helm-chart`.
- `templates/scc-rolebinding.yaml` replaces `grant_privileged_scc()`: a
  `RoleBinding` binding `system:openshift:scc:privileged` to the
  `openshell-sandbox` ServiceAccount, in the same release, scoped to
  `.Release.Namespace`.
- `templates/route.yaml` replaces `manifests/openshell-route.yaml`: the same
  passthrough-TLS gRPC Route, but using `.Release.Namespace` instead of a
  hardcoded `namespace: openshell` — so a release installed under a
  different namespace gets a correctly-scoped, non-colliding Route
  automatically (OpenShift's default host pattern:
  `<name>-<namespace>.<apps-domain>`).
- `values.yaml` / `values-ocp.yaml.tpl` / `values-ocp-no-oidc.yaml.tpl` carry
  the same settings the old flat values files did (image tags, security
  contexts, OIDC vs. no-OIDC auth), now nested under the `openshell:` alias
  key so they pass straight through to the subchart.
- `pkiInitJob.serverDnsNames` (the gateway's TLS cert SANs) moved *out* of
  the values files and into two `--set-string` flags computed at deploy time
  in `scripts/deploy-openshell.sh` / `configure-oidc.sh` /
  `upgrade-pki.sh`: `openshell-gw-${NAMESPACE}.${APPS_DOMAIN}` (exact match)
  and `*.${APPS_DOMAIN}` (wildcard, used for ADR-0009's internal service
  routing). This is the one piece of the chart that genuinely depends on
  both the namespace and the apps domain at deploy time, so it can't live in
  a static values file if a second, differently-namespaced deploy is meant
  to get its own correct SAN.
- `scripts/deploy-openshell.sh`, `configure-oidc.sh`, and `upgrade-pki.sh`
  now run `helm dependency build charts/openshell` followed by one `helm
  upgrade --install`/`helm upgrade` against the local wrapper chart, instead
  of pointing at the upstream OCI chart directly plus a separate `oc apply`.
- `scripts/teardown.sh` drops its `oc adm policy remove-scc-from-user` and
  `oc delete -f manifests/openshell-route.yaml` calls — `helm uninstall
  openshell` now removes the RoleBinding and Route along with the gateway.
- `manifests/openshell-route.yaml` and `charts/openshell/values-ocp.yaml`
  (a stale, hand-edited snapshot from a different sandbox cluster, dead
  since deploy scripts only ever read from `.rendered/`) are deleted.
- `Chart.lock` is committed (pins the exact resolved digest); the vendored
  dependency tarball under `charts/openshell/charts/` is not (matches the
  existing `charts/*/charts/` `.gitignore` entry) — `helm dependency build`
  re-fetches it from `Chart.lock` on every deploy, same as `charts/rhoai/*`
  already did for its own subcharts.

## Consequences
- One `helm upgrade --install` / one `helm uninstall` is now the complete
  picture of the OpenShell gateway, its SCC binding, and its Route — no
  drift between three independently-tracked lifecycles.
- The Route (and, via `NAMESPACE`, the PKI SAN) is namespace-parametrized,
  which is what makes cluster coexistence (ADR-0020) possible without
  editing a manifest by hand for a second deployment.
- No functional change to what gets deployed: same SCC scope, same Route
  spec (passthrough TLS, `grpc` target port), same gateway settings. This is
  a mechanism change only (imperative → declarative), following the pattern
  already validated end-to-end (including a from-scratch redeploy +
  Playwright suite) in `agentops-example`.
- Requires network access to `ghcr.io` (OCI registry) at every deploy/verify
  step that touches this chart, same dependency the project already had via
  the direct `helm upgrade --install ... oci://ghcr.io/...` it replaces.

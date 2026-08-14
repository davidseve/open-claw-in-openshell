# ADR-0017: RHOAI-Managed MLflow — Empirical CRC Test Results and Scope Decision

## Status

**Scope superseded by [ADR-0018](ADR-0018-rhoai-mlflow-sole-backend.md)
(2026-07-25)**: once the "Resolution" section below confirmed a real trace
landing end-to-end, the original opt-in/standalone-by-default scope decision
was revisited and replaced — RHOAI MLflow is now wired unconditionally into
`cluster-lifecycle.sh`'s `deploy`/`full` commands and standalone MLflow was
removed entirely (not kept as the default with RHOAI as an opt-in
experiment, as originally decided here). The resource-budget finding (host
memory drops to ~11 GiB combined on CRC) is unchanged and now an *accepted*
trade-off rather than a reason to keep the two paths separate — see
ADR-0018's "Consequences". Everything below (empirical test results,
resolution log) remains an accurate historical record of how that trace was
actually achieved and is still the canonical reference for the constraints
involved; only the final scope *decision* changed.

Originally: Accepted. Empirically tested on CRC (not just inferred from
documentation) on 2026-07-24. **Nuanced outcome**: RHOAI + minimal MLflow
alone fits comfortably on this laptop's CRC; combined with the rest of the
OpenClaw-in-OpenShell stack, it functionally works but breaches this
project's own resource-safety floor for protecting the host machine (Cursor,
desktop apps). Original decision: ship `charts/rhoai/` and
`scripts/deploy-rhoai-mlflow.sh` as a proven, standalone, opt-in local
experiment; do not wire it into `cluster-lifecycle.sh`'s combined `deploy`/`full`
commands; treat AWS OCP as the primary target for running RHOAI MLflow
together with the full stack.

## Context

Phase 12 (`ROADMAP.md`) plans to replace the standalone MLflow deployment
(`ghcr.io/mlflow/mlflow:v3.10.1` in the `observability` namespace, ADR-0014)
with RHOAI's own managed MLflow, reusing the Helm chart / Makefile pattern
already proven in the sibling `agentops-example` repo
(`deploy/helm/{operators,platform,database,mlflow}`,
`.cursor/skills/cluster-bootstrap`).

Before committing resources to this, we needed to know whether it's even
possible to run RHOAI locally on this laptop's CRC instance, given the
project's hard rule (`documentation-sources.mdc`): validate against official
docs, don't guess.

### What the docs say

Per [Installing and deploying OpenShift AI, 3.4](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install):

> "For single-node OpenShift clusters, the node must have at least 32 CPUs
> and 128 GiB RAM" (2-worker clusters need 8 CPU / 32 GiB *per node* instead).

CRC counts as single-node OpenShift. The laptop has 22 logical CPUs / 62 GiB
RAM total — roughly 1.5-2x short on CPU and 2x short on RAM even if 100% of
the host were dedicated to CRC. By the book, this is unsupported.

### Why we tested anyway

The person running this deployment wanted certainty from a real attempt, not
just the documented minimum, before waiting on AWS cluster access (expected
to take a while). So we ran a two-stage empirical test on a freshly rebuilt
CRC instance, with a hard-reserved resource floor protecting the host
machine (Cursor + desktop apps) throughout.

## Resource safety budget used for the test

Measured live on the host before testing: 62 GiB RAM total, 22 logical CPUs,
Cursor + browser + desktop baseline ≈ 15 GiB RSS. Reserved floor: **≥16 GiB
RAM and ≥6 logical CPUs unconditionally** for the host. CRC VM sized at the
edge of that floor: **16 vCPU / 40960 MiB (40 GiB) RAM / 100 GiB disk**
(`crc config set cpus 16 / memory 40960 / disk-size 100`).

One finding worth recording for future sizing decisions: CRC/libvirt commits
memory to the host close to the full configured allocation once the cluster
has been running under any real load, largely independent of how much the
*guest* actually uses. `virsh dominfo crc` reported "Used memory: 41943040
KiB" (the full 40 GiB) throughout, and host-side qemu RSS grew from ~24 GiB
(fresh boot) to the full ~40 GiB after only ~15 minutes of light workloads —
even though `crc status` showed the *guest* using only 11-13 GiB internally.
**Sizing the VM config is effectively sizing a fixed host RAM tax, not an
elastic ceiling.**

## Stage 1: RHOAI + minimal MLflow only (no OpenShell/OpenClaw)

Deployed via the new `charts/rhoai/` (operators + platform + database +
mlflow, trimmed from `agentops-example` to only `mlflowoperator: Managed`,
everything else `Removed` — see "Charts" below) using the new
`scripts/deploy-rhoai-mlflow.sh`.

**Result: PASS, comfortably.**

| Check | Result |
|---|---|
| RHOAI operator CSV (`rhods-operator.3.4.2`) | `Succeeded` (after one manual `InstallPlan` approval — `installPlanApproval: Manual` per this repo's own security posture) |
| `DataScienceCluster` phase | `Ready` (`MLflowOperatorReady=True`; all other components correctly `False`/`Removed`) |
| MLflow CR | `Available=True`, reachable at `https://rh-ai.apps-crc.testing/mlflow` |
| Pods | All `Running` (rhods-operator ×3, mlflow-operator-controller-manager, mlflow, mlflow-db, dashboard-redirect ×2 — the last is a core-operator pod unrelated to the `dashboard` DSC component, which was `Removed`) |
| CRC-internal RAM usage | 11.36 GB of the 42 GB VM budget |
| Host available memory | Dropped from 23 GiB baseline to **18 GiB** — inside the 16 GiB floor, comfortably |
| Elapsed time | ~2.5 minutes install + wait (after InstallPlan approval) |

## Stage 2: full OpenClaw-in-OpenShell stack alongside RHOAI/MLflow

Ran `./scripts/cluster-lifecycle.sh deploy` (bootstrap + OpenShell + OpenClaw
sandbox) on the *same* still-running CRC instance, deliberately **without**
`--with-oidc --with-obs` — Stage 1 had already used up enough of the budget
that adding Keycloak + a second, redundant standalone MLflow/Tempo/OTel
stack on top wasn't a reasonable use of the remaining headroom.

**Result: functionally works, but breaches the resource floor.**

| Check | Result |
|---|---|
| OpenShell gateway + OpenClaw sandbox | Both `Running`, deploy completed with exit code 0 (LLM connectivity, security policy, health checks all passed per `verify.sh` layers 1-5) |
| Non-`Running`/`Completed` pods anywhere in the cluster | None — no crashes, no evictions |
| MLflow CR (RHOAI) | Still `Available=True` throughout |
| `verify.sh` Layer 1, 1a, 2, 3, 4, 5, 5b, 7a | All `PASS` |
| `verify.sh` Layer 7b, 7c, 8, 8b | `WARN` (expected — OIDC/observability deliberately not deployed for this test, not a resource failure) |
| `verify.sh` Layer 9 (Playwright) | Failing (expected — same reason: the UI auth path under test requires `deploy-oauth2-proxy.sh`, not deployed here) — **interrupted partway through** once the resource picture below was clear, since the remaining ~10 tests were re-confirming an already-understood, unrelated gap rather than producing new resource evidence |
| CRC-internal RAM usage | 11.93 GB of the 42 GB VM budget (barely more than Stage 1 alone — the *guest* itself stayed light) |
| **Host available memory** | **Dropped to 11 GiB — below the 16 GiB floor** |
| Host swap (zram) | 3.9 GiB / 8 GiB in use (compressed RAM, not disk, but still a sign of real pressure) |
| Emergency abort threshold (< 4 GiB available) | Not reached — no OOM kills (`dmesg` clean), Cursor's own processes stayed at their normal ~1.4 GiB / ~730 MiB footprint, host load average 4.2-4.9 (fine for 22 logical CPUs) |

So: the combined stack did not crash anything and Cursor was never at risk of
being killed, but it used more host memory than we budgeted for — the "host
stays above the reserved floor" criterion in the test plan was not met, even
though "no evictions/OOMs" and "core verify.sh layers pass" both were. Per
the test plan's own gating logic, this counts as a Gate B **fail on the
resource-budget criterion**, despite being a functional pass. The `/loop`
soak-test step was skipped for this reason — extending a run that already
breached the declared safety margin would only add risk, not new
information.

Immediately after capturing this evidence, `crc stop` was run to release the
full ~40 GiB reservation back to the host (confirmed: host available memory
returned to 49 GiB).

## Decision

1. **RHOAI + MLflow alone is empirically viable on this CRC setup** — keep
   `charts/rhoai/` and `scripts/deploy-rhoai-mlflow.sh` as real, tested,
   standalone tooling. Either environment (CRC or AWS) can run it in
   isolation.
2. **Do not wire `deploy-rhoai-mlflow.sh` into `cluster-lifecycle.sh`'s combined
   `deploy`/`full` commands.** Running it together with the rest of the
   OpenClaw-in-OpenShell stack on this hardware measurably squeezes the host
   below the margin this project reserves for keeping the development
   machine (Cursor, desktop apps) usable. It stays a manually-invoked,
   opt-in script, clearly documented with the resource caveat above.
3. **AWS OCP remains the primary target for running RHOAI MLflow *together*
   with the full stack** (the actual Phase 12 goal — replacing standalone
   MLflow in the real deployment). AWS-side node sizing isn't constrained by
   a shared laptop's need to also run Cursor.
4. **The `mlflow-openclaw` plugin transport stays pointed at the standalone
   MLflow (Phase 8/ADR-0014) by default on both environments for now.**
   Switching it to RHOAI MLflow is deferred until Phase 12 actually runs
   against AWS, where the combined-footprint problem found here doesn't
   apply.

This is a more nuanced answer than a flat "yes" or "no" to "does RHOAI fit
on this laptop": alone, yes, comfortably; combined with everything else this
project runs locally, functionally yes but outside the safety margin this
project itself sets for protecting the development machine.

## Addendum (2026-07-24): accepted-risk experiment — wiring `mlflow-openclaw` tracing to RHOAI MLflow on CRC

After the decision above, the user explicitly accepted the Stage 2 resource
risk and asked to go one step further: actually point the
`mlflow-openclaw` plugin's tracing transport at RHOAI-managed MLflow (instead
of the standalone MLflow it defaults to) and confirm end-to-end whether
traces land, on the same CRC hardware. This was run as a one-off,
explicitly-labeled experiment — see the plan
`rhoai_mlflow_openclaw_crc_risk_test` — not a change to the CRC default.

### What was built and verified working

- **RBAC**: `scripts/wire-rhoai-mlflow-tracing.sh` (new) binds the live
  `mlflow-integration` ClusterRole to `system:serviceaccount:openshell:openshell-sandbox`,
  mints a 24h SA token, creates/reuses an `openclaw-tracing` MLflow experiment
  in the `openshell` workspace via the RHOAI MLflow Route (with
  `Authorization: Bearer` + `X-MLFLOW-WORKSPACE: openshell` — confirmed this
  header requirement is real and enforced), and extracts
  `openshift-service-ca.crt` for TLS trust. **All of this worked on the first
  successful run** — RBAC, workspace header, and experiment creation are not
  the blocker.
- **Network policy**: an additive `rhoai_mlflow_direct` block was added to
  `policies/openclaw-sandbox.yaml` (host `mlflow.redhat-ods-applications.svc`,
  port `8443`, `protocol: rest`) alongside the existing `mlflow_direct`
  block. The policy applied cleanly and the L4/nftables layer allowed the
  connection through — confirmed via `openshell logs`, which showed the
  connection reaching the L7 proxy stage rather than being dropped at the
  network-policy level.
- **Gateway wiring**: the live sandbox `openclaw.json` was patched (tracking
  URI, experiment ID) and the gateway was restarted with
  `MLFLOW_TRACKING_TOKEN`, `MLFLOW_TRACKING_SERVER_CERT_PATH`, and
  `MLFLOW_WORKSPACE` env vars. The gateway started cleanly and the
  `mlflow-openclaw` plugin logged `exporting traces to
  https://mlflow.redhat-ods-applications.svc.cluster.local:8443
  (experiment=1)` at startup.

### What blocked it: a platform-layer TLS trust gap in the OpenShell sandbox proxy, not the anticipated SDK bug

The plan flagged a known upstream SDK gap
([mlflow/mlflow#23898](https://github.com/mlflow/mlflow/issues/23898)) where
`@mlflow/core`'s `createOssAuth` might not send `X-MLFLOW-WORKSPACE`. That
turned out to be moot — the request never got far enough to test it:

1. Direct `curl` probes from inside the sandbox to
   `https://mlflow.redhat-ods-applications.svc:8443` (both the Service DNS
   name and the external Route host) failed with `curl: (56) Recv failure:
   Connection reset by peer`.
2. `openshell logs` showed the OpenShell L7 REST proxy intercepting the
   connection (TLS MITM, as designed for policy enforcement), presenting its
   own certificate to the sandbox client, then failing to establish its
   *upstream* leg to the real MLflow endpoint — logged as a `NET:FAIL` — because
   the proxy does not trust the certificate chain OpenShift's internal
   `service-ca` uses to sign in-cluster Service endpoints.
3. `openshell policy update --help` confirmed the `rest` protocol policy
   schema has no field to inject a custom upstream CA bundle or disable
   upstream TLS verification for a specific endpoint — this isn't a
   misconfiguration on our side, it's a genuine capability gap for reaching
   any in-cluster HTTPS service signed by `service-ca` (as opposed to a
   public CA) through the L7 proxy.
4. Sending a real OpenClaw chat message (via a temporarily-enabled
   `chatCompletions` HTTP endpoint, used only for this test) reproduced the
   same failure at the application layer: the gateway log recorded `Failed to
   export trace tr-...: Error: API request failed: fetch failed` from
   `@mlflow/core`'s `makeRequest`, immediately, for both spans of the trace —
   consistent with a TLS-handshake-level failure, not an HTTP 4xx/5xx from
   MLflow itself. This confirms the blocker is below the application/SDK
   layer entirely, so the workspace-header SDK gap was never reached and
   remains unconfirmed either way.

### Resource outcome

Available host memory stayed at **16 GiB** at the point of verification —
at the safety floor but not below the ~4 GiB emergency-abort threshold from
the test plan. No abort was needed. `crc stop` was run immediately after
capturing the log evidence above, per the plan's Phase F.

### Decision impact

This does not change the ADR-0017 decision above — it adds a **second,
independent blocker** on top of the already-documented resource-budget one:
even setting resource risk aside, wiring RHOAI MLflow tracing through the
OpenShell sandbox's L7 `rest` proxy is currently blocked by a TLS-trust gap
for `service-ca`-signed in-cluster endpoints. Options for a future attempt,
not pursued here since this was explicitly a one-off probe:

- Reach RHOAI MLflow via its external Route (public-CA-chain TLS) from the
  sandbox instead of the in-cluster Service — would need the Route host
  added to the network policy and re-testing whether the proxy trusts the
  cluster's public ingress CA.
- File/track an OpenShell feature request for custom CA injection or
  per-endpoint upstream TLS-verify opt-out in the `rest` policy schema.
- Re-test on AWS OCP, where the same `service-ca` trust question applies
  identically — this is a proxy capability gap, not a CRC-specific
  artifact, so it will very likely reproduce there too and should be
  resolved (or routed around via the Route option above) before Phase 12's
  real integration work assumes in-cluster Service access will work.

The `mlflow-openclaw` plugin transport stays pointed at the standalone
MLflow by default; the live sandbox config patch made for this experiment
was not committed (per the plan, only the RBAC script and network-policy
addition are kept as reusable, examined artifacts).

## Correction (2026-07-25): the TLS trust gap has a real fix — `tls: skip`

The addendum above (point 3, "What blocked it") stated that OpenShell's
`rest` protocol policy schema has "no field to inject a custom upstream CA
bundle or disable upstream TLS verification for a specific endpoint." **That
was wrong** — or more precisely, incomplete. It was confirmed correct only
for the `--add-endpoint` CLI shorthand (which really does only expose
`websocket-credential-rewrite`, `request-body-credential-rewrite`, and
`allowed-ip=<CIDR>`, per strings extracted from the OpenShell binary). It is
**not** true of the full policy YAML schema — the same schema this project
already uses in `policies/openclaw-sandbox.yaml`. OpenShell's official
policy-schema and security-best-practices docs confirm a per-endpoint `tls:
skip` field: it disables the proxy's TLS termination/inspection for that one
endpoint, letting encrypted bytes pass through untouched. The real TLS
handshake then happens directly between the `mlflow-openclaw` plugin's Node
process and RHOAI MLflow, validated against the CA bundle already extracted
by `scripts/wire-rhoai-mlflow-tracing.sh` (`openshift-service-ca.crt`, wired
via `MLFLOW_TRACKING_SERVER_CERT_PATH`) — a value that was already being
produced and passed correctly in the original experiment, but never actually
used, because the proxy's MITM intercepted the connection before the real
client ever saw MLflow's certificate.

Applied: `tls: skip` added to the `rhoai_mlflow_direct` endpoint in
`policies/openclaw-sandbox.yaml`. Accepted trade-off: L7 credential-rewrite/
inspection is skipped for this one endpoint — irrelevant here, since the
Bearer token is injected via the `MLFLOW_TRACKING_TOKEN` environment
variable at gateway start, not OpenShell's credential-rewrite mechanism.

**Consequence for "options for a future attempt" above**: superseded. The
Route-vs-Service option and the "file an OpenShell feature request" option
are no longer needed — `tls: skip` is a policy-schema field, not a
CRC-vs-AWS or Route-vs-Service distinction, so it should apply identically on
AWS OCP without further investigation.

**Repository correction**: the addendum's source citations
(`crates/openshell-supervisor-network/...`) referenced a placeholder path
from this project's own rules, not the real upstream project. The actual
upstream repository is [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell).
Its commit [`3b21df1` (PR #862)](https://github.com/NVIDIA/OpenShell/commit/3b21df190d1a0d824c2b529dc26630cf4ef5b7cf)
added trust for the sandbox container's own system CAs — unrelated to this
fix, since `openshift-service-ca.crt` is never injected into the sandbox's
system trust store; `tls: skip` is the applicable mechanism given what this
project already has in place.

### Independent finding: the pinned plugin can't reach the `X-MLFLOW-WORKSPACE` SDK fix either way

[mlflow/mlflow#23927](https://github.com/mlflow/mlflow/pull/23927) (merged
2026-06-11) does fix a real gap in `@mlflow/core`'s TypeScript SDK
(`createOssAuth` not sending `X-MLFLOW-WORKSPACE`) — but it landed in
`@mlflow/core@0.3.0` (2026-07-07), and the pinned plugin,
`@mlflow/mlflow-openclaw@0.2.0-rc.0`, depends on `@mlflow/core@^0.2.0`, which
npm's caret range resolves to `0.2.0` exactly (2026-02-27, before the fix).
This gap is independent of the TLS blocker above and was never actually
reached in the original experiment (the TLS handshake failed first). See
`docs/constraints.md` #4b for the (not yet implemented) fix — an npm
`overrides` entry forcing `@mlflow/core@0.3.0` — and re-test whether the
workspace header is actually needed once `tls: skip` unblocks real requests.


### End-to-end validation (2026-07-25): network/auth layer confirmed fixed; a new, deeper blocker found at the Node TLS layer

Redeployed on CRC (RHOAI+MLflow and the OpenShell/OpenClaw sandbox from the
original experiment were still running after a `crc stop`/`start` cycle) and
re-tested with `tls: skip` + the declarative rework above in place.

**Confirmed fixed** — the original blocker (proxy MITM resetting the
connection) is gone. From inside the sandbox:

```
curl -vk -H "Authorization: Bearer <token>" -H "X-MLFLOW-WORKSPACE: openshell" \
  https://mlflow.redhat-ods-applications.svc:8443/api/2.0/mlflow/experiments/get-by-name?experiment_name=openclaw-tracing
```

completes a real TLS handshake against MLflow's actual certificate
(`CN=mlflow.redhat-ods-applications.svc`, issued by
`openshift-service-serving-signer`, **not** a proxy-injected one), and —
using the real SA token read back from the declarative Secret — returns the
real experiment (`experiment_id: "1"`). Same result via `curl --cacert
<the extracted service-ca.crt>` (proper validation, not `-k`): confirms the
CA bundle staged by `scripts/wire-rhoai-mlflow-tracing.sh` /
`scripts/launch-openclaw.sh --rhoai-mlflow` is the right one. The declarative
RBAC + token Secret + experiment-provisioning Job all worked correctly on a
real `helm upgrade` (after fixing two bugs found live — see below) — this
part of the plan is fully validated end-to-end.

**Two implementation bugs found and fixed live** (both now fixed in the
committed templates/scripts, not just worked around):
1. `helm upgrade --reuse-values` does not merge in a chart's *new* values.yaml
   keys added after the release's first install — it reuses the previous
   release's fully-computed values as the base, which had no
   `openclawIntegration` key at all. Fixed by passing `-f values.yaml`
   explicitly instead of `--reuse-values` in
   `scripts/wire-rhoai-mlflow-tracing.sh`.
2. The experiment-provisioning Job's `grep` pattern for extracting
   `experiment_id` from MLflow's JSON response required no whitespace after
   the colon; MLflow's actual responses pretty-print with
   `"experiment_id": "1"` (space after colon), so the match silently failed
   and the idempotent get-by-name-or-create logic fell through to a
   `RESOURCE_ALREADY_EXISTS` create error. Fixed the regex in
   `openclaw-integration-experiment-job.yaml` to tolerate optional
   whitespace.

**New blocker found — does not land a trace end-to-end yet**: getting the
`mlflow-openclaw` plugin's own Node process to trust MLflow's certificate
required more than the network-policy fix. `@mlflow/core@0.2.0`'s HTTP
client (`clients/utils.js`) calls plain global `fetch()` with no custom
TLS/dispatcher options and never reads `MLFLOW_TRACKING_SERVER_CERT_PATH` —
confirmed by reading its source; that env var is a Python-mlflow-client
convention with no effect on this TypeScript SDK. The standard Node
mechanism to extend the default trust store, `NODE_EXTRA_CA_CERTS`, does
make a plain `fetch()` to RHOAI MLflow succeed in isolation (verified with a
minimal repro script) — **but setting it for the whole gateway process
breaks the MaaS LLM provider's own HTTPS call in that same process**,
confirmed live and reproduced twice:

```
[model-fetch] error provider=maas ... causeCode=SELF_SIGNED_CERT_IN_CHAIN message=fetch failed
...
cause: RequestAbortedError [AbortError]: Proxy response (403) !== 200 when HTTP Tunneling
```

i.e. it changes how Node's (experimental) `EnvHttpProxyAgent` negotiates the
sandbox proxy's CONNECT tunnel for the *unrelated* `maas_inference` policy
endpoint, breaking live chat entirely — confirmed by toggling
`NODE_EXTRA_CA_CERTS` on and off with everything else held constant: chat
works / mlflow export TLS-fails without it, chat breaks / mlflow export
still fails (differently) with it. Since breaking chat is strictly worse
than missing traces, `scripts/launch-openclaw.sh --rhoai-mlflow` deliberately
does **not** set `NODE_EXTRA_CA_CERTS` — the gateway is left in the safe
state (chat works, RHOAI trace export TLS-fails the same way it did before
`tls: skip`, one layer higher up the stack). The `prompt-trace-linker.js`
sidecar's curl-based path (verified separately with `--cacert`, real
validation, real token) is unaffected, since it doesn't share the gateway's
Node fetch/proxy context.

**Real fix, not yet implemented**: the plugin's own client needs a TLS
context/dispatcher scoped to just its own HTTP calls (e.g. a custom undici
`Agent`/`Client` with `connect: { ca: ... }` passed explicitly to its
`fetch()` calls, instead of relying on the process-global trust store) —
a change to `@mlflow/mlflow-openclaw`/`@mlflow/core` itself, out of scope
for this project to patch (would need to extend
`scripts/patch-mlflow-plugin.py`, or fork the dependency). Filed as the next
open item, not attempted in this session given the risk of further breaking
the live sandbox.

**Net effect on this ADR's scope decision**: unchanged. The `tls: skip`
network-policy fix and the declarative RBAC/token/experiment rework are
real, validated improvements (kept). But "traces actually landing in RHOAI
MLflow" is still not achieved — now blocked one layer higher (Node
process-wide TLS trust vs. the MaaS proxy path) instead of at the network
policy layer. **Conclusion: still not worth combining with the full stack on
CRC** (unchanged from the original addendum), and the conditional
"standalone-mlflow-removal" migration (see the session's implementation plan)
does **not** proceed — its entry condition ("RHOAI MLflow integration
validated end-to-end, real trace visible in RHOAI MLflow") is not met.

### Follow-up (2026-07-25, same day): the two real blockers above are fixed; a third, previously-hidden one was found underneath

Went back into the still-running sandbox (no redeploy) to properly root-cause
the two items the section above left as "known limitations" instead of fixes.
Both turned out to have real, concrete fixes; fixing them uncovered a third,
independent bug that was masked the whole time.

**Fix 1 — the `NODE_EXTRA_CA_CERTS` conflict was a single-value-overwrite bug, not a fundamental clash.** Dumped the actual gateway Node process's
environment (`/proc/<pid>/environ`, not just `oc exec`'s own shell) and found
that OpenShell's sandbox runtime *already* sets, for every gateway process,
independent of anything in this repo:

```
HTTPS_PROXY=http://10.200.0.1:3128
NODE_USE_ENV_PROXY=1
NODE_EXTRA_CA_CERTS=/etc/openshell-tls/openshell-ca.pem
```

`NODE_USE_ENV_PROXY=1` makes Node's (experimental) `EnvHttpProxyAgent` route
every `fetch()` — for *any* destination — through the sandbox's local proxy
at `10.200.0.1:3128` via HTTP `CONNECT`. `NODE_EXTRA_CA_CERTS` is set to
`openshell-ca.pem` so Node trusts the proxy's own MITM certificate on
endpoints the proxy terminates TLS for (e.g. `maas_inference`, which has no
`tls: skip`). The previous session's fix attempt pointed
`NODE_EXTRA_CA_CERTS` at a file containing *only* RHOAI's `service-ca.crt`,
via `--env` — since it's a single-value env var, this **overwrote** (not
extended) OpenShell's own baseline value, so Node stopped trusting the
proxy's MITM cert, breaking the MaaS call. `NODE_EXTRA_CA_CERTS` accepts
multiple concatenated PEM certs in one file, so the real fix is to build a
combined bundle (`cat openshell-ca.pem service-ca.crt > combined.pem`) and
point `NODE_EXTRA_CA_CERTS` at the union instead of a replacement.
**Confirmed live**: with the combined bundle, a real chat completion through
the gateway (`POST /v1/chat/completions` → MaaS) returned `HTTP 200` — no
regression — while the mlflow-openclaw plugin's `fetch()` to RHOAI MLflow
got past the TLS layer entirely for the first time. Implemented permanently
in `scripts/launch-openclaw.sh` (builds `.combined-ca-bundle.pem` in the
sandbox workspace whenever `--rhoai-mlflow` is passed, and points
`NODE_EXTRA_CA_CERTS` at it instead of leaving it unset).

**Fix 2 (the real, previously-hidden blocker) — a hostname mismatch silently defeated `tls: skip` itself.** With the CA fixed, the plugin's request to
RHOAI MLflow still failed — but now with a *different*, more specific error:
`TypeError: fetch failed`, `cause: RequestAbortedError [AbortError]: Proxy
response (403) !== 200 when HTTP Tunneling` — the exact same error shape
that broke MaaS before, but now on the *MLflow* request. Reproduced the
identical failure with plain `curl -x http://10.200.0.1:3128 ... CONNECT
mlflow.redhat-ods-applications.svc.cluster.local:8443` → `403`, ruling out
anything Node-specific. Then, changing **only** the hostname in an otherwise
byte-identical request — the short 3-label Service DNS form
(`mlflow.redhat-ods-applications.svc`) instead of the FQDN
(`mlflow.redhat-ods-applications.svc.cluster.local`) — flipped the result to
a clean `200`. Root cause: `policies/openclaw-sandbox.yaml`'s
`rhoai_mlflow_direct` endpoint is keyed on the short form
(`host: "mlflow.redhat-ods-applications.svc"`), but
`scripts/wire-rhoai-mlflow-tracing.sh` built `RHOAI_MLFLOW_TRACKING_URI` (and
therefore the gateway's `openclaw.json` `trackingUri`, and the linker's
`MLFLOW_URL`) using the FQDN. The proxy's CONNECT-tunnel handler does an
exact string match against the policy's configured host — no DNS-equivalence
or suffix matching — so the FQDN request never matched the `rhoai_mlflow_direct` policy (with its `tls: skip`) at all and fell through to
default-deny, independent of TLS/CA/token/RBAC, all of which were already
correct. **This means the "TLS trust gap" framing in the 2026-07-24
correction above was itself imprecise** for this specific failure mode: once
`tls: skip` is configured, using the *wrong hostname string* anywhere that
constructs the URL defeats it just as completely as not having `tls: skip`
at all, but with a confusingly TLS-shaped error (a rejected CONNECT looks
identical to a TLS failure from the client's perspective, since curl reports
both as connection failures). Fixed by changing
`scripts/wire-rhoai-mlflow-tracing.sh`'s `RHOAI_MLFLOW_SVC_URL` to the short
form. **Confirmed live**: with both fixes in place, the plugin's real
`createTrace` call now reaches MLflow's actual API handler and gets a real
API-level response.

**Fix 3, attempted, blocked by a new, unrelated issue — `X-MLFLOW-WORKSPACE` confirmed as the true final gap, npm override not deployable as-is.** With
fixes 1 and 2 in place, the trace export error changed one more time, to
exactly what `docs/constraints.md` #4b predicted:

```
Failed to export trace ...: Error: API request failed: HTTP 400: Bad Request
  - {"error":{"code":"INVALID_PARAMETER_VALUE","message":"Workspace context is required for this request."}}
```

This confirms, with a real live request (not a static code read), that
`@mlflow/core@0.2.0`'s `createTrace` really does omit `X-MLFLOW-WORKSPACE`
and that this really is the last remaining gap — every other layer (network
policy, TLS, RBAC, SA token auth) is now provably working end-to-end.
Attempted the fix documented as "not yet implemented" in
`docs/constraints.md` #4b: added `"overrides": {"@mlflow/core": "0.3.0"}` to
the plugin directory's own `package.json` (it's installed as its own
isolated npm project, so `overrides` applies locally) and re-ran `npm
install`. This failed with `npm error code E403 ... 403 Forbidden - GET
https://registry.npmjs.org/@mlflow%2fcore - policy_denied`. The exact same
package name had already been fetched successfully once before, for the
original `^0.2.0` resolution — so this isn't a blanket npm-registry block,
but some more specific policy decision (not configured anywhere in this
repo's `policies/openclaw-sandbox.yaml`, which has no npm/registry entries
at all — it must come from OpenShell's own base sandbox policy or a
supply-chain control outside this project's configuration surface). Not
investigated further this session — reverted the `package.json` change
(harmless no-op, since `npm install` never completed) rather than push on an
unfamiliar OpenShell subsystem live against the only running sandbox.

**Updated state, for a future session to pick up**: network + TLS + RBAC +
auth are now fully validated working end-to-end against RHOAI MLflow, live,
with no regression to MaaS chat. The **only** remaining gap to a real trace
landing is `X-MLFLOW-WORKSPACE`, and the only remaining gap to *that* is
understanding why OpenShell's sandbox denies this specific npm fetch. Options
for next time: (a) investigate the `policy_denied` mechanism directly (ask
OpenShell docs/support what determines it, or try fetching the exact tarball
URL manually to see if it's version-specific vs. package-specific), (b) vendor
`@mlflow/core@0.3.0`'s fixed `auth`/`clients` code into
`scripts/patch-mlflow-plugin.py` as a source patch instead of an npm-level
override (same category of fix already used for two other compat issues on
this same plugin), or (c) wait for `@mlflow/mlflow-openclaw` to bump its own
`@mlflow/core` dependency upstream past `0.2.0`.

**Net effect on this ADR's scope decision (superseded by the next section,
same day)**: at the time this paragraph was written, the migration still did
not proceed. Fixed minutes later — see below.

### Resolution (2026-07-25, same day): `X-MLFLOW-WORKSPACE` backported, real trace confirmed end-to-end

Read the installed `@mlflow/core@0.2.0`'s `dist/auth/index.js` directly:
`createOssAuth()`'s `headersProvider` builds `Content-Type` and
`Authorization` but never `X-MLFLOW-WORKSPACE` — exactly the gap
[mlflow/mlflow#23927](https://github.com/mlflow/mlflow/pull/23927) fixed
upstream in `0.3.0`. Since the npm `overrides` route to pull in `0.3.0` is
blocked by the unresolved `policy_denied` issue (constraint #4e), backported
the fix as a **source patch on the already-installed 0.2.0 file** instead —
the same technique `scripts/patch-mlflow-plugin.py` already uses for two
other compatibility gaps on this same plugin (constraint #5), just applied
one file deeper into the dependency tree:

```javascript
const headersProvider = async () => {
    const headers = { 'Content-Type': 'application/json' };
    if (authHeader) {
        headers['Authorization'] = authHeader;
    }
    // Backport of mlflow/mlflow#23927 (upstream fix landed in @mlflow/core@0.3.0)
    const workspace = options.workspace || process.env.MLFLOW_WORKSPACE;
    if (workspace) {
        headers['X-MLFLOW-WORKSPACE'] = workspace;
    }
    return headers;
};
```

Applied live, restarted the gateway, sent a real chat message through the
(temporarily re-enabled, then reverted) local `chatCompletions` endpoint,
and queried RHOAI MLflow's real traces API directly — **a real trace is
there**:

```json
{
  "traces": [{
    "request_id": "tr-692adb65bddad6913a4ddfdd93929028",
    "experiment_id": "1",
    "status": "OK",
    "request_metadata": [
      {"key": "mlflow.traceInputs", "value": "{\"messages\":[{\"role\":\"user\",\"content\":\"Respond with exactly one word: TRACED\"}]}"},
      {"key": "mlflow.traceOutputs", "value": "{\"messages\":[{\"role\":\"assistant\",\"content\":\"TRACED\"}]}"}
    ]
  }]
}
```

`scripts/prompt-trace-linker.js` (also running against the corrected
short-hostname URL, constraint #4d) picked it up on its very next 30s poll
cycle and logged `[linker] Linked trace tr-692adb65bddad6913a4ddfdd93929028`
— the full pipeline (gateway → real trace in RHOAI MLflow → linker tagging)
works end-to-end, with no regression to MaaS chat (verified `HTTP 200`
throughout every restart in this sequence).

All three real root causes from the "Follow-up" section above are now fixed
in the actual scripts (not just live sandbox hacks — `scripts/launch-openclaw.sh`'s Step 7 patch heredoc includes the backport, applied
idempotently on every launch, same as the other two patches on this file):

1. Combined `NODE_EXTRA_CA_CERTS` bundle (constraint #4c) — `scripts/launch-openclaw.sh`.
2. Short-form hostname matching the network policy (constraint #4d) — `scripts/wire-rhoai-mlflow-tracing.sh`.
3. `X-MLFLOW-WORKSPACE` backport (constraint #4b) — `scripts/launch-openclaw.sh` Step 7.

**Net effect on this ADR's scope decision, for real this time**: the
condition for the conditional "standalone-mlflow-removal" migration in the
session's implementation plan — "RHOAI MLflow integration validated
end-to-end, real trace visible in RHOAI MLflow" — **is now met**. Whether to
actually execute that (large, ~40-file) migration is a separate decision
deferred to the user, not assumed here — see the resource-budget caveat this
ADR already raised (CRC's available memory falls to ~11 GiB when RHOAI and
the full OpenClaw stack run together; removing standalone MLflow entirely
would make that the *only* option for local traces, with no lightweight
fallback).

### Open question for a future revisit

Whether `tls: skip` can eventually be removed for this endpoint — e.g. if
OpenShell adds a supported way to inject a custom upstream CA bundle (so the
proxy can keep doing TLS termination/inspection while still trusting
`service-ca`-signed endpoints) rather than skipping inspection entirely.
Not pursued now; flagged for later re-evaluation once/if OpenShell's policy
schema evolves.

## Scope decision superseded (2026-07-25, same day): full migration executed, not just the opt-in experiment

With the "Resolution" section's condition met, the user was asked whether to
go further than this ADR's original scope — actually replace standalone
MLflow project-wide rather than keep RHOAI MLflow as a separate, manually-
invoked opt-in path alongside it — and explicitly approved doing so,
including accepting the resource trade-off on CRC documented above ("Sí,
acepto el coste de recursos en CRC ... ya lo dijiste antes"). This is a
strictly larger scope change than anything decided earlier in this ADR, so
it's captured as its own ADR rather than another patch here: see
[ADR-0018](ADR-0018-rhoai-mlflow-sole-backend.md) for the full decision,
the ~40-file migration it covers, and the updated resource-consequence
framing (no lightweight fallback left; the ~11 GiB combined-footprint number
from Stage 2 above is now simply "how much headroom local dev has left",
not a reason to avoid combining the two stacks).

Concretely, this reverses two of the four decision points in the original
"## Decision" section above:
- Point 2 ("do not wire `deploy-rhoai-mlflow.sh` into `cluster-lifecycle.sh`'s
  combined `deploy`/`full` commands") — reversed. `scripts/cluster-lifecycle.sh`
  now calls `deploy-rhoai-mlflow.sh` and `wire-rhoai-mlflow-tracing.sh`
  unconditionally in Phases 4 and 6 of `cmd_deploy`.
- Point 4 ("the `mlflow-openclaw` plugin transport stays pointed at the
  standalone MLflow by default") — reversed. The standalone
  `ghcr.io/mlflow/mlflow` deployment was removed entirely; RHOAI MLflow is
  the plugin's only transport target now.

Points 1 and 3 (RHOAI+MLflow alone is viable; AWS remains the primary target
for the *combined* footprint at scale) are unaffected — they were already
true regardless of which environment happens to be running the combined
stack locally.

## Charts

`charts/rhoai/` (new) — adapted from `agentops-example/deploy/helm/{operators,platform,database,mlflow}`,
trimmed to only what Phase 12 needs:

- `operators/` — RHOAI Subscription, `installPlanApproval: Manual` (differs
  from `agentops-example`'s `Automatic`, per this repo's `AGENTS.md`: *"Use
  installPlanApproval: Manual for OLM operators to prevent unreviewed
  upgrades"*).
- `platform/` — `DataScienceCluster` with only `mlflowoperator: Managed`
  by default; `dashboard`, `kserve`, `llamastackoperator`, `trustyai`,
  `modelsAsService`, `aipipelines`, `feastoperator`, `kueue`,
  `modelregistry`, `ray`, `trainer`, `trainingoperator`, `sparkoperator`,
  `workbenches` all `Removed`. (`dashboard` is overridden to `Managed` on
  AWS OCP only — see [ADR-0018](ADR-0018-rhoai-mlflow-sole-backend.md)'s
  2026-07-27 amendment; CRC keeps it `Removed`, matching this ADR's
  original minimal-footprint decision.)
- `database/` — Postgres backend, scoped to a single `mlflow` database (no
  `evalhub`, unlike `agentops-example`).
- `mlflow/` — `MLflow` CR + Route + the DNS NetworkPolicy workaround for the
  known `mlflow-operator` CoreDNS-port bug (carried over verbatim from
  `agentops-example`, same operator version, same bug).
- `Makefile` — same ordered deploy/wait pattern as `agentops-example/deploy/Makefile`,
  minus the `evalhub` targets.

Unlike `agentops-example`, no plaintext database password is committed to
`values.yaml` (`AGENTS.md`: "Never commit secrets, API keys, or credentials
to git"). `scripts/deploy-rhoai-mlflow.sh` generates one with `openssl rand`
on first run, persists it to `secrets/secrets.env` (gitignored), and injects
it via `helm --set-string` — the same pattern already used by
`scripts/deploy-keycloak.sh` / `scripts/deploy-oauth2-proxy.sh`.

## Consequences

- Local CRC development keeps its current, lighter default (`cluster-lifecycle.sh
  full`/`deploy`, standalone MLflow) as the everyday path — no regression to
  the existing local dev experience.
- Anyone who wants to experiment with RHOAI MLflow locally can run
  `./scripts/deploy-rhoai-mlflow.sh` directly, with the documented
  expectation that combining it with the rest of the stack will use most of
  a 62 GiB laptop's spare capacity and should not be left running alongside
  normal Cursor/desktop use for extended periods.
- When AWS cluster access is available, Phase 12's actual integration work
  (bearer SA token, TLS CA mount, `X-MLFLOW-WORKSPACE` header, network
  policy egress, plugin transport switch) proceeds there, unblocked by any
  of the findings in this ADR.
- `charts/rhoai/Makefile`'s `validate` target was fixed during this test — it
  originally asserted 3 Helm releases (copy-paste leftover from an earlier
  draft) when the trimmed chart set actually produces 4
  (`rhoai-operators`, `rhoai-platform`, `rhoai-database`, `rhoai-mlflow`).

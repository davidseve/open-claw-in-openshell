# ADR-0018: RHOAI-Managed MLflow as the Sole Tracing/Prompt-Registry Backend

## Status

Accepted (2026-07-25). Supersedes the MLflow half of
[ADR-0014](ADR-0014-agent-observability.md) (Pipeline 2), the backend
described in [ADR-0015](ADR-0015-mlflow-prompt-registry.md), and the
opt-in/standalone-default scope decision in
[ADR-0017](ADR-0017-rhoai-mlflow-scope.md).

## Context

[ADR-0017](ADR-0017-rhoai-mlflow-scope.md) tracked an "accepted-risk
experiment": point the `mlflow-openclaw` plugin's tracing transport at
RHOAI-managed MLflow (`charts/rhoai/`) instead of the standalone
`ghcr.io/mlflow/mlflow` deployment ([ADR-0014](ADR-0014-agent-observability.md)), without touching the standalone deployment or the
default `cluster-lifecycle.sh` path. That experiment ran into, and eventually
fixed, three independent blockers on the same day (2026-07-25):

1. A Node process-wide TLS trust conflict between the sandbox's L7 proxy
   MITM certificate and RHOAI MLflow's `service-ca`-signed certificate
   (`NODE_EXTRA_CA_CERTS` single-value overwrite bug).
2. A hostname mismatch (FQDN vs. short Service DNS form) that silently
   defeated the OpenShell `tls: skip` policy field for the RHOAI MLflow
   endpoint, at the exact-match `CONNECT`-tunnel policy layer.
3. The pinned `@mlflow/mlflow-openclaw@0.2.0-rc.0` plugin's dependency,
   `@mlflow/core@0.2.0`, never sending the `X-MLFLOW-WORKSPACE` header
   RHOAI MLflow requires (fixed upstream in `0.3.0` by
   [mlflow/mlflow#23927](https://github.com/mlflow/mlflow/pull/23927), but
   unreachable via `npm overrides` due to an unrelated OpenShell sandbox
   `policy_denied` on that specific fetch — worked around with a source
   patch on the already-installed `0.2.0` file instead).

With all three fixed, a real chat message produced a real trace in RHOAI
MLflow (`request_id: tr-692adb65bddad6913a4ddfdd93929028`, real input/output
content), and `scripts/prompt-trace-linker.js` tagged it on its very next
poll cycle — the full pipeline (gateway → RHOAI MLflow trace → linker tag)
was confirmed working end-to-end, with no regression to MaaS chat
throughout. This met the entry condition ADR-0017 had set for a much larger
follow-up decision: whether to remove standalone MLflow from the project
entirely, given that RHOAI MLflow now provably works.

The user was presented with this choice and explicitly approved the full
scope: plan the complete ~40-file removal first, then accept the CRC
resource trade-off, then implement it.

## Decision

**RHOAI-managed MLflow (`charts/rhoai/`) is now the sole tracing and
prompt-registry backend for this project.** The standalone
`ghcr.io/mlflow/mlflow` deployment (`manifests/observability/mlflow.yaml[.tpl]`, the `mlflow` container in
`scripts/deploy-observability.sh`) was removed entirely — no plain-HTTP,
no-auth fallback remains anywhere in the codebase. Every deploy of this
project, on every environment (CRC and AWS OCP alike), ends with RHOAI
MLflow deployed and wired:

- `scripts/cluster-lifecycle.sh`'s `cmd_deploy`/`cmd_full` call
  `scripts/deploy-rhoai-mlflow.sh` and `scripts/wire-rhoai-mlflow-tracing.sh`
  unconditionally (not gated behind `--with-obs`, which now only controls
  the separate, MLflow-unrelated Tempo/OTel Collector infrastructure
  stack — see [ADR-0014](ADR-0014-agent-observability.md)'s still-Accepted
  Pipeline 1).
- `scripts/launch-openclaw.sh` always sources RHOAI MLflow wiring facts
  (`.rendered/rhoai-mlflow/wiring.env`) and configures the sandbox's
  `mlflow-openclaw` plugin, gateway env vars, and CA trust accordingly —
  there is no code path left that configures the plugin against anything
  else.
- The three fixes from the ADR-0017 experiment (combined
  `NODE_EXTRA_CA_CERTS` bundle, short-hostname `tls: skip` matching,
  `X-MLFLOW-WORKSPACE` source-patch backport) are permanent, idempotent
  parts of `scripts/launch-openclaw.sh` and
  `scripts/wire-rhoai-mlflow-tracing.sh` — not one-off live-sandbox hacks.
- The MLflow Prompt Registry mechanism from
  [ADR-0015](ADR-0015-mlflow-prompt-registry.md) (`register_prompt`,
  `@production` alias, versioned fetch into the sandbox, read-only
  lockdown, trace-tag linking) is **unchanged in design** — only its
  backend, tracking URI, and auth (Bearer token + `X-MLFLOW-WORKSPACE`
  header, TLS validated against `openshift-service-ca.crt`) changed.
  `scripts/prompt-registry/seed-mlflow-prompts.sh` and
  `scripts/prompt-registry/fetch-prompts-from-mlflow.sh` were updated
  accordingly (later moved into `scripts/prompt-registry/` together with
  `prompt-trace-linker.js` — see that directory's `README.md`).

### What did NOT change

- [ADR-0014](ADR-0014-agent-observability.md)'s Pipeline 1 (Tempo + OTel
  Collector for infrastructure logs/metrics, `OTEL_TRACES_EXPORTER=none`)
  is untouched — it never carried agent traces and still doesn't.
  `scripts/deploy-observability.sh` now deploys only this pipeline.
- The `openclaw-integration` RBAC (RoleBinding), SA token (Secret), and
  MLflow experiment (Helm hook Job) declarative resources added to
  `charts/rhoai/mlflow/templates/` during the ADR-0017 experiment are
  unchanged by this ADR — they were already built to be the permanent
  mechanism, not experiment-only scaffolding.
- The `tls: skip` policy field on the `mlflow_direct` (renamed from
  `rhoai_mlflow_direct`) endpoint in `policies/openclaw-sandbox.yaml`
  remains in place — see ADR-0017's "Open question for a future revisit"
  for the standing question of whether it can eventually be replaced by a
  supported custom-CA-injection mechanism.

## Alternatives Considered

1. **Keep both backends, RHOAI opt-in (status quo per ADR-0017).** Rejected
   per explicit user direction once RHOAI MLflow was proven working
   end-to-end: maintaining two parallel tracing/prompt-registry backends
   (each with its own deploy script, auth model, and documentation) is pure
   maintenance overhead once one of them is fully functional and the other
   was never going to be the real target (Phase 12's actual goal was always
   to *replace* standalone MLflow, per the original `ROADMAP.md`).
2. **Keep standalone MLflow as a lightweight fallback for low-resource
   environments.** Rejected — the user explicitly accepted the CRC resource
   trade-off (see "Consequences" below) in favor of a single, simpler
   codebase over a dual-path one with an escape hatch that would rarely be
   exercised and would still need to be kept working/tested.
3. **Defer the removal until AWS OCP access is available and re-validate
   there first.** Rejected — the three blockers fixed in the ADR-0017
   experiment (TLS trust, hostname matching, workspace header) are
   OpenShell-proxy-level and MLflow-SDK-level issues, not CRC-specific
   artifacts; they were expected to reproduce identically on AWS. The user
   chose to proceed on the strength of the CRC validation rather than wait.

## Consequences

- **No lightweight local-tracing fallback exists anymore.** On CRC, running
  RHOAI + MLflow together with the full OpenClaw-in-OpenShell stack
  measurably drops host-available memory to ~11 GiB (down from a ~16 GiB
  safety floor this project otherwise tries to protect — see ADR-0017's
  Stage 2 results) and engages swap. This is now an **accepted, deliberate
  trade-off**, not a to-be-fixed gap: functionally nothing crashes or gets
  OOM-killed, it's simply tighter headroom for other things running on the
  same laptop (Cursor, browser, etc.) during local dev sessions.
- **Simpler mental model going forward**: exactly one tracing backend,
  one prompt-registry backend, one auth model (Bearer SA token +
  `X-MLFLOW-WORKSPACE`, workspace-scoped RBAC via
  `self_subject_access_review`) to reason about, document, and test.
- **RBAC/token/experiment provisioning is now mandatory infrastructure**,
  not an opt-in add-on — `charts/rhoai/mlflow`'s `openclawIntegration` Helm
  values block defaults to `false` only so a bare `make -C charts/rhoai
  deploy-all` (RHOAI+MLflow alone, no OpenShell) doesn't fail against a
  nonexistent ServiceAccount; every real project deploy flow flips it on
  via `wire-rhoai-mlflow-tracing.sh`'s `helm upgrade
  --set openclawIntegration.enabled=true`.
- **All prompt/trace-related scripts now require RHOAI MLflow's wiring
  facts to exist** (`.rendered/rhoai-mlflow/wiring.env`, produced by
  `scripts/wire-rhoai-mlflow-tracing.sh`) before they can authenticate —
  `scripts/verify.sh` and `scripts/test-tracing.sh` both degrade to
  `warn`/skip (not silent false-pass) when that file is missing, rather
  than trying an unauthenticated request that would just 401/400.
  (`scripts/smoke-test-e2e.sh` was later removed — it duplicated
  `verify.sh` Layer 8/8b/9; see the 2026-07-26 simplification pass.)
- **Documentation and history**: [ADR-0014](ADR-0014-agent-observability.md) and [ADR-0015](ADR-0015-mlflow-prompt-registry.md) are marked
  Superseded (MLflow half only, for ADR-0014) but kept verbatim as
  historical record of the original design rationale — not deleted, per
  the project's own preference for traceable decision history.
  [ADR-0017](ADR-0017-rhoai-mlflow-scope.md)'s empirical findings and fix
  log remain the canonical reference for *how* the integration actually
  works (TLS trust, hostname matching, workspace header) — this ADR does
  not repeat those details, only the scope decision that followed them.

## Amendment (2026-07-27): RHOAI Dashboard enabled for Prompt Registry / Traces UI visibility — AWS only, kept Removed on CRC

While validating the Prompt Registry UI (browsing `openclaw-system.*` prompts
and their linked traces through the RHOAI Dashboard, as opposed to the API/
SDK access already covered above), found and fixed two more gaps — one real
bug, one an intentional scope decision this ADR had not made explicit yet.

**Scope decision, environment-conditional**: `charts/rhoai/platform`'s
`dashboard` component **stays `Removed` by default** (the value in
`values.yaml`, unchanged from ADR-0017's original minimal-footprint chart —
this project's actual tracing/prompt-registry needs are all met by the
MLflow Route's API/SDK alone, validated end-to-end without the Dashboard).
`scripts/deploy-rhoai-mlflow.sh` now overrides it to **`Managed`** (+
`genAiStudio: true` via the new `charts/rhoai/platform/templates/
dashboard-config.yaml`) by layering the declarative
`charts/rhoai/platform/values-aws.yaml` overlay on top of `values.yaml`
(instead of `values-crc.yaml`, which restates the `Removed`/`false`
defaults explicitly) **only when `CRC_MODE` is false**, i.e. on AWS OCP.
Rationale: the Dashboard is a "nice to browse"
convenience (2 `rhods-dashboard` pods, 9 containers each) with zero effect
on whether tracing/prompt-registration actually works — not worth the extra
footprint on a resource-constrained CRC laptop that's already sharing RAM
with Cursor (see ADR-0017's Stage 2 findings), but a reasonable default on
a dedicated AWS cluster where a human is more likely to want to browse the
registry through a UI. First tried enabling it unconditionally on CRC too;
reverted after the user pointed out it adds real footprint for zero
functional benefit there — see `docs/constraints.md` #20's prerequisite
note for the up-to-date, environment-conditional description.

**Real bug found and fixed**: prompts registered by
`scripts/prompt-registry/seed-mlflow-prompts.sh` were confirmed present and
correctly tagged via the API/SDK, but invisible in the Dashboard's
per-experiment Prompts tab. Root cause: `register_prompt()` was called
without an active MLflow experiment set, so every prompt's
`_mlflow_experiment_ids` tag defaulted to `,0,` (the "Default" experiment)
instead of the `openclaw-tracing` experiment the Dashboard's per-experiment
Prompts page filters on. Fixed by having `seed-mlflow-prompts.sh` call
`mlflow.set_experiment(experiment_id=...)` first, with
`wire-rhoai-mlflow-tracing.sh` passing through the experiment ID it already
captures. Full writeup: `docs/constraints.md` #20.

**Namespace label**: `opendatahub.io/dashboard: "true"` was also added to
the `openshell` namespace (`scripts/bootstrap-ocp.sh`) so the Dashboard
lists it as a Data Science Project. This was investigated as a candidate
root cause for the bug above and ruled out (prompts were still invisible
with the label alone, before the experiment-id fix) — but it's kept since
it's part of the now-working configuration and is a reasonable prerequisite
for the Dashboard to recognize the namespace at all.

Net effect on this ADR's "Consequences" section: no change to the tracing/
prompt-registry backend or its API-level auth model, only an additional UI
surface (RHOAI Dashboard) turned on for the same underlying data.

## References

- [ADR-0014: Agent Observability — Dual-Pipeline Tracing with OTel + MLflow](ADR-0014-agent-observability.md) (superseded, MLflow half)
- [ADR-0015: System Prompts via MLflow Prompt Registry](ADR-0015-mlflow-prompt-registry.md) (backend superseded, mechanism unchanged)
- [ADR-0017: RHOAI-Managed MLflow — Empirical CRC Test Results and Scope Decision](ADR-0017-rhoai-mlflow-scope.md) (empirical validation + original scope, now superseded)
- [mlflow/mlflow#23927](https://github.com/mlflow/mlflow/pull/23927) — upstream `X-MLFLOW-WORKSPACE` fix, backported as a source patch
- `docs/constraints.md` #4b, #4c, #4d, #4e — the concrete blockers and fixes referenced above

# ADR-0017: RHOAI-Managed MLflow — Empirical CRC Test Results and Scope Decision

## Status

Accepted. Empirically tested on CRC (not just inferred from documentation)
on 2026-07-24. **Nuanced outcome**: RHOAI + minimal MLflow alone fits
comfortably on this laptop's CRC; combined with the rest of the
OpenClaw-in-OpenShell stack, it functionally works but breaches this
project's own resource-safety floor for protecting the host machine (Cursor,
desktop apps). Decision: ship `charts/rhoai/` and
`scripts/deploy-rhoai-mlflow.sh` as a proven, standalone, opt-in local
experiment; do not wire it into `crc-lifecycle.sh`'s combined `deploy`/`full`
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

Ran `./scripts/crc-lifecycle.sh deploy` (bootstrap + OpenShell + OpenClaw
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
2. **Do not wire `deploy-rhoai-mlflow.sh` into `crc-lifecycle.sh`'s combined
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

## Charts

`charts/rhoai/` (new) — adapted from `agentops-example/deploy/helm/{operators,platform,database,mlflow}`,
trimmed to only what Phase 12 needs:

- `operators/` — RHOAI Subscription, `installPlanApproval: Manual` (differs
  from `agentops-example`'s `Automatic`, per this repo's `AGENTS.md`: *"Use
  installPlanApproval: Manual for OLM operators to prevent unreviewed
  upgrades"*).
- `platform/` — `DataScienceCluster` with only `mlflowoperator: Managed`;
  `dashboard`, `kserve`, `llamastackoperator`, `trustyai`, `modelsAsService`,
  `aipipelines`, `feastoperator`, `kueue`, `modelregistry`, `ray`, `trainer`,
  `trainingoperator`, `sparkoperator`, `workbenches` all `Removed`.
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

- Local CRC development keeps its current, lighter default (`crc-lifecycle.sh
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

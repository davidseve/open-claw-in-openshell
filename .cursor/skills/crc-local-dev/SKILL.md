---
description: "Deploy and manage a local CRC (OpenShift Local) instance as a mirror of the AWS OCP deployment for OpenClaw-in-OpenShell testing."
user_invocable: true
---

# CRC Local Dev

Deploy, test, and tear down a local OpenShift cluster via CRC that mirrors the AWS OCP deployment exactly.

## Principle

CRC is a local mirror of the AWS OCP deployment, not a different environment. The same scripts, Helm values, OpenClaw config, sandbox policies, and verification tests run on both. The only variable is `APPS_DOMAIN` (defined once in `scripts/common.sh`). Any divergence is a bug.

## Prerequisites

- CRC binary at `$CRC_BIN` (default: `/home/dseveria/Applications/crc-linux-amd64/crc-linux-2.57.0-amd64/crc`)
- Pull secret at `~/Downloads/pull-secret.txt` (from https://console.redhat.com/openshift/create/local)
- `oc`, `helm`, `openshell` CLIs in PATH
- `secrets/secrets.env` with `MAAS_API_KEY` populated
- KVM/libvirt configured (`crc setup --check-only` passes)

## Quick Start (One-Shot)

```bash
cd /home/dseveria/git/ai/agents/open-claw-in-openshell
./scripts/cluster-lifecycle.sh full
```

This runs: `setup` -> `deploy` -> `verify` in sequence.

## Commands

```bash
./scripts/cluster-lifecycle.sh setup       # Configure CRC (16 vCPU, 40 GB RAM, 100 GB disk — sized for RHOAI+MLflow, see ADR-0017/ADR-0018), run preflight, start VM, login
./scripts/cluster-lifecycle.sh start       # Start existing CRC VM + oc login
./scripts/cluster-lifecycle.sh deploy      # Deploy full stack: bootstrap + RHOAI/MLflow + openshell + openclaw
./scripts/cluster-lifecycle.sh verify      # Run verification suite (all layers)
./scripts/cluster-lifecycle.sh teardown    # Remove stack from CRC (keep VM)
./scripts/cluster-lifecycle.sh stop        # Stop CRC VM (preserves state)
./scripts/cluster-lifecycle.sh delete      # Destroy CRC VM entirely
./scripts/cluster-lifecycle.sh status      # Show CRC and cluster status
./scripts/cluster-lifecycle.sh full        # setup + deploy + verify (autonomous)
```

### Optional Flags

```bash
./scripts/cluster-lifecycle.sh deploy --with-oidc    # Also deploy Keycloak OIDC
./scripts/cluster-lifecycle.sh deploy --with-obs     # Also deploy infra observability (Tempo/OTel Collector — logs/metrics only)
./scripts/cluster-lifecycle.sh full                  # Full stack with everything (OIDC+obs by default)
./scripts/cluster-lifecycle.sh full --minimal        # Full stack without OIDC and infra observability
./scripts/cluster-lifecycle.sh full --fresh          # Delete existing VM and start from scratch
```

RHOAI + MLflow (the sole tracing/prompt-registry backend, see
[ADR-0018](../../docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)) are
**not** behind `--with-obs` — they're deployed and wired unconditionally on
every `deploy`/`full` run, on every environment.

## Architecture

```
Laptop (Fedora, Intel Ultra 7, 64 GB RAM)
  ├── Host: crc CLI, oc, helm, openshell
  └── CRC VM (16 vCPU, 40 GB RAM, OCP 4.20.5)
       ├── namespace: openshell
       │    ├── OpenShell Gateway (StatefulSet)
       │    └── OpenClaw Sandbox (Pod)
       ├── namespace: redhat-ods-applications (mandatory)
       │    └── RHOAI-managed MLflow (sole tracing/prompt-registry backend)
       ├── namespace: observability (opt-in, --with-obs)
       │    ├── OTel Collector
       │    └── Tempo
       └── Routes: *.apps-crc.testing
```

## Domain Handling

`APPS_DOMAIN` in `scripts/common.sh` is the single source of truth. It is auto-detected from the cluster via `oc get ingresses.config.openshift.io cluster`. Template files (`.tpl`) use `__APPS_DOMAIN__` placeholders which are rendered at deploy time.

| Environment | APPS_DOMAIN |
|---|---|
| CRC | `apps-crc.testing` |
| AWS OCP | `apps.ocp.sandbox315.opentlc.com` |

No CRC-specific config files exist. Same templates, same scripts, different domain.

## CRC vs AWS Differences

Three differences, all isolated:

1. **OLM operator**: CRC skips OLM subscription (single-node may lack catalog). CRDs are applied directly. Controlled by `CRC_MODE` in `bootstrap-ocp.sh`.
2. **Keycloak/infra observability**: Opt-in on CRC via `--with-oidc` / `--with-obs` flags. Always deployed on AWS.
3. **RHOAI-managed MLflow**: mandatory on **both** CRC and AWS since [ADR-0018](../../docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md) — it is the sole tracing/prompt-registry backend, wired unconditionally by `cluster-lifecycle.sh`'s `deploy`/`full` commands (not gated behind any flag). Empirically validated on CRC (not just inferred from docs) — see [ADR-0017](../../docs/adrs/ADR-0017-rhoai-mlflow-scope.md): RHOAI + minimal MLflow alone fits fine on a 16 vCPU / 40 GiB CRC VM; combined with the full OpenShell + OpenClaw stack, host free memory drops to ~11 GiB and swap engages — functionally fine (no crashes/evictions), but tight on a shared dev laptop. This is now an **accepted trade-off** (ADR-0018), not a reason to keep the two paths separate — there is no lightweight standalone-MLflow fallback anymore.

## Known Issues

- **OIDC token TTL**: Default Keycloak access token lifespan is 300s (5 minutes). Increase to 1800s for long-running scripts like `verify.sh`. Deploy scripts handle this via the Keycloak admin API.
- **Deploy order**: RHOAI + MLflow must be deployed *before* OpenShell (the `mlflow-integration` ClusterRole/namespace it binds RBAC to must exist first); `wire-rhoai-mlflow-tracing.sh` (RBAC, SA token, experiment, prompt seeding) must run *after* OpenShell (binds to the `openshell-sandbox` SA it creates). When `--with-oidc` is set, Keycloak must also be deployed before `configure-oidc.sh` runs. See constraint #10 in `docs/constraints.md`.
- **oauth-proxy (browser UI auth)**: Since ADR-0016, `deploy-oauth2-proxy.sh` deploys `oauth-proxy` (OpenShift fork, `-provider=openshift`) with a ServiceAccount-based OAuth client — no Keycloak client/secret involved. Keycloak's `openclaw-ui` client from the pre-ADR-0016 setup is retired.

## Troubleshooting

```bash
# Check CRC VM status
crc status

# Login to CRC cluster
eval $(crc oc-env)
oc login -u kubeadmin -p $(crc console --credentials | grep -oP "(?<=password is ')([^']+)" | head -1) https://api.crc.testing:6443 --insecure-skip-tls-verify

# Check pods
oc get pods -n openshell

# Check sandbox logs
openshell sandbox connect openclaw-gw

# Re-deploy after changes
./scripts/cluster-lifecycle.sh teardown
./scripts/cluster-lifecycle.sh deploy

# Full reset
./scripts/cluster-lifecycle.sh delete
./scripts/cluster-lifecycle.sh full
```

## File Map

| File | Purpose |
|------|---------|
| `scripts/cluster-lifecycle.sh` | Cluster + stack lifecycle manager (deploy/verify/teardown work against CRC or a real cluster identically; setup/start/stop/delete are CRC VM-only) |
| `scripts/common.sh` | Shared vars, `detect_environment()`, `render_template()` |
| `charts/openshell/values-ocp.yaml.tpl` | Helm values template |
| `config/openclaw.json.tpl` | OpenClaw config template |
| `manifests/openclaw-service-route.yaml.tpl` | Route manifest template |
| `.rendered/` | Generated files (gitignored, ephemeral) |

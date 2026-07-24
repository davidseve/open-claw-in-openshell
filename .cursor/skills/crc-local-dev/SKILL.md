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
./scripts/crc-lifecycle.sh full
```

This runs: `setup` -> `deploy` -> `verify` in sequence.

## Commands

```bash
./scripts/crc-lifecycle.sh setup       # Configure CRC (12 vCPU, 24 GB RAM, 80 GB disk), run preflight, start VM, login
./scripts/crc-lifecycle.sh start       # Start existing CRC VM + oc login
./scripts/crc-lifecycle.sh deploy      # Deploy full stack: bootstrap + openshell + openclaw
./scripts/crc-lifecycle.sh verify      # Run verification suite (all layers)
./scripts/crc-lifecycle.sh teardown    # Remove stack from CRC (keep VM)
./scripts/crc-lifecycle.sh stop        # Stop CRC VM (preserves state)
./scripts/crc-lifecycle.sh delete      # Destroy CRC VM entirely
./scripts/crc-lifecycle.sh status      # Show CRC and cluster status
./scripts/crc-lifecycle.sh full        # setup + deploy + verify (autonomous)
```

### Optional Flags

```bash
./scripts/crc-lifecycle.sh deploy --with-oidc    # Also deploy Keycloak OIDC (Phase 7)
./scripts/crc-lifecycle.sh deploy --with-obs     # Also deploy observability stack (Phase 8)
./scripts/crc-lifecycle.sh full                  # Full stack with everything (OIDC+obs by default)
./scripts/crc-lifecycle.sh full --minimal        # Full stack without OIDC and observability
./scripts/crc-lifecycle.sh full --fresh          # Delete existing VM and start from scratch
```

## Architecture

```
Laptop (Fedora, Intel Ultra 7, 64 GB RAM)
  ├── Host: crc CLI, oc, helm, openshell
  └── CRC VM (12 vCPU, 24 GB RAM, OCP 4.20.5)
       ├── namespace: openshell
       │    ├── OpenShell Gateway (StatefulSet)
       │    └── OpenClaw Sandbox (Pod)
       ├── namespace: observability (opt-in)
       │    ├── OTel Collector
       │    ├── Tempo
       │    └── MLflow
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
2. **Keycloak/Observability**: Opt-in on CRC via `--with-oidc` / `--with-obs` flags. Always deployed on AWS.
3. **RHOAI-managed MLflow (Phase 12)**: standalone-only experiment on CRC via `./scripts/deploy-rhoai-mlflow.sh`, run manually and never combined with the rest of the stack for long. Empirically tested (not just inferred from docs) — see [ADR-0017](../../docs/adrs/ADR-0017-rhoai-mlflow-scope.md): RHOAI + minimal MLflow alone fits fine on a 16 vCPU / 40 GiB CRC VM, but combined with the full OpenShell + OpenClaw stack it drops host free memory below this project's Cursor-safety floor (fine functionally, not fine for a shared dev laptop). Not wired into `crc-lifecycle.sh`'s `deploy`/`full` commands for this reason. AWS is the primary target for running it together with everything else — see `deploy-full-aws` skill.

## Known Issues

- **OIDC token TTL**: Default Keycloak access token lifespan is 300s (5 minutes). Increase to 1800s for long-running scripts like `verify.sh`. Deploy scripts handle this via the Keycloak admin API.
- **Deploy order**: When `--with-oidc` is set, Keycloak and Observability must be deployed *before* OpenShell to ensure the OIDC issuer and MLflow are available when `configure-oidc.sh` and `seed-mlflow-prompts.sh` run.
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
./scripts/crc-lifecycle.sh teardown
./scripts/crc-lifecycle.sh deploy

# Full reset
./scripts/crc-lifecycle.sh delete
./scripts/crc-lifecycle.sh full
```

## File Map

| File | Purpose |
|------|---------|
| `scripts/crc-lifecycle.sh` | CRC VM lifecycle manager |
| `scripts/common.sh` | Shared vars, `detect_environment()`, `render_template()` |
| `charts/openshell/values-ocp.yaml.tpl` | Helm values template |
| `config/openclaw.json.tpl` | OpenClaw config template |
| `manifests/openclaw-service-route.yaml.tpl` | Route manifest template |
| `.rendered/` | Generated files (gitignored, ephemeral) |

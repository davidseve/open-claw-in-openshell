---
description: "Full autonomous deploy of OpenClaw-in-OpenShell on CRC (OpenShift Local). One command does everything; agent only intervenes on failure."
user_invocable: true
---

# Deploy Full CRC

Autonomous deployment of the complete OpenClaw-in-OpenShell stack on a local CRC
cluster. The scripts do the work — the agent runs one command and verifies.

## CRITICAL: Read Constraints First

Before diagnosing ANY failure, read `docs/constraints.md`. It documents every
sandbox constraint discovered during deployment.

## Trigger

User says: `/deploy-full-crc`, "deploy everything on CRC", "start from scratch
on CRC", or similar.

## Prerequisites

- CRC binary installed (see `crc-local-dev` skill)
- Pull secret at `~/Downloads/pull-secret.txt`
- `oc`, `helm`, `openshell` CLIs in PATH
- `secrets/secrets.env` with `MAAS_API_KEY`
- KVM/libvirt configured

## Execution

### Step 1: Check CRC State

```bash
cd /home/dseveria/git/ai/agents/open-claw-in-openshell
crc status 2>/dev/null
```

If a VM exists, ask the user: **reuse** or **fresh**?

### Step 2: Run the Single Deploy Command

For fresh (no existing VM or user chose fresh):

```bash
./scripts/crc-lifecycle.sh full --fresh
```

For reuse (existing VM):

```bash
./scripts/crc-lifecycle.sh deploy --with-oidc --with-obs
./scripts/crc-lifecycle.sh verify
```

The `full --fresh` command handles the entire 10-phase deploy autonomously
(RHOAI + MLflow phases are unconditional, not gated behind `--with-obs` —
see [ADR-0018](../../docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)):
1. Bootstrap OCP (namespace, SCCs, secrets)
2. Deploy Keycloak (OIDC issuer — CLI/gRPC gateway auth only, see ADR-0016)
3. Deploy infra observability (Tempo, OTel Collector — logs/metrics only, `--with-obs`)
4. Deploy RHOAI + MLflow (sole tracing/prompt-registry backend, unconditional)
5. Deploy OpenShell (Helm install, best-effort provider)
6. Wire RHOAI MLflow tracing (RBAC, SA token, experiment, CA, prompt seeding — unconditional)
7. Configure OIDC (Helm upgrade + obtain token + create provider)
8. Deploy oauth-proxy (browser UI auth via OpenShift-native OAuth, no Keycloak — ADR-0016)
9. Launch OpenClaw in sandbox (with all constraint workarounds)
10. Smoke test + full verification

See `docs/constraints.md` constraint #10 for why this order matters.

### Step 3: Verify Result

If the command exits 0 — done. Report the URLs:
- Control UI: `https://openclaw-gw--openclaw-ui.apps-crc.testing/`
- MLflow UI: RHOAI's Route (`oc get route mlflow -n redhat-ods-applications`)
- Keycloak: `https://keycloak-openshell-keycloak.apps-crc.testing/`

If it fails — read the output, identify the failing phase, check
`docs/constraints.md`, and fix the root cause. Re-run the command (max 2 retries).

## Boundaries

- Max 2 full retries
- Do NOT re-implement script logic — just run `crc-lifecycle.sh`
- Do NOT skip verification
- On failure, read `docs/constraints.md` before diagnosing
- If a script has a bug, fix the script (not a manual workaround)

## Post-Deploy Monitoring

After a successful deploy, if the user asks to monitor, use the
`monitor-deployment` skill.

## Token Optimization

- Run the single command, do not re-implement phases
- Only read logs on failure
- Do not explain what scripts do — run them and check exit codes

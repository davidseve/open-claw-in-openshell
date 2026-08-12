---
description: "Full autonomous deploy of OpenClaw-in-OpenShell on CRC (OpenShift Local) or an AWS-hosted OCP cluster. One command does everything; agent only intervenes on failure."
user_invocable: true
---

# Deploy Full

Autonomous deployment of the complete OpenClaw-in-OpenShell stack, on either
a local CRC cluster or an AWS-hosted OpenShift cluster. The scripts do the
work (`scripts/cluster-lifecycle.sh`) — the agent picks the target environment,
runs one command, and verifies.

## CRITICAL: Read Constraints First

Before diagnosing ANY failure, read `docs/constraints.md`. It documents every
sandbox constraint discovered during deployment.

## Trigger

- CRC: `/deploy-full-crc`, "deploy everything on CRC", "start from scratch on CRC"
- AWS: `/deploy-full-aws`, "deploy everything on AWS", "deploy to production cluster"
- Ambiguous ("deploy everything", "deploy full stack"): ask the user which
  target environment (CRC or AWS) before proceeding.

## Target environment differences

| Aspect | CRC | AWS |
|--------|-----|-----|
| Setup phase | Yes (`cluster-lifecycle.sh setup` starts the VM) | No (cluster already running — just `oc login`/`oc whoami`) |
| `APPS_DOMAIN` | `apps-crc.testing` | Auto-detected from cluster |
| OLM Operator install | CRDs applied directly | Subscription via OLM catalog (`installPlanApproval: Manual`, auto-approved for the pinned channel — see `charts/rhoai/Makefile`'s `wait-operators`) |
| TLS certificates | Self-signed (CRC router) | Cluster-issued (trusted) |
| `CURL_OPTS` / `OPENSHELL_GATEWAY_INSECURE` | `-k` / `true` (self-signed router CA — `docs/constraints.md` #18) | Empty / unset (trusted certs) |

All of this is handled automatically by `common.sh`'s `detect_environment()` —
no environment-specific flags needed beyond which top-level command you run.

## Prerequisites

Common to both:
- `oc`, `helm`, `openshell` CLIs in PATH
- `secrets/secrets.env` with `MAAS_API_KEY` (copy from `secrets/secrets.template.env`)

CRC only:
- CRC binary installed (see `crc-local-dev` skill), KVM/libvirt configured
- Pull secret at `~/Downloads/pull-secret.txt`

AWS only:
- Logged into the AWS OCP cluster: `oc whoami` succeeds
- RHOAI's OLM operator catalog available (`oc get packagemanifest rhods-operator -n openshift-marketplace`)

## Execution

### CRC

**Step 1 — Check CRC state:**

```bash
cd /home/dseveria/git/ai/agents/open-claw-in-openshell
crc status 2>/dev/null
```

If a VM already exists, ask the user: **reuse** or **fresh**?

**Step 2 — Run the deploy command:**

```bash
# Fresh (no existing VM, or user chose fresh):
./scripts/cluster-lifecycle.sh full --fresh

# Reuse (existing VM):
./scripts/cluster-lifecycle.sh deploy --with-oidc --with-obs
./scripts/cluster-lifecycle.sh verify
```

### AWS

**Step 1 — Verify cluster connectivity:**

```bash
oc whoami
oc get nodes
```

**On fail**: check VPN, `oc login`, cluster status. Max 3 retries.

**Step 2 — Run the deploy command:**

```bash
./scripts/cluster-lifecycle.sh deploy --with-oidc --with-obs
./scripts/cluster-lifecycle.sh verify
```

(No `setup`/`full --fresh` step on AWS — the cluster already exists.)

### Both: the 10-phase deploy sequence

`cmd_deploy()` in `scripts/cluster-lifecycle.sh` runs the same phases on both
environments (RHOAI + MLflow are unconditional, not gated behind
`--with-obs` — see [ADR-0018](../../docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)):

1. Bootstrap OCP (namespace, SCCs, secrets)
2. Deploy Keycloak (OIDC issuer — CLI/gRPC gateway auth only, see ADR-0016)
3. Deploy infra observability (Tempo, OTel Collector — logs/metrics only, `--with-obs`)
4. Deploy RHOAI + MLflow (sole tracing/prompt-registry backend, unconditional)
5. Deploy OpenShell (Helm install, best-effort provider)
6. Wire RHOAI MLflow tracing (RBAC, SA token, experiment, CA, prompt seeding — unconditional)
7. Configure OIDC (Helm upgrade + obtain token + create provider)
8. Deploy oauth-proxy (browser UI auth via OpenShift-native OAuth, no Keycloak — ADR-0016)
9. Launch OpenClaw in sandbox (with all constraint workarounds)
10. Full verification (`verify.sh`, `VERIFY_PROFILE=full` default — see `scripts/verify.sh`)

See `docs/constraints.md` constraint #10 for why this order matters.

### Step 3: Verify result

If the command exits 0 — done. Report the URLs:
- Control UI: `https://openclaw-gw2--openclaw-ui.<APPS_DOMAIN>/`
- MLflow UI: RHOAI's Route (`oc get route mlflow -n redhat-ods-applications`)
- Keycloak: `https://keycloak-openshell-keycloak.<APPS_DOMAIN>/` (CRC: `apps-crc.testing`)

If it fails — read the output, identify the failing phase, check
`docs/constraints.md`, and fix the root cause. Re-run the command
(max 2 retries on CRC, max 3 on AWS).

## Boundaries

- Max 2 full retries (CRC) / 3 retries per phase, 3 verify cycles, 20 total iterations (AWS)
- Do NOT re-implement script logic — just run `cluster-lifecycle.sh`
- Do NOT skip verification
- On failure, read `docs/constraints.md` before diagnosing
- If a script has a bug, fix the script (not a manual workaround)

## Post-Deploy Monitoring

After a successful deploy, if the user asks to monitor, use the
`monitor-deployment` skill. Works identically on AWS and CRC — same
`verify.sh`, same repair logic, same constraints from `docs/constraints.md`.

## Token-efficient execution

Follow the global skill **`long-running-scripts`** (`~/.cursor/skills/long-running-scripts/`).

- **One command:** `./scripts/cluster-lifecycle.sh full --fresh` with high `block_until_ms` (≥ 900000) or background + `notify_on_output` `^AGENT_SCRIPT_DONE`
- **No polling** while it runs
- **On success:** read `.agent-status/cluster-lifecycle-full.json` and `.verify-status.json` — not full logs
- **Iteration:** `VERIFY_PROFILE=smoke ./scripts/verify.sh`; **full** verify only at deploy end
- **On failure only:** `tail -50` of log path from status JSON

## Token Optimization

- Run the single command, do not re-implement phases
- Only read logs on failure
- Do not explain what scripts do — run them and check exit codes

## AWS-specific TODOs (future implementation)

- [ ] Add AWS-specific pre-flight: check OLM catalog, node capacity, storage class
- [ ] Add DNS/certificate validation for custom domains
- [ ] Add backup/snapshot before deploy (for production safety)
- [ ] Integrate with ArgoCD for GitOps-managed deployments
- [ ] Add rollback capability on failure

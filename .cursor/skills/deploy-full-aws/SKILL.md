---
description: "Full autonomous deploy of OpenClaw-in-OpenShell on an AWS OCP cluster with Loop Engineering pattern: deploy, validate, auto-repair."
user_invocable: true
---

# Deploy Full AWS

Autonomous deployment of the complete OpenClaw-in-OpenShell stack on an AWS-hosted OpenShift cluster. Uses the same Loop Engineering pattern as `deploy-full-crc`.

## Trigger

User says: `/deploy-full-aws`, "deploy everything on AWS", "deploy to production cluster", or similar.

## Differences from CRC

| Aspect | CRC | AWS |
|--------|-----|-----|
| CRC setup phase | Yes (start VM) | No (cluster already running) |
| `APPS_DOMAIN` | `apps-crc.testing` | Auto-detected from cluster |
| OIDC + Observability | Included by default | Always deployed (mandatory) |
| OLM Operator | CRDs applied directly | Subscription via OLM catalog |
| TLS certificates | Self-signed (CRC) | Cluster-issued (trusted) |
| `CURL_OPTS` | `-k` (skip verify) | Empty (trusted certs) |

## Prerequisites

- Logged into the AWS OCP cluster: `oc whoami` succeeds
- `oc`, `helm`, `openshell` CLIs in PATH
- `secrets/secrets.env` with `MAAS_API_KEY`
- OLM operator catalog available (for sandboxed containers operator)

## Execution

Same loop structure as `deploy-full-crc`, with these differences:

### Phase 2: Cluster Connectivity (replaces CRC Setup)

```bash
oc whoami
oc get nodes
```

**Verify**: Cluster reachable, nodes Ready, `APPS_DOMAIN` auto-detected.
**On fail**: Check VPN, `oc login`, cluster status. Max 3 retries.

### Phases 3-9: Same as CRC

Run the deploy command. Deploy order is enforced by `cmd_deploy()` — see
constraint #10 in `docs/constraints.md`.

```bash
./scripts/crc-lifecycle.sh deploy --with-oidc --with-obs
./scripts/deploy-rhoai-mlflow.sh   # Phase 12, AWS only — see below
./scripts/crc-lifecycle.sh verify
```

This runs the 8-phase deploy sequence:
1. Bootstrap OCP (namespace, SCCs, secrets)
2. Deploy Keycloak (OIDC issuer — CLI/gRPC gateway auth only, see ADR-0016)
3. Deploy Observability (Tempo, OTel, MLflow, prompt seeding)
4. Deploy OpenShell (Helm install, best-effort provider)
5. Configure OIDC (Helm upgrade + token + create provider)
6. Deploy oauth-proxy (browser UI auth via OpenShift-native OAuth, no Keycloak — ADR-0016)
7. Launch OpenClaw in sandbox
8. Full verification

### Phase 9b (optional): RHOAI-managed MLflow (Phase 12)

`./scripts/deploy-rhoai-mlflow.sh` deploys the minimal RHOAI operator +
`DataScienceCluster` (`mlflowoperator` only) + Postgres + `MLflow` CR via
`charts/rhoai/`. Empirically tested on CRC first (see
[ADR-0017](../../docs/adrs/ADR-0017-rhoai-mlflow-scope.md)): it works fine
alone, but combined with the rest of the stack it uses more memory than a
shared dev laptop can safely spare — so AWS is the intended environment for
running it *together* with everything else. Run it after step 8 (full
verification) once RHOAI's operator catalog is confirmed available
(`oc get packagemanifest rhods-operator -n openshift-marketplace`).
`installPlanApproval: Manual` — approve the `InstallPlan` once:
```bash
oc -n redhat-ods-operator get installplan
oc -n redhat-ods-operator patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
```
The plugin transport switch (bearer SA token, TLS CA, `X-MLFLOW-WORKSPACE`
header — remaining Phase 12 tasks in `ROADMAP.md`) is not yet wired up; this
phase currently only proves the RHOAI MLflow instance itself comes up.

All scripts use `detect_environment()` from `common.sh` which auto-detects
`APPS_DOMAIN` and `CRC_MODE`. No AWS-specific flags needed.

## Boundaries

Same as CRC: max 3 retries per phase, max 3 verify cycles, max 20 total iterations. Plus:
- Same OIDC token, Node.js binary path, and Playwright caveats as CRC (see `deploy-full-crc` skill).

## State Persistence

Same `.deploy-state.json` format with `"environment": "aws"`.

## Post-Deploy Monitoring

After deploy completes, use the `monitor-deployment` skill for continuous health
checking with auto-repair. Works identically on AWS and CRC — same `verify.sh`,
same repair logic, same constraints from `docs/constraints.md`.

Invoke with: `/monitor-deployment` or "monitor the deployment"

## TODO (Future Implementation)

- [ ] Add AWS-specific pre-flight: check OLM catalog, node capacity, storage class
- [ ] Add DNS/certificate validation for custom domains
- [ ] Add backup/snapshot before deploy (for production safety)
- [ ] Integrate with ArgoCD for GitOps-managed deployments
- [ ] Add rollback capability on failure

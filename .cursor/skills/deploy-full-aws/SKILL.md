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
./scripts/crc-lifecycle.sh verify
```

This runs the 10-phase deploy sequence (RHOAI + MLflow phases are
unconditional on every environment, not gated behind `--with-obs` — see
[ADR-0018](../../docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)):
1. Bootstrap OCP (namespace, SCCs, secrets)
2. Deploy Keycloak (OIDC issuer — CLI/gRPC gateway auth only, see ADR-0016)
3. Deploy infra observability (Tempo, OTel Collector — logs/metrics only, `--with-obs`)
4. Deploy RHOAI + MLflow — RHOAI operator, minimal `mlflowoperator`-only DataScienceCluster, Postgres, `MLflow` CR via `charts/rhoai/` (unconditional)
5. Deploy OpenShell (Helm install, best-effort provider)
6. Wire RHOAI MLflow tracing (RBAC, SA token, experiment, CA staging, prompt seeding — unconditional)
7. Configure OIDC (Helm upgrade + token + create provider)
8. Deploy oauth-proxy (browser UI auth via OpenShift-native OAuth, no Keycloak — ADR-0016)
9. Launch OpenClaw in sandbox
10. Full verification

RHOAI's OLM operator catalog must be available on the cluster
(`oc get packagemanifest rhods-operator -n openshift-marketplace`).
`installPlanApproval: Manual` — `charts/rhoai/Makefile`'s `wait-operators`
target auto-approves the `InstallPlan` during Phase 4 for the exact
channel/version already pinned in `operators/values.yaml` (no pause, no
manual step, on CRC and AWS alike). To approve by hand instead (e.g. to
review the diff first, per the OCP Security Specialist role in `AGENTS.md`):
```bash
oc -n redhat-ods-operator get installplan
oc -n redhat-ods-operator patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
```

RHOAI-managed MLflow is the **sole** tracing/prompt-registry backend for this
project (no standalone MLflow deployment exists anymore — see
[ADR-0018](../../docs/adrs/ADR-0018-rhoai-mlflow-sole-backend.md)). The plugin
transport (bearer SA token, TLS CA, `X-MLFLOW-WORKSPACE` header) is fully
wired by Phase 6 above — validated end-to-end on CRC first (see
[ADR-0017](../../docs/adrs/ADR-0017-rhoai-mlflow-scope.md)'s "Resolution"
section), expected to reproduce identically on AWS since the fixes involved
are OpenShell-proxy-level and MLflow-SDK-level, not CRC-specific.

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

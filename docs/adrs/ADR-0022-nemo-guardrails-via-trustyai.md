# ADR-0022: NeMo Guardrails via TrustyAI

## Status

Accepted

## Date

2026-08-31

## Layer

Platform

## Context

This project requires input/output guardrails — jailbreak prevention, topic control, and data exfiltration blocking — integrated with RHOAI on OpenShift. The guardrails component intercepts LLM requests through NeMo Guardrails' self-check input/output rails before they reach the MaaS backend.

RHOAI 3.x provides the TrustyAI operator as the supported path for deploying NeMo Guardrails on OpenShift. This is the same pattern already proven in the sibling `agentops-example` project (ADR-0004 there).

## Options Considered

### Option 1: Standalone NeMo Guardrails sidecar

- **Pros:** Flexible deployment, can run outside OpenShift.
- **Cons:** No operator lifecycle management on OCP; must handle TLS, networking, and upgrades manually.
- **GA / support status:** Community only; not covered by Red Hat support.

### Option 2: NeMo Guardrails deployed through TrustyAI operator

- **Pros:** Operator-managed lifecycle on OCP; integrated with RHOAI DataScienceCluster; Red Hat support path.
- **Cons:** Tied to TrustyAI operator release cadence; requires RHOAI 3.x.
- **GA / support status:** Supported via [RHOAI TrustyAI docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/serving_models/serving-large-models_serving-large-models#about-trustyai-operator).

## Decision

Deploy NeMo Guardrails through the TrustyAI operator on OCP, ported from the proven `agentops-example` implementation. This aligns with Red Hat-first conventions (AGENTS.md) and reuses the existing inference router architecture (ADR-0021).

## Architecture

```
OpenClaw → inference.local → [maas-direct | maas-guardrailed] → MaaS
                                    └─ guardrailed → NeMo Guardrails → MaaS
```

OpenClaw always talks to `inference.local`. The OpenShell inference router has two providers:
- `maas-direct` → MaaS (default, no guardrails)
- `maas-guardrailed` → NeMo Guardrails Service → MaaS

Switching between them is a single `openshell inference set --provider` call — no sandbox restart, no config change.

## Changes Required

1. **DSC component**: `trustyai.managementState: Managed` in `charts/rhoai/platform/values.yaml` (was `Removed`)
2. **Helm chart**: `charts/guardrails/` — NemoGuardrails CR, ConfigMap (config.yaml + prompts + rails), MaaS API key Secret
3. **Deploy script**: `scripts/deploy-guardrails.sh` — waits for CRD, Helm install, waits for Ready
4. **Inference toggle**: `scripts/enable-guardrails.sh` / `scripts/disable-guardrails.sh` — switch inference route
5. **Dual providers**: `launch-openclaw.sh` registers both `maas-direct` and `maas-guardrailed` providers
6. **Cluster lifecycle**: `cluster-lifecycle.sh` deploys guardrails after RHOAI platform (TrustyAI CRD dependency)

## Consequences

### Positive

- Guardrails lifecycle is managed by the RHOAI operator stack
- Consistent with Red Hat-first conventions
- Hot-swappable: enable/disable guardrails without sandbox restart
- Same architecture proven in `agentops-example`

### Negative

- Guardrails configuration options are limited to what TrustyAI exposes
- Requires `trustyai: Managed` in the DSC (increases operator footprint)
- Self-check rails add latency to every request when enabled (~2-5s per input/output check)

## Version Pinning

| Component | Pinned version | Where enforced |
|---|---|---|
| TrustyAI operator | RHOAI 3.4 channel `stable-3.4` | `charts/rhoai/operators/values.yaml` |
| NeMo Guardrails | TrustyAI-managed (RHOAI 3.4 GA) | `charts/guardrails/` |

## Validation

- `make deploy-guardrails` — Helm install + wait for CR Ready
- `make validate-guardrails` — CR phase, safe chat, jailbreak block (non-streaming + streaming)
- `scripts/enable-guardrails.sh` / `scripts/disable-guardrails.sh` — hot-swap inference path

## References

- [TrustyAI on RHOAI 3.4](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/serving_models/serving-large-models_serving-large-models#about-trustyai-operator)
- [NeMo Guardrails GitHub](https://github.com/NVIDIA/NeMo-Guardrails)
- [NeMo Guardrails Docs](https://docs.nvidia.com/nemo/guardrails/)
- [agentops-example ADR-0004](../../agentops-example/docs/adr/0004-nemo-guardrails-via-trustyai.md)

# ADR-0021: Migrate to OpenShell Inference Router (inference.local)

## Status

Accepted

## Context

The deployment routed LLM traffic directly from the sandbox to the external MaaS endpoint (`maas-rhdp.apps.maas.redhatworkshops.io:443`) with `request_body_credential_rewrite: true` in the sandbox network policy. This required:

- An explicit `maas_inference` network policy block in `policies/openclaw-sandbox.yaml`
- `LITELLM_API_KEY` injected as an env var into the sandbox process via `--env` in `launch-openclaw.sh`
- OpenClaw's native `${LITELLM_API_KEY}` SecretRef syntax to resolve the credential in-process (constraint #3)
- Hardcoded MaaS endpoint URL and model IDs in `config/openclaw.json.tpl`

The upstream [opendatahub-io/agent-ops](https://github.com/opendatahub-io/agent-ops) project uses OpenShell's built-in inference router instead: sandbox code calls `inference.local` via the OpenAI SDK with `model='router'`, and the gateway transparently injects provider credentials and forwards to the configured backend.

## Decision

Migrate to OpenShell's inference router (`inference.local`):

1. Enable `providers_v2_enabled` on the gateway
2. Re-register the MaaS provider with `--type openai` (v2-compatible)
3. Configure inference route: `openshell inference set --provider maas-litellm --model claude-sonnet-4-6`
4. Update `config/openclaw.json.tpl`: `baseUrl: https://inference.local/v1`, `model: router`, `apiKey: "unused"`
5. Remove the `maas_inference` network policy block from `openclaw-sandbox.yaml`
6. Remove `LITELLM_API_KEY` injection from `launch-openclaw.sh`

## Consequences

### Benefits

- **Provider-agnostic agent code**: Swap providers (MaaS, vLLM, Bedrock, RHOAI-served model) without touching sandbox policy, `openclaw.json`, or agent code
- **No credential exposure in sandbox**: The real API key lives exclusively in the gateway's provider record; the sandbox process never sees it
- **Eliminates `request_body_credential_rewrite`**: Credential injection moves to the gateway's inference layer
- **Enables providers_v2 features**: Provider profile policy composition, per-provider policy layers auto-contributed to sandbox effective policy
- **Simplified config**: Single `base_url: https://inference.local/v1`, `model: router` — no hardcoded endpoint or model name

### Trade-offs

- **Gateway-scoped routing**: Every sandbox on the same gateway shares one provider + one model for `inference.local`. Not a limitation for this project (single sandbox), but prevents per-sandbox model selection
- **Imperative configuration**: Provider and inference route must be configured via `openshell` CLI commands, not Helm values (tracked upstream: [NVIDIA/OpenShell#1886](https://github.com/NVIDIA/OpenShell/issues/1886))
- **Model name in responses**: The inference router rewrites the model in requests but not in responses. The `mlflow-openclaw` plugin is patched (`patch-mlflow-plugin.py`) to prefer `lastAssistant.responseModel` (the real model from the API response) over the configured model ID (`router`) in MLflow traces

### Rollback

Revert config/script changes to the previous git commit. The `maas-litellm` provider persists on the gateway and is not deleted by this migration. Re-run `launch-openclaw.sh` after reverting.

## References

- [OpenShell Inference Routing docs](https://docs.nvidia.com/openshell/latest/sandboxes/inference-routing)
- [OpenShell Providers v2 docs](https://docs.nvidia.com/openshell/sandboxes/providers-v2)
- [NVIDIA/OpenShell#1886 — Declarative provider config](https://github.com/NVIDIA/OpenShell/issues/1886)
- [NVIDIA/OpenShell#896 — Multi-provider inference](https://github.com/NVIDIA/OpenShell/issues/896)
- [ADR-0005 — MaaS inference provider (superseded by this ADR)](ADR-0005-maas-inference-provider.md)

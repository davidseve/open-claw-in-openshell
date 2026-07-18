# ADR-0005: Red Hat MaaS as the Inference Provider

## Status
Accepted

## Context
We need an LLM inference provider for Claude Sonnet 4.6. Three options were evaluated:

- **Direct Anthropic API**: Call the Anthropic Messages API directly. Requires managing API keys, rate limits, and Anthropic-specific client configuration.
- **Self-hosted inference**: Deploy a model server (vLLM, TGI) on GPU nodes. Significant infrastructure cost and operational burden for a single model.
- **Red Hat MaaS**: Use Red Hat's managed LiteLLM proxy, which exposes an OpenAI-compatible `/v1/chat/completions` endpoint and handles upstream provider routing.

## Decision
Use Red Hat MaaS at `https://maas-rhdp.apps.maas.redhatworkshops.io/v1` with `api: "openai-completions"` and model `claude-sonnet-4-6`. Configure in OpenClaw as a custom LiteLLM provider.

## Consequences
- No self-hosted inference infrastructure needed: no GPU nodes, no model server deployments, no model weight management.
- OpenAI-compatible API simplifies OpenClaw configuration — the same provider format works for any model exposed through MaaS.
- Centralized billing and access control via the MaaS platform.
- Tradeoff: external dependency on MaaS availability. If the MaaS endpoint is down, inference is unavailable.
- Tradeoff: the sandbox network policy must explicitly allow egress to `maas-rhdp.apps.maas.redhatworkshops.io:443` (see sandbox policy configuration).
- Tradeoff: latency depends on the MaaS proxy and its upstream provider routing, which is outside our control.

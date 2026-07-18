# ADR-0012: Agent Observability with OpenTelemetry + Tempo + MLflow

## Status

Accepted

## Context

We need traceability of everything the OpenClaw agent does inside the sandbox: LLM API calls, tool executions, agent turn lifecycle, latencies, and token usage. The user requested "MLFlow Observability" to track agent actions.

The `rhoai-platform-ops` reference repo provides an observability module using Red Hat OpenTelemetry and Tempo operators. However, `registry.redhat.io` returned 503 during deployment, preventing OLM-based operator installation.

## Decision

Deploy a standalone observability stack without operator dependencies:

1. **Grafana Tempo** (`grafana/tempo:2.7.2`): Distributed trace storage with local disk backend.
2. **OpenTelemetry Collector** (`otel/opentelemetry-collector-contrib:0.121.0`): OTLP receiver that forwards traces to Tempo and derives RED metrics via spanmetrics connector.
3. **MLflow** (`ghcr.io/mlflow/mlflow:v2.22.0`): Experiment tracking server for agent run metrics.

The sandbox is configured with OTEL environment variables so that OpenClaw emits traces to the collector. The sandbox network policy allows egress to the collector and MLflow services.

## Trace Schema

We follow [OpenTelemetry Semantic Conventions for Generative AI](https://opentelemetry.io/docs/specs/semconv/gen-ai/):

- `gen_ai.system`: The AI system (e.g., "openclaw", "anthropic")
- `gen_ai.operation.name`: Operation type ("chat", "agent_turn")
- `gen_ai.request.model` / `gen_ai.response.model`: Model identifiers
- `gen_ai.usage.input_tokens` / `gen_ai.usage.output_tokens`: Token counts

Custom attributes for OpenClaw:
- `openclaw.agent.model`: Primary agent model
- `openclaw.agent.sandbox`: Sandbox name
- `openclaw.tool.name`: Tool being executed
- `openclaw.tool.exit_code`: Tool execution result

## Alternatives Considered

1. **Red Hat OTel/Tempo operators via OLM**: Preferred for production but blocked by registry.redhat.io 503 errors during bundle unpacking. Would require retrying when registry recovers.

2. **RHOAI MLflow CR** (`mlflow.opendatahub.io/v1`): Requires RHOAI operator which is not installed on this cluster. Too heavy for a POC.

3. **Jaeger**: Older tracing backend being superseded by Tempo in the OpenShift ecosystem.

## Consequences

### Positive
- Full distributed tracing of agent actions with standard OpenTelemetry semantics
- MLflow provides experiment tracking UI for comparing agent runs
- No operator dependency = simpler lifecycle management
- spanmetrics connector derives RED metrics without additional instrumentation

### Negative
- Standalone deployment lacks operator-managed upgrades and reconciliation
- Memory/local-disk backend for Tempo is not production-grade (needs S3/GCS for durability)
- MLflow with SQLite has limited concurrent write performance
- Traces require OpenClaw to be instrumented with OTEL SDK (env vars alone enable Node.js auto-instrumentation if the SDK is present)

## Migration Path

When registry.redhat.io recovers:
1. Install Red Hat OTel and Tempo operators
2. Replace standalone Tempo with `TempoMonolithic` CR
3. Replace standalone OTel Collector with `OpenTelemetryCollector` CR
4. Keep MLflow standalone (or migrate to RHOAI MLflow CR if RHOAI is deployed)

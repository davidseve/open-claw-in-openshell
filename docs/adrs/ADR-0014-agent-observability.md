# ADR-0014: Agent Observability — Dual-Pipeline Tracing with OTel + MLflow

## Status
Accepted (supersedes original ADR-0012 observability design)

## Context

We need end-to-end traceability of OpenClaw agent actions inside the OpenShell sandbox: LLM API calls, tool executions, agent turn lifecycle, latencies, inputs/outputs, and model metadata. The user requested MLflow as the trace UI aligned with RHOAI.

### Constraints

- The sandbox enforces default-deny networking with L7 proxy inspection (ADR-0007).
- Node.js `http.request()` does not respect `HTTP_PROXY` environment variables — only `fetch()` (via undici) does when `NODE_USE_ENV_PROXY=1`.
- MLflow 3.x introduced `fastapi_security` middleware that rejects requests with unrecognized `Host` headers and blocks cross-origin requests unless explicitly whitelisted.
- The `@mlflow/core` JavaScript SDK has bugs in `resolveArtifactUri` that prevent artifact uploads in containerized MLflow deployments with non-standard artifact roots.
- Red Hat OTel/Tempo operators were blocked by `registry.redhat.io` 503 errors, requiring standalone deployment.

## Decision

Deploy a dual-pipeline observability stack:

### Pipeline 1: OpenTelemetry → Tempo (infrastructure traces)
```
OpenClaw diagnostics-otel plugin
  → http.request() → http-proxy-bootstrap.js → sandbox HTTP proxy (10.200.0.1:3128)
    → OTel Collector (otel-collector.observability.svc:4318)
      → Tempo (distributed trace storage)
      → spanmetrics connector → Prometheus metrics
```

### Pipeline 2: @mlflow/mlflow-openclaw → MLflow (rich agent traces)
```
OpenClaw mlflow-openclaw plugin hooks (llm_input, llm_output, agent_end)
  → fetch() → sandbox HTTP proxy (automatic via undici)
    → MLflow native API (mlflow.observability.svc:5000)
      → Trace storage (SQLite + PVC artifacts)
```

### Why two pipelines

| Concern | diagnostics-otel (Pipeline 1) | mlflow-openclaw (Pipeline 2) |
|---------|-------------------------------|------------------------------|
| Trace detail | Generic spans (`message.processed`) | Rich hierarchy: AGENT root → LLM child spans |
| Content capture | Span attributes only | Full inputs/outputs (user messages, assistant responses) |
| Metadata | OTel semantic conventions | Model, provider, session ID, user ID, duration |
| Storage | Tempo (optimized for span search) | MLflow (optimized for experiment comparison) |
| UI | Grafana/Tempo | MLflow native Traces tab |

Pipeline 1 provides infrastructure-level observability. Pipeline 2 provides agent-level observability with conversation content. Both are needed; neither is redundant.

**Critical**: The OTel Collector must NOT export to MLflow (`otlphttp/mlflow` exporter removed). Only the `mlflow-openclaw` plugin sends to MLflow. Otherwise each conversation produces duplicate traces — one rich (from the plugin) and one empty/null (from the collector).

### Components

| Component | Image | Version | Purpose |
|-----------|-------|---------|---------|
| Tempo | `grafana/tempo:2.7.2` | 2.7.2 | Distributed trace storage |
| OTel Collector | `otel/opentelemetry-collector-contrib:0.121.0` | 0.121.0 | OTLP receiver, span processor, metrics |
| MLflow | `ghcr.io/mlflow/mlflow:v3.10.1` | 3.10.1 | Trace UI + experiment tracking (RHOAI 3.4 GA aligned) |

### Trace schema

We follow [OpenTelemetry Semantic Conventions for Generative AI](https://opentelemetry.io/docs/specs/semconv/gen-ai/):

- `gen_ai.system`, `gen_ai.operation.name`, `gen_ai.request.model`, `gen_ai.response.model`
- `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`

MLflow plugin enriches with:
- `mlflow.spanType`: `AGENT` (root), `LLM` (model call)
- `mlflow.spanInputs` / `mlflow.spanOutputs`: Full conversation messages
- `mlflow.llm.model`, `mlflow.llm.provider`: Model routing metadata
- `mlflow.trace.session`, `mlflow.trace.user`: Session and user identity

## Implementation Details

### Problem 1: Node.js http.request() ignores HTTP_PROXY

The sandbox routes all egress through `10.200.0.1:3128`. Node.js `fetch()` (undici) respects `HTTP_PROXY` automatically, but the OTel OTLP exporter uses `http.request()` which does not.

**Solution**: A bootstrap script (`scripts/http-proxy-bootstrap.js`) monkey-patches `http.request` and `http.get` to route through the proxy. Loaded at startup via `NODE_OPTIONS="--require /tmp/http-proxy-bootstrap.js"`. The script respects `NO_PROXY` for localhost/loopback.

### Problem 2: MLflow 3.x Host header validation

MLflow 3.5+ introduced `fastapi_security` middleware that rejects requests with `Host` headers not in a whitelist, returning 403 Forbidden.

**Solution**: `--allowed-hosts` flag with all internal service names and external Route hostnames:
```
mlflow.observability.svc, mlflow.observability.svc:*,
mlflow.observability.svc.cluster.local, mlflow.observability.svc.cluster.local:*,
*.apps-crc.testing, *.apps.*.opentlc.com, localhost:*
```

### Problem 3: MLflow CORS blocking browser UI

MLflow's `--cors-allowed-origins` does not support subdomain wildcards reliably (see [MLflow #21467](https://github.com/mlflow/mlflow/issues/21467)). Using `https://*.apps-crc.testing` results in `Blocked cross-origin request` for the UI.

**Solution**: Use exact origin in `--cors-allowed-origins`. The `mlflow.yaml.tpl` template renders the exact hostname: `https://mlflow-observability.__APPS_DOMAIN__`.

### Problem 4: MLflow artifact upload PermissionError

The `--serve-artifacts` flag (enabled by default) uses `./mlartifacts` relative to CWD as the artifact proxy destination. In a container with CWD `/` (read-only), this fails with `PermissionError: [Errno 13] Permission denied: './mlartifacts'`.

**Solution**: Add `--artifacts-destination=/mlflow/artifacts` to point the artifact proxy to the PVC-mounted directory.

### Problem 5: @mlflow/core resolveArtifactUri bug

The `@mlflow/core` JavaScript SDK's `MlflowArtifactsClient.resolveArtifactUri` uses `new URL(artifactUri)` which fails on non-standard URIs like `mlflow-artifacts:/path` and plain paths like `/mlflow/artifacts/0/traces/...`.

**Solution**: Patch `resolveArtifactUri` in `node_modules/@mlflow/core/dist/clients/artifacts/mlflow.js`:
1. Parse `mlflow-artifacts:` URIs manually (strip scheme, extract path)
2. For plain paths, strip the `/mlflow/artifacts` prefix to prevent path duplication in the API URL
3. Construct the upload URL as `${host}/api/2.0/mlflow-artifacts/artifacts${pathname}/${fileName}`

### Problem 6: Plugin activation requires config.json entries

OpenClaw reads plugin enablement from the main `config.json` file (`OPENCLAW_CONFIG_PATH`), not the state `openclaw.json` (`OPENCLAW_STATE_DIR`). Plugins must have `plugins.entries.<id>.enabled: true` in the main config to be loaded.

**Solution**: Add `plugins.entries` section to `config/openclaw.json`:
```json
{
  "plugins": {
    "entries": {
      "diagnostics-otel": { "enabled": true },
      "mlflow-openclaw": {
        "enabled": true,
        "config": {
          "trackingUri": "http://mlflow.observability.svc:5000",
          "experimentId": "0"
        },
        "hooks": { "allowConversationAccess": true }
      }
    }
  }
}
```

The `hooks.allowConversationAccess: true` is required for `mlflow-openclaw` to intercept `llm_input`, `llm_output`, and `agent_end` events.

### Problem 7: Duplicate traces from MLFLOW_TRACKING_URI env var

Setting `MLFLOW_TRACKING_URI` as an environment variable caused auto-detection by OTel/MLflow SDKs, creating a second null trace for each conversation alongside the rich one from the plugin.

**Solution**: Remove `MLFLOW_TRACKING_URI` and `MLFLOW_EXPERIMENT_ID` from gateway environment. The `mlflow-openclaw` plugin receives its config via `plugins.entries.mlflow-openclaw.config` in `config.json`.

### Problem 8: diagnostics-otel trace flood via MLflow global span processor

When both `diagnostics-otel` and `mlflow-openclaw` plugins are loaded, the MLflow JavaScript SDK (`@mlflow/core`) registers itself as a global OpenTelemetry span processor. This causes every OTel span emitted by `diagnostics-otel` (including 185+ startup initialization spans) to be captured and sent to MLflow as empty/null traces, flooding the Traces tab.

**Solution**: Disable trace export in `diagnostics-otel` while keeping logs and metrics active. This is done at two levels:

1. **Config level** (`config.json`): `diagnostics.otel.traces: false`, `logs: true`, `metrics: true`
2. **Environment level**: `OTEL_TRACES_EXPORTER=none` prevents the OTel SDK from registering a trace exporter. `OTEL_LOGS_EXPORTER=otlp` and `OTEL_METRICS_EXPORTER=otlp` keep log/metric pipelines active.

This gives a clean signal separation:
- **Traces** → `mlflow-openclaw` only → MLflow (rich, hierarchical)
- **Logs** → `diagnostics-otel` → OTel Collector → Tempo
- **Metrics** → `diagnostics-otel` → OTel Collector → Prometheus

### Problem 9: MLflow Sessions tab empty — JS SDK stores session as span attribute, not trace tag

The `@mlflow/core` JavaScript SDK stores `mlflow.trace.session` and `mlflow.trace.user` as **span attributes** inside the `traces.json` artifact file, not as entries in the `trace_tags` database table. The MLflow UI "Sessions" tab and "Group by session" feature query `trace_tags`, so sessions appear empty even though the data exists in the artifacts.

**Verification**: The trace artifacts contain the correct data:
```json
{
  "spans": [{
    "attributes": {
      "mlflow.trace.session": "agent:main:dashboard:2f2dc0da-...",
      "mlflow.trace.user": "1000670000",
      "mlflow.spanType": "AGENT"
    }
  }]
}
```

But `SELECT * FROM trace_tags` only contains `mlflow.artifactLocation`.

**Root cause**: The Python MLflow SDK writes session/user to both `trace_tags` (DB) and span attributes. The JavaScript SDK (`@mlflow/core` v0.2.0-rc.0) only writes to span attributes via the artifact upload (`PUT /api/2.0/mlflow-artifacts/artifacts/.../traces.json`). The `POST /api/3.0/mlflow/traces` request that creates the DB record does not include these tags.

**Current status**: Accepted limitation. The trace data with session and user identity IS captured and persisted (in artifacts), but the MLflow UI cannot group or filter by session. This can be resolved when:
1. The `@mlflow/core` JS SDK adds `trace_tags` support in a future version
2. A post-flush hook patches `trace_tags` via `POST /api/2.0/mlflow/traces/{id}/tags`
3. Migration to the Python MLflow SDK (e.g., via a sidecar bridge)

### Network policy

The sandbox policy allows egress to both observability endpoints:
```yaml
network_policies:
  observability:
    endpoints:
      - host: "otel-collector.observability.svc"
        port: 4318           # OTel Collector (Pipeline 1)
  mlflow_direct:
    endpoints:
      - host: "mlflow.observability.svc"
        port: 5000           # MLflow API (Pipeline 2)
```

### Gateway environment variables

Required (diagnostics-otel logs/metrics + proxy bootstrap):
```
OTEL_SERVICE_NAME=openclaw-agent
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_EXPORTER=none          # Prevent OTel trace export (Problem 8)
OTEL_LOGS_EXPORTER=otlp            # Logs via OTel Collector
OTEL_METRICS_EXPORTER=otlp         # Metrics via OTel Collector
NODE_OPTIONS="--require /tmp/http-proxy-bootstrap.js"
```

NOT required (mlflow-openclaw gets config from config.json):
```
# Do NOT set — causes duplicate traces (Problem 7):
# MLFLOW_TRACKING_URI
# MLFLOW_EXPERIMENT_ID
#
# Do NOT set — replaced by per-signal exporters above:
# OPENCLAW_DIAGNOSTICS="*"
# OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental
```

## Alternatives Considered

1. **Red Hat OTel/Tempo operators via OLM**: Preferred for production but blocked by registry.redhat.io 503 errors. Migration path preserved.

2. **diagnostics-otel only (no mlflow-openclaw)**: Produces only generic `message.processed` spans without conversation content, model details, or hierarchical agent/LLM structure. Insufficient for agent-level observability.

3. **OTel Collector exporting to both Tempo and MLflow**: Creates duplicate traces — one rich from the plugin, one empty from the collector. Removed the `otlphttp/mlflow` exporter to eliminate duplication.

4. **RHOAI MLflow CR**: Requires RHOAI operator, too heavy for this deployment.

## Consequences

### Positive
- Rich hierarchical traces visible in MLflow: AGENT → LLM spans with full I/O
- Infrastructure traces in Tempo with standard OTel semantics
- Prometheus metrics derived from spans via spanmetrics connector
- No operator dependency = simpler lifecycle
- Single trace per conversation (no duplicates)

### Negative
- `http-proxy-bootstrap.js` is a monkey-patch; breaks if Node.js changes `http.request` internals
- `@mlflow/core` artifact URI patch must be reapplied after plugin updates
- Plugin activation requires manual `config.json` entries (not auto-discovered)
- MLflow with SQLite + local PVC is not production-grade (needs S3/GCS for durability)
- Standalone Tempo local backend also not production-grade
- MLflow "Sessions" tab is empty because the JS SDK does not write `mlflow.trace.session` to `trace_tags` (Problem 9). Session data IS captured in span artifacts but not queryable from the UI.
- `OTEL_TRACES_EXPORTER=none` means no infrastructure-level traces in Tempo — only logs/metrics. Agent traces go exclusively to MLflow via the plugin.

## Migration Path

When registry.redhat.io recovers:
1. Install Red Hat OTel and Tempo operators
2. Replace standalone Tempo with `TempoMonolithic` CR
3. Replace standalone OTel Collector with `OpenTelemetryCollector` CR
4. Keep MLflow standalone (or migrate to RHOAI MLflow CR if RHOAI is deployed)
5. The `mlflow-openclaw` plugin and `http-proxy-bootstrap.js` remain unchanged

## References
- [MLflow Tracing Docs](https://mlflow.org/docs/latest/llms/tracing/index.html)
- [MLflow CORS Issue #21467](https://github.com/mlflow/mlflow/issues/21467)
- [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [OpenClaw diagnostics-otel plugin](https://docs.openclaw.ai/gateway/diagnostics)
- [agent-harness-in-a-box](https://github.com/rcarrata/agent-harness-in-a-box) (commit 76aca3b)
- ADR-0007: OpenClaw Inside Sandbox
- ADR-0008: Deployment Findings

# Informe: Trazas duplicadas en MLflow

**Proyecto**: open-claw-in-openshell
**Fecha**: 19 julio 2026

---

## Resumen

Al enviar un mensaje desde la Control UI (webchat), MLflow registra **dos trazas independientes** de la misma interaccion. Cada una proviene de una capa de instrumentacion distinta. No hay correlacion entre ellas.

| Metrica | Valor |
|---|---|
| Trazas por interaccion | 2 (deberia ser 1) |
| Correlacion entre trazas | Ninguna |

---

## Trazas observadas

Mensaje de prueba: `"hola"` → `"¡Hola! ¿En que te puedo ayudar?"`

| | Traza 1 — OTel (diagnostics-otel) | Traza 2 — MLflow GenAI (mlflow-openclaw) |
|---|---|---|
| **Trace ID** | `tr-b8ba9ebcebb3f27eb...ccb7d6` | `tr-6ac5492545fed4f0...6656b` |
| **Latencia** | 3.59s | 2.99s |
| **Spans** | `openclaw.message.processed` → `openclaw.harness.run` → `openclaw.run` → `openclaw.context.assembled` + `openclaw.model.call` | `openclaw_agent` → `llm_call` |
| **Datos capturados** | Atributos operacionales: channel, source, outcome | Chat completo: system prompt, user msg, assistant response, modelo, tooling |
| **Modelo** | No visible | `claude-sonnet-4-6` |
| **Contenido del chat** | No capturado | User: "hola" → Assistant: "¡Hola! ¿En que te puedo ayudar?" |

---

## Causa raiz

ADR-0014 establece una arquitectura dual-pipeline:

### Pipeline 1: diagnostics-otel → OTel Collector
```
OpenClaw diagnostics-otel plugin
  → http.request() → http-proxy-bootstrap.js → sandbox HTTP proxy
    → OTel Collector (4318) → Tempo + spanmetrics → Prometheus
```

**Estado actual**: `OTEL_TRACES_EXPORTER=none` y `diagnostics.otel.traces: false` estan configurados. Sin embargo, el plugin diagnostics-otel SIGUE generando spans internos que MLflow captura.

### Pipeline 2: mlflow-openclaw → MLflow API
```
OpenClaw mlflow-openclaw plugin hooks (llm_input, llm_output, agent_end)
  → fetch() → sandbox HTTP proxy
    → MLflow API (5000)
```

**Estado actual**: Genera trazas ricas con contenido completo del chat, modelo, herramientas. Esta es la traza "buena" con la jerarquia `openclaw_agent` → `llm_call`.

### Por que ocurre

Aunque `OTEL_TRACES_EXPORTER=none` y `traces: false` estan configurados, el SDK `@mlflow/core` se registra como **span processor global de OpenTelemetry** al cargarse. Esto captura los spans internos de `diagnostics-otel` y los envia a MLflow como una segunda traza con estructura diferente (`openclaw.message.processed` en vez de `openclaw_agent`). El resultado son dos trazas en MLflow por cada interaccion, sin vinculo entre ellas.

---

## Estado del prompt-trace-linker.js

El linker actual (`scripts/prompt-trace-linker.js`) resuelve un problema **diferente** al de la duplicacion. Su alcance y brechas:

| Aspecto | Estado actual | Brecha |
|---|---|---|
| Funcion | Taggea trazas con versiones de prompts activos | No correlaciona trazas entre pipelines |
| Mecanismo | Polling cada 30s → busca trazas sin tag `prompt_versions` → PATCH tag | Solo opera sobre trazas MLflow GenAI, ignora trazas OTel duplicadas |
| Tag aplicado | `prompt_versions={"AGENTS":5,"SOUL":3,...}` | Se aplica a ambas trazas por igual (no distingue cual es la rica) |
| Correlacion | No implementada | No hay campo compartido (trace ID, span ID, timestamp) entre las dos trazas |
| Deduplicacion | No implementada | No suprime ni marca la traza OTel redundante |

---

## Opciones de resolucion

### Opcion A — Eliminar trazas OTel de MLflow en origen (RECOMENDADA)

Desactivar completamente `diagnostics-otel` o asegurar que su inicializacion del tracer OpenTelemetry ocurra ANTES de que `mlflow-openclaw` registre su span processor global. Si diagnostics-otel no genera spans (`traces: false` ya esta en config), investigar por que MLflow aun los captura — puede ser que el SDK de MLflow use `opentelemetry-api` directamente.

**Complejidad**: Baja. Requiere investigar el orden de carga de plugins y posiblemente ajustar la config de diagnostics-otel para no inicializar el TracerProvider cuando `traces: false`.

### Opcion B — Deduplicar en el linker

Extender `prompt-trace-linker.js` para detectar pares de trazas duplicadas (misma ventana temporal, ~0.5s) y: (1) copiar la tag `prompt_versions` solo a la traza rica, (2) marcar la traza OTel con un tag `duplicate=true` o suprimirla via la API de MLflow.

**Complejidad**: Media. Requiere heuristica temporal para emparejar trazas. Fragil si la latencia varia mucho.

### Opcion C — Propagar trace context entre pipelines

Inyectar el W3C `traceparent` del span OTel como atributo en la traza MLflow, creando un link explicito. Ambas trazas se mantienen pero son navegables como una unidad.

**Complejidad**: Alta. Requiere modificar `mlflow-openclaw` o un hook intermedio para acceder al contexto OTel activo. Depende de APIs internas de OpenClaw.

---

## Configuracion actual relevante

### config/openclaw.json

| Clave | Valor |
|---|---|
| `diagnostics.otel.traces` | `false` |
| `diagnostics.otel.metrics` | `true` |
| `diagnostics.otel.logs` | `true` |
| `plugins.diagnostics-otel.enabled` | `true` |
| `plugins.mlflow-openclaw.enabled` | `true` |
| `plugins.mlflow-openclaw.config.trackingUri` | `http://mlflow.observability.svc:5000` |

### Variables de entorno (sandbox)

| Variable | Valor |
|---|---|
| `OTEL_TRACES_EXPORTER` | `none` |
| `OTEL_LOGS_EXPORTER` | `otlp` |
| `OTEL_METRICS_EXPORTER` | `otlp` |
| `OTEL_SERVICE_NAME` | `openclaw-agent` |
| `MLFLOW_TRACKING_URI` | NO SET (intencionalmente — ver ADR-0014 Problema 7) |
| `MLFLOW_EXPERIMENT_ID` | NO SET (intencionalmente) |

---

## Siguiente paso

Investigar por que el SDK `@mlflow/core` captura spans OTel a pesar de `OTEL_TRACES_EXPORTER=none`. Si se confirma que es el global span processor, la solucion es desregistrarlo despues de la inicializacion de `mlflow-openclaw` o desactivar `diagnostics-otel` por completo (ya que solo aporta logs/metricas, no trazas).

---

## Referencias

- ADR-0014: Agent Observability — Dual-Pipeline Tracing (`docs/adrs/ADR-0014-agent-observability.md`)
- ADR-0015: System Prompts via MLflow Prompt Registry (`docs/adrs/ADR-0015-mlflow-prompt-registry.md`)
- Trace linker: `scripts/prompt-trace-linker.js`
- Config: `config/openclaw.json`
- Evidencia: capturas de pantalla de MLflow UI en `https://mlflow-observability.apps-crc.testing`

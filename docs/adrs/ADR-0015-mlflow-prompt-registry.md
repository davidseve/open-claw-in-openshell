# ADR-0015: System Prompts via MLflow Prompt Registry

## Status
**Backend superseded by [ADR-0018](ADR-0018-rhoai-mlflow-sole-backend.md)**:
the standalone MLflow deployment this ADR was written against (`observability`
namespace, plain HTTP, no auth) was fully removed and replaced by
RHOAI-managed MLflow. The mechanism/design described below — Prompt Registry
API, `@production` alias, versioned fetch into the sandbox, read-only
lockdown, trace-tag linking — is **unchanged and still Accepted**; only the
tracking URI and the addition of Bearer token + `X-MLFLOW-WORKSPACE` auth
changed. All the code implementing this ADR now lives together in
`scripts/prompt-registry/` (`seed-mlflow-prompts.sh`,
`fetch-prompts-from-mlflow.sh`, `prompt-trace-linker.js`) with its own
`README.md` explaining what it does and how to remove it entirely if this
subsystem is ever judged not worth its operational cost — see that README
before touching any of the paths mentioned below, they've moved. Kept as-is
below for historical record of the original design rationale — do not edit
the content past this point.

## Context

OpenClaw uses workspace bootstrap files (`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`) as system prompt context injected into every agent conversation. By default these are auto-seeded from built-in templates embedded in the OpenClaw Docker image.

This deployment needs:
- **Operator-controlled prompts**: operators define agent behavior, not upstream defaults.
- **Immutable prompts**: the agent must not modify its own system instructions.
- **Versioning and rollback**: prompt changes tracked with full history.
- **Traceability**: each conversation trace must record which prompt versions were active.
- **No code deploys for prompt changes**: decouple prompt iteration from sandbox lifecycle.

MLflow v3.10.1 is already deployed in the `observability` namespace (ADR-0014), accessible from the sandbox via the `mlflow_direct` network policy.

### Community validation

Prompt versioning is a recognized production pattern for LLM agents. MLflow positions its Prompt Registry as a core tool for this use case:

> "A prompt registry lets you version and test system prompt changes without redeploying your agent, then roll back if quality degrades." — [mlflow.org/prompt-registry](https://mlflow.org/prompt-registry/)

The pattern recommends: prompts as immutable versioned artifacts, production aliases (never `@latest`), rollback by alias repoint, and per-trace version tracking.

## Decision

Store operator-defined system prompts in MLflow's Prompt Registry and fetch them into the sandbox at launch time. The agent cannot modify these files.

### Prompt lifecycle

```
Operator edits prompts/*.md
  → scripts/seed-mlflow-prompts.sh registers in MLflow with @production alias
  → scripts/launch-openclaw.sh fetches @production versions into sandbox
  → Files written to /sandbox/workspace/*.md (root:root, chmod 444)
  → OpenClaw loads them as system prompt context
```

### Naming convention

Each prompt is registered via `mlflow.genai.register_prompt()` (Python SDK) which creates a registered model with internal metadata tags. The content lives in the `mlflow.prompt.text` tag of each model version. Names use `.` as separator (MLflow rejects `/` in prompt names).

| File | MLflow prompt name |
|---|---|
| `AGENTS.md` | `openclaw-system.AGENTS` |
| `SOUL.md` | `openclaw-system.SOUL` |
| `TOOLS.md` | `openclaw-system.TOOLS` |
| `IDENTITY.md` | `openclaw-system.IDENTITY` |
| `USER.md` | `openclaw-system.USER` |
| `HEARTBEAT.md` | `openclaw-system.HEARTBEAT` |
| `BOOTSTRAP.md` | `openclaw-system.BOOTSTRAP` |

`MEMORY.md` is excluded: it is agent-managed long-term memory, not an operator-controlled system prompt.

### Immutability enforcement (best-effort)

Files are written with `chmod 444` to signal read-only intent. OpenClaw's `writeFileIfMissing()` uses flag `wx` (write-only-if-absent), so it skips existing files.

**Known limitation**: `chmod 444` is not sufficient for true immutability in the sandbox. The agent runs as `sandbox` (uid 1000), which is also the owner of the workspace directory `/sandbox/workspace/`. Unix semantics allow a directory owner to `unlink` files regardless of file permissions. A jailbroken agent could `rm IDENTITY.md && echo "new content" > IDENTITY.md` to replace prompt files. This was confirmed as a real bypass vector (ref: OpenClaw issue #36190 — `bootstrapFreezeMode` proposal).

The `chmod 444` protection is defense-in-depth against accidental writes and well-behaved agents. True immutability would require one of:
- OpenClaw `bootstrapFreezeMode` (proposed upstream, not yet available)
- Mounting prompt files from a read-only volume (ConfigMap or PVC with `readOnly: true`)
- Landlock enforcement on individual workspace files (not currently supported by OpenShell)

This is accepted as a known constraint documented in `docs/constraints.md`.

### Traceability (3 layers)

**Layer 1 — Embedded metadata (per-trace via content)**

Each downloaded file includes a metadata header:
```markdown
<!-- mlflow-prompt: openclaw-system.SOUL version:3 alias:production fetched:2026-07-19T09:50:00Z -->
```

Since `mlflow-openclaw` captures full system prompt content in `mlflow.spanInputs`, this metadata appears in every trace. Searchable via `trace.text LIKE "%version:3%"`.

**Layer 2 — Experiment tags (per-deployment)**

The fetch script tags the MLflow experiment with active versions:
```
prompt.AGENTS.version = "5"
prompt.SOUL.version = "3"
```

Visible in the MLflow experiment dashboard.

**Layer 3 — Native prompt-trace linking (per-trace via sidecar)**

A Node.js sidecar (`prompt-trace-linker.js`) polls MLflow every 30 seconds for unlinked traces and:
1. Sets the `mlflow.linkedPrompts` tag with `[{"name":"openclaw-system.AGENTS","version":"3"}, ...]` — this is the standard MLflow mechanism that populates the **Prompt** column in the Traces UI with clickable links to each prompt version.
2. Calls `POST /api/2.0/mlflow/traces/link-prompts` to create entity associations in the MLflow link table.

This enables: exact search via `prompt = "openclaw-system.SOUL/3"`, visual prompt drill-down in the Traces UI, and impact analysis in the Prompt Registry (which prompts were used by which traces).

### Chat Sessions and multi-turn evaluation

The `mlflow-openclaw` plugin already sets `mlflow.trace.session` and `mlflow.trace.user` metadata on traces (since v3.12). Combined with prompt version tags, this enables:

- **Per-session quality analysis**: "Did conversations using SOUL v3 have better `ConversationCompleteness` than v2?"
- **Multi-turn evaluation**: MLflow 3.10+ scorers (`ConversationCompleteness`, `UserFrustration`) can evaluate full conversation sessions grouped by prompt version.
- **A/B testing**: Deploy different prompt versions with different aliases, compare session quality metrics.

This is a future capability enabled by the prompt versioning infrastructure, not implemented in this phase.

### Network policy

No changes required. The existing `mlflow_direct` policy (ADR-0014) allows sandbox egress to `mlflow.observability.svc:5000`. Both `curl` and `node` are in the permitted binary list.

## Alternatives Considered

1. **ConfigMap-mounted prompts**: Kubernetes-native but requires pod restart for changes. No built-in versioning, no UI for non-technical editors, no trace linkage.

2. **Custom sandbox image (Phase 10)**: Pre-bake prompts into the Docker image. Requires image rebuild for every prompt change. No versioning beyond image tags.

3. **`oc cp` from repo files**: Simple file copy at launch. No versioning, no rollback, no UI editor, no traceability.

4. **Git-based prompt registry**: Store prompts in a separate git repo, fetch at launch. Good versioning but no UI for non-technical editors, no native trace linkage, requires git access from sandbox.

MLflow Prompt Registry was chosen because it is already deployed, provides a UI for editing, supports versioning with aliases, and enables native trace-prompt linkage.

## Consequences

### Positive
- Operators control agent behavior without code changes or image rebuilds
- Full version history with rollback via alias repointing
- Non-technical users can edit prompts via MLflow UI
- Every trace records which prompt versions were active (3-layer traceability)
- Agent modification of system instructions is hindered by file permissions (best-effort; see "Immutability enforcement" caveat)
- Foundation for future A/B testing and multi-turn evaluation by prompt version

### Negative
- MLflow must be available at sandbox launch; if down, OpenClaw falls back to built-in templates
- Prompt text stored in model-version tags has size limits (~5000 chars); very large prompts may need artifact storage instead
- Sidecar adds a background process; if it fails, Layer 1 and 2 traceability still work
- The `link-prompts` API is `PUBLIC_UNDOCUMENTED` in MLflow 3.10; may change in future versions
- Prompt registration uses `mlflow.genai.register_prompt()` (Python SDK); the REST API uses the registered-models surface internally

## Components

| Component | Path | Purpose |
|---|---|---|
| Prompt source files | `prompts/*.md` | Operator-maintained prompt templates |
| Seed script | `scripts/seed-mlflow-prompts.sh` | Register prompts in MLflow with @production alias |
| Fetch script | `scripts/fetch-prompts-from-mlflow.sh` | Download prompts into sandbox workspace |
| Trace linker | `scripts/prompt-trace-linker.js` | Link MLflow prompts to traces (Prompt column + link table) |
| Launch integration | `scripts/launch-openclaw.sh` | Fetch + protect + sidecar launch |
| Deploy integration | `scripts/deploy-observability.sh` | Initial seed after MLflow deploy |

## References
- [MLflow Prompt Registry](https://mlflow.org/docs/latest/genai/prompt-registry/)
- [MLflow Use Prompts in Apps](https://mlflow.org/docs/latest/genai/prompt-registry/use-prompts-in-apps/) — automatic prompt-trace linking
- [MLflow Search Traces by Prompt](https://mlflow.org/docs/latest/genai/tracing/search-traces/) — `prompt = "name/version"` filter
- [MLflow Track Users & Sessions](https://mlflow.org/docs/latest/genai/tracing/track-users-sessions/)
- [MLflow Multi-turn Evaluation](https://mlflow.org/docs/latest/genai/eval-monitor/running-evaluation/multi-turn/)
- [Prompt Versioning Pattern](https://github.com/agentpatternscatalog/patterns/blob/main/patterns/prompt-versioning.md)
- ADR-0014: Agent Observability (MLflow deployment, network policy)

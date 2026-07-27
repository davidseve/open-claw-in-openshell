# Prompt Registry / Trace Linking Subsystem

This directory is the **single, self-contained home** for everything that
implements "system prompts versioned in MLflow, with traces tagged by the
prompt version that produced them" ([ADR-0015](../../docs/adrs/ADR-0015-mlflow-prompt-registry.md)).
It was consolidated here from a previously scattered layout (files directly
under `scripts/`, plus logic spread across `launch-openclaw.sh`, `verify.sh`,
and the `monitor-deployment` skill) specifically so that **this whole
subsystem can be found, understood, and — if a future you decides it's not
worth its operational cost — removed in one pass**.

That's a real, live option: this is a meaningful amount of extra moving
parts (a second live process in the sandbox, a second log file, extra
`verify.sh` checks, extra auto-repair rules) to answer a narrow question
("which prompt version produced this trace?") that has a much simpler
fallback — tag every trace with `PROMPT_GIT_SHA=$(git rev-parse --short HEAD)`
at launch time instead. Keep reading if you want to remove it.

## What's in here

| File | Runs where | What it does |
|------|-----------|---------------|
| `seed-mlflow-prompts.sh` | On your machine, invoked by `wire-rhoai-mlflow-tracing.sh` | Registers `prompts/*.md` in the RHOAI MLflow Prompt Registry (`mlflow.genai.register_prompt()`) and points a `@production` alias at the latest version. |
| `fetch-prompts-from-mlflow.sh` | Inside the sandbox, invoked by `launch-openclaw.sh` (`oc cp` + `oc exec`) | Downloads the `@production`-aliased prompts from MLflow into `/sandbox/workspace/*.md`, writes a `.prompt-versions.json` manifest recording which MLflow version of each prompt is in use. |
| `prompt-trace-linker.js` | Inside the sandbox, as a long-running background process, invoked by `launch-openclaw.sh` | Polls the MLflow Traces API every 30s via `/usr/bin/curl` (Node `fetch()` is blocked by the sandbox proxy — see `docs/constraints.md` #14), finds traces missing prompt-version tags, and adds an `mlflow.linkedPrompts` tag + a `prompt_versions` custom tag using the manifest from `fetch-prompts-from-mlflow.sh`. |

## How it's wired in (every touchpoint outside this directory)

- `scripts/wire-rhoai-mlflow-tracing.sh` calls `seed-mlflow-prompts.sh` once, after the RHOAI MLflow experiment/RBAC/SA-token wiring is in place.
- `scripts/launch-openclaw.sh` Step 4 copies `fetch-prompts-from-mlflow.sh` into the sandbox and runs it, then locks the fetched prompt files read-only (`chown 0:0` + `chmod 444`).
- `scripts/launch-openclaw.sh` Step 5 copies `prompt-trace-linker.js` into the sandbox and starts it with `nohup node ... &`, logging to `/sandbox/workspace/linker.log`.
- `scripts/verify.sh` Layer 8b checks: prompts registered in MLflow, `@production` aliases set, the `.prompt-versions.json` manifest exists, prompt files are read-only, the linker process is running, and recent traces carry the `mlflow.linkedPrompts`/`prompt_versions` tags.
- `.cursor/skills/monitor-deployment/SKILL.md` has an auto-repair row for `Prompt trace linker not running` (re-runs `launch-openclaw.sh`, which restarts the linker with fresh auth env vars).
- `policies/openclaw-sandbox.yaml`'s `mlflow_direct` egress policy entry (`mlflow.<ns>.svc`, `tls: skip`) is shared with the core `mlflow-openclaw` tracing plugin — **do not remove it** even if you remove this subsystem, tracing itself still needs it.

## How to remove this subsystem entirely

If you decide the "which prompt version produced this trace" feature isn't
worth it, here's the complete list of edits to fully remove it:

1. Delete this directory (`scripts/prompt-registry/`).
2. In `scripts/wire-rhoai-mlflow-tracing.sh`: delete the block that calls `seed-mlflow-prompts.sh`.
3. In `scripts/launch-openclaw.sh`: delete Step 4 (fetch) and Step 5 (linker sidecar). Replace prompt delivery with a plain `oc cp` of `prompts/*.md` into the sandbox workspace (no MLflow round-trip, no read-only lockdown needed unless you want it for its own sake).
4. In `scripts/verify.sh`: delete the "Layer 8b: MLflow Prompt Registry" section.
5. In `.cursor/skills/monitor-deployment/SKILL.md`: delete the `Prompt trace linker not running` auto-repair row and any other mentions of the linker/prompt registry.
6. Leave `policies/openclaw-sandbox.yaml`'s `mlflow_direct` entry in place — the core `mlflow-openclaw` tracing plugin still needs it.
7. Optionally, replace the lost "which prompt produced this trace" signal with something much cheaper: tag every trace at launch with `PROMPT_GIT_SHA=$(git rev-parse --short HEAD)` (one env var, no extra process).
8. Mark [ADR-0015](../../docs/adrs/ADR-0015-mlflow-prompt-registry.md) as superseded, pointing at whatever replaces it (or at "removed, see git history" if nothing does).

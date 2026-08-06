---
name: document-feature
description: >-
  Document new or modified project functionality: guides, scripts, skills,
  ROADMAP.md, AGENTS.md, and README.md cross-links. Use when adding, modifying,
  or validating a component (e.g. OpenShell, OpenClaw, RHOAI/MLflow, oauth-proxy,
  Keycloak), integration, deploy path, version pin, installer script, Helm
  chart, or Cursor skill — or when the user asks to document a feature.
  Mandatory when the technology-usage-docs rule applies.
---

# Document Feature

After implementing, modifying, or validating functionality, **update project documentation in the same session**. Do not wait for the user to ask unless they explicitly said not to document.

> **Note**: When the `technology-usage-docs` rule fires (any stack technology added or modified), running this skill is **mandatory**, not optional.

## When to run

| Trigger | Example |
|---|---|
| New platform component validated on cluster | RHOAI-managed MLflow, oauth-proxy OIDC path |
| Existing component version or config changed | OpenShell chart version bump, new Helm values, operator CSV update |
| Prerequisites or deploy path modified | New script, Makefile/`crc-lifecycle.sh` target, values file restructure |
| Verify or troubleshoot steps updated | New `verify.sh` health check, validated error workaround (candidate for `docs/constraints.md`) |
| New script or installer added | `scripts/deploy-oauth2-proxy.sh` |
| New Cursor skill added | e.g. a new `openshell-*` or `mlflow-*` skill |
| Deploy manifests or Helm values added | `charts/openshell/`, `charts/rhoai/openclaw-integration/` |
| Architecture or integration decision made | Wrapper chart, coexistence strategy, auth mode change |

## Workflow

Copy this checklist and complete every applicable item:

```
Documentation progress:
- [ ] 0. Check Accepted ADRs in docs/adrs/ — ensure the feature aligns (see adr-alignment rule)
- [ ] 1. Identify feature type and target doc location
- [ ] 2. Write or extend the primary guide (README.md / ROADMAP.md phase / docs/constraints.md)
- [ ] 3. Cross-link README.md, AGENTS.md, ROADMAP.md
- [ ] 4. Update existing skills or add new ones for repeatable workflows
- [ ] 5. Cite upstream official docs (verify, do not guess)
- [ ] 6. Record validated versions and constraints
- [ ] 7. Update ADR (Addendum) or create one via the adr skill if architectural
```

### Step 1 — Choose where to document

| Feature kind | Primary location | Also update |
|---|---|---|
| Install / deploy procedure or phase | `ROADMAP.md` phase (add tasks, mark `[x]` when validated) | `scripts/`, `charts/` |
| Architecture decision | `docs/adrs/ADR-NNNN-slug.md` (use `adr` skill) | `README.md` ADR index |
| Known limitation / non-obvious fix | `docs/constraints.md` (numbered entry) | referencing script comments |
| Agent-operable workflow | `.cursor/skills/<name>/SKILL.md` | `README.md` `.cursor/skills/` row |
| Version manifest | `ROADMAP.md` "Pinned Versions" table | `AGENTS.md` if it affects security baseline |

### Step 2 — Primary content

Every substantial addition should cover, wherever applicable:

1. **Overview** — role in the OpenShell/OpenClaw stack (link to `README.md` architecture section)
2. **Prerequisites** — cluster, tools, upstream dependencies
3. **Install / deploy** — copy-paste commands that were **validated**
4. **Verify** — health checks, expected output (wire into `scripts/verify.sh` when it's a repeatable check)
5. **Troubleshooting** — real errors encountered (symptom → cause → fix), recorded as a `docs/constraints.md` entry when non-obvious
6. **References** — upstream docs URLs (NVIDIA OpenShell / OpenClaw / Red Hat first, per project rules)

**Language**: all committed `.md` files in English.

**Version pinning**: record exact chart, operator CSV, or image tags tested in `ROADMAP.md`'s "Pinned Versions" table.

### Step 3 — Cross-links (required)

| File | What to add |
|---|---|
| `README.md` | ADR index entry (if applicable); `.cursor/skills/` row (if new skill); component table row (if new chart/dir) |
| `AGENTS.md` | Security Guidelines or role Responsibilities (if the change affects the security baseline or a role's scope) |
| `ROADMAP.md` | Mark completed validation tasks `[x]` with a short note; add new tasks under the relevant phase (or a new phase) |

Keep `AGENTS.md` and `README.md` **short** — link to `ROADMAP.md`/`docs/`, do not duplicate procedures.

### Step 4 — Skills (create or update)

**Update existing skills** that describe the changed workflow. Search `.cursor/skills/` for skills whose commands, versions, chart values, or script names changed in this session (`deploy-full`, `crc-local-dev`, `monitor-deployment`, etc.). Update them to match the new process.

**Create a new skill** when the workflow is:

- Repeated by users or agents (install, cleanup, bootstrap, health-check)
- Multi-step with project-specific conventions

Skill location: `.cursor/skills/<name>/SKILL.md`.

Register in `README.md`'s `.cursor/skills/` row.

### Step 5 — Official sources

Per `.cursor/rules/documentation-sources.mdc`:

1. Verify against NVIDIA OpenShell/OpenClaw docs or Red Hat/OpenShift docs (`WebFetch`, KB)
2. Cite the source in the guide's References section
3. Document **deltas** for this project's specific setup only — do not copy entire upstream manuals

### Step 6 — Constraints from AGENTS.md

- No secrets in repo (see `no-secrets` rule/skill)
- Declarative first: prefer Helm templates/hooks over imperative `oc`/`kubectl` steps in scripts (see `adr-alignment` rule)
- Idempotent: document uninstall/teardown when install is documented (`scripts/teardown.sh`)

## Do not

- Create standalone docs the user did not need (no drive-by markdown)
- Leave `ROADMAP.md` tasks unchecked after validation
- Document from training data without verifying versions and CRD/schema fields
- Put long install procedures only in chat — they belong in `ROADMAP.md`/`docs/`
- Leave existing skills referencing deprecated commands, removed scripts, or old versions

## Additional resources

- ADR-style decisions: use the `adr` skill — creates `docs/adrs/ADR-NNNN-slug.md` and updates the index in `README.md`
- Secret scanning before any git write: use the `no-secrets` skill

---
name: adr
description: "Create a new Architecture Decision Record (ADR). Documents context, options considered, and rationale. Updates the ADR index in README.md."
---

# Create ADR

Create a new Architecture Decision Record in `docs/adrs/`.

## Process

### 1. Determine Next ADR Number

Check `docs/adrs/` for the highest existing `ADR-NNNN-*.md` number (e.g. `ls docs/adrs/ | sort`). The next number is highest + 1, zero-padded to 4 digits.

### 2. Gather Decision Details

If the user provided a topic, use that as context. Otherwise ask:

> **What architectural decision do you need to document?**
> **What context or constraints led to this decision? What options did you consider?**

### 3. Write the ADR

Create `docs/adrs/ADR-NNNN-<kebab-case-title>.md`:

```markdown
# ADR-NNNN: <Title>

## Status
<Proposed | Accepted | Deprecated | Superseded by ADR-XXXX>

## Context
What problem or constraint motivated this decision? Include links to official
Red Hat/NVIDIA/upstream docs (per the documentation-sources rule) and to any
constraint in docs/constraints.md this decision addresses.

## Decision
What we chose and the primary rationale.

## Consequences
- Positive and negative effects, called out plainly.
- Risks and mitigations, if any.

## Related Decisions
- [ADR-XXXX: ...](./ADR-XXXX-slug.md)
- Supersedes / superseded by: ADR-YYYY (if applicable)
```

This repo's existing ADRs don't use a rigid Options-Considered/Version-Pinning/Demo-Impact template — keep new ones consistent with the surrounding style (see `ADR-0006`, `ADR-0018`, `ADR-0019` for recent examples), favoring a clear Context/Decision/Consequences narrative over filling in sections that don't apply.

**Amending an existing decision without reversing it**: add an `## Addendum (YYYY-MM-DD): <short title>` section at the end of the existing ADR instead of creating a new one (see ADR-0006's SCC addendum) — reserve a new ADR number for decisions that weren't previously documented at all, or that reverse/replace a prior one.

All ADR content must be in **English**.

### 4. Update the ADR Index

Add the new ADR to the single-line index near the bottom of `README.md`:

```markdown
· [NNNN](docs/adrs/ADR-NNNN-slug.md) Short title (current)
```

Mark a superseded ADR's entry `(superseded)` in that same line when applicable.

### 5. Cross-link (when applicable)

- `AGENTS.md` — if the decision affects project conventions, security baseline, or the roles/skills model.
- `ROADMAP.md` — mark related tasks `[x]` with a link to the ADR.
- `docs/constraints.md` — if the decision resolves or documents a specific constraint, cross-reference it.

### 6. Confirm

```
Created: docs/adrs/ADR-NNNN-<title>.md
Decision: <one-line summary>
Status: <status>
Index updated: README.md
```

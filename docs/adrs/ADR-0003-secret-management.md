# ADR-0003: Credential Management via OpenShell Providers

## Status
Accepted

## Context
The MaaS API key must be protected throughout its lifecycle. Three options were evaluated:

- **Kubernetes Secrets**: Mount the key as a volume or environment variable via a K8s Secret manifest. Simple but risks committing secret values to git and exposes the key on the sandbox filesystem.
- **External secret managers**: Use HashiCorp Vault or External Secrets Operator (ESO) to sync secrets into the cluster. Robust but adds significant infrastructure complexity for a single credential.
- **OpenShell provider injection**: Use OpenShell's built-in provider system to inject credentials at runtime via the L7 proxy. Credentials are resolved from opaque placeholders — the real value never reaches the sandbox filesystem.

## Decision
Use OpenShell's provider system: `openshell provider create --type generic --credential LITELLM_API_KEY`. The API key is stored locally in `secrets/secrets.env` (gitignored) only for the initial `provider create` command. No Kubernetes Secret manifest containing real credential values is committed to the repository.

## Consequences
- Credentials never touch the sandbox filesystem. The L7 proxy resolves opaque placeholders to real values at request time, and child processes inside the sandbox see only the placeholders.
- Clean supply chain: no secrets in git history, no secret manifests to audit for accidental exposure.
- Tradeoff: managing credentials requires the `openshell` CLI — there is no centralized UI or API for secret rotation.
- Tradeoff: no automated secret rotation. Future improvement: integrate with Vault or ESO for lifecycle management.
- The `secrets/` directory must remain in `.gitignore` and must never be staged.

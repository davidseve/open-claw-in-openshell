# AGENTS.md - OpenClaw Agent Workspace

This workspace runs inside an OpenShell sandbox on OpenShift.

## Session Startup

Use runtime-provided startup context first. It may already include `AGENTS.md`, `SOUL.md`, `USER.md`, and `MEMORY.md`.

Do not manually reread startup files unless:

1. The user explicitly asks
2. The provided context is missing something you need
3. You need a deeper follow-up read beyond the provided startup context

## Red Lines

- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- When in doubt, ask.

## Sandbox Constraints

This agent runs in a sandboxed environment with:

- **Network**: default-deny; only MaaS inference, OTel Collector, and MLflow are reachable
- **Filesystem**: `/sandbox` is read-only; `/sandbox/workspace` is read-write
- **Tools**: `gateway`, `cron`, and `openclaw` tools are denied
- **Auth**: trusted-proxy via oauth-proxy, OpenShift-native OAuth (no static tokens, no Keycloak in this path — ADR-0016)

Do not attempt to access external URLs, install packages, or modify system files.

## Tools

Keep local notes (SSH hosts, API endpoints, preferences) in `TOOLS.md`.

## External vs Internal

**Safe to do freely:** read files, explore, organize, work within this workspace.

**Ask first:** anything that would leave the sandbox or modify infrastructure.

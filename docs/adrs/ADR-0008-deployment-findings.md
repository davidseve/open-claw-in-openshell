# ADR-0008: Deployment Findings — mTLS Is Non-Negotiable

## Status
Accepted

## Context
During the initial deployment of OpenShell + OpenClaw on OCP, we disabled TLS and the PKI init job (`pkiInitJob.enabled: false`, `server.disableTls: true`) to simplify the setup. This caused a cascade of failures that rendered core security features inoperative.

### Symptoms observed
1. **SSH relay broken**: `openshell sandbox exec` and `openshell forward` hung indefinitely. The gateway accepted the relay request but the supervisor never processed it.
2. **nftables bypass**: Processes launched via `oc exec` ran as `root`, which bypasses the nftables rules that redirect traffic through the L7 proxy. Any process running as root had unrestricted network access (e.g., `curl https://github.com` returned 200).
3. **No credential injection**: Without the proxy intercepting traffic, the `openshell:resolve:env:*` placeholder mechanism could not rewrite API keys in request bodies/headers. The MaaS API key had to be passed as a plaintext environment variable.
4. **Control UI unreachable via gateway**: `openshell service expose` failed. Workaround was a direct Kubernetes Service targeting the pod, which also didn't work because OpenClaw runs inside the sandbox's network namespace (unreachable from the pod's root netns).

### Root cause chain

```
disableTls + pkiInitJob.enabled=false
  → no mTLS certificates generated
    → CLI cannot authenticate to gateway over gRPC
      → must use oc port-forward (plaintext tunnel)
    → SSH relay cannot negotiate with supervisor
      → must use oc exec (runs as root)
        → root bypasses nftables
          → no proxy interception
            → no credential injection
            → no network policy enforcement
```

## Decision
**mTLS must remain enabled.** The PKI init job and TLS are not optional configuration — they are load-bearing security infrastructure.

### Corrections applied

| Fix | Change | Files |
|-----|--------|-------|
| Enable mTLS | Remove `pkiInitJob.enabled: false` and `server.disableTls: true`. Add Route hostname to `pkiInitJob.serverDnsNames` for SAN matching | `charts/openshell/values-ocp.yaml` |
| Passthrough Route | Change Route TLS termination from `edge` to `passthrough` so gRPC/mTLS goes end-to-end through HAProxy | `manifests/openshell-route.yaml` |
| mTLS client certs | Extract `openshell-client-tls` secret to `~/.config/openshell/gateways/ocp/mtls/` and register gateway with `--local` flag | CLI setup procedure |
| Credential injection | Change `apiKey` from `${LITELLM_API_KEY}` to `openshell:resolve:env:LITELLM_API_KEY` and enable `request_body_credential_rewrite` on MaaS endpoint | `config/openclaw.json`, `policies/openclaw-sandbox.yaml` |
| Control UI access | Use `openshell service expose` + `openshell forward service` instead of direct K8s Service (sandbox runs in separate netns) | `manifests/openclaw-service-route.yaml` (docs) |
| OpenClaw auth | Set `auth.mode: trusted-proxy` + `bind: loopback` + `tools.deny` for control-plane tools. Browser access via OIDC ([ADR-0012](ADR-0012-trusted-proxy-auth.md)) | `config/openclaw.json` |
| LiteLLM `store` param | Add `compat.supportsStore: false` to model definition to prevent OpenClaw from sending OpenAI-specific `store` parameter that LiteLLM rejects | `config/openclaw.json` |

### Verification results

| Check | Result |
|-------|--------|
| `openshell status` | Connected via mTLS to gateway Route |
| `openshell sandbox connect` + `whoami` | Returns `sandbox` (correct user identity) |
| `curl https://github.com` from sandbox user | 403 Forbidden (proxy blocks, policy enforced) |
| `curl MaaS/v1/chat/completions` from sandbox user | Reaches MaaS, credential injected by proxy |
| `openshell forward service` | Tunnels port 18789 to local machine |
| `openshell service expose` | Registers sandbox service with gateway |
| Control UI via oauth2-proxy OIDC | Connects (Keycloak login), Health OK |
| Chat completion end-to-end | Message sent from UI, reaches MaaS via proxy with credential injection |

### OpenClaw auth: `auth.mode=trusted-proxy` (revised from `none`, then `token`)

~~The original deployment used `auth.mode: none` + `bind: loopback`, arguing that the 5 enclosing security layers made OpenClaw auth redundant.~~ **This was wrong.** See the "CRITICAL: Agent config.patch vulnerability" section below.

The intermediate fix was `auth.mode: token` with a static shared secret. **This was subsequently superseded by `auth.mode: trusted-proxy`** (see [ADR-0012](ADR-0012-trusted-proxy-auth.md)) because:
- The token was a shared static secret with no per-user identity or revocation
- oauth2-proxy could not inject the token into WebSocket connections, making OIDC and token auth mutually exclusive
- The `config.patch` vulnerability is mitigated by `tools.deny` + Landlock, not by the owner/non-owner distinction

**Current resolution**: `auth.mode: trusted-proxy` trusts connections from loopback (`127.0.0.1`, `::1`) and reads user identity from the `x-forwarded-user` header set by oauth2-proxy. Browser access is via Keycloak OIDC through oauth2-proxy — no token needed.

### OpenClaw `store` parameter fix

OpenClaw sends `store: false` by default in chat completion requests (an OpenAI-specific parameter). LiteLLM/MaaS rejects it with `Extra inputs are not permitted`.

**Fix**: Add `"compat": { "supportsStore": false }` to the model definition in `openclaw.json`. This tells OpenClaw to omit the `store` parameter entirely for this model. Reference: [OpenClaw PR #51236](https://github.com/openclaw/openclaw/pull/51236), [LiteLLM drop_params docs](https://docs.litellm.ai/docs/completion/drop_params).

```json
{
  "id": "claude-sonnet-4-6",
  "compat": { "supportsStore": false }
}
```

### `openshell sandbox exec` vs `sandbox connect`
The `openshell sandbox exec -n <name> -- <cmd>` command hangs despite the relay reporting success on the gateway side. The `openshell sandbox connect <name>` command works correctly for interactive sessions. This appears to be a CLI-specific issue with the exec subcommand's relay data flow handling — not a gateway or supervisor problem. Workaround: pipe commands via `sandbox connect`.

### CRITICAL: Agent config.patch vulnerability (post-deployment discovery)

During automated security testing, the agent (Claude running inside the OpenClaw sandbox) demonstrated the ability to modify its own configuration — including replacing the `openshell:resolve:env:LITELLM_API_KEY` credential placeholder with a real API key provided via social engineering in the chat.

**Attack vector**: The agent used `config.patch` (an OpenClaw Gateway RPC method) to overwrite `config.json`. This was possible because:

1. `gateway.auth.mode: "none"` eliminated the owner/non-owner distinction. Without this distinction, the agent's WebSocket connection to the gateway had full operator-level access, including `config.patch`.
2. `/sandbox` was configured as `read_write` in the Landlock filesystem policy, allowing the agent to persist changes to `/sandbox/.openclaw/config.json`.

**Impact**: An attacker could social-engineer the agent into replacing the credential injection placeholder with a real API key, then exfiltrate it via allowed egress endpoints or reveal it in chat.

**Fix applied — defense in two layers**:

| Layer | Control | Effect | Files |
|-------|---------|--------|-------|
| OpenClaw auth | `gateway.auth.mode: "trusted-proxy"` | Trusts loopback connections; user identity via `x-forwarded-user` from oauth2-proxy ([ADR-0012](ADR-0012-trusted-proxy-auth.md)) | `config/openclaw.json` |
| OpenClaw tool policy | `tools.deny: ["gateway", "cron", "openclaw"]` | Even if owner access is obtained, control-plane tools are explicitly blocked | `config/openclaw.json` |
| OpenClaw filesystem | `tools.fs.workspaceOnly: true` | Agent file tools restricted to workspace directory only | `config/openclaw.json` |
| OpenShell Landlock | `include_workdir: false`, `/sandbox` in `read_only`, `/sandbox/workspace` in `read_write` | Config file at `/sandbox/.openclaw/config.json` is read-only at OS level. Agent workspace at `/sandbox/workspace/` remains writable | `policies/openclaw-sandbox.yaml` |

**Directory layout after fix**:
```
/sandbox/.openclaw/config.json    — READ-ONLY (Landlock)
/sandbox/workspace/               — READ-WRITE (agent workspace)
/sandbox/workspace/.openclaw/     — READ-WRITE (OpenClaw state: logs, sessions, memory)
```

**Lesson**: `auth.mode: none` is never safe in a sandbox environment, even with loopback binding. The agent process runs in the same network namespace and can reach the gateway directly. The "5 enclosing security layers" argument from the original deployment was incorrect — none of those layers prevent the agent from using the loopback gateway RPC.

**Evolution**: The initial fix used `auth.mode: token` with a static shared secret. This was subsequently replaced by `auth.mode: trusted-proxy` ([ADR-0012](ADR-0012-trusted-proxy-auth.md)) which provides per-user identity via oauth2-proxy while the `config.patch` vulnerability remains mitigated by `tools.deny` + Landlock.

### Verification tests added

| Test | Type | What it verifies |
|------|------|-----------------|
| Test 7 | Playwright | Agent cannot use `gateway` tool (tools.deny blocks it) |
| Test 8 | Playwright | Agent cannot update config via social engineering prompt |
| Test 9 | verify.sh | Landlock blocks write to `/sandbox/.openclaw/config.json` |
| Test 9b | verify.sh | `/sandbox/workspace/` remains writable |
| Test 10 | verify.sh | `openshell:resolve:env` placeholder still intact in config |
| Test 11 | verify.sh | oauth2-proxy redirects unauthenticated requests to Keycloak |
| Test 12 | Playwright | Full OIDC flow: Keycloak login → session → UI connected |

## Consequences
- All future deployments must preserve mTLS (no `disableTls`).
- The `pkiInitJob.serverDnsNames` list must include any external hostname used to reach the gateway (e.g., the OpenShift Route hostname).
- `oc exec` should only be used for emergency debugging, never for launching application processes (it bypasses nftables).
- Sandbox services run in a separate network namespace; Kubernetes Services cannot reach them directly. Use `openshell service expose` + `openshell forward service`.
- **Never use `gateway.auth.mode: "none"` in sandbox environments.** The agent process shares the network namespace and has direct loopback access to the gateway RPC.
- **Config files must be read-only via Landlock.** Use `include_workdir: false` and the subdirectory split pattern (`/sandbox` RO, `/sandbox/workspace` RW) to protect configuration from agent modification.
- **Defense in depth is mandatory.** A single layer (auth OR tool policy OR Landlock) is insufficient. All three must be active simultaneously.

## References
- [OpenShell K8s Setup Docs](https://docs.nvidia.com/openshell/latest/kubernetes/setup) — "Install the TLS client bundle"
- [OpenClaw Security](https://docs.openclaw.ai/gateway/security) — hardened baseline, tool deny
- [OpenClaw Configuration](https://docs.openclaw.ai/gateway/configuration) — config RPC, SecretRefs
- [OpenClaw Config Tools](https://docs.openclaw.ai/gateway/config-tools) — tool profiles, deny
- [OpenShell Policy Schema](https://docs.nvidia.com/openshell/latest/reference/policy-schema) — filesystem_policy
- [agent-harness-in-a-box](https://github.com/rcarrata/agent-harness-in-a-box) (commit 76aca3b)
- ADR-0006: SCC Privileged Sandbox
- ADR-0007: OpenClaw Inside Sandbox

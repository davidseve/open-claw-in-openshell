# ADR-0012: Trusted-Proxy Auth — Eliminating the Static Gateway Token

## Status
Accepted (supersedes token auth from ADR-0008)

## Context

ADR-0008 introduced `gateway.auth.mode: "token"` after discovering the `config.patch` vulnerability when `auth.mode: "none"` was used. The token was a static shared secret (`openssl rand -hex 32`) generated at deploy time and injected via `OPENCLAW_GATEWAY_TOKEN` environment variable. Users accessed the UI by appending `#token=<TOKEN>` to the URL.

This worked but introduced friction:

1. **Token distribution**: the token had to be shared out-of-band with every user who needed browser access.
2. **No per-user identity**: the token was a single shared secret — it could not distinguish between users, enforce roles, or be individually revoked.
3. **oauth2-proxy incompatibility**: oauth2-proxy performs OIDC authentication but cannot inject arbitrary tokens into the proxied WebSocket handshake. This made the OIDC flow (Phase 7b) and the token flow mutually exclusive.
4. **Test complexity**: Playwright tests had to manage the token via `extraHTTPHeaders` and URL fragment injection.

Meanwhile, the security layers surrounding the OpenClaw gateway had matured significantly:

| Layer | Mechanism | Protects against |
|-------|-----------|-----------------|
| Sandbox network namespace | Isolated netns, only loopback from gateway | Direct pod access |
| OpenShell Gateway | mTLS + OIDC JWT validation | Unauthenticated CLI/API access |
| oauth2-proxy | Keycloak OIDC session + cookie | Unauthenticated browser access |
| Keycloak | Identity broker → OCP OAuth | Unauthorized users |

All connections reaching the OpenClaw gateway at `localhost:18789` have already been authenticated by at least two of these layers. The gateway token was defense-in-depth without meaningful incremental security.

## Decision

Replace `auth.mode: "token"` with `auth.mode: "trusted-proxy"`.

### Configuration

```json
{
  "gateway": {
    "auth": {
      "mode": "trusted-proxy",
      "trustedProxy": {
        "userHeader": "x-forwarded-email",
        "requiredHeaders": ["x-forwarded-proto", "x-forwarded-host"],
        "allowLoopback": true
      }
    },
    "trustedProxies": ["127.0.0.1", "::1", "10.217.0.0/22", "10.217.4.0/23", "192.168.0.0/16"],
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
```

In this mode, the OpenClaw gateway trusts connections from loopback and the cluster pod/service networks. The `x-forwarded-email` header (set by oauth2-proxy) provides per-user identity to the gateway.

### Runtime decisions and rationale

The following configuration decisions were made during implementation and validated against OpenClaw's trusted-proxy documentation:

#### 1. `userHeader: "x-forwarded-email"` (not `x-forwarded-user`)

oauth2-proxy with Keycloak OIDC sends three identity headers:
- `x-forwarded-user`: the Keycloak **subject UUID** (e.g. `a2e714d9-d337-44cb-...`), not a human-readable identifier
- `x-forwarded-email`: the user's email (e.g. `admin@openshell.local`)
- `x-forwarded-preferred-username`: the Keycloak username (e.g. `admin`)

`x-forwarded-email` was chosen because it is human-readable, unique, and consistent with audit trail expectations. The UUID in `x-forwarded-user` is opaque and harder to correlate in logs.

#### 2. `allowLoopback: true`

OpenClaw rejects trusted-proxy authentication from loopback sources (`127.0.0.1`, `::1`) by default as an anti-spoofing measure (error: `trusted_proxy_loopback_source`). This is because any local process could forge identity headers on loopback.

In the OpenShell sandbox architecture, this check must be explicitly overridden because:
- The gateway binds to `loopback` (only `127.0.0.1:18789`)
- OpenShell's service proxy terminates mTLS externally and connects to the sandbox's loopback address
- oauth2-proxy authenticates users before traffic enters the OpenShell service proxy chain

**Important caveat**: the sandbox shares a network namespace between the OpenShell supervisor and the agent process. This means the agent can also reach loopback and could forge identity headers. The `allowLoopback` override is a trade-off: without it, trusted-proxy mode cannot work in this topology. The residual risk is mitigated by `tools.deny` blocking the `gateway` tool and Landlock making `/sandbox/.openclaw/` read-only. See "Residual risks" below.

#### 3. `trustedProxies` includes cluster CIDRs

The `X-Forwarded-For` chain contains multiple IPs from the traffic path:

```
Browser → OCP Router (192.168.127.1) → HAProxy (10.217.0.2) → oauth2-proxy → OpenShell → sandbox (127.0.0.1)
```

OpenClaw validates the entire forwarding chain against `trustedProxies`. If any IP in `X-Forwarded-For` is not in the trusted list, the request is rejected. The CIDRs cover:
- `10.217.0.0/22`: OCP cluster pod network
- `10.217.4.0/23`: OCP service network
- `192.168.0.0/16`: CRC host network (covers `192.168.127.1` from the CRC VM bridge)

For production OCP clusters, replace these CIDRs with the actual cluster network ranges from `oc get network.config cluster`.

#### 4. `dangerouslyDisableDeviceAuth: true`

OpenClaw's Control UI requires device pairing (browser-generated device identity) for scope authorization. In trusted-proxy mode, WebSocket sessions without device identity receive empty scopes — causing `connect failed` after successful authentication.

The browser cannot complete device pairing because:
- The WebSocket connection is proxied through oauth2-proxy → OpenShell → sandbox
- Device identity generation requires a direct HTTPS connection to the gateway
- The proxy chain prevents the browser from establishing the direct TLS context needed for device fingerprinting

This flag preserves the requested operator scopes even without device identity. The security trade-off is acceptable because:
- User identity is already verified by oauth2-proxy + Keycloak OIDC
- `requiredHeaders` ensures the request came through the proxy chain
- The sandbox network namespace prevents direct access from any other source

#### 5. `requiredHeaders: ["x-forwarded-proto", "x-forwarded-host"]`

These headers are injected by oauth2-proxy and the OpenShift router. Requiring them adds friction to header spoofing — a sandbox-internal process would need to forge the full proxy header set, not just `x-forwarded-email`.

**Important caveat**: `requiredHeaders` is a hygiene measure, not a security boundary. Any process with loopback access (including the agent) can trivially set any HTTP headers. The real protection against identity spoofing comes from the upstream authentication layers (oauth2-proxy + Keycloak OIDC), not from header validation at the gateway level.

### What was removed

- `OPENCLAW_GATEWAY_TOKEN` environment variable (no longer injected at sandbox creation)
- `secrets/.openclaw-gw-token` file
- `load_gw_token()` function from `scripts/common.sh`
- Token references in `verify.sh`, `launch-openclaw.sh`
- `extraHTTPHeaders` with `Authorization: Bearer` in Playwright config
- URL fragment `#token=<TOKEN>` access pattern

### What was added

- `tests/auth.setup.ts`: Playwright auth setup that automates Keycloak OIDC login
- Playwright projects (`auth-setup`, `ui-tests`, `security-tests`) with `storageState` for session persistence
- `manifests/oauth2-proxy/configmap.yaml.tpl`: template with `__APPS_DOMAIN__` for environment portability

## Security analysis

### The `config.patch` vulnerability (ADR-0008) remains mitigated

The original reason for introducing token auth was to prevent the agent from calling `config.patch` via the gateway RPC. With `trusted-proxy` mode, this is still prevented by the remaining two defense layers:

| Layer | Control | Effect |
|-------|---------|--------|
| OpenClaw tool policy | `tools.deny: ["gateway", "cron", "openclaw"]` | Control-plane tools explicitly blocked |
| OpenShell Landlock | `/sandbox/.openclaw/` read-only | Original config immutable at OS level |

The token's contribution was the owner/non-owner distinction, which prevented `config.patch` calls from non-owner connections. With `tools.deny`, the `gateway` tool (which wraps `config.patch`) is blocked regardless of owner status. With Landlock, the original config at `/sandbox/.openclaw/config.json` cannot be written.

**Important caveat**: the active OpenClaw config lives at `/sandbox/workspace/.openclaw/openclaw.json`, which is in the read-write workspace zone. Landlock protects the original config template but not the active config. The `tools.deny` policy is the primary protection against `config.patch` exploitation. See "Residual risks" below.

### Threat model comparison

| Threat | Token mode | Trusted-proxy mode |
|--------|-----------|-------------------|
| Agent calls `config.patch` | Blocked (non-owner) | Blocked (`tools.deny` + Landlock) |
| Unauthenticated browser access | Blocked (no token) | Blocked (oauth2-proxy redirects to Keycloak) |
| Unauthenticated CLI access | Blocked (gateway OIDC) | Blocked (gateway OIDC) |
| Direct pod access | Blocked (network namespace) | Blocked (network namespace) |
| Token leak/sharing | Risk exists | N/A (no token) |
| Per-user identity | Not possible (shared secret) | Available via `x-forwarded-user` |
| Session revocation | Not possible (static token) | Possible (Keycloak session management) |

## Defense-in-depth summary

The following layers ensure that `allowLoopback` and `dangerouslyDisableDeviceAuth` do not weaken the overall security posture:

| Layer | Mechanism | What it prevents | Residual gap |
|-------|-----------|-----------------|--------------|
| 1. OIDC authentication | oauth2-proxy + Keycloak | Unauthenticated access; only verified users get `x-forwarded-email` | None — external auth boundary |
| 2. Required headers | `requiredHeaders` config | Adds friction to header spoofing | Agent can forge headers (shared netns) |
| 3. Network isolation | nftables + network namespace | External or pod-to-pod access | Agent shares netns with supervisor |
| 4. Forwarding chain validation | `trustedProxies` CIDRs | Traffic from untrusted network sources | None — CIDRs are cluster-scoped |
| 5. Tool policy | `tools.deny: ["gateway", "cron", "openclaw"]` | Agent calling control-plane tools | Model could be jailbroken to use raw HTTP |
| 6. Config protection | Landlock (RO on `/sandbox/.openclaw/`) | Write to original config template | Active config at `/sandbox/workspace/` is RW |
| 7. Allowed origins | `controlUi.allowedOrigins` | Cross-origin WebSocket hijacking | None — standard CORS enforcement |

## Residual risks

The following risks are accepted trade-offs of this architecture:

1. **Agent can spoof identity headers**: The agent process shares a network namespace with the OpenShell supervisor. It can `curl localhost:18789` with arbitrary `x-forwarded-email` headers. `requiredHeaders` adds friction but is not a hard boundary. **Mitigation**: `tools.deny` blocks the `gateway` tool; the agent has no direct incentive to forge headers. **Future**: OpenShell issue tracking netns separation between supervisor and agent.

2. **Active config is writable**: The OpenClaw gateway reads its active config from `/sandbox/workspace/.openclaw/openclaw.json`, which is in the read-write workspace zone. Landlock only protects the original template at `/sandbox/.openclaw/config.json`. A jailbroken agent could modify the active config directly via filesystem writes. **Mitigation**: `tools.deny` blocks the `gateway` tool (the normal config modification path); direct JSON edits require the agent to know the config schema and restart the gateway. **Future**: mount active config as read-only or use OpenClaw's `bootstrapFreezeMode`.

3. **Prompt files are not truly immutable**: `chmod 444` prevents accidental writes but the sandbox user owns the parent directory and can `rm` + recreate files. See ADR-0015 for details and OpenClaw issue #36190. **Mitigation**: best-effort protection; MLflow Prompt Registry provides audit trail of changes.

## Consequences

- All browser access goes through oauth2-proxy → Keycloak OIDC. No more URL token sharing.
- Per-user identity is available in the OpenClaw gateway via the `x-forwarded-email` header (email address, not Keycloak UUID).
- Playwright tests exercise the real OIDC flow (Keycloak login → session cookie → proxied access).
- The `config.patch` protection relies on `tools.deny` + Landlock instead of owner/non-owner distinction. Both must remain active.
- `auth.mode: "none"` remains prohibited in sandbox environments (ADR-0008 still applies).
- `dangerouslyDisableDeviceAuth` should be removed if OpenClaw adds support for device pairing through proxy chains in a future release.
- For production deployments, the `trustedProxies` CIDRs should be tightened to match actual cluster network ranges (avoid broad `192.168.0.0/16` unless the environment requires it).

## References

- ADR-0008: Deployment Findings (original `config.patch` vulnerability)
- ADR-0010: OIDC + OCP Federation
- ADR-0011: oauth2-proxy UI Authentication
- [OpenClaw Trusted Proxy Auth](https://docs.openclaw.ai/gateway/trusted-proxy)
- [OpenClaw Security](https://docs.openclaw.ai/gateway/security)

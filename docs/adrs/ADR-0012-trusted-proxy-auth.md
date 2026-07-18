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
        "userHeader": "x-forwarded-user"
      }
    },
    "trustedProxies": ["127.0.0.1", "::1"]
  }
}
```

In this mode, the OpenClaw gateway trusts connections from `127.0.0.1` and `::1` (loopback), which is exactly how traffic arrives from both the OpenShell gateway relay and oauth2-proxy. The `x-forwarded-user` header (set by oauth2-proxy) provides per-user identity to the gateway.

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
| OpenShell Landlock | `/sandbox/.openclaw/` read-only | Config file immutable at OS level |

The token's contribution was the owner/non-owner distinction, which prevented `config.patch` calls from non-owner connections. With `tools.deny`, the `gateway` tool (which wraps `config.patch`) is blocked regardless of owner status. With Landlock, even if `config.patch` succeeded at the RPC level, the filesystem write would fail.

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

## Consequences

- All browser access goes through oauth2-proxy → Keycloak OIDC. No more URL token sharing.
- Per-user identity is available in the OpenClaw gateway via the `x-forwarded-user` header.
- Playwright tests exercise the real OIDC flow (Keycloak login → session cookie → proxied access).
- The `config.patch` protection relies on `tools.deny` + Landlock instead of owner/non-owner distinction. Both must remain active.
- `auth.mode: "none"` remains prohibited in sandbox environments (ADR-0008 still applies).

## References

- ADR-0008: Deployment Findings (original `config.patch` vulnerability)
- ADR-0010: OIDC + OCP Federation
- ADR-0011: oauth2-proxy UI Authentication
- [OpenClaw Trusted Proxy Auth](https://docs.openclaw.ai/gateway/trusted-proxy)
- [OpenClaw Security](https://docs.openclaw.ai/gateway/security)

# ADR-0011: oauth2-proxy for OpenClaw UI Authentication

## Status

Accepted

## Context

After Phase 7 (Keycloak OIDC), the OpenShell gateway enforces OIDC authentication on gRPC API calls (CLI/sandbox management). However, the OpenClaw Control UI—served through OpenShell's HTTP service proxy—still requires a static token passed via URL fragment (`#token=<value>`).

This creates a split authentication model:
- CLI: per-user OIDC via Keycloak (SSO with OCP credentials)
- UI: shared static token (no per-user identity, no audit trail)

The static token is a shared secret that cannot be rotated automatically, provides no user identity for audit, and requires manual distribution to each user.

OpenShell's service proxy does not enforce OIDC on HTTP service routes. It forwards requests to the sandbox without authentication checks and without injecting identity headers. The proxy only strips `Authorization`, `cf-access-jwt-assertion`, and client certificate headers—all other headers pass through to the sandbox.

## Decision

Deploy **oauth2-proxy** (v7.15.3) as an OIDC authentication gateway in front of the OpenClaw UI route. Configure OpenClaw to use `trusted-proxy` auth mode, reading user identity from the `X-Forwarded-User` header injected by oauth2-proxy in reverse proxy mode.

### Architecture

```
Browser → Route (edge TLS) → oauth2-proxy → OpenShell service route (passthrough) → OpenShell GW → Sandbox (OpenClaw trusted-proxy)
```

### Key design choices

1. **oauth2-proxy over custom code**: oauth2-proxy is a mature, well-maintained CNCF-adjacent project with native Keycloak OIDC support, WebSocket proxying, and session cookie management. No custom authentication code needed.

2. **Edge TLS on the auth route**: The new route uses OpenShift's wildcard certificate (edge termination), eliminating browser TLS warnings from the self-signed gateway cert.

3. **Hairpin through external route**: oauth2-proxy uses `pass_host_header=false` with the upstream set to the existing passthrough service route. This ensures the correct Host header reaches OpenShell's service routing logic. The extra hop through the external router adds ~1-2ms latency (acceptable for a POC).

4. **`trusted-proxy` with `requiredHeaders`**: OpenClaw requires both `X-Forwarded-User` (identity) and `X-Forwarded-Access-Token` (proof of proxy chain) headers. oauth2-proxy injects these in reverse proxy mode via `pass_user_headers` and `pass_access_token`. This mitigates local spoofing from sandbox-internal processes that could otherwise forge the user header alone.

5. **Confidential client**: The `openclaw-ui` Keycloak client is confidential (server-side secret), unlike the public `openshell-cli` client. oauth2-proxy manages the client secret securely.

## Consequences

### Positive

- Eliminates the static token for UI access
- Per-user identity and audit trail via Keycloak
- SSO experience: users authenticate once with OCP credentials
- Proper TLS (no browser warnings)
- Session cookies with automatic refresh (168h expiry, 1h refresh)
- Role-based access: only users with `openshell-user` realm role can access the UI

### Negative

- Additional component to maintain (oauth2-proxy deployment)
- Hairpin latency through external route (~1-2ms per request)
- WebSocket session depends on cookie validity (168h is generous)
- `allowLoopback: true` in trusted-proxy mode means any localhost process could theoretically spoof identity (mitigated by `requiredHeaders` and sandbox isolation)

### Security model

| Threat | Mitigation |
|--------|-----------|
| External access without login | oauth2-proxy redirects to Keycloak |
| Header injection from outside | Only route to OpenShell is passthrough (SNI-matched), and the auth route goes through oauth2-proxy which controls headers |
| Sandbox-internal spoofing | `requiredHeaders` demands `X-Forwarded-Access-Token` (valid OAuth token) which sandbox processes cannot forge |
| Cookie theft | `Secure`, `SameSite=Lax`, `HttpOnly` cookie flags |
| Session fixation | oauth2-proxy generates new session on each login |

## Alternatives Considered

1. **`auth.mode: none`**: Remove all auth, rely on network isolation. Rejected: no identity, no audit, URL leak = full access.

2. **Keep static token**: No changes. Rejected: user explicitly requested eliminating the static token.

3. **Custom nginx + lua-resty-openidc**: More control but significantly more configuration and maintenance burden.

4. **OpenShift OAuth Proxy sidecar**: Standard OCP pattern but requires injecting into the OpenShell pod (complex with Helm) and only supports OCP OAuth, not arbitrary Keycloak realms.

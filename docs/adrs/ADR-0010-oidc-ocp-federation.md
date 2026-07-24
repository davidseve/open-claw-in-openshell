# ADR-0010: OIDC via Keycloak with OCP Identity Federation

## Status
Accepted. **Scope narrowed by [ADR-0016](ADR-0016-openshift-native-oauth-spike.md)
(2026-07-23): this ADR's decision now applies only to the CLI/gRPC gateway
auth path.** The browser UI path described here (and in
[ADR-0011](ADR-0011-oauth2-proxy-ui-auth.md)) was migrated off Keycloak
entirely to OpenShift-native OAuth. The "Why not direct OCP OAuth?"
incompatibility table below is still the accurate, current reason Keycloak
remains required for CLI/gRPC — ADR-0016's "Decision record" section
restates and confirms it against the OpenShell gateway source directly, and
is the canonical place to check before re-litigating Keycloak's removal.

## Context
Phase 5 established mTLS client certificates as the authentication mechanism for the OpenShell gateway. This requires users to import a PKCS12 bundle into their browser or use `openshell forward service` for local access. Phase 6 confirmed that browser access via the external service Route still requires the client cert.

Goal: eliminate the client cert requirement for CLI and browser access using standard OIDC authentication, while preserving transport TLS (ADR-0008 compliance).

### Why not direct OCP OAuth?

OpenShift's built-in OAuth server (`oauth-openshift.apps.<domain>`) is **not compatible** with OpenShell's OIDC implementation:

| OpenShell requires | OCP OAuth provides |
|---|---|
| `/.well-known/openid-configuration` | `/.well-known/oauth-authorization-server` (OAuth 2.0, not OIDC) |
| JWKS at `jwks_uri` | No JWKS endpoint |
| JWT access tokens (RS256) | Opaque tokens (`sha256~...`) |
| Role claims in JWT body | Groups in User API, not token |

### Options considered

| Option | Pros | Cons |
|--------|------|------|
| A: OCP OAuth directly | Zero extra components | Incompatible (opaque tokens, no JWKS) |
| B: Keycloak with OCP identity brokering | Users log in with OCP creds; standard OIDC JWTs; role mapping | Extra component (Keycloak pod) |
| C: External IdP (Entra, Okta) | Enterprise-grade | External dependency; not self-contained on cluster |

## Decision
**Option B: Keycloak deployed in-cluster, acting as Identity Broker to OCP OAuth.**

Users authenticate with their OCP credentials (htpasswd in this cluster) via Keycloak's "Login with OpenShift" button. Keycloak issues standard RS256 JWTs that OpenShell validates via JWKS.

### Architecture

```
CLI/Browser → Keycloak → "Login with OpenShift" → OCP OAuth
                ↓
         JWT (RS256, realm_access.roles)
                ↓
CLI/Browser → OpenShell Gateway (validates JWT via JWKS)
```

> As of ADR-0016, "Browser" above applies only to the CLI/gRPC path's
> historical context; the live browser UI flow no longer goes through
> Keycloak (see ADR-0016's rollout). This diagram remains accurate for CLI.

### Key configuration

**Keycloak realm** (`openshell`):
- Client `openshell-cli`: public, Authorization Code + PKCE
- Identity Provider `openshift`: brokers to OCP OAuth via `OAuthClient`
- Roles: `openshell-admin`, `openshell-user` (default)

**OCP OAuthClient** (`keycloak-broker`):
- Allows Keycloak to redirect users to OCP login
- Redirect URI points to Keycloak's broker endpoint

**OpenShell Helm values**:
```yaml
server:
  auth:
    allowUnauthenticatedUsers: false
  oidc:
    issuer: "https://keycloak-openshell-keycloak.apps.<domain>/realms/openshell"
    audience: "openshell-cli"
    rolesClaim: "realm_access.roles"
    adminRole: "openshell-admin"
    userRole: "openshell-user"
```

### TLS posture

- Server TLS remains enabled (`pkiInitJob` active, passthrough Route)
- Client cert requirement **auto-disabled** by the gateway when OIDC issuer is configured
- Browsers connect via HTTPS (self-signed server cert warning) + Bearer JWT
- No client cert import needed

### Login flow

```bash
openshell gateway login ocp
# Opens browser → Keycloak → "Login with OpenShift" → OCP htpasswd login
# Returns to CLI with JWT stored locally
```

## Consequences

- Users authenticate with OCP credentials (familiar UX)
- No client cert import needed for CLI or browser
- `allowUnauthenticatedUsers: false` enforced (no dev bypass)
- Keycloak adds one pod (~512Mi RAM) to the cluster
- Sandbox supervisor auth is unaffected (uses gateway-minted JWTs)
- If Keycloak is down, new logins fail (existing JWTs remain valid until expiry)
- Cluster change requires updating: KC_HOSTNAME, OAuthClient redirect URI, identity provider URLs

## References

- [OpenShell access control docs](https://docs.nvidia.com/openshell/kubernetes/access-control)
- [OpenShell gateway auth](https://docs.nvidia.com/openshell/reference/gateway-auth)
- [agent-harness-in-a-box demo 02](https://github.com/rcarrata/agent-harness-in-a-box/) (Keycloak pattern)
- [Keycloak identity brokering](https://www.keycloak.org/docs/latest/server_admin/#_identity_broker)
- [OCP OAuthClient](https://docs.openshift.com/container-platform/4.17/authentication/configuring-oauth-clients.html)
- ADR-0008: mTLS is non-negotiable (transport TLS preserved)
- ADR-0009: External service routing (wildcard SAN)

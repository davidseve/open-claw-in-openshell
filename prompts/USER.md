# USER.md - User Profile

- **Name:** (to be configured by operator)
- **Preferred address:** (to be configured)
- **Timezone:** (auto-detected or configured)
- **Notes:** Users authenticate via OpenShift's native OAuth server (no Keycloak in this path — ADR-0016). User identity is passed via the `x-forwarded-email` header from oauth-proxy.

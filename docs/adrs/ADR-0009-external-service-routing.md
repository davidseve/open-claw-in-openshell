# ADR-0009: External Service Routing via Explicit Route + Wildcard SAN

## Status
Accepted

## Context
Phase 5 established the OpenClaw Control UI accessible only via `openshell forward service` (a local port-forward tunnel over mTLS). This requires the operator to keep a terminal session running and limits access to the machine running the CLI.

Goal: expose the Control UI as a browser-accessible URL through the OpenShell gateway and OpenShift Route, without a local port-forward.

### How OpenShell service routing works

The OpenShell gateway multiplexes gRPC (CLI) and HTTP (sandbox services) on a single port. Service routing uses **Host header matching**:

1. Gateway reads wildcard SANs from its TLS certificate at startup
2. Each wildcard SAN `*.example.com` registers `example.com` as a service routing base domain
3. Incoming HTTP with Host `{sandbox}--{service}.example.com` is relayed to the sandbox's loopback port

No path-prefix routing exists; the URI path is forwarded unchanged to the sandbox process.

### Options considered

| Option | Pros | Cons |
|--------|------|------|
| A: Explicit Route per service + wildcard SAN in pkiInitJob | No IngressController changes; works with default OCP policy; simple for single service | Self-signed cert; one Route per service |
| B: Wildcard Route (`wildcardPolicy: Subdomain`) | One Route covers all services | Requires IngressController `routeAdmission.wildcardPolicy: WildcardsAllowed` (cluster-admin); broader attack surface |
| C: Gateway API HTTPRoute with wildcard hostname | Modern, portable, fine-grained | Requires Gateway API controller deployment; OCP support varies |

## Decision
**Option A: Explicit Route per service + wildcard SAN in pkiInitJob (passthrough TLS).**

This is the simplest approach that works without cluster-level configuration changes, suitable for a PoC/educational deployment. The self-signed cert produces a browser warning but is acceptable for non-production use.

### Implementation

1. **Wildcard SAN** added to `pkiInitJob.serverDnsNames`:
   ```yaml
   pkiInitJob:
     serverDnsNames:
       - "openshell-gw-openshell.apps.ocp.sandbox315.opentlc.com"
       - "*.apps.ocp.sandbox315.opentlc.com"
   ```
   The gateway derives `apps.ocp.sandbox315.opentlc.com` as a service routing domain.

2. **Explicit Route** for the OpenClaw UI:
   ```yaml
   apiVersion: route.openshift.io/v1
   kind: Route
   metadata:
     name: openclaw-ui
     namespace: openshell
   spec:
     host: openclaw-gw--openclaw-ui.apps.ocp.sandbox315.opentlc.com
     to:
       kind: Service
       name: openshell
     port:
       targetPort: grpc
     tls:
       termination: passthrough
   ```

3. **DNS resolution**: OCP's existing wildcard DNS `*.apps.<cluster_domain>` already resolves any first-level subdomain to the router LB. No additional DNS records required.

4. **PKI regeneration**: Since pkiInitJob only runs when the secret is missing, upgrading requires deleting `openshell-server-tls` and running `helm upgrade`. Script: `scripts/upgrade-pki.sh`.

### Request flow

```
Browser → DNS (*.apps.ocp...) → OCP Router/HAProxy
  → passthrough TLS → OpenShell gateway (terminates TLS)
    → Host header parse: sandbox=openclaw-gw, service=openclaw-ui
      → relay TCP to sandbox loopback:18789
        → OpenClaw responds
```

### Portability

The apps domain is auto-detected from the cluster:
```bash
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
```

When deploying to a different cluster, only `values-ocp.yaml` serverDnsNames needs updating.

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| Self-signed cert (browser warning) | Acceptable for PoC; production path: cert-manager with trusted CA |
| Wildcard SAN scope (`*.apps.<cluster>`) | Cert is self-signed, not publicly trusted; cannot be used to impersonate other services |
| Token in URL | HTTPS encrypts query params on wire; prefer `#token=` (fragment, never sent to server in logs) |
| Public Control UI access | `auth.mode: token` required; `tools.deny` blocks control-plane; Landlock protects config |
| No IngressController hardening | Default `WildcardsDisallowed` policy preserved; explicit Route per service |

## Consequences

- The Control UI is accessible at `https://openclaw-gw--openclaw-ui.apps.<cluster_domain>/?token=<TOKEN>`
- `openshell forward service` remains available as a fallback (no browser cert warning)
- Adding more sandbox services requires creating additional explicit Routes
- Transitioning to trusted certs requires cert-manager (future Phase 7 or dedicated cert work)
- The wildcard SAN does not weaken security because the cert is self-signed (not trusted by default)

## References

- [OpenShell service routing docs](https://docs.nvidia.com/openshell/sandboxes/manage-gateways) — Host-based routing, `server_sans`
- [OpenShift Route TLS termination](https://docs.openshift.com/container-platform/4.17/networking/routes/secured-routes.html)
- [OpenShift wildcard Route policy](https://docs.openshift.com/container-platform/4.17/networking/routes/route-configuration.html#nw-ingress-creating-a-wildcard-route_route-configuration)
- ADR-0008: mTLS is non-negotiable
- ADR-0006: SCC Privileged Sandbox

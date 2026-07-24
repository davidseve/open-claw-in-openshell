# Production Route for the OpenClaw Control UI, protected by OpenShift-native
# OAuth (see ADR-0016). Browsers authenticate against OCP's own OAuth server
# via oauth-proxy's `-provider=openshift` -- no Keycloak involved in this path.
#
# `reencrypt` termination is required: oauth-proxy terminates TLS itself
# using the service-CA-issued cert (see service.yaml). The OpenShift router
# trusts the internal service-serving-cert CA by default, so no
# destinationCACertificate needs to be set here.
#
# The host MUST equal OpenShell's `{sandbox}--{service}.{base_domain}`
# service-routing pattern (previously the friendlier `openclaw-ui.<domain>`)
# because oauth-proxy's WebSocket proxying never rewrites the Host header
# regardless of --pass-host-header (a real bug in this fork -- see
# deployment.yaml.tpl). Making the public hostname match what OpenShell
# expects removes the need for host rewriting entirely, fixing WebSocket
# logins. This retires the old unauthenticated static-token Route
# (`openclaw-ui`, formerly at this same hostname, pointing straight at the
# `openshell` Service) -- see manifests/openclaw-service-route.yaml.tpl's
# removal in the same change.
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: openclaw-ui-auth
  namespace: openshell
  annotations:
    haproxy.router.openshift.io/timeout: 3600s
spec:
  host: openclaw-gw--openclaw-ui.__APPS_DOMAIN__
  to:
    kind: Service
    name: oauth-proxy
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect

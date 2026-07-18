# Route for OpenClaw Control UI via OpenShell gateway service routing.
#
# The gateway routes requests by Host header pattern:
#   {sandbox}--{service}.{base_domain} → relay to sandbox loopback:{port}
#
# This Route sends browser traffic to the gateway, which then relays it
# to the OpenClaw process inside the sandbox's network namespace.
#
# Access requires: ?token=<OPENCLAW_GATEWAY_TOKEN> or Authorization header.
#
# Template: __APPS_DOMAIN__ is replaced at deploy time by scripts/common.sh render_template().
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: openclaw-ui
  namespace: openshell
spec:
  host: openclaw-gw--openclaw-ui.__APPS_DOMAIN__
  to:
    kind: Service
    name: openshell
  port:
    targetPort: grpc
  tls:
    termination: passthrough

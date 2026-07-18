# OpenShell Helm chart overrides for OpenShift Container Platform
# Based on: https://docs.nvidia.com/openshell/latest/kubernetes/setup
# Reference: https://github.com/rcarrata/agent-harness-in-a-box (commit 76aca3b)
#
# Template: __APPS_DOMAIN__ is replaced at deploy time by scripts/common.sh render_template().

replicaCount: 1

workload:
  kind: statefulset

image:
  tag: "0.0.83"

supervisor:
  image:
    tag: "0.0.83"

# Let OpenShift SCC admission assign UIDs and fsGroup
podSecurityContext:
  fsGroup: null

securityContext:
  runAsUser: null

# PKI init job creates openshell-server-tls, openshell-client-tls,
# and openshell-jwt-keys secrets automatically on first install.
# mTLS is required for SSH relay, sandbox exec, and credential injection.
pkiInitJob:
  serverDnsNames:
    - "openshell-gw-openshell.__APPS_DOMAIN__"
    - "*.__APPS_DOMAIN__"

server:
  auth:
    allowUnauthenticatedUsers: false

  oidc:
    issuer: "https://keycloak-openshell-keycloak.__APPS_DOMAIN__/realms/openshell"
    audience: "openshell-cli"
    jwksTtl: 60
    rolesClaim: "realm_access.roles"
    adminRole: "openshell-admin"
    userRole: "openshell-user"
    caConfigMapName: "openshell-oidc-ca"

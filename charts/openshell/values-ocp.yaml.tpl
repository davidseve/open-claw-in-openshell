# OIDC overlay: OpenShell gateway auth via Keycloak (browser/headless OIDC
# login for the CLI/gRPC path — see scripts/configure-oidc.sh and
# docs/adrs/ADR-0012-trusted-proxy-auth.md for why the *UI* uses trusted-proxy
# instead, a separate path).
#
# Template: __APPS_DOMAIN__ is replaced at deploy time by scripts/common.sh
# render_template(). Keep this file's non-oidc/auth sections in sync with
# values-ocp-no-oidc.yaml.tpl by hand if you change one — see that file's
# header comment for why they're two explicit files instead of one generated
# from the other by stripping the `oidc:` block.

openshell:
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

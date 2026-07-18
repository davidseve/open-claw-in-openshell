apiVersion: v1
kind: ConfigMap
metadata:
  name: oauth2-proxy-config
  namespace: openshell
data:
  oauth2-proxy.cfg: |
    provider = "keycloak-oidc"
    oidc_issuer_url = "https://keycloak-openshell-keycloak.__APPS_DOMAIN__/realms/openshell"
    client_id = "openclaw-ui"
    redirect_url = "https://openclaw-ui.__APPS_DOMAIN__/oauth2/callback"
    upstreams = ["https://openclaw-gw--openclaw-ui.__APPS_DOMAIN__"]
    ssl_upstream_insecure_skip_verify = true
    pass_host_header = false
    proxy_websockets = true
    pass_user_headers = true
    pass_access_token = true
    pass_authorization_header = false
    email_domains = ["*"]
    cookie_secure = true
    cookie_samesite = "lax"
    cookie_expire = "168h"
    cookie_refresh = "1h"
    cookie_name = "_openclaw_proxy"
    skip_provider_button = true
    reverse_proxy = true
    allowed_roles = ["openshell-user"]
    code_challenge_method = "S256"
    http_address = "0.0.0.0:4180"
    scope = "openid email profile roles"
    skip_jwt_bearer_tokens = true
    insecure_oidc_allow_unverified_email = true
    ssl_insecure_skip_verify = true

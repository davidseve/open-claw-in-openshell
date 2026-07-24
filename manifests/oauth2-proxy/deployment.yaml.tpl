# OpenShift-native browser auth for the OpenClaw Control UI. Uses the
# `openshift/oauth-proxy` fork (not the community
# quay.io/oauth2-proxy/oauth2-proxy image) because only this fork implements
# `-provider=openshift` and SA-based OAuth clients via TokenRequest — no
# Keycloak broker required for this path. See ADR-0016.
#
# `--pass-host-header=true` + the public Route hostname
# (openclaw-gw--openclaw-ui.__APPS_DOMAIN__, matching OpenShell's
# {sandbox}--{service} routing pattern) work around a real bug in this
# fork's WebSocket reverse proxy: `NewWebSocketOrRestReverseProxy` in
# oauthproxy.go never applies `setProxyUpstreamHostHeader` to the
# `wsutil`-based WebSocket proxy (only to the plain HTTP one), so WebSocket
# upgrades always forwarded the original inbound Host header regardless of
# `--pass-host-header`. Fixed upstream in oauth2-proxy/oauth2-proxy (PR
# #3290) but not backported to this OpenShift fork, and also present
# unfixed in opendatahub-io/kube-auth-proxy (verified in its
# pkg/upstream/http.go `newWebSocketReverseProxy`). Making the public
# hostname *equal* the upstream's expected Host sidesteps the bug for both
# HTTP and WebSocket traffic instead of depending on host rewriting at all.
# See ADR-0016 "WebSocket login failure" section.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth-proxy
  namespace: openshell
  labels:
    app: oauth-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: oauth-proxy
  template:
    metadata:
      labels:
        app: oauth-proxy
    spec:
      serviceAccountName: openclaw-ui-oauth-proxy
      # The public Route (openclaw-gw--openclaw-ui.__APPS_DOMAIN__, see
      # route.yaml.tpl) now points at THIS Service, not at the `openshell`
      # Service anymore -- so --upstream can no longer resolve that hostname
      # through the Route without looping back into this same Deployment.
      # This hostAlias makes the hostname resolve straight to the `openshell`
      # Service's ClusterIP instead, so --upstream still dials the real
      # OpenShell gateway while keeping the same Host/SNI value that both the
      # gateway's routing and its self-signed cert's wildcard SAN expect.
      # __OPENSHELL_GW_CLUSTER_IP__ is substituted at deploy time (see
      # scripts/deploy-oauth2-proxy.sh) since the ClusterIP is dynamic.
      hostAliases:
        - ip: __OPENSHELL_GW_CLUSTER_IP__
          hostnames:
            - openclaw-gw--openclaw-ui.__APPS_DOMAIN__
      containers:
        - name: oauth-proxy
          image: registry.redhat.io/openshift4/ose-oauth-proxy:latest
          args:
            - --provider=openshift
            - --openshift-service-account=openclaw-ui-oauth-proxy
            # Explicit :8080 is required: the hostAlias below sends this
            # hostname straight to the `openshell` Service's ClusterIP,
            # bypassing the Route/router that used to supply the implicit
            # :443. The Service's only listener is `grpc` on 8080 (a
            # passthrough-TLS multiplexed gRPC+HTTP port -- see the
            # `openshell-gw` Route's `targetPort: grpc`), so without the
            # explicit port oauth-proxy dials 10.x.x.x:443, which nothing
            # listens on, and every proxied request (including WebSocket
            # upgrades) hangs until it times out.
            - --upstream=https://openclaw-gw--openclaw-ui.__APPS_DOMAIN__:8080
            - --ssl-insecure-skip-verify=true
            - --upstream-ca=/etc/openshell/ca.crt
            - --https-address=:8443
            - --http-address=
            - --tls-cert=/etc/tls/private/tls.crt
            - --tls-key=/etc/tls/private/tls.key
            - --cookie-secret-file=/etc/proxy/secrets/session_secret
            - --cookie-expire=168h
            - --cookie-refresh=1h
            - --email-domain=*
            - --pass-host-header=true
            - --pass-user-headers=true
            - --pass-access-token=true
            - --skip-provider-button=true
          ports:
            - containerPort: 8443
              name: https
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /oauth/healthz
              port: https
              scheme: HTTPS
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /oauth/healthz
              port: https
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: tls
              mountPath: /etc/tls/private
              readOnly: true
            - name: session-secret
              mountPath: /etc/proxy/secrets
              readOnly: true
            - name: openshell-ca
              mountPath: /etc/openshell
              readOnly: true
      volumes:
        - name: tls
          secret:
            secretName: oauth-proxy-tls
        - name: session-secret
          secret:
            secretName: oauth-proxy-session-secret
        # openshell-server-tls's ca.crt signs the passthrough-TLS cert
        # presented by the OpenShell relay upstream this proxy forwards to.
        # Without trusting it explicitly, oauth-proxy's reverse proxy to the
        # upstream fails with "x509: certificate signed by unknown authority"
        # (this fork has no upstream-specific insecure-skip-verify, unlike
        # the community oauth2-proxy's ssl_upstream_insecure_skip_verify).
        - name: openshell-ca
          secret:
            secretName: openshell-server-tls
            items:
              - key: ca.crt
                path: ca.crt

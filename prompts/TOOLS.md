# TOOLS.md - Local Notes

This file is for your specifics — the stuff that's unique to this deployment.

## Environment

- **Platform**: OpenShift Container Platform (OCP)
- **Inference**: Red Hat MaaS (LiteLLM) → Claude Sonnet 4.6
- **Observability**: RHOAI-managed MLflow (traces + prompt registry) + OTel Collector + Tempo (infra logs/metrics only)
- **Auth**: OpenShift-native OAuth via oauth-proxy (browser UI, ADR-0016); Keycloak OIDC remains for the CLI/gRPC gateway path only

## Network Access (from sandbox)

| Endpoint | Purpose |
|---|---|
| `maas-rhdp.apps.maas.redhatworkshops.io:443` | LLM inference |
| `otel-collector.observability.svc:4317/4318` | OTel traces (infra logs/metrics) |
| `mlflow.redhat-ods-applications.svc:8443` | RHOAI-managed MLflow — agent traces + prompt registry (TLS, auth required) |

Everything else is blocked by the sandbox network policy.

## Add Your Notes

Add whatever helps you do your job. This is your cheat sheet.

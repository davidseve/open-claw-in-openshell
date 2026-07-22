# TOOLS.md - Local Notes

This file is for your specifics — the stuff that's unique to this deployment.

## Environment

- **Platform**: OpenShift Container Platform (OCP)
- **Inference**: Red Hat MaaS (LiteLLM) → Claude Sonnet 4.6
- **Observability**: MLflow + OTel Collector + Tempo
- **Auth**: Keycloak OIDC via oauth2-proxy

## Network Access (from sandbox)

| Endpoint | Purpose |
|---|---|
| `maas-rhdp.apps.maas.redhatworkshops.io:443` | LLM inference |
| `otel-collector.observability.svc:4317/4318` | OTel traces |
| `mlflow.observability.svc:5000` | MLflow traces |

Everything else is blocked by the sandbox network policy.

## Add Your Notes

Add whatever helps you do your job. This is your cheat sheet.

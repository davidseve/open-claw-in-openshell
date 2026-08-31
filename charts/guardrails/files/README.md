# NeMo Guardrails config files

Edit these files to change NeMo input/output rails:

- `prompts.yml` — self-check prompts (jailbreak / moderation)
- `rails.co` — Colang flows (built-in self-check rails)

`config.yaml` is **not** stored here; Helm renders it in
[`templates/configmap-nemo-config.yaml`](../templates/configmap-nemo-config.yaml)
from `values.yaml` and secrets (`MAAS_BASE_URL`, `INFERENCE_MODEL`, etc.).

After changes, redeploy:

```bash
make deploy-guardrails
```

See [ADR-0022](../../../docs/adrs/ADR-0022-nemo-guardrails-via-trustyai.md).

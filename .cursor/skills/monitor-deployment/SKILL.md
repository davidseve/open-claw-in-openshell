---
description: "Continuous health monitoring of the OpenClaw-in-OpenShell deployment using Loop Engineering. Runs verify.sh on a schedule, auto-repairs known failures, reports only changes."
user_invocable: true
---

# Monitor Deployment

Continuous health monitoring loop for a running OpenClaw-in-OpenShell deployment.
Uses the Cursor `/loop` pattern with project-specific auto-repair logic.

## Trigger

User says: `/monitor-deployment`, "monitor the deployment", "watch the cluster",
"keep checking health", or similar. Also activated when `deploy-full-crc` or
`deploy-full-aws` completes and the user asks to keep watching.

## Prerequisites

- Deployment completed (via `deploy-full-crc` or `deploy-full-aws`)
- `oc whoami` succeeds (logged into the cluster)
- `openshell status` succeeds (CLI connected to gateway)
- `scripts/verify.sh` runs successfully at least once



## How It Works

This skill follows the Cursor `/loop` skill pattern (fixed schedule mode) with
project-specific verification and auto-repair logic.

### Architecture

```
┌─────────────────────────────────────────────────┐
│  Background Shell (loop)                        │
│  while true; do                                 │
│    sleep <interval>                             │
│    echo 'AGENT_LOOP_TICK_DEPLOY_HEALTH {...}'   │
│  done                                           │
└──────────────────────┬──────────────────────────┘
                       │ notify_on_output
                       ▼
┌─────────────────────────────────────────────────┐
│  Agent (on wake)                                │
│  1. Refresh OIDC token if needed                │
│  2. Run scripts/verify.sh                       │
│  3. Compare result with last known state        │
│  4. If new failures → attempt auto-repair       │
│  5. If auto-repair fails → report to user       │
│  6. If all green → silent (no noise)            │
└─────────────────────────────────────────────────┘
```



## Execution



### Step 1: Parse Interval

Accept user-specified interval or default to 5 minutes.

Examples:

- `/monitor-deployment` → 5m (default)
- `/monitor-deployment 10m` → 10 minutes
- `/monitor-deployment 2m` → 2 minutes
- "monitor every 15 minutes" → 15m

Minimum: 2 minutes (verify.sh takes ~90 seconds to run).
Maximum: 60 minutes.

### Step 2: Baseline Run

Run `verify.sh` once immediately to establish the baseline state.

```bash
cd /home/dseveria/git/ai/agents/open-claw-in-openshell
bash scripts/verify.sh 2>&1
```

Parse the output and record:

- Total PASS / FAIL / WARN counts
- List of FAIL check names (if any)
- List of WARN check names
- Exit code

Save as `.monitor-state.json`:

```json
{
  "started": "ISO-8601",
  "interval_seconds": 300,
  "last_run": "ISO-8601",
  "last_exit_code": 0,
  "pass_count": 42,
  "fail_count": 0,
  "warn_count": 3,
  "failures": [],
  "warnings": ["warn name 1", "warn name 2"],
  "repair_attempts": {},
  "consecutive_green": 0,
  "total_ticks": 0
}
```

Report the baseline to the user briefly:

```
Monitoring armed (every 5m)
  Baseline: 42 passed, 0 failed, 3 warnings
  Next tick in 5 minutes
  Say "stop monitoring" to end
```



### Step 3: Arm the Loop

Start a background shell with `notify_on_output`:

```bash
while true; do
  sleep <interval_seconds>
  echo 'AGENT_LOOP_TICK_DEPLOY_HEALTH {"prompt":"verify deployment health"}'
done
```

Configuration:

- **Shell description**: `Loop every <interval>: verify deployment health`
- **block_until_ms**: `0` (immediate background)
- **notify_on_output**:
  - **pattern**: `^AGENT_LOOP_TICK_DEPLOY_HEALTH`
  - **reason**: `deploy health check`
  - **debounce_ms**: `60000`



### Step 4: On Each Tick

When the sentinel fires, the agent executes this procedure:

#### 4a. Refresh OIDC Token

OIDC tokens expire every 30 minutes (constraint #9 in `docs/constraints.md`).
Before running anything that uses `openshell` CLI, source `common.sh` and call
the idempotent refresh helper:

```bash
source scripts/common.sh
ensure_oidc_token
```

This checks `openshell status` and only refreshes if the token is expired.



#### 4b. Run Verification

```bash
bash scripts/verify.sh 2>&1
```

Parse the output. Extract PASS/FAIL/WARN counts and check names.

#### 4c. Compare with Last State

Read `.monitor-state.json` and compare:


| Condition                      | Action                                      |
| ------------------------------ | ------------------------------------------- |
| Same as before (all green)     | Silent. Increment `consecutive_green`.      |
| Same failures as before        | Silent. Already reported.                   |
| **New failure appeared**       | Attempt auto-repair (Step 5).               |
| **Previous failure recovered** | Report recovery to user.                    |
| **3 consecutive green runs**   | Report "stable" once, then go silent again. |




#### 4d. Update State

Write updated `.monitor-state.json` with new counts, timestamps, and tick number.

### Step 5: Auto-Repair

When a NEW failure is detected, the agent attempts to repair it automatically.
Each failure type has a maximum of 2 repair attempts per monitoring session.

#### Known Failure → Repair Mapping

These are the known failures and their documented fixes. Each maps directly to
a constraint in `docs/constraints.md` and a "HOW TO FIX" in `verify.sh`.


| Failure Pattern                            | Auto-Repair Command                                                                                                                                                                                                                     | Constraint |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| `/usr/local/bin/node exists`               | `oc exec $SANDBOX -c agent -- bash -c 'cp /usr/local/bin/node /usr/bin/node && rm -f /usr/local/bin/node'`                                                                                                                              | #2         |
| `Node.js fetch() to MaaS fails`            | Re-run `scripts/launch-openclaw.sh` (restarts gateway without HTTP_PROXY)                                                                                                                                                               | #3         |
| `Sandbox proxy denied MaaS`                | Check `openshell logs openclaw-gw`, then re-run `scripts/launch-openclaw.sh`                                                                                                                                                            | #2, #3     |
| `Gateway LLM auth failed`                  | Re-run `scripts/launch-openclaw.sh` (re-injects API key)                                                                                                                                                                                | #3         |
| `mlflow-openclaw plugin may not be loaded` | Re-run `scripts/launch-openclaw.sh` (reinstalls plugin)                                                                                                                                                                                 | #4, #5     |
| `No traces in MLflow`                      | Re-run `scripts/launch-openclaw.sh`                                                                                                                                                                                                     | #5         |
| `Prompt trace linker not running`          | `oc exec $SANDBOX -c agent -- bash -c 'MLFLOW_EXPERIMENT_ID=0 MLFLOW_URL=http://mlflow.observability.svc:5000 OPENCLAW_WORKSPACE_DIR=/sandbox/workspace nohup node /tmp/prompt-trace-linker.js > /sandbox/workspace/linker.log 2>&1 &'` | #8         |
| `OpenClaw health check failed`             | Re-run `scripts/launch-openclaw.sh`                                                                                                                                                                                                     | #6         |
| `CLI not connected to gateway`             | `source scripts/common.sh && ensure_oidc_token`                                                                                                                                                                                         | #9         |
| `oauth-proxy pod not ready`                | `oc -n openshell rollout restart deployment oauth-proxy`                                                                                                                                                                                | ADR-0016   |
| `Keycloak pod not Running`                 | `oc -n openshell-keycloak rollout restart deployment keycloak` (CLI/gRPC OIDC only, browser UI unaffected)                                                                                                                              | —          |
| `MLflow pod not ready`                     | `oc -n observability rollout restart deployment mlflow`                                                                                                                                                                                 | —          |
| `Service endpoint is not reachable`        | Re-run `scripts/launch-openclaw.sh` (starts gateway in sandbox namespace)                                                                                                                                                              | #11        |
| `tls handshake eof`                        | Wait 30s, retry — route stabilizing after helm upgrade                                                                                                                                                                                 | #12        |




#### Repair Procedure

1. Match the FAIL message against the table above
2. Check `repair_attempts` in `.monitor-state.json` — skip if already at max (2)
3. Execute the repair command
4. Wait 30 seconds for stabilization
5. Re-run `scripts/verify.sh`
6. If fixed → report recovery, reset `repair_attempts` for that failure
7. If still failing → increment `repair_attempts`, report to user



#### Unknown Failures

If the failure doesn't match any known pattern:

1. Do NOT attempt repair
2. Report the failure to the user with the exact FAIL line
3. Suggest: "Check `docs/constraints.md` and `verify.sh` layer comments for diagnosis"



### Step 6: Stopping

The loop stops when:

1. User says "stop monitoring", "stop the loop", or similar
2. Agent detects 10 consecutive green runs (stable — no point monitoring)
3. A failure can't be auto-repaired after 2 attempts (needs human intervention)

On stop:

1. Kill the background shell PID
2. Await the shell task to consume the completion notification
3. Report final state:
  ```
   Monitoring stopped
     Duration: Xh Ym
     Total ticks: N
     Final state: X passed, Y failed, Z warnings
     Repairs performed: N
  ```



## Boundaries

- Max 2 auto-repair attempts per failure type per session
- Never auto-repair unknown failures
- Never modify `verify.sh` or `launch-openclaw.sh` during monitoring
- Never skip token refresh — OIDC tokens expire (constraint #9)
- On `launch-openclaw.sh` re-run, wait 60 seconds before verify (gateway startup time)
- Do NOT report on every tick. Only report on state CHANGES (new failure, recovery, stable)
- Do NOT read script contents — just run them and parse output
- After killing the loop, ALWAYS await the shell to prevent stale wake notifications



## Interaction with deploy-full-crc / deploy-full-aws

After a successful deploy, the user may say "now monitor it" or just `/monitor-deployment`.
The agent should:

1. Read the deploy state from `.deploy-state.json` to understand the environment
2. Use the same `NAMESPACE`, `SANDBOX_NAME`, and `APPS_DOMAIN` as the deploy
3. Start monitoring without re-deploying

If the deploy failed, do NOT start monitoring. Tell the user to fix the deploy first.

## File Map


| File                         | Purpose                                            |
| ---------------------------- | -------------------------------------------------- |
| `scripts/verify.sh`          | The verification script executed on each tick      |
| `scripts/launch-openclaw.sh` | Primary repair action for sandbox/gateway failures |
| `scripts/configure-oidc.sh`  | OIDC token refresh                                 |
| `docs/constraints.md`        | Reference for all known sandbox constraints        |
| `.monitor-state.json`        | Persistent state for the monitoring loop           |
| `.deploy-state.json`         | Deploy state (read-only, for environment context)  |



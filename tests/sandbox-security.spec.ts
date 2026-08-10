/**
 * Sandbox security enforcement is validated deterministically in
 * `scripts/verify.sh` Layer 4 (and tools.deny in Layer 5) via
 * `openshell sandbox` / `sandbox_run` — not via LLM chat.
 *
 * Former tests here asked the model to run curl/sudo/nslookup and
 * pattern-matched natural-language refusals. That measured model
 * cooperativeness under gpt-oss, not proxy/Landlock/SCC policy, and
 * caused flaky Layer 9 failures while Layer 4 stayed green.
 *
 * Keep this file as a no-op project anchor so older docs/commands that
 * reference `--project=security-tests` do not break; it does not assert
 * sandbox policy. Re-introduce chat-level checks only for quality /
 * exfiltration-of-secrets via the UI (negative string asserts), not for
 * egress/sudo/IMDS/DNS.
 */
import { test } from '@playwright/test';

test.describe('Sandbox Security Validation', () => {
  test('deferred to verify.sh Layer 4 (deterministic sandbox_run)', async () => {
    test.info().annotations.push({
      type: 'note',
      description:
        'See scripts/verify.sh Layer 4: identity, egress, IMDS, sudo, arbitrary host, /etc/shadow, Landlock, credentials',
    });
  });
});

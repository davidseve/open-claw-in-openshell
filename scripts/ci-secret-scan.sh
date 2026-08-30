#!/usr/bin/env bash
# ci-secret-scan.sh — lightweight secret-pattern scan for GitHub Actions.
# Complements the no-secrets skill; skips docs and intentional test fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

should_skip_file() {
  local file="$1"
  case "$file" in
    *.env.example|secrets.template.env|secrets/secrets.template.env) return 0 ;;
    .github/workflows/*) return 0 ;;
    .cursor/skills/no-secrets/*) return 0 ;;
  esac
  return 1
}

is_placeholder_line() {
  local line="$1"
  [[ "$line" =~ (CHANGE_ME|REPLACE_ME|PLACEHOLDER|NOT_A_REAL|example\.com|your-token-here|xxx) ]]
}

patterns=(
  'AKIA[0-9A-Z]{16}'
  'ghp_[A-Za-z0-9]{20,}'
  'glpat-[A-Za-z0-9_-]{20,}'
  'sk-[A-Za-z0-9]{20,}'
  'BEGIN (RSA |OPENSSH )?PRIVATE KEY'
)

failed=0
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  should_skip_file "$file" && continue

  for pattern in "${patterns[@]}"; do
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      line="${hit#*:}"
      if is_placeholder_line "$line"; then
        continue
      fi
      echo "::error file=${file}::Possible secret matched pattern: ${pattern}"
      echo "$hit"
      failed=1
    done < <(grep -nE "$pattern" "$file" 2>/dev/null || true)
  done
done < <(git ls-files)

exit "$failed"

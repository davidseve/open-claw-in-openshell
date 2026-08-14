#!/usr/bin/env bash
# agent-run.sh — token-efficient wrapper for long-running scripts (Cursor + Claude Code)
#
# Canonical copy: ~/.local/share/long-running-scripts/agent-run.sh
# Vendor into repos: cp ~/.local/share/long-running-scripts/agent-run.sh scripts/lib/
#
# Usage:
#   source scripts/lib/agent-run.sh
#   agent_run "deploy-all" make deploy-all
#   agent_run "verify" env VERIFY_PROFILE=smoke ./scripts/verify.sh
#
# Environment:
#   AGENT_QUIET=1     Redirect verbose output to .logs/ (default: 1 when sourced for agent_run)
#   AGENT_STATUS_DIR  Default: .agent-status
#   AGENT_LOG_DIR     Default: .logs
set -euo pipefail

AGENT_STATUS_DIR="${AGENT_STATUS_DIR:-.agent-status}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-.logs}"
AGENT_QUIET="${AGENT_QUIET:-1}"

_agent_run_slug() {
  local s="$1"
  s="${s//[^a-zA-Z0-9._-]/-}"
  echo "${s}"
}

_agent_run_iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Public alias for scripts that manage their own body.
agent_run_now() {
  _agent_run_iso_now
}

_agent_run_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Emit AGENT_SCRIPT_DONE sentinel + write .agent-status/<slug>.json
agent_run_finish() {
  local script_name="$1"
  local exit_code="$2"
  local started_at="$3"
  local finished_at="$4"
  local log_file="${5:-}"
  local command_str="${6:-}"
  local summary="${7:-}"
  shift 7 || true
  local artifacts_json=""
  if [[ $# -gt 0 ]]; then
    artifacts_json="$1"
  fi

  local slug
  slug="$(_agent_run_slug "$script_name")"
  local status_file="${AGENT_STATUS_DIR}/${slug}.json"
  local duration=0
  if [[ -n "$started_at" && -n "$finished_at" ]]; then
    duration=$(python3 -c "
from datetime import datetime
s=datetime.fromisoformat('${started_at}'.replace('Z','+00:00'))
f=datetime.fromisoformat('${finished_at}'.replace('Z','+00:00'))
print(int((f-s).total_seconds()))
" 2>/dev/null || echo 0)
  fi

  mkdir -p "$AGENT_STATUS_DIR"
  {
    printf '{'
    printf '"script":"%s",' "$(_agent_run_json_escape "$script_name")"
    printf '"command":"%s",' "$(_agent_run_json_escape "$command_str")"
    printf '"startedAt":"%s",' "$started_at"
    printf '"finishedAt":"%s",' "$finished_at"
    printf '"durationSeconds":%s,' "$duration"
    printf '"exitCode":%s,' "$exit_code"
    if [[ -n "$log_file" ]]; then
      printf '"logFile":"%s",' "$(_agent_run_json_escape "$log_file")"
    fi
    printf '"summary":"%s"' "$(_agent_run_json_escape "$summary")"
    if [[ -n "$artifacts_json" ]]; then
      printf ',"artifacts":%s' "$artifacts_json"
    fi
    printf '}\n'
  } >"$status_file"

  local sentinel_payload
  sentinel_payload=$(printf '{"script":"%s","exitCode":%s,"durationSeconds":%s,"statusFile":"%s"}' \
    "$(_agent_run_json_escape "$script_name")" "$exit_code" "$duration" "$(_agent_run_json_escape "$status_file")")
  echo "AGENT_SCRIPT_DONE ${sentinel_payload}"
}

# Run a command with optional quiet logging and status emission.
# Args: script_name command [args...]
agent_run() {
  local script_name="$1"
  shift
  [[ $# -gt 0 ]] || { echo "agent_run: missing command" >&2; return 2; }

  local slug started_at finished_at log_file command_str exit_code summary
  slug="$(_agent_run_slug "$script_name")"
  started_at="$(_agent_run_iso_now)"
  mkdir -p "$AGENT_LOG_DIR" "$AGENT_STATUS_DIR"

  command_str=$(printf '%q ' "$@")
  command_str="${command_str%" "}"

  if [[ "$AGENT_QUIET" == "1" ]]; then
    log_file="${AGENT_LOG_DIR}/${slug}-$(date -u +%Y%m%dT%H%M%SZ).log"
    set +e
    {
      echo "==> agent_run: ${script_name}"
      echo "    command: ${command_str}"
      echo "    started: ${started_at}"
      echo "    log: ${log_file}"
      echo ""
      "$@"
    } >"$log_file" 2>&1
    exit_code=$?
    set -e
    # Progress lines only on stdout (token-efficient)
    echo "==> ${script_name} finished (exit ${exit_code}, log: ${log_file})"
  else
    log_file=""
    set +e
    "$@"
    exit_code=$?
    set -e
  fi

  finished_at="$(_agent_run_iso_now)"
  if [[ "$exit_code" -eq 0 ]]; then
    summary="OK"
  else
    summary="failed with exit ${exit_code}"
  fi

  agent_run_finish "$script_name" "$exit_code" "$started_at" "$finished_at" "$log_file" "$command_str" "$summary"
  return "$exit_code"
}

# Call at end of a script that manages its own logging (writes status + sentinel only).
agent_run_emit_status() {
  local script_name="$1"
  local exit_code="$2"
  local started_at="$3"
  local log_file="${4:-}"
  local command_str="${5:-}"
  local summary="${6:-}"
  local artifacts_json="${7:-}"
  local finished_at
  finished_at="$(_agent_run_iso_now)"
  if [[ -n "$artifacts_json" ]]; then
    agent_run_finish "$script_name" "$exit_code" "$started_at" "$finished_at" "$log_file" "$command_str" "$summary" "$artifacts_json"
  else
    agent_run_finish "$script_name" "$exit_code" "$started_at" "$finished_at" "$log_file" "$command_str" "$summary"
  fi
  return "$exit_code"
}

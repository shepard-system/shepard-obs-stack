#!/usr/bin/env bash
# hooks/claude/post-tool-use.sh — Claude Code PostToolUse hook
#
# Stdin JSON:
#   { "session_id", "tool_name", "tool_input", "tool_response", "tool_use_id",
#     "transcript_path", "cwd", "hook_event_name" }
#
# Emits: tool_calls_total + events_total counters to Prometheus via OTel Collector.
# Loki logs and Tempo traces are handled by Claude's native OTel export.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Rust accelerator: full hook replacement
source "${SCRIPT_DIR}/../lib/accelerator.sh"
if [[ -n "$SHEPARD_HOOK" ]]; then
  "$SHEPARD_HOOK" hook claude post-tool-use
  exit $?
fi
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"
source "${SCRIPT_DIR}/../lib/sensitive-patterns.sh"

input="$(cat)"

tool_name="$(jq -r '.tool_name // ""' <<< "$input")"
cwd="$(jq -r '.cwd // ""' <<< "$input")"

# Git context
get_git_context "$cwd"

# Sensitive file access detection
tool_input="$(jq -r '.tool_input // "{}" | if type == "string" then . else tostring end' <<< "$input" 2>/dev/null || echo "{}")"
sensitive_match=$(check_sensitive_access "$tool_input")
if [[ -n "$sensitive_match" ]]; then
  sens_labels=$(jq -n -c --arg s "claude-code" --arg t "$tool_name" --arg g "$GIT_REPO" \
    '{source:$s, tool:$t, git_repo:$g}')
  emit_counter "sensitive_file_access" "1" "$sens_labels"
fi

# Tool status: check tool_response for error patterns
tool_status="success"
tool_response="$(jq -r '.tool_response // "" | if type == "string" then . else tostring end' <<< "$input" 2>/dev/null || echo "")"
if echo "$tool_response" | grep -qiE '(^error|"error"|traceback|exit code [1-9]|command failed|FAILED|panic:)' 2>/dev/null; then
  tool_status="error"
fi

# Emit OTLP metrics for Prometheus
labels=$(jq -n -c --arg s "claude-code" --arg t "$tool_name" --arg ts "$tool_status" --arg g "$GIT_REPO" \
  '{source:$s, tool:$t, tool_status:$ts, git_repo:$g}')
emit_counter "tool_calls"  "1"  "$labels"
evt_labels=$(jq -n -c --arg s "claude-code" --arg e "tool_use" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events"      "1"  "$evt_labels"

exit 0

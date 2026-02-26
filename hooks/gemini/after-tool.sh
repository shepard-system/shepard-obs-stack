#!/usr/bin/env bash
# hooks/gemini/after-tool.sh — Gemini CLI AfterTool hook
#
# Gemini passes tool execution context on stdin (JSON).
# Env vars: GEMINI_SESSION_ID, GEMINI_PROJECT_DIR, GEMINI_CWD
#
# Must output valid JSON to stdout.
# Emits: tool_calls_total + events_total counters to Prometheus via OTel Collector.
# Loki logs and Tempo traces are handled by Gemini's native OTel export.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"

input="$(cat)"

tool_name="$(jq -r '.tool_name // .toolName // "unknown"' <<< "$input" 2>/dev/null || echo "unknown")"

cwd="$(jq -r '.cwd // ""' <<< "$input" 2>/dev/null)"
[[ -z "$cwd" ]] && cwd="${GEMINI_CWD:-${GEMINI_PROJECT_DIR:-}}"

# Git context
get_git_context "$cwd"

# Tool status: check tool_response for error patterns
tool_status="success"
tool_response="$(jq -r '.tool_response // "" | if type == "string" then . else tostring end' <<< "$input" 2>/dev/null || echo "")"
if echo "$tool_response" | grep -qiE '(^error|"error"|traceback|exit code [1-9]|command failed|FAILED|panic:)' 2>/dev/null; then
  tool_status="error"
fi

# Emit OTLP metrics for Prometheus
labels=$(jq -n -c --arg s "gemini-cli" --arg t "$tool_name" --arg ts "$tool_status" --arg g "$GIT_REPO" \
  '{source:$s, tool:$t, tool_status:$ts, git_repo:$g}')
emit_counter "tool_calls"  "1"  "$labels"
evt_labels=$(jq -n -c --arg s "gemini-cli" --arg e "tool_use" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events"      "1"  "$evt_labels"

# Gemini requires JSON output on stdout
echo '{}'
exit 0

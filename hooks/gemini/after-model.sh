#!/usr/bin/env bash
# hooks/gemini/after-model.sh — Gemini CLI AfterModel hook
#
# Fires on every LLM response. Only emits on the final chunk
# (when finishReason is set) to avoid flooding.
#
# Must output valid JSON to stdout.
# Emits: events_total counter to Prometheus via OTel Collector.
# Loki logs are handled by Gemini's native OTel export.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"

input="$(cat)"

# Only emit on final chunk (finishReason is set)
finish_reason="$(jq -r '.llm_response.candidates[0].finishReason // ""' <<< "$input" 2>/dev/null || echo "")"
[[ -z "$finish_reason" ]] && { echo '{}'; exit 0; }

cwd="$(jq -r '.cwd // ""' <<< "$input" 2>/dev/null)"
[[ -z "$cwd" ]] && cwd="${GEMINI_CWD:-${GEMINI_PROJECT_DIR:-}}"

# Git context
get_git_context "$cwd"

# Emit OTLP metrics for Prometheus
evt_labels=$(jq -n -c --arg s "gemini-cli" --arg e "model_call" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events"  "1"  "$evt_labels"

# Gemini requires JSON output on stdout
echo '{}'
exit 0

#!/usr/bin/env bash
# hooks/gemini/session-end.sh — Gemini CLI SessionEnd hook
#
# Stdin JSON:
#   { "session_id", "transcript_path", "cwd", "hook_event_name",
#     "timestamp", "reason" }
#
# Emits: events_total(session_end) counter to Prometheus via OTel Collector.
# All token/cost/session metrics come from Gemini's native OTel export.
# Must output valid JSON to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"

input="$(cat)"

cwd="$(jq -r '.cwd // ""' <<< "$input" 2>/dev/null)"
[[ -z "$cwd" ]] && cwd="${GEMINI_CWD:-${GEMINI_PROJECT_DIR:-}}"

# Git context
get_git_context "$cwd"

# Emit session_end event
evt_labels=$(jq -n -c --arg s "gemini-cli" --arg e "session_end" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events" "1" "$evt_labels"

# Gemini requires JSON output on stdout
echo '{}'
exit 0
